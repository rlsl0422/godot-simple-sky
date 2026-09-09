@tool
class_name AtmosphereCloudController
extends Node

const CloudNoiseGen = preload("res://scripts/cloud_noise_generator.gd")

## Controller for the Physically-Based Atmosphere and Volumetric Cloud system.
## Provides intuitive artistic parameters, time-of-day animation, weather presets,
## and automatic synchronization with DirectionalLight3D and WorldEnvironment.

enum PerformanceMode {
	LOW,      ## 24 steps, 2 light steps (Ideal for low-end devices)
	MEDIUM,   ## 36 steps, 4 light steps (Golden Cross: ~60+ FPS on MX450)
	HIGH,     ## 48 steps, 6 light steps (Rich density and detail)
	ULTRA     ## 64 steps, 8 light steps (Cinematic fidelity)
}

enum WeatherPreset {
	CUSTOM,
	CLEAR_SKY,         ## Crystal clear blue sky with thin wisps
	FAIR_CUMULUS,      ## Iconic fluffy cotton-ball cumulus clouds
	GOLDEN_HOUR,       ## Scenic sunset with warm scattering and silver rims
	DRAMATIC_OVERCAST, ## Heavy, moody cloud deck
	STORMY_EVENING     ## Dark, intimidating storm atmosphere
}

# ==========================================
# EXPORTS: ENVIRONMENT & NODES
# ==========================================
@export_group("Nodes")
@export var world_environment: WorldEnvironment
@export var sun_light: DirectionalLight3D

# ==========================================
# EXPORTS: PRESETS & PERFORMANCE
# ==========================================
@export_group("Presets & Performance")
@export var weather_preset: WeatherPreset = WeatherPreset.FAIR_CUMULUS:
	set(val):
		weather_preset = val
		_apply_weather_preset(val)

@export var performance_mode: PerformanceMode = PerformanceMode.MEDIUM:
	set(val):
		performance_mode = val
		_apply_performance_mode(val)

# ==========================================
# EXPORTS: TIME & SUN
# ==========================================
@export_group("Time & Sun")
@export_range(0.0, 24.0, 0.05) var time_of_day: float = 14.5: ## 0.0-24.0 hours (e.g. 12 = Noon, 18 = Sunset)
	set(val):
		time_of_day = val
		_update_sun_and_atmosphere()

@export_range(-90.0, 90.0, 1.0) var sun_latitude: float = 35.0: ## Solar path declination angle
	set(val):
		sun_latitude = val
		_update_sun_and_atmosphere()

@export_range(0.0, 50.0, 0.5) var sun_intensity: float = 24.0:
	set(val):
		sun_intensity = val
		_update_material_uniform("sun_intensity", val)

@export var sun_color: Color = Color(1.0, 0.96, 0.90):
	set(val):
		sun_color = val
		_update_material_uniform("sun_color", Vector3(val.r, val.g, val.b))

# ==========================================
# EXPORTS: CLOUD AESTHETICS (INTUITIVE UX)
# ==========================================
@export_group("Cloud Appearance")
@export var clouds_enabled: bool = true:
	set(val):
		clouds_enabled = val
		_update_material_uniform("clouds_enabled", val)

@export_range(0.0, 1.0, 0.01) var cloud_coverage: float = 0.45: ## Overall cloud amount (0 = Clear, 1 = Dense cover)
	set(val):
		cloud_coverage = val
		_update_material_uniform("cloud_coverage", val)

@export_range(0.1, 4.0, 0.05) var cloud_density: float = 1.2: ## Cloud body thickness and opacity
	set(val):
		cloud_density = val
		_update_material_uniform("cloud_density_multiplier", val)

@export_range(500.0, 4000.0, 50.0) var cloud_bottom_altitude: float = 1600.0: ## Cloud base altitude in meters
	set(val):
		cloud_bottom_altitude = val
		_update_material_uniform("cloud_bottom_altitude", val)

@export_range(500.0, 6000.0, 50.0) var cloud_thickness: float = 2800.0: ## Height from base to cloud top
	set(val):
		cloud_thickness = val
		_update_material_uniform("cloud_top_altitude", cloud_bottom_altitude + val)

@export_range(0.0, 1.0, 0.01) var detail_fluffiness: float = 0.4: ## Micro edge erosion and fluffiness
	set(val):
		detail_fluffiness = val
		_update_material_uniform("detail_strength", val)

@export_range(0.05, 1.0, 0.01) var cloud_scale: float = 0.10: ## Base spatial scale in 1/km
	set(val):
		cloud_scale = val
		_update_material_uniform("cloud_scale", val)

@export_range(100.0, 2000.0, 10.0) var cloud_curvature_radius_km: float = 150.0: ## Effective planetary curvature for clouds
	set(val):
		cloud_curvature_radius_km = val
		_update_material_uniform("cloud_curvature_radius_km", val)

@export_range(0.0, 1.0, 0.05) var satellite_cloud_amount: float = 0.45: ## Clustered baby clouds around main cloud mass
	set(val):
		satellite_cloud_amount = val
		_update_material_uniform("satellite_cloud_amount", val)

@export_range(0.0, 1.0, 0.05) var zenith_sky_clearance: float = 0.55: ## Horizon vs overhead open blue sky balance
	set(val):
		zenith_sky_clearance = val
		_update_material_uniform("zenith_sky_clearance", val)

@export_range(0.0, 5.0, 0.1) var silver_lining: float = 2.4: ## Edge rim glow when looking toward the sun
	set(val):
		silver_lining = val
		_update_material_uniform("silver_lining_intensity", val)

# ==========================================
# EXPORTS: TONE MAPPING & EXPOSURE
# ==========================================
@export_group("Tone Mapping & Exposure")
@export_enum("None (Linear HDR)", "ACES Film (Recommended)", "Reinhard", "Filmic") var tonemap_mode: int = 1:
	set(val):
		tonemap_mode = val
		_update_material_uniform("tonemap_mode", val)

@export_range(0.1, 4.0, 0.05) var exposure: float = 1.0:
	set(val):
		exposure = val
		_update_material_uniform("exposure", val)

@export_range(1.0, 20.0, 0.5) var white_point: float = 6.0:
	set(val):
		white_point = val
		_update_material_uniform("white_point", val)

@export_range(0.0, 1.0, 0.05) var sun_corona_intensity: float = 0.20:
	set(val):
		sun_corona_intensity = val
		_update_material_uniform("sun_corona_intensity", val)

# ==========================================
# EXPORTS: WIND & DYNAMICS
# ==========================================
@export_group("Wind & Dynamics")
@export_range(0.0, 100.0, 0.5) var wind_speed_kmh: float = 25.0: ## Wind speed in km/h
	set(val):
		wind_speed_kmh = val
		_update_wind()

@export_range(0.0, 360.0, 1.0) var wind_heading_degrees: float = 60.0: ## Direction the wind is blowing towards
	set(val):
		wind_heading_degrees = val
		_update_wind()

@export var animate_time: bool = true
@export_range(0.0, 10.0, 0.1) var time_progression_speed: float = 0.05 ## Hours per real-time minute

# Internal references
var _sky_material: ShaderMaterial
var _current_sun_direction: Vector3 = Vector3(0.0, 0.5, -0.866)

func _ready() -> void:
	_setup_materials_and_textures()
	_apply_performance_mode(performance_mode)
	_apply_weather_preset(weather_preset)
	_update_material_uniform("tonemap_mode", tonemap_mode)
	_update_material_uniform("exposure", exposure)
	_update_material_uniform("white_point", white_point)
	_update_material_uniform("sun_corona_intensity", sun_corona_intensity)
	_update_sun_and_atmosphere()
	_update_wind()

func _process(delta: float) -> void:
	if animate_time and not Engine.is_editor_hint():
		# Time progression: 1 hour in (60 / time_progression_speed) seconds
		var hours_per_sec = time_progression_speed / 60.0
		time_of_day = fmod(time_of_day + hours_per_sec * delta, 24.0)
	
	if _sky_material:
		_sky_material.set_shader_parameter("custom_time", Time.get_ticks_msec() * 0.001)
		var cam = get_viewport().get_camera_3d() if get_viewport() else null
		if cam:
			_sky_material.set_shader_parameter("camera_world_position", cam.global_position)

func _setup_materials_and_textures() -> void:
	if not world_environment or not world_environment.environment:
		return
		
	var env = world_environment.environment
	if not env.sky:
		env.sky = Sky.new()
		
	var sky = env.sky
	if not sky.sky_material or not (sky.sky_material is ShaderMaterial):
		var mat = ShaderMaterial.new()
		var shader_res = load("res://shaders/atmosphere_clouds.gdshader")
		mat.shader = shader_res
		sky.sky_material = mat
		
	_sky_material = sky.sky_material as ShaderMaterial
	
	# Load or procedurally generate 3D/2D textures
	var base_tex = CloudNoiseGen.get_or_create_base_noise()
	var detail_tex = CloudNoiseGen.get_or_create_detail_noise()
	var weather_map = CloudNoiseGen.get_or_create_weather_map()
	
	if _sky_material:
		if base_tex:
			_sky_material.set_shader_parameter("base_noise_tex", base_tex)
		if detail_tex:
			_sky_material.set_shader_parameter("detail_noise_tex", detail_tex)
		if weather_map:
			_sky_material.set_shader_parameter("weather_tex", weather_map)
		print("[AtmosphereCloudController] Textures bound: base=%s, detail=%s, weather=%s" % [base_tex != null, detail_tex != null, weather_map != null])

func _update_sun_and_atmosphere() -> void:
	# Solar hour angle: H = 0 at noon (12h), -PI/2 at 6h (sunrise), +PI/2 at 18h (sunset)
	var hour_angle = (time_of_day - 12.0) * (PI / 12.0)
	var lat_rad = deg_to_rad(sun_latitude)
	
	# Solar position vector in world space:
	# Y: Zenith height (peaks at noon H=0, zero at 6h sunrise & 18h sunset)
	var sun_y = cos(hour_angle) * cos(lat_rad)
	# X: East (-) to West (+) transit
	var sun_x = sin(hour_angle)
	# Z: Solar declination tilt
	var sun_z = -cos(hour_angle) * sin(lat_rad)
	
	_current_sun_direction = Vector3(sun_x, sun_y, sun_z).normalized()
	
	# Physical color temperature shift near horizon (Sunset / Sunrise)
	var sun_height = _current_sun_direction.y
	var dynamic_sun_color = sun_color
	var dynamic_energy = sun_intensity
	
	if sun_height > 0.15:
		# Day: Crisp warm-white
		dynamic_sun_color = sun_color
		dynamic_energy = sun_intensity
	elif sun_height > -0.05:
		# Sunset / Dawn transition: Rich golden-orange to crimson
		var t = clampf((sun_height + 0.05) / 0.2, 0.0, 1.0)
		var sunset_color = Color(1.0, 0.45, 0.18)
		dynamic_sun_color = sunset_color.lerp(sun_color, t)
		dynamic_energy = lerpf(sun_intensity * 0.4, sun_intensity, t)
	else:
		# Night: Moon/starlight ambient
		dynamic_sun_color = Color(0.15, 0.22, 0.35)
		dynamic_energy = 0.5
		
	_update_material_uniform("sun_direction", _current_sun_direction)
	_update_material_uniform("sun_color", Vector3(dynamic_sun_color.r, dynamic_sun_color.g, dynamic_sun_color.b))
	_update_material_uniform("sun_intensity", dynamic_energy)
	
	# Synchronize Godot DirectionalLight3D
	if sun_light:
		sun_light.look_at_from_position(Vector3.ZERO, -_current_sun_direction, Vector3.UP)
		sun_light.light_color = dynamic_sun_color
		sun_light.light_energy = maxf(dynamic_energy * 0.1, 0.05)
		sun_light.visible = sun_height > -0.1

func _update_wind() -> void:
	var heading_rad = deg_to_rad(wind_heading_degrees)
	var dir = Vector3(sin(heading_rad), 0.0, cos(heading_rad)).normalized()
	var speed_ms = (wind_speed_kmh * 1000.0) / 3600.0
	
	_update_material_uniform("wind_direction", dir)
	_update_material_uniform("wind_speed", speed_ms)

func _apply_performance_mode(mode: PerformanceMode) -> void:
	match mode:
		PerformanceMode.LOW:
			_update_material_uniform("max_steps", 30)
			_update_material_uniform("max_light_steps", 2)
			_update_material_uniform("empty_skip_multiplier", 1.1)
			_update_material_uniform("max_distance_km", 28.0)
			_update_material_uniform("detail_lod_distance_km", 6.0)
		PerformanceMode.MEDIUM:
			# Golden cross default (~50-60 FPS on MX450)
			_update_material_uniform("max_steps", 34)
			_update_material_uniform("max_light_steps", 3)
			_update_material_uniform("empty_skip_multiplier", 1.15)
			_update_material_uniform("max_distance_km", 36.0)
			_update_material_uniform("detail_lod_distance_km", 12.0)
		PerformanceMode.HIGH:
			_update_material_uniform("max_steps", 48)
			_update_material_uniform("max_light_steps", 5)
			_update_material_uniform("empty_skip_multiplier", 1.8)
			_update_material_uniform("max_distance_km", 45.0)
			_update_material_uniform("detail_lod_distance_km", 18.0)
		PerformanceMode.ULTRA:
			_update_material_uniform("max_steps", 64)
			_update_material_uniform("max_light_steps", 6)
			_update_material_uniform("empty_skip_multiplier", 1.5)
			_update_material_uniform("max_distance_km", 52.0)
			_update_material_uniform("detail_lod_distance_km", 24.0)

func _apply_weather_preset(preset: WeatherPreset) -> void:
	match preset:
		WeatherPreset.CLEAR_SKY:
			cloud_coverage = 0.12
			cloud_density = 0.8
			detail_fluffiness = 0.25
			silver_lining = 1.8
			time_of_day = 13.0
		WeatherPreset.FAIR_CUMULUS:
			cloud_coverage = 0.42
			cloud_density = 1.3
			detail_fluffiness = 0.42
			silver_lining = 2.4
			cloud_bottom_altitude = 1600.0
			cloud_thickness = 2600.0
			time_of_day = 14.5
		WeatherPreset.GOLDEN_HOUR:
			cloud_coverage = 0.45
			cloud_density = 1.3
			detail_fluffiness = 0.45
			silver_lining = 3.6
			time_of_day = 17.6
		WeatherPreset.DRAMATIC_OVERCAST:
			cloud_coverage = 0.82
			cloud_density = 2.2
			detail_fluffiness = 0.35
			silver_lining = 1.2
			cloud_bottom_altitude = 1200.0
			cloud_thickness = 3800.0
			time_of_day = 15.0
		WeatherPreset.STORMY_EVENING:
			cloud_coverage = 0.92
			cloud_density = 2.8
			detail_fluffiness = 0.5
			silver_lining = 1.0
			cloud_bottom_altitude = 900.0
			cloud_thickness = 4500.0
			time_of_day = 19.0
		WeatherPreset.CUSTOM:
			pass
			
	_sync_all_to_shader()

func _sync_all_to_shader() -> void:
	_update_material_uniform("clouds_enabled", clouds_enabled)
	_update_material_uniform("cloud_coverage", cloud_coverage)
	_update_material_uniform("cloud_density_multiplier", cloud_density)
	_update_material_uniform("cloud_bottom_altitude", cloud_bottom_altitude)
	_update_material_uniform("cloud_top_altitude", cloud_bottom_altitude + cloud_thickness)
	_update_material_uniform("cloud_scale", cloud_scale)
	_update_material_uniform("cloud_curvature_radius_km", cloud_curvature_radius_km)
	_update_material_uniform("satellite_cloud_amount", satellite_cloud_amount)
	_update_material_uniform("zenith_sky_clearance", zenith_sky_clearance)
	_update_material_uniform("detail_strength", detail_fluffiness)
	_update_material_uniform("silver_lining_intensity", silver_lining)
	_update_sun_and_atmosphere()
	_update_wind()

func _update_material_uniform(param_name: String, value: Variant) -> void:
	if _sky_material:
		_sky_material.set_shader_parameter(param_name, value)
