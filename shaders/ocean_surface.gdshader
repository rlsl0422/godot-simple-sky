shader_type spatial;
render_mode cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

/*
 * Physically-Based Infinite Ocean Surface Shader
 * - 4-Octave Gerstner Wave 3D Displacement & Analytical Normals
 * - Dual Procedural Micro-Ripples
 * - GGX Solar Specular & Sky Horizon Reflection
 * - Wave Crest Subsurface Scattering (SSS)
 * - Depth-Buffer Beer-Lambert Absorption & Shoreline Foam
 * - Crest Peak Foam Generation
 * - Two-Sided Snell's Window & Total Internal Reflection for Underwater Look
 */

// ==========================================
// UNIFORMS: WAVE DYNAMICS (GERSTNER)
// ==========================================
group_uniforms Wave_Dynamics;
uniform float wave_amplitude : hint_range(0.0, 10.0, 0.05) = 1.2;
uniform float wave_length : hint_range(5.0, 200.0, 1.0) = 35.0;
uniform float wave_speed : hint_range(0.1, 5.0, 0.05) = 1.2;
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
uniform vec3 absorption_coefficients = vec3(0.32, 0.07, 0.02); // Red, Green, Blue extinction per meter
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
uniform float mesh_radius : hint_range(500.0, 10000.0, 100.0) = 3500.0;
uniform float horizon_fade_distance : hint_range(200.0, 3000.0, 50.0) = 1200.0;
uniform float custom_time = 0.0;

// Textures for scene depth and color sampling
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

// Varyings passed to fragment
varying vec3 v_world_pos;
varying vec3 v_analytical_normal;
varying float v_wave_crest;
varying float v_cam_dist;

// 4-Wave Gerstner Wave Structure
struct Wave {
	vec2 dir;
	float amplitude;
	float length;
	float speed;
	float steepness;
};

void evaluate_gerstner(vec2 pos, float time_val, out vec3 displacement, out vec3 normal, out float crest_factor) {
	// 4 harmonic octaves derived from base parameters
	Wave waves[4];
	
	vec2 d0 = normalize(primary_wind_dir);
	// Slight angular spreads for realistic sea chop
	vec2 d1 = normalize(vec2(d0.x * 0.92 - d0.y * 0.38, d0.x * 0.38 + d0.y * 0.92));
	vec2 d2 = normalize(vec2(d0.x * 0.82 + d0.y * 0.57, -d0.x * 0.57 + d0.y * 0.82));
	vec2 d3 = normalize(vec2(-d0.y, d0.x) * 0.7 + d0 * 0.7);

	waves[0] = Wave(d0, wave_amplitude * 0.52, wave_length * 1.00, wave_speed * 1.00, wave_steepness);
	waves[1] = Wave(d1, wave_amplitude * 0.28, wave_length * 0.52, wave_speed * 1.25, wave_steepness * 1.1);
	waves[2] = Wave(d2, wave_amplitude * 0.14, wave_length * 0.24, wave_speed * 1.60, wave_steepness * 1.2);
	waves[3] = Wave(d3, wave_amplitude * 0.06, wave_length * 0.11, wave_speed * 2.10, wave_steepness * 1.3);

	vec3 disp = vec3(0.0);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);
	float crest_accum = 0.0;
	float total_amp = 0.0001;

	for (int i = 0; i < 4; i++) {
		float k = 6.2831853 / max(waves[i].length, 0.1);
		float c = sqrt(9.81 / k) * waves[i].speed;
		float w = k * c;
		float a = waves[i].amplitude;
		total_amp += a;
		
		// Gerstner Q parameter: clamped to prevent wave loop self-intersection
		float q = waves[i].steepness / (k * a * 4.0 + 0.0001);
		q = clamp(q, 0.0, 0.75);

		float phase = k * dot(waves[i].dir, pos) - w * time_val;
		float cos_p = cos(phase);
		float sin_p = sin(phase);

		disp.x += waves[i].dir.x * (q * a * cos_p);
		disp.z += waves[i].dir.y * (q * a * cos_p);
		disp.y += a * sin_p;

		// Analytical Derivatives for exact normal calculation
		float wa = k * a;
		tangent.x -= waves[i].dir.x * waves[i].dir.x * (q * wa * sin_p);
		tangent.z -= waves[i].dir.x * waves[i].dir.y * (q * wa * sin_p);
		tangent.y += waves[i].dir.x * (wa * cos_p);

		binormal.x -= waves[i].dir.x * waves[i].dir.y * (q * wa * sin_p);
		binormal.z -= waves[i].dir.y * waves[i].dir.y * (q * wa * sin_p);
		binormal.y += waves[i].dir.y * (wa * cos_p);

		// Wave crest indicator: sharper crest peaks have higher values
		crest_accum += sin_p * a;
	}

	displacement = disp;
	normal = normalize(cross(binormal, tangent));
	crest_factor = clamp((disp.y + total_amp * 0.5) / (total_amp * 1.5), 0.0, 1.0);
}

// Procedural micro-ripples normal (Dual-scrolling high frequency)
vec3 get_micro_ripples(vec2 world_xz, float time_val, float lod_fade) {
	vec2 uv1 = world_xz * 0.12 + primary_wind_dir * time_val * 0.08;
	vec2 uv2 = world_xz * 0.28 - vec2(-primary_wind_dir.y, primary_wind_dir.x) * time_val * 0.12;

	vec2 d1 = vec2(cos(uv1.x * 4.0), -sin(uv1.y * 3.0)) * 0.05;
	vec2 d2 = vec2(-sin(uv2.x * 6.0), cos(uv2.y * 4.0)) * 0.03;

	vec2 ripple_norm_xz = (d1 + d2) * lod_fade;
	return normalize(vec3(ripple_norm_xz.x, 1.0, ripple_norm_xz.y));
}

void vertex() {
	// Base world position from transform
	vec3 world_v = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float time_val = custom_time > 0.0 ? custom_time : TIME;

	// Distance from camera for progressive wave LOD
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float cam_dist = length(world_v.xz - cam_pos.xz);
	v_cam_dist = cam_dist;

	// Progressive wave attenuation at far distances to prevent horizon aliasing
	float dist_fade = clamp(1.0 - (cam_dist - (mesh_radius - horizon_fade_distance)) / max(horizon_fade_distance, 1.0), 0.0, 1.0);

	vec3 disp;
	vec3 norm;
	float crest;
	evaluate_gerstner(world_v.xz, time_val, disp, norm, crest);

	disp *= dist_fade;

	// Apply displacement to vertex in local space
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

	// Distance LOD for micro ripples: smoothly flattens out beyond 250m to avoid speckle noise
	float ripple_lod = clamp(1.0 - v_cam_dist / 250.0, 0.0, 1.0);
	vec3 ripple_n = get_micro_ripples(v_world_pos.xz, time_val, ripple_lod);

	// Blend analytical Gerstner normal with procedural ripples in tangent/world space
	vec3 base_norm = normalize(v_analytical_normal);
	vec3 N = normalize(vec3(base_norm.x + ripple_n.x * 0.45, base_norm.y * ripple_n.y, base_norm.z + ripple_n.z * 0.45));

	// Distance fade to true flat UP vector near mesh perimeter for seamless sky blend
	float perimeter_fade = clamp((mesh_radius - v_cam_dist) / max(horizon_fade_distance, 1.0), 0.0, 1.0);
	N = normalize(mix(vec3(0.0, 1.0, 0.0), N, perimeter_fade));

	// ==========================================
	// TWO-SIDED HANDLING (Underwater View: Snell's Window)
	// ==========================================
	bool is_underwater = !FRONT_FACING || cam_pos.y < 0.0;
	if (is_underwater) {
		N = -N; // Flip normal for looking up at the water surface from below
	}

	// ==========================================
	// DEPTH BUFFER INTERACTION (Beer-Lambert & Contact Foam)
	// ==========================================
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec3 scene_pixel_pos = upos.xyz / upos.w;
	float scene_linear_depth = -scene_pixel_pos.z;
	float surface_linear_depth = -VERTEX.z;
	float water_depth = max(scene_linear_depth - surface_linear_depth, 0.0);

	// Beer-Lambert light extinction through water column:
	// Red wavelengths are strongly absorbed first, leaving deep blue-greens
	vec3 depth_transmittance = exp(-absorption_coefficients * (water_depth / max(water_clarity * 0.25, 0.1)));
	vec3 water_body_color = mix(deep_water_color, shallow_water_color, clamp(depth_transmittance.y * 1.2, 0.0, 1.0));

	// ==========================================
	// OPTICAL PHENOMENA: FRESNEL & SNELL'S WINDOW
	// ==========================================
	float n1 = is_underwater ? 1.333 : 1.0;
	float n2 = is_underwater ? 1.0 : 1.333;
	float f0 = pow((n1 - n2) / (n1 + n2), 2.0); // ~0.02

	float NdotV = clamp(dot(N, V), 0.0, 1.0);
	float fresnel = f0 + (1.0 - f0) * pow(1.0 - NdotV, 5.0);

	if (is_underwater) {
		// Total Internal Reflection (TIR): Critical angle ~48.6 degrees
		// Outside the cone (Snell's window), light undergoes 100% total internal reflection of deep water
		float critical_cos = sqrt(1.0 - (1.0 / (1.333 * 1.333))); // ~0.661
		if (NdotV < critical_cos) {
			fresnel = 1.0; // Total internal reflection
		}
	}

	// ==========================================
	// SUBSURFACE SCATTERING (Wave Crest Backlight Transmission)
	// ==========================================
	// Looking into the sun through a wave crest produces brilliant turquoise back-illumination
	float sss_factor = pow(clamp(dot(V, -L), 0.0, 1.0), 3.5);
	float crest_sss_mask = smoothstep(0.4, 0.9, v_wave_crest);
	vec3 sss_light = sss_color * sss_intensity * sss_factor * crest_sss_mask * clamp(sun_direction.y * 2.0, 0.0, 1.0);

	// ==========================================
	// FOAM GENERATION (Crest Foam & Contact Foam)
	// ==========================================
	// 1. Crest peak foam (breaking waves at sharp tops)
	float crest_foam = smoothstep(crest_foam_threshold, crest_foam_threshold + 0.18, v_wave_crest) * crest_foam_intensity;
	
	// 2. Contact foam (shoreline & intersecting geometry)
	float contact_foam = 0.0;
	if (!is_underwater && water_depth < contact_foam_distance) {
		float foam_noise = sin(v_world_pos.x * 2.0 + time_val * 2.5) * cos(v_world_pos.z * 2.0 - time_val * 1.8);
		contact_foam = smoothstep(contact_foam_distance, 0.05, water_depth) * (0.8 + 0.2 * foam_noise);
	}
	float total_foam = clamp(crest_foam + contact_foam, 0.0, 1.0) * perimeter_fade;

	// ==========================================
	// SUN SPECULAR (Microfacet GGX)
	// ==========================================
	vec3 H = normalize(L + V);
	float NdotH = clamp(dot(N, H), 0.0, 1.0);
	float alpha = surface_roughness * surface_roughness;
	float alpha2 = alpha * alpha;
	float denom = (NdotH * NdotH * (alpha2 - 1.0) + 1.0);
	float D = alpha2 / (3.14159265 * denom * denom + 0.0001);
	
	// Geometric shadowing (Smith)
	float k_spec = (surface_roughness + 1.0) * (surface_roughness + 1.0) / 8.0;
	float NdotL = clamp(dot(N, L), 0.0, 1.0);
	float g_v = NdotV / (NdotV * (1.0 - k_spec) + k_spec);
	float g_l = NdotL / (NdotL * (1.0 - k_spec) + k_spec);
	float G = g_v * g_l;
	
	float ggx_spec = (D * G * fresnel) / max(4.0 * NdotV * NdotL, 0.001);
	vec3 sun_specular_energy = sun_color * sun_intensity * ggx_spec * clamp(NdotL, 0.0, 1.0);

	// ==========================================
	// SKY ENVIRONMENT REFLECTION
	// ==========================================
	vec3 R = reflect(-V, N);
	float sky_elevation = clamp(R.y, 0.0, 1.0);
	vec3 sky_reflected = mix(sky_horizon_color, sky_ambient_color, pow(sky_elevation, 0.5));

	// Refracted scene color from underwater
	vec3 refracted_scene = texture(screen_texture, SCREEN_UV).rgb;
	// Mix water body with refracted bottom
	vec3 water_composite = mix(refracted_scene * depth_transmittance, water_body_color, 1.0 - depth_transmittance.y * 0.7);

	// Final surface composite: Water Base + Sky Reflection via Fresnel + SSS + Sun Specular + Foam
	vec3 surface_color = mix(water_composite, sky_reflected, fresnel);
	surface_color += sss_light;
	surface_color += sun_specular_energy;
	surface_color = mix(surface_color, foam_color, total_foam);

	// Fade outer edges to horizon color to blend with sky dome
	vec3 final_color = mix(sky_horizon_color, surface_color, perimeter_fade);

	// Godot PBR Material outputs
	ALBEDO = final_color;
	ROUGHNESS = mix(surface_roughness, 0.85, total_foam);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	NORMAL = (VIEW_MATRIX * vec4(N, 0.0)).xyz;
}
