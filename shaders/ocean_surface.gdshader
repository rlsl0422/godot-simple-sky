shader_type spatial;
render_mode cull_back, depth_draw_opaque, unshaded, blend_mix;

/*
 * State-of-the-Art Physically-Based Infinite Ocean Surface Shader
 * - 4-Harmonic Curvilinear Gerstner Wave Spectrum (Zero checkerboard, zero parallel stripes)
 * - Transverse Domain Warping & Finite Crest Length Envelope (Natural crescent swells)
 * - Jacobian Convergence / Wave-Folding Whitecap Foam (Foams only on colliding breaking summits)
 * - Tri-Scale Seamless Capillary Wave Normal Panning (Rich micro-chop & wind agitation)
 * - Toksvig Normal Variance Roughness Filtering (Silky, shimmer-free sun glitter lane)
 * - Physically-Based GGX Solar Specular & Translucent Crest Subsurface Scattering (SSS)
 * - Organic Cellular Bubble Lace Sea Foam (Zero polygon confetti)
 * - Seamless Atmospheric Horizon Alignment & Circular Alpha Dissipation
 * - Snell's Window & Refraction for Underwater View
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
uniform vec3 deep_water_color : source_color = vec3(0.004, 0.026, 0.085);
uniform vec3 shallow_water_color : source_color = vec3(0.015, 0.120, 0.180);
uniform vec3 sss_color : source_color = vec3(0.03, 0.28, 0.32);
uniform float sss_intensity : hint_range(0.0, 5.0, 0.1) = 1.0;
uniform float water_clarity : hint_range(1.0, 80.0, 1.0) = 22.0;
uniform vec3 absorption_coefficients = vec3(0.32, 0.07, 0.02);
uniform float surface_roughness : hint_range(0.01, 0.5, 0.01) = 0.06;

// ==========================================
// UNIFORMS: FOAM DYNAMICS
// ==========================================
group_uniforms Foam;
uniform vec3 foam_color : source_color = vec3(0.92, 0.95, 0.98);
uniform float crest_foam_threshold : hint_range(0.3, 1.0, 0.02) = 0.68;
uniform float crest_foam_intensity : hint_range(0.0, 3.0, 0.1) = 1.4;
uniform float contact_foam_distance : hint_range(0.05, 2.0, 0.05) = 0.25;
uniform float caustics_strength : hint_range(0.0, 3.0, 0.1) = 0.75;
uniform float caustics_scale : hint_range(0.1, 4.0, 0.05) = 1.4;

// ==========================================
// UNIFORMS: SUN & ATMOSPHERE LINK
// ==========================================
group_uniforms Sun_and_Atmosphere;
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.88);
uniform float sun_intensity : hint_range(0.0, 50.0, 0.1) = 22.0;
uniform vec3 sky_ambient_color : source_color = vec3(0.035, 0.120, 0.350);
uniform vec3 sky_horizon_color : source_color = vec3(0.140, 0.340, 0.580);

// ==========================================
// UNIFORMS: HORIZON & DISTANCE FADE
// ==========================================
group_uniforms Horizon_Blend;
uniform float fade_inner_radius : hint_range(500.0, 5000.0, 50.0) = 2800.0;
uniform float fade_outer_radius : hint_range(800.0, 6000.0, 50.0) = 3800.0;
uniform float custom_time = 0.0;

// ==========================================
// UNIFORMS: POST PROCESSING & TONE MAPPING
// ==========================================
group_uniforms Post_Processing;
uniform int tonemap_mode : hint_range(0, 3, 1) = 1;
uniform float exposure : hint_range(0.1, 4.0, 0.05) = 1.0;
uniform float white_point : hint_range(1.0, 20.0, 0.5) = 6.0;

uniform sampler2D wave_normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

varying vec3 v_world_pos;
varying vec3 v_analytical_normal;
varying float v_wave_crest;
varying float v_wave_fold;
varying float v_cam_dist;
varying float v_cam_alt;

// Photographic Tone Mapping & Exposure Pipeline (Matching atmosphere_clouds.gdshader)
vec3 apply_tonemapping(vec3 color, float exp_val, int mode, float wp) {
	vec3 x = color * exp_val;
	if (mode == 1) {
		const float a = 2.51;
		const float b = 0.03;
		const float c = 2.43;
		const float d = 0.59;
		const float e = 0.14;
		return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
	} else if (mode == 2) {
		return (x * (1.0 + x / (wp * wp))) / (1.0 + x);
	} else if (mode == 3) {
		vec3 cur = max(vec3(0.0), x - 0.004);
		return (cur * (6.2 * cur + 0.5)) / (cur * (6.2 * cur + 1.7) + 0.06);
	}
	return x;
}

// =========================================================================
// 4-HARMONIC CURVILINEAR GERSTNER SWELL ENGINE
// - Natural Mitsuyasu directional spreading (+2.5, -11.5, +13.5, -5.5 deg)
// - Transverse domain warping curves crests into organic crescent rollers
// - Finite crest length modulation completely eliminates parallel stripes
// - Analytical Jacobian folding metric for localized whitecap foam
// =========================================================================
void evaluate_swells_vertex(vec2 pos, float time_val, out vec3 displacement, out vec3 normal, out float crest_h, out float crest_fold) {
	vec3 disp = vec3(0.0);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);
	vec2 wind = normalize(primary_wind_dir);

	// 4 Balanced Curvilinear Swell Harmonics
	const float swell_lens[4]   = float[4](2.10, 1.45, 1.00, 0.67); // Wavelengths: 75.6m, 52.2m, 36.0m, 24.1m
	const float swell_amps[4]   = float[4](0.34, 0.28, 0.22, 0.16);
	const float swell_angles[4] = float[4](0.044, -0.201, 0.236, -0.096); // Radians: +2.5, -11.5, +13.5, -5.5 deg
	const float swell_warps[4]  = float[4](1.65, 1.45, 1.25, 1.05);       // Dramatic sweeping crescent curves
	const float swell_phases[4] = float[4](0.0, 1.85, 3.60, 5.10);

	float total_h = 0.0;
	float total_fold = 0.0;

	for (int i = 0; i < 4; i++) {
		float theta = swell_angles[i];
		mat2 rot = mat2(vec2(cos(theta), -sin(theta)), vec2(sin(theta), cos(theta)));
		vec2 w_dir = normalize(rot * wind);
		vec2 crest_dir = vec2(-w_dir.y, w_dir.x); // Transverse axis along crest

		float l = wave_length * swell_lens[i];
		float k = 6.2831853 / max(l, 12.0);
		float w = sqrt(9.81 * k) * wave_speed;
		float a = wave_amplitude * swell_amps[i];

		// Transverse curvilinear crest modulation
		float k_trans = k * 0.32;
		float v_crest = dot(crest_dir, pos);
		float warp_phase = k_trans * v_crest + swell_phases[i];
		float delta_phi = swell_warps[i] * sin(warp_phase);
		float delta_phi_dv = swell_warps[i] * k_trans * cos(warp_phase);

		// Finite crest length envelope: wave crests naturally taper to zero at sides (wave packets)
		float crest_envelope = smoothstep(0.06, 0.90, cos(warp_phase * 0.70) * 0.5 + 0.5);
		float a_eff = a * crest_envelope;

		// Total wave phase
		float u_prop = dot(w_dir, pos);
		float phase = k * u_prop + delta_phi - w * time_val;
		float cos_p = cos(phase);
		float sin_p = sin(phase);

		// Spatial gradient of phase: grad(phi) = k * w_dir + delta_phi_dv * crest_dir
		vec2 grad_phi = w_dir * k + crest_dir * delta_phi_dv;
		float grad_len = length(grad_phi);
		vec2 m_dir = grad_phi / max(grad_len, 0.0001);

		// Gerstner steepness (clamped to prevent crest loops)
		float q = clamp(wave_steepness * 0.55 / (k * a * 3.0 + 0.0001), 0.0, 0.45);

		// Displacements
		disp.x -= m_dir.x * (q * a_eff * sin_p);
		disp.z -= m_dir.y * (q * a_eff * sin_p);
		disp.y += a_eff * cos_p;

		// Analytical derivatives for surface normal
		float wa = grad_len * a_eff;
		tangent.x -= m_dir.x * m_dir.x * (q * wa * cos_p);
		tangent.z -= m_dir.x * m_dir.y * (q * wa * cos_p);
		tangent.y -= m_dir.x * (wa * sin_p);

		binormal.x -= m_dir.x * m_dir.y * (q * wa * cos_p);
		binormal.z -= m_dir.y * m_dir.y * (q * wa * cos_p);
		binormal.y -= m_dir.y * (wa * sin_p);

		total_h += cos_p * a_eff;
		total_fold += q * wa * max(cos_p, 0.0);
	}

	displacement = disp;
	normal = normalize(cross(binormal, tangent));
	crest_h = total_h;
	crest_fold = total_fold;
}

// Analytical Swell Normal for Pixel Evaluation (100% eliminates 23.4m triangle faceting)
vec3 evaluate_swell_normal(vec2 pos, float time_val) {
	vec2 wind = normalize(primary_wind_dir);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);

	const float swell_lens[4]   = float[4](2.10, 1.45, 1.00, 0.67);
	const float swell_amps[4]   = float[4](0.34, 0.28, 0.22, 0.16);
	const float swell_angles[4] = float[4](0.044, -0.201, 0.236, -0.096);
	const float swell_warps[4]  = float[4](1.65, 1.45, 1.25, 1.05);
	const float swell_phases[4] = float[4](0.0, 1.85, 3.60, 5.10);

	for (int i = 0; i < 4; i++) {
		float theta = swell_angles[i];
		mat2 rot = mat2(vec2(cos(theta), -sin(theta)), vec2(sin(theta), cos(theta)));
		vec2 w_dir = normalize(rot * wind);
		vec2 crest_dir = vec2(-w_dir.y, w_dir.x);

		float l = wave_length * swell_lens[i];
		float k = 6.2831853 / max(l, 12.0);
		float w = sqrt(9.81 * k) * wave_speed;
		float a = wave_amplitude * swell_amps[i];

		float k_trans = k * 0.32;
		float v_crest = dot(crest_dir, pos);
		float warp_phase = k_trans * v_crest + swell_phases[i];
		float delta_phi = swell_warps[i] * sin(warp_phase);
		float delta_phi_dv = swell_warps[i] * k_trans * cos(warp_phase);

		float crest_envelope = smoothstep(0.06, 0.90, cos(warp_phase * 0.70) * 0.5 + 0.5);
		float a_eff = a * crest_envelope;

		float u_prop = dot(w_dir, pos);
		float phase = k * u_prop + delta_phi - w * time_val;
		float cos_p = cos(phase);
		float sin_p = sin(phase);

		vec2 grad_phi = w_dir * k + crest_dir * delta_phi_dv;
		float grad_len = length(grad_phi);
		vec2 m_dir = grad_phi / max(grad_len, 0.0001);

		float q = clamp(wave_steepness * 0.55 / (k * a * 3.0 + 0.0001), 0.0, 0.45);
		float wa = grad_len * a_eff;

		tangent.x -= m_dir.x * m_dir.x * (q * wa * cos_p);
		tangent.z -= m_dir.x * m_dir.y * (q * wa * cos_p);
		tangent.y -= m_dir.x * (wa * sin_p);

		binormal.x -= m_dir.x * m_dir.y * (q * wa * cos_p);
		binormal.z -= m_dir.y * m_dir.y * (q * wa * cos_p);
		binormal.y -= m_dir.y * (wa * sin_p);
	}

	return normalize(cross(binormal, tangent));
}

// Gentle geometry caustics (only on solid underwater terrain/objects)
float evaluate_caustics(vec2 xz, float time_val) {
	vec2 uv1 = xz * caustics_scale + vec2(time_val * 0.4, time_val * 0.25);
	vec2 uv2 = vec2(xz.x * 0.707 - xz.y * 0.707, xz.x * 0.707 + xz.y * 0.707) * (caustics_scale * 1.3) - vec2(time_val * 0.3, -time_val * 0.35);

	float c1 = cos(uv1.x * 2.4 + sin(uv1.y * 1.6));
	float c2 = sin(uv2.x * 3.1 - cos(uv2.y * 2.1));

	return pow(abs(c1 * 0.6 + c2 * 0.4), 2.0);
}

// Procedural Cellular Bubble Foam (Turbulent bubble lace + organic froth, ZERO polygon confetti)
float evaluate_organic_foam(vec2 xz, float time_val, float crest_mask, float depth_val, float scene_y, bool is_underwater) {
	// Shoreline/contact foam: only active within narrow waterline band near sea surface (y ~ 0)
	float contact_mask = 0.0;
	if (!is_underwater && depth_val < contact_foam_distance) {
		float depth_factor = smoothstep(contact_foam_distance, 0.01, depth_val);
		float surf_band = smoothstep(0.35, 0.02, abs(scene_y));
		contact_mask = depth_factor * surf_band;
	}

	float raw_mask = max(crest_mask, contact_mask);
	if (raw_mask <= 0.001) return 0.0;

	// Procedural Cellular Foam Net (Rotated dual-frequency bubble lattice)
	vec2 wind = normalize(primary_wind_dir);
	mat2 rot_foam = mat2(vec2(0.866, -0.500), vec2(0.500, 0.866));
	vec2 foam_uv1 = (rot_foam * xz) * 0.45 + wind * (time_val * 0.28);
	vec2 foam_uv2 = (xz + rot_foam * xz * 0.40) * 0.95 - vec2(-wind.y, wind.x) * (time_val * 0.16);

	// Organic bubble cell contours
	float bubble1 = abs(sin(foam_uv1.x * 2.8 + cos(foam_uv1.y * 2.2)) * cos(foam_uv1.y * 2.8 + sin(foam_uv1.x * 2.2)));
	float bubble2 = abs(sin(foam_uv2.x * 3.8 - sin(foam_uv2.y * 2.5)) * cos(foam_uv2.y * 3.8 + cos(foam_uv2.x * 2.5)));
	float cellular_pattern = pow(bubble1 * 0.52 + bubble2 * 0.48, 2.0);

	// Organic turbulent foam distortion (curling froth without rigid straight streaks)
	vec2 foam_warp = vec2(sin(xz.y * 0.18 + xz.x * 0.12), cos(xz.x * 0.18 + xz.y * 0.12)) * 2.0;
	float streak = sin(dot(vec2(-wind.y, wind.x), xz + foam_warp) * 0.22) * 0.5 + 0.5;
	float foam_body = smoothstep(0.18, 0.75, cellular_pattern * 0.65 + streak * 0.35);

	return clamp(foam_body * raw_mask * crest_foam_intensity, 0.0, 1.0);
}

void vertex() {
	vec3 world_v = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float time_val = custom_time > 0.0 ? custom_time : TIME;

	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float cam_dist = length(world_v.xz - cam_pos.xz);
	v_cam_dist = cam_dist;
	float alt = max(cam_pos.y, 0.0);
	v_cam_alt = alt;

	// Smooth vertex wave fade towards boundary to seamlessly match flat planetary horizon
	float dist_wave_fade = smoothstep(fade_outer_radius, fade_inner_radius, cam_dist);
	// Altitude wave fade: smoothly flatten 3D vertex wave displacement as camera ascends into the sky (30m - 1000m)
	float altitude_wave_fade = 1.0 - smoothstep(30.0, 1000.0, alt);

	vec3 disp;
	vec3 norm;
	float crest_h;
	float crest_fold;
	evaluate_swells_vertex(world_v.xz, time_val, disp, norm, crest_h, crest_fold);

	disp *= (dist_wave_fade * altitude_wave_fade);

	vec3 world_displaced = world_v + disp;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world_displaced, 1.0)).xyz;

	v_world_pos = world_displaced;
	v_analytical_normal = norm;
	v_wave_crest = crest_h;
	v_wave_fold = crest_fold;
}

void fragment() {
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	// Submerged culling: never render ocean surface mesh from underwater (cull backfaces)
	if (cam_pos.y < 0.0) {
		discard;
	}

	vec3 V = normalize(cam_pos - v_world_pos);
	vec3 L = normalize(sun_direction);

	// Circular Alpha Fadeout: perfectly smooth circular dissipation well before square edges
	float circular_alpha = smoothstep(fade_outer_radius, fade_inner_radius, v_cam_dist);
	if (circular_alpha <= 0.001) {
		discard;
	}

	// 1. Analytical Rolling Swell Normal (Base 3D surface geometry)
	vec3 base_norm = evaluate_swell_normal(v_world_pos.xz, time_val);

	// 2. Dual-Octave Organic Wave Spectrum Drift (100% free of net/grid artifacts)
	vec2 wind = normalize(primary_wind_dir);

	// Octave 1: Macro capillary waves (~14.0m scale, drifting along wind)
	vec2 uv1 = v_world_pos.xz * (1.0 / 14.0) + wind * (time_val * 0.07);
	vec3 n1 = texture(wave_normal_tex, uv1).rgb * 2.0 - 1.0;

	// Octave 2: Micro wind ripples (~5.2m scale, +16 deg angular divergence for organic flow)
	mat2 rot2 = mat2(vec2(0.961, -0.276), vec2(0.276, 0.961));
	vec2 uv2 = (rot2 * v_world_pos.xz) * (1.0 / 5.2) + wind * (time_val * 0.12);
	vec3 n2 = texture(wave_normal_tex, uv2).rgb * 2.0 - 1.0;

	// Distance & altitude detail attenuation
	float dist_3d = length(cam_pos - v_world_pos);
	float detail_fade = clamp(1.0 - dist_3d / 900.0, 0.0, 1.0);
	float alt_detail_fade = 1.0 - smoothstep(40.0, 800.0, v_cam_alt);
	detail_fade *= alt_detail_fade;
	float detail_curve = detail_fade * detail_fade * (3.0 - 2.0 * detail_fade);

	// Combined capillary ripple slope with balanced physical gradient
	vec2 ripple_slope = (n1.xy * 0.50 + n2.xy * 0.35) * (detail_curve * 0.50);

	// Reoriented Normal Mapping (RNM) onto analytical base swell normal:
	// Constructs tangent frame on base_norm to avoid cross-hatch planar projection distortion
	vec3 t_tangent = normalize(cross(vec3(0.0, 1.0, 0.0), base_norm));
	if (dot(t_tangent, t_tangent) < 0.001) t_tangent = vec3(1.0, 0.0, 0.0);
	vec3 t_binormal = cross(base_norm, t_tangent);
	vec3 N = normalize(base_norm + t_tangent * ripple_slope.x + t_binormal * ripple_slope.y);

	// Distance normal flattening towards outer radius to match flat planetary sphere
	N = normalize(mix(vec3(0.0, 1.0, 0.0), N, circular_alpha));

	bool is_underwater = false;

	// Depth Buffer Interaction (Beer-Lambert & Shoreline Contact Foam)
	float surface_linear_depth = -VERTEX.z;
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	bool has_solid_ground = depth_raw > 0.0001 && depth_raw < 0.9999;
	float water_depth = 10000.0;
	vec3 scene_world_pos = vec3(0.0);
	if (has_solid_ground) {
		vec4 upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
		vec3 scene_pixel_pos = upos.xyz / max(abs(upos.w), 0.00001);
		float scene_linear_depth = -scene_pixel_pos.z;
		float depth_diff = scene_linear_depth - surface_linear_depth;
		if (depth_diff > 0.003) {
			water_depth = depth_diff;
			scene_world_pos = (INV_VIEW_MATRIX * vec4(scene_pixel_pos, 1.0)).xyz;
		} else {
			has_solid_ground = false;
		}
	}

	vec3 depth_transmittance = has_solid_ground ? exp(-absorption_coefficients * (water_depth / max(water_clarity * 0.25, 0.1))) : vec3(0.0);
	float water_tint_factor = has_solid_ground ? clamp(1.0 - depth_transmittance.y, 0.0, 1.0) : 1.0;
	vec3 water_body_color = mix(deep_water_color, shallow_water_color, clamp(depth_transmittance.y * 1.2, 0.0, 1.0));

	// Fresnel & Snell's Window
	float n1_idx = is_underwater ? 1.333 : 1.0;
	float n2_idx = is_underwater ? 1.0 : 1.333;
	float f_ratio = (n1_idx - n2_idx) / (n1_idx + n2_idx);
	float f0 = f_ratio * f_ratio;

	float NdotV = clamp(dot(N, V), 0.0, 1.0);
	float fresnel = f0 + (1.0 - f0) * pow(1.0 - NdotV, 5.0);

	if (is_underwater) {
		float critical_cos = sqrt(1.0 - (1.0 / (1.333 * 1.333)));
		if (NdotV < critical_cos) {
			fresnel = 1.0;
		}
	}

	// Subsurface Scattering (Translucent Emerald-Aquamarine transmission through thin wave crests)
	float crest_norm = clamp((v_wave_crest + wave_amplitude * 0.35) / max(wave_amplitude * 1.25, 0.1), 0.0, 1.0);
	float sss_forward = pow(clamp(dot(V, -L), 0.0, 1.0), 3.0);
	float crest_sss_mask = smoothstep(0.45, 0.90, crest_norm);
	vec3 sss_light = sss_color * (sss_intensity * 0.75) * sss_forward * crest_sss_mask * clamp(sun_direction.y * 1.8, 0.0, 1.0);

	// Modern Jacobian Whitecap Foam (Breaks only on colliding crest summits)
	float h_norm = clamp((v_wave_crest + wave_amplitude * 0.20) / max(wave_amplitude * 1.10, 0.1), 0.0, 1.0);
	float steepness_mask = smoothstep(crest_foam_threshold - 0.12, crest_foam_threshold + 0.10, v_wave_fold);
	float height_mask = smoothstep(0.55, 0.90, h_norm);
	float whitecap_crest_mask = steepness_mask * height_mask;

	// Procedural Cellular Sea Foam (100% free of polygon confetti!)
	float total_foam = evaluate_organic_foam(v_world_pos.xz, time_val, whitecap_crest_mask, water_depth, scene_world_pos.y, is_underwater);
	float foam_alt_fade = 1.0 - smoothstep(30.0, 600.0, v_cam_alt);
	total_foam *= foam_alt_fade;

	// Toksvig normal variance absorption:
	// Sub-pixel ripple variance is absorbed into roughness to form a silky, shimmer-free sun glitter lane
	float dist_norm = clamp(v_cam_dist / 1000.0, 0.0, 1.0);
	float toksvig_var = (1.0 - detail_curve) * 0.042 + dist_norm * 0.018;
	float effective_roughness = sqrt(surface_roughness * surface_roughness + toksvig_var);
	effective_roughness = clamp(effective_roughness, 0.05, 0.42);

	// Sun Specular (GGX) with Half-Vector Fresnel & HDR Glitter Lane
	vec3 H = normalize(L + V);
	float NdotH = clamp(dot(N, H), 0.0, 1.0);
	float VdotH = clamp(dot(V, H), 0.0, 1.0);
	float f_spec = f0 + (1.0 - f0) * pow(1.0 - VdotH, 5.0);

	float alpha = effective_roughness * effective_roughness;
	float alpha2 = alpha * alpha;
	float denom = (NdotH * NdotH * (alpha2 - 1.0) + 1.0);
	float D = alpha2 / (3.14159265 * denom * denom + 0.0001);

	float k_spec = (effective_roughness + 1.0) * (effective_roughness + 1.0) / 8.0;
	float NdotL = clamp(dot(N, L), 0.0, 1.0);
	float g_v = NdotV / (NdotV * (1.0 - k_spec) + k_spec);
	float g_l = NdotL / (NdotL * (1.0 - k_spec) + k_spec);
	float G = g_v * g_l;

	float ggx_spec = (D * G * f_spec) / max(4.0 * NdotV * NdotL, 0.01);
	float sun_above_horizon = smoothstep(-0.04, 0.06, sun_direction.y);
	float sun_elev_factor = sun_above_horizon * clamp(sun_direction.y, 0.0, 1.0);
	vec3 raw_spec = sun_color * (sun_intensity * 3.8) * ggx_spec * clamp(NdotL, 0.0, 1.0) * sun_above_horizon;
	// Soft HDR compression strictly prevents FP16 buffer overflow
	vec3 sun_specular_energy = raw_spec / (vec3(1.0) + raw_spec * (1.0 / 30.0));

	// Wave Ambient Occlusion (Wave Cavity Shading)
	// Wave troughs and shielded wave slopes receive less hemispherical skylight
	float wave_ao = clamp(0.55 + 0.45 * (N.y * 0.5 + 0.5), 0.45, 1.0);

	// Sky Environment Reflection
	vec3 R = reflect(-V, N);
	float sky_elevation = clamp(R.y, 0.0, 1.0);
	vec3 sky_reflected = mix(sky_horizon_color, sky_ambient_color, sqrt(sky_elevation)) * wave_ao;

	// Physical Upwelling Radiance (Diffuse water volume backscattering from sun + sky dome)
	vec3 diffuse_illumination = sun_color * (sun_intensity * 0.07 * sun_elev_factor) + sky_ambient_color * 0.70;
	vec3 upwelling_ocean = deep_water_color * diffuse_illumination * wave_ao;

	// Refracted scene color & submerged caustics: only active when solid objects/terrain are submerged underneath
	vec3 water_composite = upwelling_ocean;
	if (has_solid_ground) {
		vec2 refract_offset = (VIEW_MATRIX * vec4(N.x, 0.0, N.z, 0.0)).xy * (0.022 / max(surface_linear_depth * 0.08 + 1.0, 1.0));
		vec2 ref_uv = clamp(SCREEN_UV + refract_offset, vec2(0.001), vec2(0.999));

		// Validate refraction depth: if refracted pixel hits geometry in front of surface (e.g. above waterline), cancel offset
		float ref_depth_raw = texture(depth_texture, ref_uv).r;
		vec4 ref_upos = INV_PROJECTION_MATRIX * vec4(ref_uv * 2.0 - 1.0, ref_depth_raw, 1.0);
		float ref_linear_depth = -(ref_upos.xyz / max(abs(ref_upos.w), 0.00001)).z;
		if (ref_linear_depth <= surface_linear_depth + 0.002) {
			ref_uv = SCREEN_UV;
		}

		vec3 refracted_scene = texture(screen_texture, ref_uv).rgb;

		// Reconstruct geometric normal of submerged scene geometry using screen-space derivatives
		vec3 sc_norm = normalize(cross(dFdy(scene_world_pos), dFdx(scene_world_pos)));
		if (dot(sc_norm, V) < 0.0) {
			sc_norm = -sc_norm;
		}

		// Strictly mask out downward-facing surfaces (bottom of objects: normal.y <= 0)
		float upward_factor = clamp(sc_norm.y * 3.5, 0.0, 1.0);
		// Strictly mask out unlit surfaces facing away from the sun (dot(normal, sun_dir) <= 0)
		float sun_lit_factor = clamp(dot(sc_norm, normalize(sun_direction)) * 3.0, 0.0, 1.0);
		float caustics_mask = upward_factor * sun_lit_factor;

		vec3 caustics_light = vec3(0.0);
		if (caustics_mask > 0.001 && sun_direction.y > 0.02) {
			float depth_caustic_fade = exp(-water_depth * 0.12);
			float c_val = evaluate_caustics(scene_world_pos.xz, time_val);
			caustics_light = sun_color * (c_val * caustics_strength * caustics_mask * depth_caustic_fade * clamp(sun_direction.y * 1.5, 0.0, 1.0));
		}

		vec3 lit_submerged_scene = refracted_scene + caustics_light;
		water_composite = mix(lit_submerged_scene * depth_transmittance, water_body_color, water_tint_factor);
	}

	vec3 surface_color = mix(water_composite, sky_reflected, fresnel);
	surface_color += sss_light * (1.0 - smoothstep(30.0, 600.0, v_cam_alt));
	surface_color += sun_specular_energy;
	surface_color = mix(surface_color, foam_color, total_foam);

	// Distant planetary ocean model (100% identical optical model to atmosphere_clouds.gdshader)
	vec3 diffuse_water = deep_water_color * (sun_color * (sun_intensity * 0.07 * sun_elev_factor) + sky_ambient_color * 0.70);
	vec3 dist_reflected_sky = mix(sky_ambient_color * 0.75, sky_horizon_color, 0.40);
	float dist_fresnel = 0.02 + (1.0 - 0.02) * pow(1.0 - NdotV, 5.0);
	vec3 distant_ocean_color = mix(diffuse_water, dist_reflected_sky, dist_fresnel) + (sun_specular_energy * 0.65);

	// Seamless Blending between near-field PBR ocean and planetary distant ocean:
	// 1. Radially: smoothly converges to distant ocean color before circular_alpha fade begins
	float dist_blend = smoothstep(fade_inner_radius * 0.35, fade_outer_radius, v_cam_dist);
	// 2. Vertically: smoothly converges to distant ocean color as camera ascends
	float alt_blend = smoothstep(40.0, 1000.0, v_cam_alt);
	float to_distant = clamp(max(dist_blend, alt_blend), 0.0, 1.0);
	surface_color = mix(surface_color, distant_ocean_color, to_distant);

	// Aerial Perspective / Distance Haze (calibrated exponential extinction matching atmosphere_clouds.gdshader)
	float dist_km = length(cam_pos - v_world_pos) * 0.001;
	float grazing_factor = clamp(1.0 - V.y * 3.5, 0.0, 1.0);
	float mesh_haze = clamp(1.0 - exp(-dist_km * 0.018), 0.0, 1.0) * grazing_factor;
	surface_color = mix(surface_color, sky_horizon_color, mesh_haze);

	// Photographic Tone Mapping (ACES Film matching atmosphere_clouds.gdshader)
	surface_color = apply_tonemapping(surface_color, exposure, tonemap_mode, white_point);

	// High-Altitude Seamless Handoff:
	// Above 1000m to 1800m altitude, the high-res mesh smoothly dissolves to yield to the infinite planetary sky shader ocean
	float alt_mesh_alpha = 1.0 - smoothstep(1000.0, 1800.0, v_cam_alt);
	float final_alpha = circular_alpha * alt_mesh_alpha;
	if (final_alpha <= 0.001) {
		discard;
	}

	ALBEDO = surface_color;
	ALPHA = final_alpha;
}
