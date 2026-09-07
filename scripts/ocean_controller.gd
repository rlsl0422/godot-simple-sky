@tool
class_name OceanController
extends Node3D

## Infinite Ocean & Physically-Based Underwater Optics Controller
## Manages camera-following ocean surface grid, Gerstner wave parameters,
## PBR water surface optics, and depth-based underwater volumetric scattering.

const AtmosphereController = preload("res://scripts/atmosphere_cloud_controller.gd")

enum OceanPreset {
	CUSTOM,
	CALM_LAKE,      ## Glassy, subtle ripples, high water clarity
	GENTLE_OCEAN,   ## Natural rolling waves, balanced foam, turquoise crest SSS (Default)
	ROUGH_SEAS,     ## High swells, heavy crest foam, darker deep water
	STORMY_TEMPEST  ## Massive towering waves, aggressive foam, low visibility
}

# ==========================================
# EXPORTS: NODES & LINKS
# ==========================================
@export_group("Linked Nodes")
@export var atmosphere_controller: AtmosphereController
@export var camera: Camera3D
@export var ocean_mesh_instance: MeshInstance3D
@export var underwater_quad: MeshInstance3D

# ==========================================
# EXPORTS: PRESETS
# ==========================================
@export_group("Preset")
@export var ocean_preset: OceanPreset = OceanPreset.GENTLE_OCEAN:
	set(val):
		ocean_preset = val
		_apply_ocean_preset(val)

# ==========================================
# EXPORTS: WAVE DYNAMICS
# ==========================================
@export_group("Wave Dynamics")
@export_range(0.0, 8.0, 0.05) var wave_amplitude: float = 1.1: ## Wave peak height (meters)
	set(val):
		wave_amplitude = val
		_update_ocean_uniform("wave_amplitude", val)

@export_range(5.0, 150.0, 1.0) var wave_length: float = 38.0: ## Base wavelength (meters)
	set(val):
		wave_length = val
		_update_ocean_uniform("wave_length", val)

@export_range(0.1, 4.0, 0.05) var wave_speed: float = 1.2: ## Wave propagation velocity
	set(val):
		wave_speed = val
		_update_ocean_uniform("wave_speed", val)

@export_range(0.0, 1.0, 0.02) var wave_steepness: float = 0.55: ## Gerstner sharpness (choppiness)
	set(val):
		wave_steepness = val
		_update_ocean_uniform("wave_steepness", val)

@export_range(0.0, 360.0, 1.0) var wave_wind_heading: float = 65.0: ## Wind propagation angle in degrees
	set(val):
		wave_wind_heading = val
		_update_wind_direction()

# ==========================================
# EXPORTS: WATER OPTICS & COLORS
# ==========================================
@export_group("Water Optics")
@export var deep_water_color: Color = Color(0.012, 0.065, 0.14):
	set(val):
		deep_water_color = val
		_update_ocean_uniform("deep_water_color", Vector3(val.r, val.g, val.b))

@export var shallow_water_color: Color = Color(0.08, 0.32, 0.42):
	set(val):
		shallow_water_color = val
		_update_ocean_uniform("shallow_water_color", Vector3(val.r, val.g, val.b))

@export var sss_color: Color = Color(0.15, 0.75, 0.62):
	set(val):
		sss_color = val
		_update_ocean_uniform("sss_color", Vector3(val.r, val.g, val.b))

@export_range(0.0, 5.0, 0.1) var sss_intensity: float = 2.2: ## Crest transmission glow intensity
	set(val):
		sss_intensity = val
		_update_ocean_uniform("sss_intensity", val)

@export_range(2.0, 60.0, 1.0) var water_clarity: float = 22.0: ## Visual penetration depth (meters)
	set(val):
		water_clarity = val
		_update_ocean_uniform("water_clarity", val)

@export_range(0.01, 0.4, 0.01) var surface_roughness: float = 0.06:
	set(val):
		surface_roughness = val
		_update_ocean_uniform("surface_roughness", val)

# ==========================================
# EXPORTS: FOAM & SHORELINE
# ==========================================
@export_group("Foam Dynamics")
@export_range(0.3, 1.0, 0.02) var crest_foam_threshold: float = 0.68:
	set(val):
		crest_foam_threshold = val
		_update_ocean_uniform("crest_foam_threshold", val)

@export_range(0.0, 3.0, 0.1) var crest_foam_intensity: float = 1.6:
	set(val):
		crest_foam_intensity = val
		_update_ocean_uniform("crest_foam_intensity", val)

@export_range(0.1, 5.0, 0.1) var contact_foam_distance: float = 1.4:
	set(val):
		contact_foam_distance = val
		_update_ocean_uniform("contact_foam_distance", val)

# ==========================================
# EXPORTS: UNDERWATER OPTICS (Y < 0)
# ==========================================
@export_group("Underwater Optics")
@export var underwater_scatter_color: Color = Color(0.02, 0.16, 0.26):
	set(val):
		underwater_scatter_color = val
		_update_underwater_uniform("water_scatter_color", Vector3(val.r, val.g, val.b))

@export_range(0.005, 0.08, 0.002) var underwater_turbidity: float = 0.025: ## In-scattering density
	set(val):
		underwater_turbidity = val
		_update_underwater_uniform("turbidity", val)

@export_range(0.0, 3.0, 0.1) var caustics_strength: float = 0.8:
	set(val):
		caustics_strength = val
		_update_underwater_uniform("caustics_strength", val)

@export_range(10.0, 150.0, 5.0) var underwater_max_visibility: float = 80.0:
	set(val):
		underwater_max_visibility = val
		_update_underwater_uniform("max_visibility_meters", val)

@export_group("Godrays")
@export_range(0.0, 5.0, 0.1) var godray_intensity: float = 2.4:
	set(val):
		godray_intensity = val
		_update_underwater_uniform("godray_intensity", val)

@export_group("Horizon & Distance Fade")
@export_range(500.0, 4000.0, 50.0) var fade_inner_radius: float = 1400.0:
	set(val):
		fade_inner_radius = val
		_update_ocean_uniform("fade_inner_radius", val)

@export_range(800.0, 5000.0, 50.0) var fade_outer_radius: float = 2400.0:
	set(val):
		fade_outer_radius = val
		_update_ocean_uniform("fade_outer_radius", val)

# Internal Grid Configuration
const GRID_SIZE: float = 6000.0
const GRID_SUBDIVISIONS: int = 256
var _ocean_mat: ShaderMaterial
var _underwater_mat: ShaderMaterial

func _ready() -> void:
	_init_ocean_mesh()
	_init_underwater_quad()
	_apply_ocean_preset(ocean_preset)
	_sync_all_uniforms()

func _process(_delta: float) -> void:
	var cam = camera if camera else (get_viewport().get_camera_3d() if get_viewport() else null)
	if not cam:
		return

	var cam_pos = cam.global_position

	# 1. Camera-following grid snapping to prevent vertex crawling/swimming
	if ocean_mesh_instance:
		var grid_step = GRID_SIZE / float(GRID_SUBDIVISIONS)
		var snapped_x = floorf(cam_pos.x / grid_step) * grid_step
		var snapped_z = floorf(cam_pos.z / grid_step) * grid_step
		ocean_mesh_instance.global_position = Vector3(snapped_x, 0.0, snapped_z)

	# 2. Toggle underwater post processing quad based on camera height
	if underwater_quad:
		var is_submerged = cam_pos.y < 0.4
		underwater_quad.visible = is_submerged
		if is_submerged:
			# Keep underwater quad tightly aligned to camera viewport
			underwater_quad.global_transform = cam.global_transform

	# 3. Synchronize lighting and time with AtmosphereController
	_sync_environment_from_atmosphere()

func _init_ocean_mesh() -> void:
	if not ocean_mesh_instance:
		ocean_mesh_instance = MeshInstance3D.new()
		ocean_mesh_instance.name = "OceanSurfaceMesh"
		add_child(ocean_mesh_instance)
		ocean_mesh_instance.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else self

	var plane_mesh = ocean_mesh_instance.mesh as PlaneMesh
	if not plane_mesh or plane_mesh.size.x != GRID_SIZE:
		plane_mesh = PlaneMesh.new()
		plane_mesh.size = Vector2(GRID_SIZE, GRID_SIZE)
		plane_mesh.subdivide_width = GRID_SUBDIVISIONS
		plane_mesh.subdivide_depth = GRID_SUBDIVISIONS
		ocean_mesh_instance.mesh = plane_mesh

	if not ocean_mesh_instance.material_override or not (ocean_mesh_instance.material_override is ShaderMaterial):
		var mat = ShaderMaterial.new()
		mat.shader = load("res://shaders/ocean_surface.gdshader")
		ocean_mesh_instance.material_override = mat

	_ocean_mat = ocean_mesh_instance.material_override as ShaderMaterial
	if _ocean_mat:
		_ocean_mat.set_shader_parameter("fade_inner_radius", fade_inner_radius)
		_ocean_mat.set_shader_parameter("fade_outer_radius", fade_outer_radius)

func _init_underwater_quad() -> void:
	if not underwater_quad:
		underwater_quad = MeshInstance3D.new()
		underwater_quad.name = "UnderwaterPostQuad"
		add_child(underwater_quad)
		underwater_quad.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else self

	var quad_mesh = underwater_quad.mesh as QuadMesh
	if not quad_mesh:
		quad_mesh = QuadMesh.new()
		quad_mesh.size = Vector2(2.0, 2.0)
		underwater_quad.mesh = quad_mesh

	if not underwater_quad.material_override or not (underwater_quad.material_override is ShaderMaterial):
		var mat = ShaderMaterial.new()
		mat.shader = load("res://shaders/underwater_post.gdshader")
		underwater_quad.material_override = mat

	_underwater_mat = underwater_quad.material_override as ShaderMaterial
	underwater_quad.extra_cull_margin = 16384.0 # Always render regardless of frustum
	underwater_quad.visible = false

func _sync_environment_from_atmosphere() -> void:
	if not atmosphere_controller:
		return

	var sun_dir = atmosphere_controller._current_sun_direction
	var sun_col = atmosphere_controller.sun_color
	var sun_int = atmosphere_controller.sun_intensity
	var time_sec = Time.get_ticks_msec() * 0.001

	# Approximate sky ambient & horizon colors from solar elevation
	var sun_height = clampf(sun_dir.y, 0.0, 1.0)
	var sky_amb = Color(0.15, 0.35, 0.60).lerp(Color(0.85, 0.45, 0.20), clampf((0.2 - sun_dir.y) * 4.0, 0.0, 1.0))
	var sky_hor = Color(0.65, 0.75, 0.85).lerp(Color(0.95, 0.55, 0.25), clampf((0.2 - sun_dir.y) * 4.0, 0.0, 1.0))

	if _ocean_mat:
		_ocean_mat.set_shader_parameter("sun_direction", sun_dir)
		_ocean_mat.set_shader_parameter("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b))
		_ocean_mat.set_shader_parameter("sun_intensity", sun_int)
		_ocean_mat.set_shader_parameter("sky_ambient_color", Vector3(sky_amb.r, sky_amb.g, sky_amb.b))
		_ocean_mat.set_shader_parameter("sky_horizon_color", Vector3(sky_hor.r, sky_hor.g, sky_hor.b))
		_ocean_mat.set_shader_parameter("custom_time", time_sec)

	if _underwater_mat:
		_underwater_mat.set_shader_parameter("sun_direction", sun_dir)
		_underwater_mat.set_shader_parameter("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b))
		_underwater_mat.set_shader_parameter("sun_intensity", sun_int)
		_underwater_mat.set_shader_parameter("custom_time", time_sec)

func _update_wind_direction() -> void:
	var rad = deg_to_rad(wave_wind_heading)
	var dir = Vector2(sin(rad), cos(rad)).normalized()
	_update_ocean_uniform("primary_wind_dir", dir)

func _sync_all_uniforms() -> void:
	_update_wind_direction()
	_update_ocean_uniform("wave_amplitude", wave_amplitude)
	_update_ocean_uniform("wave_length", wave_length)
	_update_ocean_uniform("wave_speed", wave_speed)
	_update_ocean_uniform("wave_steepness", wave_steepness)
	_update_ocean_uniform("deep_water_color", Vector3(deep_water_color.r, deep_water_color.g, deep_water_color.b))
	_update_ocean_uniform("shallow_water_color", Vector3(shallow_water_color.r, shallow_water_color.g, shallow_water_color.b))
	_update_ocean_uniform("sss_color", Vector3(sss_color.r, sss_color.g, sss_color.b))
	_update_ocean_uniform("sss_intensity", sss_intensity)
	_update_ocean_uniform("water_clarity", water_clarity)
	_update_ocean_uniform("surface_roughness", surface_roughness)
	_update_ocean_uniform("crest_foam_threshold", crest_foam_threshold)
	_update_ocean_uniform("crest_foam_intensity", crest_foam_intensity)
	_update_ocean_uniform("contact_foam_distance", contact_foam_distance)
	_update_ocean_uniform("fade_inner_radius", fade_inner_radius)
	_update_ocean_uniform("fade_outer_radius", fade_outer_radius)

	_update_underwater_uniform("water_scatter_color", Vector3(underwater_scatter_color.r, underwater_scatter_color.g, underwater_scatter_color.b))
	_update_underwater_uniform("turbidity", underwater_turbidity)
	_update_underwater_uniform("caustics_strength", caustics_strength)
	_update_underwater_uniform("max_visibility_meters", underwater_max_visibility)
	_update_underwater_uniform("godray_intensity", godray_intensity)

func _update_ocean_uniform(param: String, value: Variant) -> void:
	if _ocean_mat:
		_ocean_mat.set_shader_parameter(param, value)

func _update_underwater_uniform(param: String, value: Variant) -> void:
	if _underwater_mat:
		_underwater_mat.set_shader_parameter(param, value)

func _apply_ocean_preset(preset: OceanPreset) -> void:
	match preset:
		OceanPreset.CALM_LAKE:
			wave_amplitude = 0.35
			wave_length = 20.0
			wave_speed = 0.8
			wave_steepness = 0.35
			water_clarity = 35.0
			surface_roughness = 0.03
			crest_foam_intensity = 0.2
			sss_intensity = 1.0
			underwater_turbidity = 0.012
			caustics_strength = 1.0

		OceanPreset.GENTLE_OCEAN:
			wave_amplitude = 1.1
			wave_length = 38.0
			wave_speed = 1.2
			wave_steepness = 0.55
			water_clarity = 22.0
			surface_roughness = 0.06
			crest_foam_threshold = 0.68
			crest_foam_intensity = 1.6
			sss_intensity = 2.2
			underwater_turbidity = 0.025
			caustics_strength = 0.8

		OceanPreset.ROUGH_SEAS:
			wave_amplitude = 2.6
			wave_length = 55.0
			wave_speed = 1.8
			wave_steepness = 0.72
			water_clarity = 15.0
			surface_roughness = 0.12
			crest_foam_threshold = 0.52
			crest_foam_intensity = 2.2
			sss_intensity = 2.8
			underwater_turbidity = 0.045
			caustics_strength = 0.5

		OceanPreset.STORMY_TEMPEST:
			wave_amplitude = 4.8
			wave_length = 80.0
			wave_speed = 2.5
			wave_steepness = 0.85
			water_clarity = 8.0
			surface_roughness = 0.18
			crest_foam_threshold = 0.40
			crest_foam_intensity = 2.8
			sss_intensity = 1.2
			underwater_turbidity = 0.075
			caustics_strength = 0.2

		OceanPreset.CUSTOM:
			pass

	_sync_all_uniforms()
