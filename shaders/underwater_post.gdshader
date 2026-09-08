shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled;

/*
 * Photographic Tropical Underwater Optics & Subtle Godrays
 * - Eliminates 100% of circular interference / slicing moire rings
 * - Smooth, natural, subtle sun shafts (godrays)
 * - Crystal-clear tropical water gradient (Cyan to deep cobalt)
 * - Editor 3D viewport support & zero noise
 */

group_uniforms Underwater_Optics;
uniform vec3 water_scatter_color : source_color = vec3(0.0, 0.55, 0.78);      // Luminous Tropical Cyan
uniform vec3 deep_extinction_color : source_color = vec3(0.002, 0.04, 0.16);  // Deep Clean Cobalt
uniform vec3 absorption_coefficients = vec3(0.42, 0.065, 0.015);              // Red disappears first
uniform float turbidity : hint_range(0.001, 0.04, 0.001) = 0.007;             // Crystal clear
uniform float max_visibility_meters : hint_range(10.0, 200.0, 5.0) = 120.0;

group_uniforms Godrays;
uniform float godray_intensity : hint_range(0.0, 4.0, 0.05) = 1.1;             // Soft, subtle intensity
uniform float godray_sharpness : hint_range(1.0, 8.0, 0.5) = 3.5;              // Natural beam width
uniform float godray_phase_g : hint_range(0.4, 0.95, 0.01) = 0.80;
uniform float caustics_strength : hint_range(0.0, 3.0, 0.1) = 0.6;
uniform float caustics_scale : hint_range(0.1, 4.0, 0.05) = 1.4;

group_uniforms Sun_Sync;
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.98, 0.92);
uniform float sun_intensity = 24.0;
uniform float custom_time = 0.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void vertex() {
	// Fullscreen clip-space quad
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Gentle geometry caustics (only on solid underwater terrain/objects)
float evaluate_caustics(vec2 xz, float time_val) {
	vec2 uv1 = xz * caustics_scale + vec2(time_val * 0.4, time_val * 0.25);
	vec2 uv2 = vec2(xz.x * 0.707 - xz.y * 0.707, xz.x * 0.707 + xz.y * 0.707) * (caustics_scale * 1.3) - vec2(time_val * 0.3, -time_val * 0.35);

	float c1 = cos(uv1.x * 2.4 + sin(uv1.y * 1.6));
	float c2 = sin(uv2.x * 3.1 - cos(uv2.y * 2.1));

	return pow(abs(c1 * 0.6 + c2 * 0.4), 2.0);
}

// Henyey-Greenstein forward phase function
float phase_hg(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 0.001), 1.5));
}

void fragment() {
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	// Submerged check: only render when camera is below sea level (y < 0.15)
	if (cam_pos.y > 0.15) {
		discard;
	}

	// 1. Mathematically exact view ray reconstruction (independent of depth buffer, NaN-free)
	vec4 view_ray_h = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 1.0, 1.0);
	vec3 view_ray = view_ray_h.xyz / max(abs(view_ray_h.w), 0.00001);
	vec3 ray_dir = normalize((INV_VIEW_MATRIX * vec4(view_ray, 0.0)).xyz);

	// 2. Depth buffer reading & solid geometry hit distance
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec3 scene_color = texture(screen_texture, SCREEN_UV).rgb;

	// In Godot 4 Forward+ (Vulkan reversed-Z), clear sky depth is 0.0 (or 1.0 in some backends)
	bool is_sky = raw_depth <= 0.0001 || raw_depth >= 0.9999;

	float solid_dist = max_visibility_meters;
	vec3 world_pos = cam_pos + ray_dir * max_visibility_meters;
	if (!is_sky) {
		vec4 scene_h = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
		vec3 scene_vpos = scene_h.xyz / max(abs(scene_h.w), 0.00001);
		solid_dist = min(length(scene_vpos), max_visibility_meters);
		world_pos = (INV_VIEW_MATRIX * vec4(scene_vpos, 1.0)).xyz;
	}

	// Distance to water surface (y = 0) along view ray
	float dist_to_surface = ray_dir.y > 0.001 ? (-cam_pos.y / ray_dir.y) : max_visibility_meters;
	float water_path = min(solid_dist, dist_to_surface);

	// 3. Spectral Beer-Lambert Extinction
	vec3 extinction = exp(-absorption_coefficients * water_path);

	// 4. Crystal Clear Tropical In-Scattering
	float depth_below_surface = max(-cam_pos.y, 0.0);
	float sun_down_attenuation = exp(-depth_below_surface * 0.05);
	vec3 ambient_sun = sun_color * (sun_intensity * 0.05 * sun_down_attenuation);

	float inscatter_factor = 1.0 - exp(-turbidity * water_path);
	vec3 local_scatter_color = mix(water_scatter_color, deep_extinction_color, clamp(depth_below_surface * 0.02, 0.0, 1.0));
	vec3 inscattered_light = local_scatter_color * (ambient_sun + vec3(0.04, 0.12, 0.22)) * inscatter_factor;

	// 5. NATURAL, SUBTLE GODRAYS (Directional, Depth-Attenuated, Zero Anti-Solar Artifacts)
	vec3 godray_accum = vec3(0.0);
	vec3 sun_norm = normalize(sun_direction);
	float sun_cos = dot(ray_dir, sun_norm);

	// Strict Forward Hemisphere Mask: completely eliminates 100% of rays in anti-solar direction
	// Rays only appear when looking toward the sun (fading to 0 at 78 degrees off-axis)
	float sun_forward_mask = smoothstep(0.20, 0.60, sun_cos);

	// Monotonic Physical Depth Extinction:
	// Sunlight exponentially extinguishes with depth into the deep ocean.
	// Red vanishes in 5m, green in 30m, blue penetrates deeper but extinguishes by 80-100m.
	vec3 solar_depth_decay = exp(-vec3(0.35, 0.08, 0.045) * depth_below_surface);

	if (sun_direction.y > 0.02 && godray_intensity > 0.01 && sun_forward_mask > 0.001) {
		float forward_phase = phase_hg(sun_cos, godray_phase_g);

		// Continuous radial beam fan aligned with solar vector
		vec3 up_ref = abs(sun_norm.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 sun_right = normalize(cross(sun_norm, up_ref));
		vec3 sun_up = cross(sun_right, sun_norm);
		vec2 radial_coords = vec2(dot(ray_dir, sun_right), dot(ray_dir, sun_up));
		float radial_dist = length(radial_coords);
		float radial_angle = atan(radial_coords.y, radial_coords.x);

		// 3 Harmonic angular beam frequencies for organic sunbeams
		float b1 = sin(radial_angle * 11.0 + time_val * 0.18) * 0.5 + 0.5;
		float b2 = cos(radial_angle * 17.0 - time_val * 0.24) * 0.5 + 0.5;
		float b3 = sin(radial_angle * 27.0 + time_val * 0.12) * 0.5 + 0.5;
		float radial_fan = pow(b1 * 0.55 + b2 * 0.30 + b3 * 0.15, godray_sharpness);

		// Smooth core blending to eliminate central star pinch
		radial_fan = mix(0.75, radial_fan, smoothstep(0.04, 0.25, radial_dist));

		// Volumetric water column integration along view ray
		const int GODRAY_STEPS = 10;
		float march_limit = min(water_path, 30.0);
		float step_len = march_limit / float(GODRAY_STEPS);

		float depth_accum = 0.0;
		for (int i = 0; i < GODRAY_STEPS; i++) {
			float march_d = (float(i) + 0.5) * step_len;
			vec3 sample_p = cam_pos + ray_dir * march_d;
			if (sample_p.y > 0.0) break;

			float s_depth = -sample_p.y;
			// Vertical extinction from surface downwards
			float light_atten = exp(-s_depth * 0.08);
			depth_accum += light_atten * step_len;
		}

		// Normalized path factor: strictly bounded in [0, 1] so deep water never amplifies energy
		float path_norm = depth_accum / max(march_limit, 1.0);

		// Soft, natural godray energy tinted with tropical cyan and attenuated by camera depth
		vec3 beam_tint = mix(sun_color, vec3(0.25, 0.85, 0.98), 0.45);
		vec3 godray_raw = beam_tint * solar_depth_decay * (path_norm * radial_fan * forward_phase * sun_forward_mask * godray_intensity * 0.30 * clamp(sun_direction.y * 1.5, 0.0, 1.0));
		
		// Soft shoulder tone compression (prevents blinding blowout near surface)
		godray_accum = godray_raw / (1.0 + godray_raw * 0.8);
	}

	// 6. Gentle Caustics on Solid Geometry only
	vec3 caustics_light = vec3(0.0);
	if (!is_sky && world_pos.y <= 0.0) {
		float depth_caustic_fade = exp(-abs(world_pos.y) * 0.10);
		float caustic_val = evaluate_caustics(world_pos.xz, time_val);
		caustics_light = sun_color * (caustic_val * caustics_strength * depth_caustic_fade * clamp(sun_direction.y, 0.0, 1.0));
	}

	// 7. Final Color Assembly
	vec3 attenuated_scene = (scene_color + caustics_light) * extinction;
	vec3 final_color = attenuated_scene + inscattered_light + godray_accum;

	float surface_blend = clamp((-cam_pos.y + 0.08) / 0.25, 0.0, 1.0);
	ALBEDO = mix(scene_color, final_color, surface_blend);
}
