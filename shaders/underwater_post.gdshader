shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled;

/*
 * Physically-Based Underwater Optics & Scattering Post-Processing Shader
 * Fullscreen Quad Renderer
 * - Spectral Beer-Lambert Wavelength Extinction (Red -> Green -> Blue)
 * - Volumetric Water In-Scattering (Depth-dependent ambient & solar)
 * - Underwater Caustics Mapping
 * - Subtle Fluid Refraction Wave Distortion
 */

group_uniforms Underwater_Optics;
uniform vec3 water_scatter_color : source_color = vec3(0.02, 0.16, 0.26);
uniform vec3 deep_extinction_color : source_color = vec3(0.005, 0.03, 0.08);
uniform vec3 absorption_coefficients = vec3(0.35, 0.08, 0.025); // [R, G, B] per meter
uniform float turbidity : hint_range(0.005, 0.1, 0.002) = 0.025; // In-scattering density
uniform float max_visibility_meters : hint_range(10.0, 200.0, 5.0) = 80.0;
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
	// Fullscreen NDC quad trick
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Procedural 2-layer dynamic caustics pattern
float get_caustics(vec2 xz, float time_val) {
	vec2 uv1 = xz * caustics_scale + vec2(time_val * 0.4, time_val * 0.25);
	vec2 uv2 = xz * (caustics_scale * 1.35) - vec2(time_val * 0.3, -time_val * 0.35);

	float c1 = sin(uv1.x * 2.8 + uv1.y * 1.7) * cos(uv1.x * 1.9 - uv1.y * 3.1);
	float c2 = sin(uv2.x * 3.4 - uv2.y * 2.2) * cos(uv2.x * 2.3 + uv2.y * 3.7);

	float pattern = abs(c1 + c2);
	return pow(pattern, 3.0);
}

void fragment() {
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	vec3 cam_pos = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	// Only active when camera is underwater (cam_pos.y <= 0.2m)
	if (cam_pos.y > 0.5) {
		discard;
	}

	// 1. Subtle screen fluid refraction distortion
	vec2 distort_uv = SCREEN_UV + vec2(
		sin(SCREEN_UV.y * 30.0 + time_val * 2.0),
		cos(SCREEN_UV.x * 30.0 + time_val * 2.0)
	) * distortion_strength;

	// Sample raw scene color and depth
	vec3 scene_color = texture(screen_texture, distort_uv).rgb;
	float raw_depth = texture(depth_texture, distort_uv).r;

	// Reconstruct view and world positions
	vec4 ndc = vec4(distort_uv * 2.0 - 1.0, raw_depth, 1.0);
	vec4 view_h = INV_PROJECTION_MATRIX * ndc;
	vec3 view_pos = view_h.xyz / view_h.w;
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;

	// Is this ray hitting sky / far plane?
	bool is_sky = raw_depth >= 0.9999 || raw_depth <= 0.0001;
	float ray_dist = is_sky ? max_visibility_meters : length(view_pos);
	ray_dist = min(ray_dist, max_visibility_meters);

	// Compute water path length:
	// If looking above water (world_pos.y > 0.0), water path stops at y = 0
	float water_path = ray_dist;
	if (world_pos.y > 0.0) {
		vec3 ray_dir = normalize(world_pos - cam_pos);
		if (ray_dir.y > 0.001) {
			float dist_to_surface = -cam_pos.y / ray_dir.y;
			water_path = clamp(dist_to_surface, 0.0, ray_dist);
		}
	}

	// 2. Spectral Beer-Lambert Extinction:
	// T(lambda) = exp(-absorption * distance)
	vec3 extinction = exp(-absorption_coefficients * water_path);

	// Sun light attenuation with water depth
	float depth_below_surface = max(-cam_pos.y, 0.0);
	float sun_down_attenuation = exp(-absorption_coefficients.y * depth_below_surface * 0.15);
	vec3 ambient_sun = sun_color * (sun_intensity * 0.08 * sun_down_attenuation);

	// 3. Volumetric In-Scattering:
	// Fog color becomes deep_extinction_color at extreme depths
	float inscatter_factor = 1.0 - exp(-turbidity * water_path);
	vec3 local_scatter_color = mix(water_scatter_color, deep_extinction_color, clamp(depth_below_surface * 0.04, 0.0, 1.0));
	vec3 inscattered_light = local_scatter_color * (ambient_sun + vec3(0.12, 0.22, 0.32)) * inscatter_factor;

	// 4. Underwater Caustics on underwater surfaces
	vec3 caustics_light = vec3(0.0);
	if (!is_sky && world_pos.y <= 0.0) {
		float depth_caustic_fade = exp(-abs(world_pos.y) * 0.12);
		float caustic_val = get_caustics(world_pos.xz, time_val);
		caustics_light = sun_color * (caustic_val * caustics_strength * depth_caustic_fade * clamp(sun_direction.y, 0.0, 1.0));
	}

	// 5. Final Color Assembly
	vec3 attenuated_scene = (scene_color + caustics_light) * extinction;
	vec3 final_color = attenuated_scene + inscattered_light;

	// Soft transition near water surface boundary (y between -0.2 and 0.2)
	float surface_blend = clamp((-cam_pos.y + 0.1) / 0.3, 0.0, 1.0);
	ALBEDO = mix(scene_color, final_color, surface_blend);
}
