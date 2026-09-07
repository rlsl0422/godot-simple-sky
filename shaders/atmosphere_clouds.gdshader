shader_type sky;
render_mode use_half_res_pass;

/*
 * Physically-Based Atmosphere & Volumetric Clouds System
 * Designed for Godot 4.7 Forward+ with Golden Cross Performance Optimizations.
 *
 * All planetary raymarching calculations are normalized to Kilometer (km) units
 * to ensure pristine 32-bit floating point precision and eliminate catastrophic cancellation.
 */

// ==========================================
// UNIFORMS: ATMOSPHERE & SUN
// ==========================================
group_uniforms Atmosphere;
uniform vec3 sun_direction = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.88);
uniform float sun_intensity : hint_range(0.0, 50.0, 0.1) = 22.0;
uniform float sun_disk_size : hint_range(0.001, 0.05, 0.001) = 0.015;
uniform float atmosphere_density : hint_range(0.1, 5.0, 0.1) = 1.0;
uniform float rayleigh_strength : hint_range(0.1, 4.0, 0.1) = 1.0;
uniform float mie_strength : hint_range(0.0, 5.0, 0.1) = 1.2;
uniform float ozone_strength : hint_range(0.0, 4.0, 0.1) = 1.2;
uniform vec3 ground_color : source_color = vec3(0.12, 0.10, 0.08);

// ==========================================
// UNIFORMS: VOLUMETRIC CLOUDS
// ==========================================
group_uniforms Clouds;
uniform bool clouds_enabled = true;
uniform sampler3D base_noise_tex : filter_linear, repeat_enable;
uniform sampler3D detail_noise_tex : filter_linear, repeat_enable;
uniform sampler2D weather_tex : filter_linear, repeat_enable;

uniform float cloud_coverage : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform float cloud_density_multiplier : hint_range(0.1, 5.0, 0.1) = 1.2;
uniform float cloud_bottom_altitude : hint_range(500.0, 5000.0, 50.0) = 1600.0; // In meters
uniform float cloud_top_altitude : hint_range(2000.0, 10000.0, 50.0) = 4400.0;   // In meters
uniform float cloud_scale : hint_range(0.05, 2.0, 0.01) = 0.22;                   // 1/km scale
uniform float detail_scale : hint_range(0.5, 10.0, 0.1) = 3.5;
uniform float detail_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float weather_scale : hint_range(0.005, 0.2, 0.005) = 0.045;

uniform vec3 wind_direction = vec3(1.0, 0.0, 0.5);
uniform float wind_speed : hint_range(0.0, 100.0, 0.5) = 15.0; // m/s
uniform float custom_time = 0.0;
uniform vec3 camera_world_position = vec3(0.0);

// ==========================================
// UNIFORMS: LIGHTING & SCATTERING
// ==========================================
group_uniforms Cloud_Lighting;
uniform float forward_scattering_g : hint_range(0.1, 0.99, 0.01) = 0.78;
uniform float backward_scattering_g : hint_range(0.0, 0.8, 0.01) = 0.32;
uniform float silver_lining_spread : hint_range(0.5, 0.999, 0.001) = 0.95;
uniform float silver_lining_intensity : hint_range(0.0, 5.0, 0.1) = 2.4;
uniform float powder_effect_strength : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform float ambient_intensity : hint_range(0.0, 3.0, 0.05) = 0.85;
uniform vec3 cloud_base_color : source_color = vec3(0.94, 0.95, 0.98);
uniform vec3 cloud_ambient_color : source_color = vec3(0.42, 0.50, 0.65);

// ==========================================
// UNIFORMS: QUALITY & PERFORMANCE (GOLDEN CROSS)
// ==========================================
group_uniforms Performance;
uniform int max_steps : hint_range(16, 96, 2) = 36;
uniform int max_light_steps : hint_range(2, 8, 1) = 4;
uniform float empty_skip_multiplier : hint_range(1.0, 3.0, 0.1) = 2.0;
uniform float max_distance_km : hint_range(10.0, 60.0, 1.0) = 24.0;
uniform float detail_lod_distance_km : hint_range(4.0, 20.0, 1.0) = 12.0;

// ==========================================
// UNIFORMS: POST PROCESSING & TONE MAPPING
// ==========================================
group_uniforms Post_Processing;
uniform int tonemap_mode : hint_range(0, 3, 1) = 1; // 0: None (Linear HDR), 1: ACES Film, 2: Reinhard, 3: Filmic
uniform float exposure : hint_range(0.1, 4.0, 0.05) = 1.0;
uniform float white_point : hint_range(1.0, 20.0, 0.5) = 6.0;
uniform float sun_corona_intensity : hint_range(0.0, 1.0, 0.05) = 0.20;

// ==========================================
// PHYSICAL CONSTANTS (Normalized to Kilometers)
// ==========================================
const float R_EARTH = 6360.0;       // Earth radius: 6360 km
const float R_ATMOSPHERE = 6420.0;  // Atmosphere radius: 6420 km (60km thickness)
const float H_RAYLEIGH = 8.0;       // Scale height: 8 km
const float H_MIE = 1.2;            // Scale height: 1.2 km

// Scattering coefficients per km (scaled from standard SI wavelength factors)
const vec3 BETA_R = vec3(0.0058, 0.0135, 0.0331);
const vec3 BETA_M = vec3(0.0210);
const vec3 BETA_O = vec3(0.000342, 0.000829, 0.000035);

// Interleaved Gradient Noise for screen-space ray jittering (Jimenez 2014)
float get_ign(vec2 screen_uv) {
	vec2 pixel_pos = screen_uv * vec2(1920.0, 1080.0);
	vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
	return fract(magic.z * fract(dot(pixel_pos, magic.xy)));
}

// Robust Ray-Sphere intersection in km space
bool ray_sphere_intersect(vec3 ro, vec3 rd, float rad, out float t0, out float t1) {
	float b = dot(ro, rd);
	float c = dot(ro, ro) - rad * rad;
	float d = b * b - c;
	if (d < 0.0) {
		t0 = -1.0;
		t1 = -1.0;
		return false;
	}
	float sqrt_d = sqrt(d);
	t0 = -b - sqrt_d;
	t1 = -b + sqrt_d;
	return true;
}

// Henyey-Greenstein Phase Function
float henyey_greenstein(float cos_angle, float g) {
	float g2 = g * g;
	return ((1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_angle, 1.5)));
}

// Dual Henyey-Greenstein Phase Function
float dual_henyey_greenstein(float cos_theta, float g_fwd, float g_back) {
	float fwd = henyey_greenstein(cos_theta, g_fwd);
	float bck = henyey_greenstein(cos_theta, -g_back);
	return mix(bck, fwd, 0.7);
}

// Rayleigh Phase Function
float rayleigh_phase(float cos_theta) {
	return (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
}

// Remap helper
float remap(float val, float old_min, float old_max, float new_min, float new_max) {
	return new_min + (((val - old_min) / max(old_max - old_min, 0.00001)) * (new_max - new_min));
}

// Photographic Tone Mapping & Exposure Pipeline
vec3 apply_tonemapping(vec3 color, float exp_val, int mode, float wp) {
	vec3 x = color * exp_val;
	if (mode == 1) {
		// ACES Film Tone Mapping (Narkowicz 2015)
		const float a = 2.51;
		const float b = 0.03;
		const float c = 2.43;
		const float d = 0.59;
		const float e = 0.14;
		return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
	} else if (mode == 2) {
		// Reinhard Extended Tone Mapping with White Point
		return (x * (1.0 + x / (wp * wp))) / (1.0 + x);
	} else if (mode == 3) {
		// Filmic Shoulder Rolloff
		vec3 cur = max(vec3(0.0), x - 0.004);
		return (cur * (6.2 * cur + 0.5)) / (cur * (6.2 * cur + 1.7) + 0.06);
	}
	// Mode 0: None / Linear HDR passthrough
	return x;
}

// Atmospheric In-Scattering in km space
void compute_atmosphere(vec3 eye_pos_km, vec3 ray_dir, vec3 sun_dir, out vec3 sky_color, out vec3 sun_light_color) {
	float t_atm_0, t_atm_1;
	bool hit_atm = ray_sphere_intersect(eye_pos_km, ray_dir, R_ATMOSPHERE, t_atm_0, t_atm_1);
	
	if (!hit_atm || t_atm_1 <= 0.0) {
		sky_color = vec3(0.01, 0.02, 0.04);
		sun_light_color = sun_color * sun_intensity;
		return;
	}
	
	float t_start = max(t_atm_0, 0.0);
	float t_end = t_atm_1;
	
	// Planet ground cutoff
	float t_earth_0, t_earth_1;
	if (ray_sphere_intersect(eye_pos_km, ray_dir, R_EARTH, t_earth_0, t_earth_1)) {
		if (t_earth_0 > 0.0) {
			t_end = min(t_end, t_earth_0);
		}
	}
	
	const int ATM_STEPS = 10;
	float step_size = (t_end - t_start) / float(ATM_STEPS);
	float cos_theta = dot(ray_dir, sun_dir);
	
	float p_rayleigh = rayleigh_phase(cos_theta);
	// Forward Mie scattering (solar aureole): soft, warm halo around the sun that gracefully drops into sky blue
	float p_mie = henyey_greenstein(cos_theta, 0.75) * 0.18;
	
	vec3 total_rayleigh = vec3(0.0);
	vec3 total_mie = vec3(0.0);
	vec3 optical_depth = vec3(0.0);
	
	vec3 current_pos = eye_pos_km + ray_dir * (t_start + step_size * 0.5);
	
	for (int i = 0; i < ATM_STEPS; i++) {
		float height = length(current_pos) - R_EARTH;
		if (height > 0.0) {
			float d_rayleigh = exp(-height / H_RAYLEIGH) * step_size * rayleigh_strength * atmosphere_density;
			float d_mie = exp(-height / H_MIE) * step_size * mie_strength * atmosphere_density;
			
			// Light path to sun
			float t_sun_0, t_sun_1;
			ray_sphere_intersect(current_pos, sun_dir, R_ATMOSPHERE, t_sun_0, t_sun_1);
			float sun_step = max(t_sun_1, 0.0) / 4.0;
			float sun_od_r = 0.0;
			float sun_od_m = 0.0;
			
			for (int j = 0; j < 4; j++) {
				vec3 sun_pos = current_pos + sun_dir * (sun_step * (float(j) + 0.5));
				float h_sun = length(sun_pos) - R_EARTH;
				if (h_sun > 0.0) {
					sun_od_r += exp(-h_sun / H_RAYLEIGH) * sun_step * rayleigh_strength * atmosphere_density;
					sun_od_m += exp(-h_sun / H_MIE) * sun_step * mie_strength * atmosphere_density;
				}
			}
			
			vec3 tau = BETA_R * (optical_depth.x + sun_od_r) +
			           BETA_M * 1.1 * (optical_depth.y + sun_od_m) +
			           BETA_O * ozone_strength * (optical_depth.x + sun_od_r);
			vec3 attenuation = exp(-tau);
			
			total_rayleigh += attenuation * d_rayleigh;
			total_mie += attenuation * d_mie;
			optical_depth += vec3(d_rayleigh, d_mie, 0.0);
		}
		current_pos += ray_dir * step_size;
	}
	
	vec3 inscattering = (total_rayleigh * BETA_R * p_rayleigh + total_mie * BETA_M * p_mie) * sun_intensity * sun_color;
	
	vec3 horizon_tint = mix(vec3(0.015, 0.03, 0.06), inscattering, smoothstep(-0.06, 0.08, sun_dir.y));
	sky_color = horizon_tint;
	
	vec3 direct_sun_tau = BETA_R * optical_depth.x + BETA_M * optical_depth.y;
	sun_light_color = sun_color * sun_intensity * exp(-direct_sun_tau * 0.5);
}

// Sample Cloud Density (pos in km space)
float sample_cloud_density(vec3 pos_km, float height_norm, vec2 wind_offset_km, bool sample_detail) {
	// 1. Weather Map Sampling (Coverage, Cloud Type, Density)
	vec2 weather_uv = (pos_km.xz + wind_offset_km * 0.04) * weather_scale;
	vec4 weather = texture(weather_tex, weather_uv);
	
	float cov_thresh = 1.0 - clamp(cloud_coverage * 1.25, 0.05, 0.95);
	float cluster_mask = smoothstep(cov_thresh - 0.22, cov_thresh + 0.22, weather.r);
	if (cluster_mask < 0.005) return 0.0;
	
	// 2. 3D Organic Convective Profile (Banishes flat tabletop plank):
	float edge_taper = smoothstep(0.0, 0.50, cluster_mask);
	
	// Base undulates with weather map B channel (local thermal updrafts):
	float base_undulation = (weather.b - 0.5) * 0.18;
	float base_start = 0.02 + (1.0 - edge_taper) * 0.25 + base_undulation;
	float base_fade = smoothstep(base_start, base_start + 0.18, height_norm);
	
	// Rounded dome ceiling: centers billow high into cauliflower heads, edges curve down
	float top_ceiling = 0.65 + edge_taper * 0.32;
	float top_fade = 1.0 - smoothstep(top_ceiling * 0.72, top_ceiling, height_norm);
	
	float h_grad = base_fade * top_fade;
	if (h_grad < 0.005) return 0.0;
	
	// 3. 3D Coordinates & Base Shape Texture Sampling
	vec3 p = vec3(pos_km.x * cloud_scale, (pos_km.y - R_EARTH) * cloud_scale, pos_km.z * cloud_scale)
	         + vec3(wind_offset_km.x, 0.0, wind_offset_km.y) * 0.10;
	
	// Domain warp from weather map channels to create wind-swept vortices
	vec3 warp = vec3(weather.g - 0.5, 0.0, weather.b - 0.5) * 0.25;
	vec4 base_sample = texture(base_noise_tex, p + warp);
	
	// 4. Combined Perlin-Worley + Cauliflower Billow lobes (Zone I)
	// Base shape (R) modulated by medium (G) and fine (B, A) Worley lobes
	float billow_lobes = base_sample.g * 0.60 + base_sample.b * 0.28 + base_sample.a * 0.12;
	float cloud_shape = remap(base_sample.r, -(1.0 - billow_lobes) * 0.40, 1.0, 0.0, 1.0);
	
	// Updraft dome has prominent rounded billow lobes (cauliflower texture)
	cloud_shape = mix(cloud_shape, billow_lobes, smoothstep(0.35, 0.85, height_norm) * 0.45);
	
	float cloud_mass = cloud_shape * h_grad * cluster_mask;
	
	// 5. Density thresholding
	float cov_threshold = 0.18;
	float density = smoothstep(cov_threshold, cov_threshold + 0.32, cloud_mass) * cloud_density_multiplier * 3.6;
	
	// 6. Micro-detail erosion (only for nearby clouds to maintain 60 FPS)
	if (density > 0.01 && sample_detail) {
		vec3 detail_p = (p + warp) * detail_scale + vec3(wind_offset_km.x, 0.0, wind_offset_km.y) * 0.25;
		vec4 detail_noise = texture(detail_noise_tex, detail_p);
		float detail_fbm = detail_noise.r * 0.625 + detail_noise.g * 0.25 + detail_noise.b * 0.125;
		float erosion = mix(detail_fbm, 1.0 - detail_fbm, clamp(height_norm * 0.5, 0.0, 1.0));
		density = remap(density, erosion * detail_strength * 0.35, 1.0, 0.0, 1.0);
		density = max(density, 0.0);
	}
	
	return density;
}

void sky() {
	vec3 ray_dir = normalize(EYEDIR);
	vec3 sun_dir = normalize(sun_direction);
	
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	// Wind offset in km
	vec2 wind_offset_km = wind_direction.xz * (wind_speed * 0.001) * time_val;
	
	// Camera world position in km space
	vec3 camera_pos_km = vec3(0.0, R_EARTH + 0.02, 0.0) + camera_world_position * 0.001;
	
	// 1. Atmosphere Base Pass
	vec3 sky_color = vec3(0.0);
	vec3 sun_light_color = vec3(0.0);
	compute_atmosphere(camera_pos_km, ray_dir, sun_dir, sky_color, sun_light_color);
	
	// 2. Cloud Shell Ray-Sphere Intersections in km space
	float r_bottom_km = R_EARTH + (cloud_bottom_altitude * 0.001);
	float r_top_km = R_EARTH + (cloud_top_altitude * 0.001);
	
	float t_bot_0, t_bot_1;
	float t_top_0, t_top_1;
	bool hit_bottom = ray_sphere_intersect(camera_pos_km, ray_dir, r_bottom_km, t_bot_0, t_bot_1);
	bool hit_top = ray_sphere_intersect(camera_pos_km, ray_dir, r_top_km, t_top_0, t_top_1);
	
	float t_start = -1.0;
	float t_end = -1.0;
	float cam_dist = length(camera_pos_km);
	
	if (cam_dist < r_bottom_km) {
		if (hit_bottom && t_bot_1 > 0.0) {
			t_start = max(t_bot_1, 0.0);
			t_end = t_top_1;
		}
	} else if (cam_dist <= r_top_km) {
		t_start = 0.0;
		t_end = hit_bottom && t_bot_0 > 0.0 ? t_bot_0 : t_top_1;
	} else {
		if (hit_top && t_top_0 > 0.0) {
			t_start = t_top_0;
			t_end = hit_bottom && t_bot_0 > 0.0 ? t_bot_0 : t_top_1;
		}
	}
	
	// Earth ground cutoff
	float t_ground_0, t_ground_1;
	bool hit_ground = ray_sphere_intersect(camera_pos_km, ray_dir, R_EARTH, t_ground_0, t_ground_1) && (t_ground_0 > 0.0);
	if (hit_ground) {
		t_end = min(t_end, t_ground_0);
		if (t_start > t_ground_0) {
			t_start = -1.0;
		}
	}
	
	// Clamp marching distance to max_distance_km to prevent horizon ray stretching & slice banding
	if (t_start >= 0.0) {
		if (t_start >= max_distance_km) {
			t_start = -1.0; // Distant horizon rays beyond max distance seamlessly merge into pure atmospheric haze
		} else {
			t_end = min(t_end, max_distance_km);
		}
	}
	
	// 3. Physical Sun Disc with smooth limb darkening, soft corona, and ground cutoff
	vec3 sun_disc_color = vec3(0.0);
	float cos_sun = dot(ray_dir, sun_dir);
	if (!hit_ground && ray_dir.y > -0.02) {
		float sun_angular_radius = sun_disk_size * 0.5;
		float sun_angular_dist = acos(clamp(cos_sun, -1.0, 1.0));
		
		if (sun_angular_dist < sun_angular_radius) {
			float mu = sqrt(max(0.0, 1.0 - (sun_angular_dist * sun_angular_dist) / (sun_angular_radius * sun_angular_radius)));
			float limb = 0.55 + 0.45 * mu;
			float edge_soft = smoothstep(sun_angular_radius, sun_angular_radius * 0.85, sun_angular_dist);
			sun_disc_color = sun_light_color * 1.5 * limb * edge_soft;
		}
		
		float corona = pow(clamp(cos_sun, 0.0, 1.0), 500.0) * (sun_corona_intensity * 0.25);
		sun_disc_color += sun_light_color * corona;
	}
	
	// 4. Volumetric Raymarching
	if (clouds_enabled && t_start >= 0.0 && t_end > t_start) {
		float march_length = t_end - t_start;
		float base_step = march_length / float(max_steps);
		
		// Low-discrepancy screen-space ray jitter using Interleaved Gradient Noise (Jimenez 2014)
		// Full [0, 1] range completely destroys all slice alignment and staircase terracing (Fixes Feedback 4)
		float dither = get_ign(SCREEN_UV);
		float current_t = t_start + base_step * dither;
		
		vec3 accumulated_cloud_color = vec3(0.0);
		float transmittance = 1.0;
		
		float phase_cloud = dual_henyey_greenstein(cos_sun, forward_scattering_g, backward_scattering_g);
		float silver_lining = pow(clamp(cos_sun, 0.0, 1.0), 24.0) * silver_lining_intensity;
		
		int consecutive_zeros = 0;
		
		for (int i = 0; i < max_steps; i++) {
			if (current_t >= t_end || transmittance < 0.01) break;
			
			vec3 sample_pos = camera_pos_km + ray_dir * current_t;
			float current_alt = length(sample_pos);
			float height_norm = clamp((current_alt - r_bottom_km) / (r_top_km - r_bottom_km), 0.0, 1.0);
			
			bool sample_detail = current_t < detail_lod_distance_km;
			float density = sample_cloud_density(sample_pos, height_norm, wind_offset_km, sample_detail);
			
			// Distance fade near horizon: smoothly merges distant clouds into the horizon boundary haze
			float horizon_fade = clamp(1.0 - (current_t - (max_distance_km * 0.55)) / (max_distance_km * 0.45), 0.0, 1.0);
			density *= horizon_fade;
			
			if (density > 0.001) {
				consecutive_zeros = 0;
				
				// Progressive multi-scale light marching toward sun (in km):
				float optical_depth_sun = 0.0;
				float l_dists[4] = float[4](0.15, 0.45, 1.20, 2.80);
				float l_weights[4] = float[4](0.22, 0.48, 1.00, 1.80);
				
				for (int j = 0; j < max_light_steps; j++) {
					int idx = min(j, 3);
					float l_dist = l_dists[idx];
					vec3 light_pos = sample_pos + sun_dir * l_dist;
					float l_alt = length(light_pos);
					float l_height_norm = clamp((l_alt - r_bottom_km) / (r_top_km - r_bottom_km), 0.0, 1.0);
					
					float l_dens = sample_cloud_density(light_pos, l_height_norm, wind_offset_km, false);
					optical_depth_sun += l_dens * l_weights[idx] * 8.5;
				}
				
				// Smooth light attenuation without binary cliffs (eliminates salt-and-pepper shadow grain)
				float beer = exp(-optical_depth_sun * 0.60);
				float powder = 1.0 - exp(-optical_depth_sun * 1.6 * powder_effect_strength);
				float sun_light_attenuation = beer * mix(1.0, powder, 0.55);
				// Multiple forward scattering softens shadow underbelly like real clouds in reference photo
				float multi_scatter = exp(-optical_depth_sun * 0.12) * 0.45;
				
				// Hemispherical ambient lighting: blue skylight from above + warm terrain bounce from below
				float crevice_ao = clamp(1.0 - density * 0.20, 0.30, 1.0);
				vec3 sky_ambient = sky_color * 0.60 + cloud_ambient_color * 0.75;
				vec3 ground_ambient = ground_color * 0.60 + vec3(0.06, 0.05, 0.04);
				vec3 ambient = mix(ground_ambient, sky_ambient, clamp(height_norm * 1.2, 0.0, 1.0)) * ambient_intensity * crevice_ao;
				
				vec3 sun_normalized = sun_light_color / max(sun_intensity, 1.0);
				float phase_term = phase_cloud + silver_lining * 0.45;
				float direct_lighting = sun_light_attenuation * phase_term + multi_scatter * 0.55;
				vec3 direct_sun = sun_normalized * direct_lighting * 1.6;
				vec3 step_energy = (direct_sun + ambient) * cloud_base_color;
				
				// Soft, physically plausible volumetric extinction
				float sample_step_extinction = density * base_step * 8.0;
				float sample_transmittance = exp(-sample_step_extinction);
				
				accumulated_cloud_color += step_energy * (1.0 - sample_transmittance) * transmittance;
				transmittance *= sample_transmittance;
				
				current_t += base_step;
			} else {
				consecutive_zeros++;
				float skip = consecutive_zeros > 2 ? base_step * empty_skip_multiplier : base_step;
				current_t += skip;
			}
		}
		
		// Aerial perspective (haze over distant clouds)
		float dist_to_clouds = min(t_start, max_distance_km);
		float haze_factor = 1.0 - exp(-dist_to_clouds * 0.035 * atmosphere_density);
		accumulated_cloud_color = mix(accumulated_cloud_color, sky_color * (1.0 - transmittance), haze_factor * 0.65);
		
		// Sun disc dissolves exponentially into clouds; only forward Mie glow remains behind clouds
		vec3 direct_sun_disc = sun_disc_color * pow(transmittance, 2.2);
		
		vec3 final_color = sky_color * transmittance + accumulated_cloud_color + direct_sun_disc;
		COLOR = apply_tonemapping(final_color, exposure, tonemap_mode, white_point);
	} else {
		vec3 final_color = sky_color + sun_disc_color;
		COLOR = apply_tonemapping(final_color, exposure, tonemap_mode, white_point);
	}
}
