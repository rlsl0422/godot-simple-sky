shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled;

/*
 * Physically-Based Underwater Optics with Volumetric Godrays
 * Fullscreen Quad Renderer
 * - Spectral Beer-Lambert Wavelength Extinction
 * - Volumetric Water In-Scattering
 * - Volumetric Underwater Godrays / Sun Shafts (Henyey-Greenstein Forward Phase)
 * - Underwater Caustics on Geometry
 * - Fluid Wave Distortion
 */

group_uniforms Underwater_Optics;
uniform vec3 water_scatter_color : source_color = vec3(0.02, 0.16, 0.26);
uniform vec3 deep_extinction_color : source_color = vec3(0.005, 0.03, 0.08);
uniform vec3 absorption_coefficients = vec3(0.35, 0.08, 0.025);
uniform float turbidity : hint_range(0.005, 0.1, 0.002) = 0.025;
uniform float max_visibility_meters : hint_range(10.0, 200.0, 5.0) = 80.0;

group_uniforms Godrays;
uniform float godray_intensity : hint_range(0.0, 5.0, 0.1) = 2.4;
uniform float godray_phase_g : hint_range(0.3, 0.95, 0.01) = 0.78;
uniform float caustics_strength : hint_range(0.0, 3.0, 0.1) = 0.8;
uniform float caustics_scale : hint_range(0.1, 2.0, 0.05) = 0.6;
uniform float distortion_strength : hint_range(0.0, 0.02, 0.001) = 0.0025;

group_uniforms Sun_Sync;
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.88);
uniform float sun_intensity = 20.0;
uniform float custom_time = 0.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Procedural dynamic caustics pattern
float get_caustics(vec2 xz, float time_val) {
	vec2 uv1 = xz * caustics_scale + vec2(time_val * 0.4, time_val * 0.25);
	vec2 uv2 = xz * (caustics_scale * 1.35) - vec2(time_val * 0.3, -time_val * 0.35);

	float c1 = sin(uv1.x * 2.8 + uv1.y * 1.7) * cos(uv1.x * 1.9 - uv1.y * 3.1);
	float c2 = sin(uv2.x * 3.4 - uv2.y * 2.2) * cos(uv2.x * 2.3 + uv2.y * 3.7);

	return pow(abs(c1 + c2), 2.5);
}

// Henyey-Greenstein phase function for forward solar scattering
float phase_hg(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 0.001), 1.5));
}

void fragment() {
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	if (cam_pos.y > 0.5) {
		discard;
	}

	// 1. Subtle screen fluid refraction distortion
	vec2 distort_uv = SCREEN_UV + vec2(
		sin(SCREEN_UV.y * 28.0 + time_val * 2.2),
		cos(SCREEN_UV.x * 28.0 + time_val * 2.2)
	) * distortion_strength;

	vec3 scene_color = texture(screen_texture, distort_uv).rgb;
	float raw_depth = texture(depth_texture, distort_uv).r;

	vec4 ndc = vec4(distort_uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view_h = INV_PROJECTION_MATRIX * ndc;
	vec3 view_pos = view_h.xyz / view_h.w;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;

	bool is_sky = raw_depth >= 0.9999 || raw_depth <= 0.0001;
	float ray_dist = is_sky ? max_visibility_meters : length(view_pos);
	ray_dist = min(ray_dist, max_visibility_meters);

	vec3 ray_dir = normalize(world_pos - cam_pos);

	// Compute underwater ray length
	float water_path = ray_dist;
	if (world_pos.y > 0.0 && ray_dir.y > 0.001) {
		float dist_to_surface = -cam_pos.y / ray_dir.y;
		water_path = clamp(dist_to_surface, 0.0, ray_dist);
	}

	// 2. Spectral Beer-Lambert Extinction
	vec3 extinction = exp(-absorption_coefficients * water_path);

	// 3. Volumetric In-Scattering
	float depth_below_surface = max(-cam_pos.y, 0.0);
	float sun_down_attenuation = exp(-absorption_coefficients.y * depth_below_surface * 0.15);
	vec3 ambient_sun = sun_color * (sun_intensity * 0.08 * sun_down_attenuation);

	float inscatter_factor = 1.0 - exp(-turbidity * water_path);
	vec3 local_scatter_color = mix(water_scatter_color, deep_extinction_color, clamp(depth_below_surface * 0.04, 0.0, 1.0));
	vec3 inscattered_light = local_scatter_color * (ambient_sun + vec3(0.12, 0.22, 0.32)) * inscatter_factor;

	// 4. VOLUMETRIC GODRAYS (Light Shafts)
	vec3 godray_accum = vec3(0.0);
	float sun_cos = dot(ray_dir, normalize(sun_direction));
	float forward_phase = phase_hg(sun_cos, clamp(godray_phase_g, 0.5, 0.82));

	if (sun_direction.y > 0.0 && godray_intensity > 0.01) {
		const int GODRAY_STEPS = 12;
		float step_len = min(water_path, 40.0) / float(GODRAY_STEPS);
		// Interleaved gradient noise for silky smooth shaft dithering
		vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
		float dither = fract(magic.z * fract(dot(FRAGCOORD.xy, magic.xy))) * 0.5;

		for (int i = 0; i < GODRAY_STEPS; i++) {
			float march_d = (float(i) + dither) * step_len;
			vec3 sample_p = cam_pos + ray_dir * march_d;
			if (sample_p.y > 0.0) break;

			float s_depth = -sample_p.y;

			// Project surface wave caustics along solar ray
			vec2 proj_surface_xz = sample_p.xz + sun_direction.xz * (s_depth / max(sun_direction.y, 0.1));
			float caustic_shaft = get_caustics(proj_surface_xz * 0.35, time_val);

			// Broad crepuscular beam variance
			float broad_beam = sin(proj_surface_xz.x * 0.12 + time_val * 0.2) * cos(proj_surface_xz.y * 0.12 - time_val * 0.15) * 0.5 + 0.5;
			float shaft_mask = caustic_shaft * (0.6 + 0.4 * broad_beam);

			// Attenuation through water column
			vec3 light_in_water = exp(-absorption_coefficients * (s_depth * 0.18 + march_d * 0.08));
			godray_accum += sun_color * shaft_mask * light_in_water * step_len;
		}

		// Soft shoulder tone compression on godray energy to prevent white burn
		godray_accum *= forward_phase * godray_intensity * 0.20 * clamp(sun_direction.y * 1.5, 0.0, 1.0);
		godray_accum = (godray_accum * (1.0 + godray_accum * 0.25)) / (1.0 + godray_accum);
	}

	// 5. Caustics on Geometry
	vec3 caustics_light = vec3(0.0);
	if (!is_sky && world_pos.y <= 0.0) {
		float depth_caustic_fade = exp(-abs(world_pos.y) * 0.12);
		float caustic_val = get_caustics(world_pos.xz, time_val);
		caustics_light = sun_color * (caustic_val * caustics_strength * depth_caustic_fade * clamp(sun_direction.y, 0.0, 1.0));
	}

	// 6. Final Color Assembly
	vec3 attenuated_scene = (scene_color + caustics_light) * extinction;
	vec3 final_color = attenuated_scene + inscattered_light + godray_accum;

	float surface_blend = clamp((-cam_pos.y + 0.1) / 0.3, 0.0, 1.0);
	ALBEDO = mix(scene_color, final_color, surface_blend);
}
