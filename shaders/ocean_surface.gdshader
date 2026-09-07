shader_type spatial;
render_mode cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx, blend_mix;

/*
 * Physically-Based Infinite Ocean Surface Shader
 * - 8-Wave Golden Ratio Gerstner Waves (Banishes artificial grid/checkerboard)
 * - Non-Periodic Organic Micro-Ripples
 * - Circular Smooth Alpha Fadeout (Eliminates square mesh corner artifacts)
 * - Seamless Sky Atmosphere Horizon Alignment
 * - GGX Solar Specular & Subsurface Scattering (SSS)
 * - Shoreline Contact & Crest Peak Foam
 * - Snell's Window for Underwater Look
 */

// ==========================================
// UNIFORMS: WAVE DYNAMICS
// ==========================================
group_uniforms Wave_Dynamics;
uniform float wave_amplitude : hint_range(0.0, 8.0, 0.05) = 1.1;
uniform float wave_length : hint_range(5.0, 150.0, 1.0) = 36.0;
uniform float wave_speed : hint_range(0.1, 4.0, 0.05) = 1.2;
uniform float wave_steepness : hint_range(0.0, 1.0, 0.02) = 0.55;
uniform vec2 primary_wind_dir = vec2(0.866, 0.5);

// ==========================================
// UNIFORMS: WATER OPTICS & COLORS
// ==========================================
group_uniforms Water_Optics;
uniform vec3 deep_water_color : source_color = vec3(0.012, 0.065, 0.14);
uniform vec3 shallow_water_color : source_color = vec3(0.08, 0.32, 0.42);
uniform vec3 sss_color : source_color = vec3(0.15, 0.75, 0.62);
uniform float sss_intensity : hint_range(0.0, 5.0, 0.1) = 2.2;
uniform float water_clarity : hint_range(1.0, 80.0, 1.0) = 22.0;
uniform vec3 absorption_coefficients = vec3(0.32, 0.07, 0.02);
uniform float surface_roughness : hint_range(0.01, 0.5, 0.01) = 0.06;

// ==========================================
// UNIFORMS: FOAM DYNAMICS
// ==========================================
group_uniforms Foam;
uniform vec3 foam_color : source_color = vec3(0.92, 0.95, 0.98);
uniform float crest_foam_threshold : hint_range(0.3, 1.0, 0.02) = 0.68;
uniform float crest_foam_intensity : hint_range(0.0, 3.0, 0.1) = 1.6;
uniform float contact_foam_distance : hint_range(0.1, 5.0, 0.1) = 1.4;

// ==========================================
// UNIFORMS: SUN & ATMOSPHERE LINK
// ==========================================
group_uniforms Sun_and_Atmosphere;
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.88);
uniform float sun_intensity : hint_range(0.0, 50.0, 0.1) = 22.0;
uniform vec3 sky_ambient_color : source_color = vec3(0.2, 0.4, 0.65);
uniform vec3 sky_horizon_color : source_color = vec3(0.65, 0.75, 0.85);

// ==========================================
// UNIFORMS: HORIZON & DISTANCE FADE
// ==========================================
group_uniforms Horizon_Blend;
uniform float fade_inner_radius : hint_range(500.0, 5000.0, 50.0) = 1400.0;
uniform float fade_outer_radius : hint_range(800.0, 6000.0, 50.0) = 2400.0;
uniform float custom_time = 0.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

varying vec3 v_world_pos;
varying vec3 v_analytical_normal;
varying float v_wave_crest;
varying float v_cam_dist;

// 8-Wave Gerstner Spectrum using Golden Ratio Angular Dispersion to banish any grid lattice
void evaluate_gerstner_8(vec2 pos, float time_val, out vec3 displacement, out vec3 normal, out float crest_factor) {
	vec3 disp = vec3(0.0);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);
	float crest_accum = 0.0;
	float total_amp = 0.0001;

	// Base wave propagation direction
	vec2 base_dir = normalize(primary_wind_dir);

	// Relative frequencies and amplitudes based on dispersion relation
	float freq_multipliers[8] = float[8](1.0, 1.414, 2.12, 3.25, 4.87, 7.31, 11.2, 17.5);
	float amp_multipliers[8]  = float[8](0.40, 0.24, 0.15, 0.09, 0.055, 0.032, 0.018, 0.010);
	// Golden Angle offsets (137.5 degrees) for complete non-periodic distribution
	float angle_offsets[8]    = float[8](0.0, 0.38, -0.45, 0.82, -0.95, 1.42, -1.55, 2.15);

	for (int i = 0; i < 8; i++) {
		float theta = angle_offsets[i];
		mat2 rot = mat2(vec2(cos(theta), -sin(theta)), vec2(sin(theta), cos(theta)));
		vec2 w_dir = normalize(rot * base_dir);

		float l = wave_length / freq_multipliers[i];
		float k = 6.2831853 / max(l, 0.1);
		float c = sqrt(9.81 / k) * wave_speed;
		float w = k * c;
		float a = wave_amplitude * amp_multipliers[i];
		total_amp += a;

		float q = (wave_steepness * 0.75) / (k * a * 8.0 + 0.0001);
		q = clamp(q, 0.0, 0.65);

		float phase = k * dot(w_dir, pos) - w * time_val;
		float cos_p = cos(phase);
		float sin_p = sin(phase);

		disp.x += w_dir.x * (q * a * cos_p);
		disp.z += w_dir.y * (q * a * cos_p);
		disp.y += a * sin_p;

		float wa = k * a;
		tangent.x -= w_dir.x * w_dir.x * (q * wa * sin_p);
		tangent.z -= w_dir.x * w_dir.y * (q * wa * sin_p);
		tangent.y += w_dir.x * (wa * cos_p);

		binormal.x -= w_dir.x * w_dir.y * (q * wa * sin_p);
		binormal.z -= w_dir.y * w_dir.y * (q * wa * sin_p);
		binormal.y += w_dir.y * (wa * cos_p);

		crest_accum += sin_p * a;
	}

	displacement = disp;
	normal = normalize(cross(binormal, tangent));
	crest_factor = clamp((disp.y + total_amp * 0.5) / (total_amp * 1.5), 0.0, 1.0);
}

// Procedural Organic Micro-Ripples (Dual Trochoidal Wavelets - No Checkers)
vec3 get_organic_ripples(vec2 pos, float time_val, float lod_fade) {
	if (lod_fade <= 0.01) return vec3(0.0, 1.0, 0.0);

	// Two non-orthogonal coordinate frames
	mat2 rot1 = mat2(vec2(0.866, -0.5), vec2(0.5, 0.866));
	mat2 rot2 = mat2(vec2(0.383, 0.924), vec2(-0.924, 0.383));

	vec2 p1 = rot1 * pos * 0.45 + primary_wind_dir * time_val * 0.35;
	vec2 p2 = rot2 * pos * 0.85 - vec2(-primary_wind_dir.y, primary_wind_dir.x) * time_val * 0.45;

	// Curvilinear wavelets
	float f1 = sin(p1.x + sin(p1.y * 1.3));
	float f2 = cos(p2.x * 1.4 - sin(p2.y * 1.1));

	vec2 d1 = vec2(cos(p1.x + sin(p1.y * 1.3)), cos(p1.y * 1.3) * 1.3) * 0.045;
	vec2 d2 = vec2(-sin(p2.x * 1.4 - sin(p2.y * 1.1)) * 1.4, cos(p2.y * 1.1) * 1.1) * 0.035;

	vec2 rip_xz = (rot1 * d1 + rot2 * d2) * lod_fade;
	return normalize(vec3(rip_xz.x, 1.0, rip_xz.y));
}

void vertex() {
	vec3 world_v = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float time_val = custom_time > 0.0 ? custom_time : TIME;

	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float cam_dist = length(world_v.xz - cam_pos.xz);
	v_cam_dist = cam_dist;

	// Smooth vertex wave fade towards boundary to seamlessly match flat sky ocean (y=0)
	float dist_wave_fade = smoothstep(fade_outer_radius, fade_inner_radius, cam_dist);

	vec3 disp;
	vec3 norm;
	float crest;
	evaluate_gerstner_8(world_v.xz, time_val, disp, norm, crest);

	disp *= dist_wave_fade;

	vec3 world_displaced = world_v + disp;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_displaced, 1.0)).xyz;

	v_world_pos = world_displaced;
	v_analytical_normal = norm;
	v_wave_crest = crest;
}

void fragment() {
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 V = normalize(cam_pos - v_world_pos);
	vec3 L = normalize(sun_direction);

	// Circular Alpha Fadeout: perfectly smooth circular dissipation well before square edges
	float circular_alpha = smoothstep(fade_outer_radius, fade_inner_radius, v_cam_dist);
	if (circular_alpha <= 0.001) {
		discard;
	}

	// Micro ripples LOD fade (flattens beyond 200m to eliminate glint aliasing)
	float ripple_lod = clamp(1.0 - v_cam_dist / 200.0, 0.0, 1.0);
	vec3 ripple_n = get_organic_ripples(v_world_pos.xz, time_val, ripple_lod);

	vec3 base_norm = normalize(v_analytical_normal);
	vec3 N = normalize(vec3(base_norm.x + ripple_n.x * 0.4, base_norm.y * ripple_n.y, base_norm.z + ripple_n.z * 0.4));

	// Distance normal flattening towards outer radius to match flat planetary sphere
	N = normalize(mix(vec3(0.0, 1.0, 0.0), N, circular_alpha));

	bool is_underwater = !FRONT_FACING || cam_pos.y < 0.0;
	if (is_underwater) {
		N = -N;
	}

	// Depth Buffer Interaction (Beer-Lambert & Contact Foam)
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec3 scene_pixel_pos = upos.xyz / upos.w;
	float scene_linear_depth = -scene_pixel_pos.z;
	float surface_linear_depth = -VERTEX.z;
	float water_depth = max(scene_linear_depth - surface_linear_depth, 0.0);

	vec3 depth_transmittance = exp(-absorption_coefficients * (water_depth / max(water_clarity * 0.25, 0.1)));
	vec3 water_body_color = mix(deep_water_color, shallow_water_color, clamp(depth_transmittance.y * 1.2, 0.0, 1.0));

	// Fresnel & Snell's Window
	float n1 = is_underwater ? 1.333 : 1.0;
	float n2 = is_underwater ? 1.0 : 1.333;
	float f0 = pow((n1 - n2) / (n1 + n2), 2.0);

	float NdotV = clamp(dot(N, V), 0.0, 1.0);
	float fresnel = f0 + (1.0 - f0) * pow(1.0 - NdotV, 5.0);

	if (is_underwater) {
		float critical_cos = sqrt(1.0 - (1.0 / (1.333 * 1.333)));
		if (NdotV < critical_cos) {
			fresnel = 1.0;
		}
	}

	// Subsurface Scattering (Wave Crest SSS)
	float sss_factor = pow(clamp(dot(V, -L), 0.0, 1.0), 3.5);
	float crest_sss_mask = smoothstep(0.4, 0.9, v_wave_crest);
	vec3 sss_light = sss_color * sss_intensity * sss_factor * crest_sss_mask * clamp(sun_direction.y * 2.0, 0.0, 1.0);

	// Foam
	float crest_foam = smoothstep(crest_foam_threshold, crest_foam_threshold + 0.18, v_wave_crest) * crest_foam_intensity;
	float contact_foam = 0.0;
	if (!is_underwater && water_depth < contact_foam_distance) {
		contact_foam = smoothstep(contact_foam_distance, 0.05, water_depth);
	}
	float total_foam = clamp(crest_foam + contact_foam, 0.0, 1.0);

	// Sun Specular (GGX)
	vec3 H = normalize(L + V);
	float NdotH = clamp(dot(N, H), 0.0, 1.0);
	float alpha = surface_roughness * surface_roughness;
	float alpha2 = alpha * alpha;
	float denom = (NdotH * NdotH * (alpha2 - 1.0) + 1.0);
	float D = alpha2 / (3.14159265 * denom * denom + 0.0001);

	float k_spec = (surface_roughness + 1.0) * (surface_roughness + 1.0) / 8.0;
	float NdotL = clamp(dot(N, L), 0.0, 1.0);
	float g_v = NdotV / (NdotV * (1.0 - k_spec) + k_spec);
	float g_l = NdotL / (NdotL * (1.0 - k_spec) + k_spec);
	float G = g_v * g_l;

	float ggx_spec = (D * G * fresnel) / max(4.0 * NdotV * NdotL, 0.001);
	vec3 sun_specular_energy = sun_color * sun_intensity * ggx_spec * clamp(NdotL, 0.0, 1.0);

	// Sky Environment Reflection
	vec3 R = reflect(-V, N);
	float sky_elevation = clamp(R.y, 0.0, 1.0);
	vec3 sky_reflected = mix(sky_horizon_color, sky_ambient_color, pow(sky_elevation, 0.5));

	vec3 refracted_scene = texture(screen_texture, SCREEN_UV).rgb;
	vec3 water_composite = mix(refracted_scene * depth_transmittance, water_body_color, 1.0 - depth_transmittance.y * 0.7);

	vec3 surface_color = mix(water_composite, sky_reflected, fresnel);
	surface_color += sss_light;
	surface_color += sun_specular_energy;
	surface_color = mix(surface_color, foam_color, total_foam);

	ALBEDO = surface_color;
	ROUGHNESS = mix(surface_roughness, 0.85, total_foam);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	NORMAL = (VIEW_MATRIX * vec4(N, 0.0)).xyz;

	// Alpha fadeout: smooth circular fade to let sky planetary ocean seamlessly take over
	ALPHA = circular_alpha;
}
