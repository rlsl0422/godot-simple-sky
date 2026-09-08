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
uniform vec3 ground_color : source_color = vec3(0.18, 0.22, 0.20);
uniform vec3 deep_water_color : source_color = vec3(0.012, 0.080, 0.220);

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
uniform float cloud_scale : hint_range(0.05, 2.0, 0.01) = 0.12;                   // 1/km scale
uniform float detail_scale : hint_range(0.5, 10.0, 0.1) = 3.5;
uniform float detail_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float weather_scale : hint_range(0.005, 0.2, 0.005) = 0.045;
uniform float cloud_curvature_radius_km : hint_range(150.0, 3000.0, 10.0) = 300.0; // Effective planetary curvature for clouds

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
uniform vec3 cloud_base_color : source_color = vec3(0.96, 0.97, 1.0);
uniform vec3 cloud_ambient_color : source_color = vec3(0.65, 0.72, 0.85);

// ==========================================
// UNIFORMS: QUALITY & PERFORMANCE (GOLDEN CROSS)
// ==========================================
group_uniforms Performance;
uniform int max_steps : hint_range(16, 96, 2) = 36;
uniform int max_light_steps : hint_range(2, 8, 1) = 4;
uniform float empty_skip_multiplier : hint_range(1.0, 3.0, 0.05) = 1.15;
uniform float max_distance_km : hint_range(10.0, 60.0, 1.0) = 36.0;
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
float get_ign(vec2 pixel_pos) {
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
	float cam_height = length(eye_pos_km) - R_EARTH;
	float horizon_dip = -sqrt(max(2.0 * cam_height / R_EARTH, 0.0));
	vec3 march_dir = ray_dir;
	if (march_dir.y < horizon_dip + 0.002) {
		march_dir = normalize(vec3(ray_dir.x, horizon_dip + 0.002, ray_dir.z));
	}
	
	float t_atm_0, t_atm_1;
	bool hit_atm = ray_sphere_intersect(eye_pos_km, march_dir, R_ATMOSPHERE, t_atm_0, t_atm_1);
	
	if (!hit_atm || t_atm_1 <= 0.0) {
		sky_color = vec3(0.01, 0.02, 0.04);
		sun_light_color = sun_color * sun_intensity;
		return;
	}
	
	float t_start = max(t_atm_0, 0.0);
	float t_end = min(t_atm_1, t_start + 45.0);
	
	const int ATM_STEPS = 10;
	float step_size = (t_end - t_start) / float(ATM_STEPS);
	float cos_theta = dot(march_dir, sun_dir);
	
	float p_rayleigh = rayleigh_phase(cos_theta);
	// Forward Mie scattering (solar aureole): soft, warm halo around the sun that gracefully drops into sky blue
	float p_mie = henyey_greenstein(cos_theta, 0.75) * 0.18;
	
	vec3 total_rayleigh = vec3(0.0);
	vec3 total_mie = vec3(0.0);
	vec3 optical_depth = vec3(0.0);
	
	vec3 current_pos = eye_pos_km + march_dir * (t_start + step_size * 0.5);
	
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
		current_pos += march_dir * step_size;
	}
	
	vec3 inscattering = (total_rayleigh * BETA_R * p_rayleigh + total_mie * BETA_M * p_mie) * sun_intensity * sun_color;
	
	vec3 horizon_tint = mix(vec3(0.015, 0.03, 0.06), inscattering, smoothstep(-0.06, 0.08, sun_dir.y));
	
	// Marine Boundary Layer (MBL) forward & multiple-scattered aerosol white haze (Photo matching)
	float h_angle = march_dir.y - horizon_dip;
	float aerosol_band = exp(-max(h_angle, 0.0) / 0.038);
	float sun_elev = clamp(sun_dir.y * 1.2 + 0.15, 0.05, 1.0);
	vec3 sun_norm = sun_color * sun_elev;
	vec3 aerosol_white = mix(vec3(0.88, 0.93, 0.98), sun_norm, 0.35) * clamp(sun_intensity * 0.058, 0.6, 1.4);
	horizon_tint = mix(horizon_tint, aerosol_white, aerosol_band * 0.68 * clamp(sun_dir.y * 2.0 + 0.2, 0.0, 1.0));
	
	sky_color = horizon_tint;
	
	vec3 direct_sun_tau = BETA_R * optical_depth.x + BETA_M * optical_depth.y;
	sun_light_color = sun_color * sun_intensity * exp(-direct_sun_tau * 0.5);
}

// Sample Cloud Density (pos in km space)
float sample_cloud_density(vec3 pos_km, float height_norm, vec2 wind_offset_km, float detail_fade) {
	// 1. Multi-scale Weather Map Sampling (Coverage, Cloud Type, Density)
	vec2 weather_uv = (pos_km.xz + wind_offset_km * 0.04) * weather_scale;
	vec4 weather = texture(weather_tex, weather_uv);
	
	float macro_cov = weather.r;
	// Use weather.b (density noise) as micro convective variation without expensive second texture sample
	float micro_cov = clamp(weather.b * 1.35 - 0.15, 0.0, 1.0);
	
	// Dual-scale coverage combination:
	// Macro systems establish vast cloud fronts; micro pockets populate standalone small cumulus
	float cloud_system = max(macro_cov, micro_cov * 0.76);
	float cov_thresh = 1.0 - clamp(cloud_coverage * 1.32, 0.08, 0.92);
	float cluster_mask = smoothstep(cov_thresh - 0.20, cov_thresh + 0.16, cloud_system);
	if (cluster_mask < 0.005) return 0.0;
	
	// Cloud scale metric: 0.0 = small distinct cloud, 1.0 = massive cloud front
	float cloud_size_factor = smoothstep(cov_thresh - 0.10, cov_thresh + 0.18, macro_cov);
	
	// 2. 3D Convective Profile with Towering Cauliflower Updrafts:
	float edge_taper = smoothstep(0.0, 0.45, cluster_mask);
	
	// Base condensation line (flat, velvety underside):
	float base_start = mix(0.04, 0.01, cloud_size_factor) + (1.0 - edge_taper) * 0.16 + (weather.b - 0.5) * 0.12;
	float base_fade = smoothstep(base_start, base_start + 0.12, height_norm);
	
	// Dome top: Towers can reach up to height_norm = 0.96!
	// Gentle rolloff so 3D Worley domes form natural rounded cauliflower peaks without being cut flat!
	float max_height = mix(0.68, 0.96, cloud_size_factor) + edge_taper * 0.12;
	float top_fade = smoothstep(max_height, max_height - 0.38, height_norm);
	
	float h_grad = base_fade * top_fade;
	if (h_grad < 0.005) return 0.0;
	
	// 3. 3D Coordinates with Isotropic Spherical Lobe Scaling
	// Vertical multiplier (1.85) ensures vertical cauliflower lobes are round and spherical rather than pancake squashed!
	vec3 p = vec3(pos_km.x * cloud_scale, (pos_km.y - R_EARTH) * (cloud_scale * 1.85), pos_km.z * cloud_scale)
	         + vec3(wind_offset_km.x, 0.0, wind_offset_km.y) * 0.10;
	
	// Domain warp from weather map channels to create wind-swept vortices
	vec3 warp = vec3(weather.g - 0.5, 0.0, weather.b - 0.5) * 0.25;
	vec4 base_sample = texture(base_noise_tex, p + warp);
	
	// 4. Combined Perlin-Worley + Cauliflower Billow lobes (Zone I)
	float billow_worley = base_sample.g * 0.60 + base_sample.b * 0.28 + base_sample.a * 0.12;
	// Bulging spherical cauliflower lobes: cell centers bulge outward, valleys indent
	float lobe_sculpt = remap(base_sample.r, (1.0 - billow_worley) * 0.35, 1.0, 0.0, 1.0);
	
	// Large clouds retain an expansive, cohesive core instead of shredding into small uniform pieces
	float core_preservation = smoothstep(0.25, 0.75, cluster_mask) * cloud_size_factor;
	float billow_mod = mix(0.70 + 0.45 * billow_worley, 0.92 + 0.25 * billow_worley, core_preservation * 0.80);
	float cloud_shape = lobe_sculpt * billow_mod;
	
	// Updraft dome accentuates rounded billows toward the top
	float dome_boost = smoothstep(0.25, 0.85, height_norm);
	cloud_shape = mix(cloud_shape, cloud_shape * (0.75 + 0.60 * billow_worley), dome_boost * 0.55);
	
	float cloud_mass = cloud_shape * h_grad * cluster_mask;
	
	// 5. Density thresholding with smooth yet plump condensation boundary
	float cov_threshold = mix(0.18, 0.13, core_preservation);
	float density = smoothstep(cov_threshold, cov_threshold + 0.22, cloud_mass) * cloud_density_multiplier * 3.4;
	
	// 6. Micro-detail erosion: active on upper billows, suppressed on cloud base for velvety smooth underside
	if (density > 0.005 && detail_fade > 0.01) {
		vec3 detail_p = (p + warp) * detail_scale + vec3(wind_offset_km.x, 0.0, wind_offset_km.y) * 0.25;
		vec4 detail_noise = texture(detail_noise_tex, detail_p);
		float detail_fbm = detail_noise.r * 0.625 + detail_noise.g * 0.25 + detail_noise.b * 0.125;
		float erosion = mix(detail_fbm, 1.0 - detail_fbm, clamp(height_norm * 0.5, 0.0, 1.0));
		float base_suppress = smoothstep(0.08, 0.32, height_norm); // Velvety smooth cloud base
		float edge_mask = clamp(1.0 - density * 0.30, 0.0, 1.0);
		float erode_amount = erosion * detail_strength * 0.22 * detail_fade * edge_mask * base_suppress;
		density = smoothstep(erode_amount, 1.0, density) * density;
	}
	
	return density;
}

// Physically-based distant planetary ocean shading
vec3 compute_distant_ocean(vec3 eye_pos_km, vec3 ray_dir, vec3 sun_dir, vec3 sun_light_color, vec3 sky_color, float t_ground, float time_val) {
	vec3 hit_p_km = eye_pos_km + ray_dir * t_ground;
	vec3 N = normalize(hit_p_km); // Planetary sphere normal
	
	// Micro-ripples on planetary scale
	float wave_phase = dot(hit_p_km.xz, vec2(15.0, 11.0)) + time_val * 1.5;
	vec3 wave_n = normalize(vec3(sin(wave_phase) * 0.04, 1.0, cos(wave_phase) * 0.04));
	N = normalize(mix(N, wave_n, 0.35));
	
	vec3 V = -ray_dir;
	float NdotV = clamp(dot(N, V), 0.0, 1.0);
	float f0 = 0.02;
	float fresnel = f0 + (1.0 - f0) * pow(1.0 - NdotV, 5.0);
	
	// Sun Specular (GGX)
	vec3 H = normalize(sun_dir + V);
	float NdotH = clamp(dot(N, H), 0.0, 1.0);
	float alpha2 = 0.02;
	float denom = (NdotH * NdotH * (alpha2 - 1.0) + 1.0);
	float D = alpha2 / (3.14159265 * denom * denom + 0.0001);
	vec3 specular = sun_light_color * D * fresnel * clamp(sun_dir.y * 1.5, 0.0, 1.0) * 0.35;
	
	// Deep Ocean Base Color + Fresnel Reflection of Sky
	vec3 diffuse_water = deep_water_color * (sun_light_color * 0.07 * clamp(sun_dir.y, 0.05, 1.0) + sky_color * 0.70);
	vec3 reflected_sky = mix(sky_color * 0.75, vec3(0.18, 0.38, 0.65), 0.45);
	vec3 ocean_surface = mix(diffuse_water, reflected_sky, fresnel) + specular;
	
	return ocean_surface;
}

void sky() {
	vec3 ray_dir = normalize(EYEDIR);
	vec3 sun_dir = normalize(sun_direction);
	
	float time_val = custom_time > 0.0 ? custom_time : TIME;
	// Wind offset in km
	vec2 wind_offset_km = wind_direction.xz * (wind_speed * 0.001) * time_val;
	
	// Camera world position in km space with minimum safe ground clearance
	float safe_cam_alt = max(camera_world_position.y, 2.0) * 0.001;
	vec3 camera_pos_km = vec3(camera_world_position.x * 0.001, R_EARTH + safe_cam_alt, camera_world_position.z * 0.001);
	
	// 1. Atmosphere Base Pass
	vec3 sky_color = vec3(0.0);
	vec3 sun_light_color = vec3(0.0);
	compute_atmosphere(camera_pos_km, ray_dir, sun_dir, sky_color, sun_light_color);
	
	// 2. Curved Cloud Shell Ray-Sphere Intersections in km space
	// Uses effective planetary curvature radius (cloud_curvature_radius_km) so distant clouds
	// physically descend toward the horizon and merge with the sea horizon haze naturally.
	float r_curv = cloud_curvature_radius_km;
	vec3 cam_cloud_km = vec3(0.0, r_curv + safe_cam_alt, 0.0);
	float r_bottom_curv = r_curv + (cloud_bottom_altitude * 0.001);
	float r_top_curv = r_curv + (cloud_top_altitude * 0.001);
	
	float t_bot_0, t_bot_1;
	float t_top_0, t_top_1;
	bool hit_bottom = ray_sphere_intersect(cam_cloud_km, ray_dir, r_bottom_curv, t_bot_0, t_bot_1);
	bool hit_top = ray_sphere_intersect(cam_cloud_km, ray_dir, r_top_curv, t_top_0, t_top_1);
	
	float t_start = -1.0;
	float t_end = -1.0;
	float cam_dist = length(cam_cloud_km);
	
	if (cam_dist < r_bottom_curv) {
		if (hit_bottom && t_bot_1 > 0.0) {
			t_start = max(t_bot_1, 0.0);
			t_end = t_top_1;
		}
	} else if (cam_dist <= r_top_curv) {
		t_start = 0.0;
		t_end = hit_bottom && t_bot_0 > 0.0 ? t_bot_0 : t_top_1;
	} else {
		if (hit_top && t_top_0 > 0.0) {
			t_start = t_top_0;
			t_end = hit_bottom && t_bot_0 > 0.0 ? t_bot_0 : t_top_1;
		}
	}
	
	// Earth ground cutoff (prevents clouds from ever dipping beneath the ocean surface)
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
		// Spanning full [0, 1) range guarantees 100% continuous coverage with zero dead-zone slice gaps,
		// completely eliminating concentric horizontal rib stripes and wood-grain contour banding.
		float dither = get_ign(FRAGCOORD.xy);
		float current_t = t_start + base_step * dither;
		
		vec3 accumulated_cloud_color = vec3(0.0);
		float transmittance = 1.0;
		
		float phase_cloud = dual_henyey_greenstein(cos_sun, forward_scattering_g, backward_scattering_g);
		float silver_lining = pow(clamp(cos_sun, 0.0, 1.0), 24.0) * silver_lining_intensity;
		
		int consecutive_zeros = 0;
		
		for (int i = 0; i < max_steps; i++) {
			if (current_t >= t_end || transmittance < 0.01) break;
			
			vec3 sample_pos_world = camera_pos_km + ray_dir * current_t;
			vec3 sample_pos_cloud = cam_cloud_km + ray_dir * current_t;
			float current_alt = length(sample_pos_cloud);
			float height_norm = clamp((current_alt - r_bottom_curv) / (r_top_curv - r_bottom_curv), 0.0, 1.0);
			
			float detail_fade = clamp(1.0 - (current_t - (detail_lod_distance_km * 0.60)) / max(detail_lod_distance_km * 0.40, 0.001), 0.0, 1.0);
			float density = sample_cloud_density(sample_pos_world, height_norm, wind_offset_km, detail_fade);
			
			// Distance fade near horizon: keeps clouds solid down to horizon (31km) and softly merges into white boundary haze
			float horizon_fade = clamp(1.0 - (current_t - (max_distance_km * 0.80)) / (max_distance_km * 0.20), 0.0, 1.0);
			density *= horizon_fade;
			
			if (density > 0.001) {
				consecutive_zeros = 0;
				
				// Progressive multi-scale light marching toward sun (in km):
				float optical_depth_sun = 0.0;
				float l_dists[4] = float[4](0.08, 0.25, 0.80, 2.40);
				float l_weights[4] = float[4](0.18, 0.42, 0.90, 1.70);
				float l_dens_first = 0.0;
				
				for (int j = 0; j < max_light_steps; j++) {
					int idx = min(j, 3);
					float l_dist = l_dists[idx];
					vec3 light_pos_world = sample_pos_world + sun_dir * l_dist;
					vec3 light_pos_cloud = sample_pos_cloud + sun_dir * l_dist;
					float l_alt = length(light_pos_cloud);
					float l_height_norm = clamp((l_alt - r_bottom_curv) / (r_top_curv - r_bottom_curv), 0.0, 1.0);
					
					float l_dens = sample_cloud_density(light_pos_world, l_height_norm, wind_offset_km, 0.0);
					if (j == 0) l_dens_first = l_dens;
					optical_depth_sun += l_dens * l_weights[idx] * 4.2;
				}
				
				// Smooth light attenuation without binary cliffs (eliminates salt-and-pepper shadow grain)
				float beer = exp(-optical_depth_sun * 0.38);
				float powder = 1.0 - exp(-optical_depth_sun * 1.5 * powder_effect_strength);
				float sun_light_attenuation = beer * mix(1.0, powder, 0.60);
				
				// Directional lobe curvature / micro-crevice shadowing (enhances "몽글몽글" spherical puffiness)
				float lobe_curvature = clamp(1.0 - (l_dens_first - density * 0.6) * 0.20, 0.75, 1.15);
				
				// Multiple forward scattering softens shadow underbelly (luminous pearl-white bounce)
				float multi_scatter = exp(-optical_depth_sun * 0.065) * 0.60;
				
				// Hemispherical ambient lighting: soft skylight from above + luminous diffuse daylight bounce from ocean
				float crevice_ao = clamp(1.0 - density * 0.18, 0.45, 1.0);
				vec3 sky_ambient = sky_color * 0.85 + cloud_ambient_color * 0.80;
				vec3 ocean_ambient = mix(deep_water_color * 1.6, sky_color, 0.65) + vec3(0.18, 0.22, 0.26);
				vec3 ambient = mix(ocean_ambient, sky_ambient, clamp(height_norm * 1.2, 0.15, 1.0)) * ambient_intensity * crevice_ao;
				
				vec3 sun_normalized = sun_light_color / max(sun_intensity, 1.0);
				float phase_term = phase_cloud + silver_lining * 0.45;
				float direct_lighting = (sun_light_attenuation * phase_term * lobe_curvature) + multi_scatter * 0.55;
				vec3 direct_sun = sun_normalized * direct_lighting * 1.6;
				vec3 step_energy = (direct_sun + ambient) * cloud_base_color;
				
				// Soft, physically plausible volumetric extinction (bounded to prevent harsh single-step opacity banding)
				float sample_step_extinction = density * min(base_step, 0.20) * 5.2;
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
		
		// Aerial perspective (distant clouds smoothly dissolve into white horizon haze)
		float dist_to_clouds = min(t_start, max_distance_km);
		float haze_factor = 1.0 - exp(-dist_to_clouds * 0.026 * atmosphere_density);
		accumulated_cloud_color = mix(accumulated_cloud_color, sky_color * (1.0 - transmittance), haze_factor * 0.72);
		
		// Sun disc dissolves exponentially into clouds; only forward Mie glow remains behind clouds
		vec3 direct_sun_disc = sun_disc_color * pow(transmittance, 2.2);
		
		vec3 background = sky_color;
		if (hit_ground) {
			float cam_height = length(camera_pos_km) - R_EARTH;
			float horizon_dip = -sqrt(max(2.0 * cam_height / R_EARTH, 0.0));
			vec3 ocean_surface = compute_distant_ocean(camera_pos_km, ray_dir, sun_dir, sun_light_color, sky_color, t_ground_0, time_val);
			
			float g_haze = clamp(1.0 - exp(-t_ground_0 * 0.04 * atmosphere_density), 0.0, 1.0);
			float horizon_factor = smoothstep(horizon_dip - 0.025, horizon_dip + 0.002, ray_dir.y);
			float total_haze = max(g_haze, horizon_factor);
			background = mix(ocean_surface, sky_color, total_haze);
		}
		vec3 final_color = background * transmittance + accumulated_cloud_color + direct_sun_disc;
		COLOR = apply_tonemapping(final_color, exposure, tonemap_mode, white_point);
	} else {
		vec3 base_surface = sky_color;
		if (hit_ground) {
			float cam_height = length(camera_pos_km) - R_EARTH;
			float horizon_dip = -sqrt(max(2.0 * cam_height / R_EARTH, 0.0));
			vec3 ocean_surface = compute_distant_ocean(camera_pos_km, ray_dir, sun_dir, sun_light_color, sky_color, t_ground_0, time_val);
			
			float g_haze = clamp(1.0 - exp(-t_ground_0 * 0.04 * atmosphere_density), 0.0, 1.0);
			float horizon_factor = smoothstep(horizon_dip - 0.025, horizon_dip + 0.002, ray_dir.y);
			float total_haze = max(g_haze, horizon_factor);
			base_surface = mix(ocean_surface, sky_color, total_haze);
		}
		vec3 final_color = base_surface + sun_disc_color;
		COLOR = apply_tonemapping(final_color, exposure, tonemap_mode, white_point);
	}
}
