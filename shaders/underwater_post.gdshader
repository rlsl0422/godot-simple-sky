shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled;

/*
 * Photographic Tropical Underwater Optics & Crystal Godrays
 * Perfectly matches real photographic reference:
 * - Silky smooth, crystal-clear water with ZERO frosted glass / mosaic noise
 * - Distinct, thin, high-contrast sunbeams (godrays) streaming from the surface
 * - Luminous tropical cyan to deep cobalt blue gradient
 * - Deterministic, non-jittered raymarching for pristine stability
 */

group_uniforms Underwater_Optics;
uniform vec3 water_scatter_color : source_color = vec3(0.0, 0.55, 0.78);      // Luminous Tropical Cyan
uniform vec3 deep_extinction_color : source_color = vec3(0.002, 0.04, 0.16);  // Deep Clean Cobalt
uniform vec3 absorption_coefficients = vec3(0.42, 0.065, 0.015);              // Red disappears first, blue stays longest
uniform float turbidity : hint_range(0.001, 0.04, 0.001) = 0.007;             // Crystal clear water column
uniform float max_visibility_meters : hint_range(10.0, 200.0, 5.0) = 120.0;

group_uniforms Godrays;
uniform float godray_intensity : hint_range(0.0, 5.0, 0.1) = 2.4;
uniform float godray_sharpness : hint_range(2.0, 16.0, 0.5) = 8.5;             // Crisp, distinct thin sun shafts
uniform float godray_phase_g : hint_range(0.4, 0.95, 0.01) = 0.82;
uniform float caustics_strength : hint_range(0.0, 3.0, 0.1) = 0.75;
uniform float caustics_scale : hint_range(0.1, 4.0, 0.05) = 1.6;

group_uniforms Sun_Sync;
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.98, 0.92);
uniform float sun_intensity = 24.0;
uniform float custom_time = 0.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Continuous, high-contrast surface wave interference pattern (Zero noise/grain)
float evaluate_sun_shafts(vec2 xz, float time_val) {
	// 3 Non-parallel wave fronts traveling on the surface
	vec2 uv1 = xz * caustics_scale + vec2(time_val * 0.45, time_val * 0.25);
	vec2 uv2 = vec2(xz.x * 0.707 - xz.y * 0.707, xz.x * 0.707 + xz.y * 0.707) * (caustics_scale * 1.45) - vec2(time_val * 0.35, -time_val * 0.4);
	vec2 uv3 = vec2(xz.x * 0.383 + xz.y * 0.924, -xz.x * 0.924 + xz.y * 0.383) * (caustics_scale * 2.3) + vec2(-time_val * 0.22, time_val * 0.32);

	float w1 = cos(uv1.x * 2.5 + sin(uv1.y * 1.7));
	float w2 = sin(uv2.x * 3.3 - cos(uv2.y * 2.3));
	float w3 = cos(uv3.x * 4.4 + uv3.y * 3.6);

	float comb = abs(w1 * 0.50 + w2 * 0.35 + w3 * 0.15);
	// Sharp power curve creates thin, brilliant ribbons of light with dark spaces between them
	return pow(clamp(comb * 1.25, 0.0, 1.0), godray_sharpness);
}

// Henyey-Greenstein forward phase function
float phase_hg(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 0.001), 1.5));
}

void fragment() {
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	if (cam_pos.y > 0.4) {
		discard;
	}

	// 1. Precise, UN-JITTERED Depth Reconstruction (Completely eliminates frosted glass / mosaic artifacts)
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec3 scene_color = texture(screen_texture, SCREEN_UV).rgb;

	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view_h = INV_PROJECTION_MATRIX * ndc;
	vec3 view_pos = view_h.xyz / view_h.w;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;

	bool is_sky = raw_depth >= 0.9999 || raw_depth <= 0.0001;
	float ray_dist = is_sky ? max_visibility_meters : length(view_pos);
	ray_dist = min(ray_dist, max_visibility_meters);

	vec3 ray_dir = normalize(world_pos - cam_pos);

	// Underwater ray length
	float water_path = ray_dist;
	if (world_pos.y > 0.0 && ray_dir.y > 0.001) {
		float dist_to_surface = -cam_pos.y / ray_dir.y;
		water_path = clamp(dist_to_surface, 0.0, ray_dist);
	}

	// 2. Spectral Beer-Lambert Extinction
	vec3 extinction = exp(-absorption_coefficients * water_path);

	// 3. Crystal Clear Tropical In-Scattering
	float depth_below_surface = max(-cam_pos.y, 0.0);
	float sun_down_attenuation = exp(-absorption_coefficients.y * depth_below_surface * 0.12);
	vec3 ambient_sun = sun_color * (sun_intensity * 0.08 * sun_down_attenuation);

	float inscatter_factor = 1.0 - exp(-turbidity * water_path);
	vec3 local_scatter_color = mix(water_scatter_color, deep_extinction_color, clamp(depth_below_surface * 0.035, 0.0, 1.0));
	vec3 inscattered_light = local_scatter_color * (ambient_sun + vec3(0.06, 0.16, 0.26)) * inscatter_factor;

	// 4. VOLUMETRIC GODRAYS (Deterministic, zero noise, high resolution rays)
	vec3 godray_accum = vec3(0.0);
	vec3 sun_norm = normalize(sun_direction);
	float sun_cos = dot(ray_dir, sun_norm);
	float forward_phase = phase_hg(sun_cos, godray_phase_g);

	if (sun_direction.y > 0.02 && godray_intensity > 0.01) {
		// Radial fan component aligned with solar transit
		vec3 up_ref = abs(sun_norm.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 sun_right = normalize(cross(sun_norm, up_ref));
		vec3 sun_up = cross(sun_right, sun_norm);
		vec2 radial_coords = vec2(dot(ray_dir, sun_right), dot(ray_dir, sun_up));
		float radial_dist = length(radial_coords);
		float radial_angle = atan(radial_coords.y, radial_coords.x);
		float radial_fan = sin(radial_angle * 18.0 + time_val * 0.35) * 0.5 + 0.5;
		radial_fan = pow(radial_fan, 2.5);
		// Smoothly blend radial fan near solar core to eliminate star-pinch artifact
		radial_fan = mix(0.85, radial_fan, smoothstep(0.04, 0.22, radial_dist));

		// Deterministic 18-step raymarching: NO random jitter eliminates 100% of grain/frosted glass
		const int GODRAY_STEPS = 18;
		float march_limit = min(water_path, 48.0);
		float step_len = march_limit / float(GODRAY_STEPS);

		vec3 shaft_accum = vec3(0.0);

		for (int i = 0; i < GODRAY_STEPS; i++) {
			float march_d = (float(i) + 0.5) * step_len;
			vec3 sample_p = cam_pos + ray_dir * march_d;
			if (sample_p.y > 0.0) break;

			float s_depth = -sample_p.y;

			// Project along solar vector to the ocean surface
			vec2 proj_surface_xz = sample_p.xz + sun_norm.xz * (s_depth / max(sun_norm.y, 0.08));
			float wave_shaft = evaluate_sun_shafts(proj_surface_xz, time_val);

			// Merge surface waves with radial crepuscular spokes
			float shaft_mask = wave_shaft * (0.35 + 0.65 * radial_fan);

			// Water column attenuation
			vec3 light_in_water = exp(-absorption_coefficients * (s_depth * 0.15 + march_d * 0.05));
			shaft_accum += shaft_mask * light_in_water * step_len;
		}

		// Brilliant tropical beam color: warm sunlight tinted with glowing cyan
		vec3 beam_tint = mix(sun_color, vec3(0.25, 0.90, 1.0), 0.35);
		vec3 godray_raw = beam_tint * (shaft_accum * forward_phase * godray_intensity * 0.32 * clamp(sun_direction.y * 1.8, 0.0, 1.0));

		// Soft shoulder curve: prevents white burnout, maintains high contrast
		godray_accum = godray_raw / (1.0 + godray_raw * 0.38);
	}

	// 5. Crisp Caustics on Geometry
	vec3 caustics_light = vec3(0.0);
	if (!is_sky && world_pos.y <= 0.0) {
		float depth_caustic_fade = exp(-abs(world_pos.y) * 0.10);
		float caustic_val = evaluate_sun_shafts(world_pos.xz, time_val);
		caustics_light = sun_color * (caustic_val * caustics_strength * depth_caustic_fade * clamp(sun_direction.y, 0.0, 1.0));
	}

	// 6. Final Composite
	vec3 attenuated_scene = (scene_color + caustics_light) * extinction;
	vec3 final_color = attenuated_scene + inscattered_light + godray_accum;

	float surface_blend = clamp((-cam_pos.y + 0.1) / 0.3, 0.0, 1.0);
	ALBEDO = mix(scene_color, final_color, surface_blend);
}
