@tool
class_name OceanController
extends Node3D

## Infinite Ocean & Physically-Based Underwater Optics Controller
## Manages camera-following ocean surface grid, Gerstner wave parameters,
## PBR water surface optics, and depth-based underwater volumetric scattering.

const AtmosphereController = preload("res://scripts/atmosphere_cloud_controller.gd")
const OceanNoiseGen = preload("res://scripts/ocean_noise_generator.gd")

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
## AtmosphereCloudController node used to synchronize atmospheric lighting, sun direction, and sky colors.
@export var atmosphere_controller: AtmosphereController
## Target Camera3D used for ocean grid snapping and underwater rendering checks (automatically defaults to active viewport camera).
@export var camera: Camera3D
## MeshInstance3D node rendering the ocean surface geometry.
@export var ocean_mesh_instance: MeshInstance3D
## Fullscreen quad MeshInstance3D handling underwater post-processing (volumetric in-scattering, refraction, and godrays).
@export var underwater_quad: MeshInstance3D

# ==========================================
# EXPORTS: PRESETS
# ==========================================
@export_group("Preset")
## Sea state preset (CUSTOM, CALM_LAKE, GENTLE_OCEAN, ROUGH_SEAS, STORMY_TEMPEST).
@export var ocean_preset: OceanPreset = OceanPreset.GENTLE_OCEAN:
	set(val):
		ocean_preset = val
		_apply_ocean_preset(val)

# ==========================================
# EXPORTS: WAVE DYNAMICS
# ==========================================
@export_group("Wave Dynamics")
## Peak vertical wave amplitude (wave height in meters), setting the summit elevation of wave crests.
@export_range(0.0, 8.0, 0.05) var wave_amplitude: float = 1.1:
	set(val):
		wave_amplitude = val
		_update_ocean_uniform("wave_amplitude", val)
		_update_underwater_uniform("wave_amplitude", val)

## Primary wavelength in meters. Larger values generate broad rolling swells; smaller values create tight coastal chop.
@export_range(5.0, 150.0, 1.0) var wave_length: float = 38.0:
	set(val):
		wave_length = val
		_update_ocean_uniform("wave_length", val)
		_update_underwater_uniform("wave_length", val)

## Wave propagation speed multiplier based on physical ocean dispersion.
@export_range(0.1, 4.0, 0.05) var wave_speed: float = 1.2:
	set(val):
		wave_speed = val
		_update_ocean_uniform("wave_speed", val)
		_update_underwater_uniform("wave_speed", val)

## Gerstner wave steepness (peakedness). 0.0 produces gentle sinusoidal swells; values approaching 1.0 produce sharp, peaked crests.
@export_range(0.0, 1.0, 0.02) var wave_steepness: float = 0.55:
	set(val):
		wave_steepness = val
		_update_ocean_uniform("wave_steepness", val)
		_update_underwater_uniform("wave_steepness", val)

## Wind heading in degrees (0° to 360°), establishing the prevailing travel direction of ocean swells.
@export_range(0.0, 360.0, 1.0) var wave_wind_heading: float = 65.0:
	set(val):
		wave_wind_heading = val
		_update_wind_direction()

# ==========================================
# EXPORTS: WATER OPTICS & COLORS
# ==========================================
@export_group("Water Optics")
## Deep water body color. Controls the deep indigo/sapphire upwelling radiance scattered back from the ocean volume.
@export var deep_water_color: Color = Color(0.004, 0.026, 0.085):
	set(val):
		deep_water_color = val
		_update_ocean_uniform("deep_water_color", Vector3(val.r, val.g, val.b))

## Shallow water color tint. Appears in shallow areas, coastlines, and around submerged geometry with high transmittance.
@export var shallow_water_color: Color = Color(0.015, 0.12, 0.18):
	set(val):
		shallow_water_color = val
		_update_ocean_uniform("shallow_water_color", Vector3(val.r, val.g, val.b))

## Subsurface scattering (SSS) transmission tint through wave crests, glowing emerald/turquoise when backlit by the sun.
@export var sss_color: Color = Color(0.015, 0.16, 0.18):
	set(val):
		sss_color = val
		_update_ocean_uniform("sss_color", Vector3(val.r, val.g, val.b))

## Subsurface scattering (SSS) intensity through wave crests when backlit by the sun.
@export_range(0.0, 5.0, 0.1) var sss_intensity: float = 1.0:
	set(val):
		sss_intensity = val
		_update_ocean_uniform("sss_intensity", val)

## Visual water clarity in meters. Maximum penetration depth before submerged objects or terrain attenuate into darkness.
@export_range(2.0, 60.0, 1.0) var water_clarity: float = 22.0:
	set(val):
		water_clarity = val
		_update_ocean_uniform("water_clarity", val)

## Microfacet surface roughness. Combined with Toksvig variance filtering to produce a silky, anti-aliased solar glitter lane.
@export_range(0.01, 0.4, 0.01) var surface_roughness: float = 0.06:
	set(val):
		surface_roughness = val
		_update_ocean_uniform("surface_roughness", val)

# ==========================================
# EXPORTS: FOAM & SHORELINE
# ==========================================
@export_group("Foam Dynamics")
## Whitecap foam Jacobian threshold. Lower values allow gentler swells to foam; higher values restrict foam to breaking peaks.
@export_range(0.3, 1.0, 0.02) var crest_foam_threshold: float = 0.68:
	set(val):
		crest_foam_threshold = val
		_update_ocean_uniform("crest_foam_threshold", val)

## Cellular bubble lace foam brightness and visibility intensity on wave crests.
@export_range(0.0, 3.0, 0.1) var crest_foam_intensity: float = 1.6:
	set(val):
		crest_foam_intensity = val
		_update_ocean_uniform("crest_foam_intensity", val)

## Contact foam detection distance in meters around coastlines and floating solid objects.
@export_range(0.05, 2.0, 0.05) var contact_foam_distance: float = 0.25:
	set(val):
		contact_foam_distance = val
		_update_ocean_uniform("contact_foam_distance", val)

# ==========================================
# EXPORTS: UNDERWATER OPTICS (Y < 0)
# ==========================================
@export_group("Underwater Optics")
## Underwater volumetric in-scattering base color (tropical cyan/emerald near surface to deep cobalt in depth).
@export var underwater_scatter_color: Color = Color(0.015, 0.45, 0.68):
	set(val):
		underwater_scatter_color = val
		_update_underwater_uniform("water_scatter_color", Vector3(val.r, val.g, val.b))

## Underwater turbidity (suspended particle density). Lower values produce crystal-clear water; higher values create murky water.
@export_range(0.002, 0.05, 0.001) var underwater_turbidity: float = 0.010:
	set(val):
		underwater_turbidity = val
		_update_underwater_uniform("turbidity", val)

## Sunlight caustics intensity projected onto underwater terrain and sunlit upward-facing object surfaces.
@export_range(0.0, 3.0, 0.1) var caustics_strength: float = 0.75:
	set(val):
		caustics_strength = val
		_update_underwater_uniform("caustics_strength", val)
		_update_ocean_uniform("caustics_strength", val)

## Maximum underwater visibility distance in meters before scene extinction converges to deep darkness.
@export_range(10.0, 150.0, 5.0) var underwater_max_visibility: float = 110.0:
	set(val):
		underwater_max_visibility = val
		_update_underwater_uniform("max_visibility_meters", val)

## Wave refraction wobble intensity when viewing outside elements (sky, sun, clouds) from beneath the undulating surface.
@export_range(0.0, 0.12, 0.002) var underwater_refraction_strength: float = 0.038:
	set(val):
		underwater_refraction_strength = val
		_update_underwater_uniform("refraction_strength", val)

# ==========================================
# EXPORTS: GODRAYS
# ==========================================
@export_group("Godrays")
## Intensity of underwater solar crepuscular rays (godrays) streaming down through the sea surface.
@export_range(0.0, 5.0, 0.1) var godray_intensity: float = 1.1:
	set(val):
		godray_intensity = val
		_update_underwater_uniform("godray_intensity", val)

## Sharpness and beam tightness of underwater godrays. Higher values yield slender, distinct beams; lower values create diffuse light shafts.
@export_range(1.0, 10.0, 0.5) var godray_sharpness: float = 3.5:
	set(val):
		godray_sharpness = val
		_update_underwater_uniform("godray_sharpness", val)

# ==========================================
# EXPORTS: HORIZON & DISTANCE FADE
# ==========================================
@export_group("Horizon & Distance Fade")
## Inner radius in meters where wave displacement starts fading to ensure seamless curvature blending with the horizon.
@export_range(500.0, 4000.0, 50.0) var fade_inner_radius: float = 1400.0:
	set(val):
		fade_inner_radius = val
		_update_ocean_uniform("fade_inner_radius", val)

## Outer radius in meters where the ocean surface mesh smoothly dissipates to transparent, preventing visible grid boundaries.
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
	# 1. Unconditionally sync lighting and time with AtmosphereController (works in Editor & Runtime)
	_sync_environment_from_atmosphere()

	# 2. Identify active camera (editor viewport or scene camera)
	var cam: Camera3D = null
	if Engine.is_editor_hint():
		if Engine.has_singleton("EditorInterface"):
			var ei = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_editor_viewport_3d"):
				var evp = ei.get_editor_viewport_3d(0)
				if evp and evp.has_method("get_camera_3d"):
					cam = evp.get_camera_3d()
		if not cam:
			var vp = get_viewport()
			if vp:
				cam = vp.get_camera_3d()
	if not cam:
		cam = camera if camera else (get_viewport().get_camera_3d() if get_viewport() else null)
	if not cam:
		return

	var cam_pos = cam.global_position

	# 3. Camera-following grid snapping to prevent vertex crawling/swimming
	if ocean_mesh_instance:
		var grid_step = GRID_SIZE / float(GRID_SUBDIVISIONS)
		var snapped_x = floorf(cam_pos.x / grid_step) * grid_step
		var snapped_z = floorf(cam_pos.z / grid_step) * grid_step
		ocean_mesh_instance.global_position = Vector3(snapped_x, 0.0, snapped_z)

	# 4. Keep underwater quad active
	if underwater_quad:
		underwater_quad.visible = true
		underwater_quad.global_position = cam.global_position

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

	ocean_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_ocean_mat = ocean_mesh_instance.material_override as ShaderMaterial
	if _ocean_mat:
		_ocean_mat.set_shader_parameter("fade_inner_radius", fade_inner_radius)
		_ocean_mat.set_shader_parameter("fade_outer_radius", fade_outer_radius)
		var normal_tex = OceanNoiseGen.get_or_create_ocean_normal()
		if normal_tex:
			_ocean_mat.set_shader_parameter("wave_normal_tex", normal_tex)

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
	underwater_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	underwater_quad.extra_cull_margin = 16384.0 # Always render regardless of frustum
	underwater_quad.custom_aabb = AABB(Vector3(-100000.0, -100000.0, -100000.0), Vector3(200000.0, 200000.0, 200000.0))
	underwater_quad.visible = true

func _sync_environment_from_atmosphere() -> void:
	if not atmosphere_controller:
		atmosphere_controller = get_node_or_null("../AtmosphereCloudController") as AtmosphereController
	if not atmosphere_controller:
		return

	var sun_dir = atmosphere_controller.current_sun_direction if ("current_sun_direction" in atmosphere_controller) else atmosphere_controller._current_sun_direction
	var sun_col = atmosphere_controller.current_sun_color if ("current_sun_color" in atmosphere_controller) else atmosphere_controller.sun_color
	var sun_int = atmosphere_controller.current_sun_energy if ("current_sun_energy" in atmosphere_controller) else atmosphere_controller.sun_intensity
	var time_sec = Time.get_ticks_msec() * 0.001

	# Physical 24-Hour Day-Night Sky & Horizon Optical Model:
	# Solves atmospheric sky dome radiance and sea horizon reflectance across all solar elevations.
	var sun_y = sun_dir.y
	var sky_amb: Color
	var sky_hor: Color
	var effective_sun_energy: float

	# Solar Elevation Thresholds:
	# sun_y >= 0.15: Broad Daylight (deep atmospheric blue zenith, deep maritime horizon)
	# 0.02 < sun_y < 0.15: Golden Hour Sunset/Sunrise (amber horizon, violet-blue sky)
	# -0.15 <= sun_y <= 0.02: Twilight / Dusk (golden sunset fading rapidly to indigo dusk)
	# sun_y < -0.15: Deep Night / Midnight (dark obsidian navy sea, deep midnight indigo sky)

	if sun_y >= 0.15:
		# 1. Daylight: High sun elevation
		# Deeper maritime sky tones to ensure rich deep ultramarine/navy ocean rather than pale sky blue
		sky_amb = Color(0.035, 0.120, 0.350)
		sky_hor = Color(0.140, 0.340, 0.580)
		effective_sun_energy = sun_int
	elif sun_y > 0.02:
		# 2. Transition: Daylight <-> Golden Hour (Sunset / Sunrise)
		var t = clampf((0.15 - sun_y) / 0.13, 0.0, 1.0)
		var day_amb = Color(0.035, 0.120, 0.350)
		var day_hor = Color(0.140, 0.340, 0.580)
		var sunset_amb = Color(0.160, 0.120, 0.300)
		var sunset_hor = Color(0.950, 0.480, 0.180)
		sky_amb = day_amb.lerp(sunset_amb, t)
		sky_hor = day_hor.lerp(sunset_hor, t)
		effective_sun_energy = sun_int
	elif sun_y >= -0.15:
		# 3. Transition: Golden Hour <-> Twilight / Dusk (Sun below horizon)
		var t = clampf((0.02 - sun_y) / 0.17, 0.0, 1.0)
		var sunset_amb = Color(0.160, 0.120, 0.300)
		var sunset_hor = Color(0.950, 0.480, 0.180)
		var twilight_amb = Color(0.008, 0.015, 0.038)
		var twilight_hor = Color(0.018, 0.032, 0.075)
		sky_amb = sunset_amb.lerp(twilight_amb, t)
		sky_hor = sunset_hor.lerp(twilight_hor, t)
		# Direct sun energy cuts off rapidly when sun sets below horizon
		effective_sun_energy = lerpf(sun_int * 0.4, 0.0, t)
	else:
		# 4. Deep Night / Midnight (e.g. 2:30 AM, 00:00 AM, 04:00 AM)
		# Deep midnight navy/indigo tones (진한 군청색 밤바다)
		var t = clampf((-0.15 - sun_y) / 0.15, 0.0, 1.0)
		var twilight_amb = Color(0.008, 0.015, 0.038)
		var twilight_hor = Color(0.018, 0.032, 0.075)
		var night_amb = Color(0.0015, 0.0035, 0.010)
		var night_hor = Color(0.0035, 0.0080, 0.020)
		sky_amb = twilight_amb.lerp(night_amb, t)
		sky_hor = twilight_hor.lerp(night_hor, t)
		effective_sun_energy = 0.0

	if _ocean_mat:
		_ocean_mat.set_shader_parameter("sun_direction", sun_dir)
		_ocean_mat.set_shader_parameter("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b))
		_ocean_mat.set_shader_parameter("sun_intensity", effective_sun_energy)
		_ocean_mat.set_shader_parameter("sky_ambient_color", Vector3(sky_amb.r, sky_amb.g, sky_amb.b))
		_ocean_mat.set_shader_parameter("sky_horizon_color", Vector3(sky_hor.r, sky_hor.g, sky_hor.b))
		_ocean_mat.set_shader_parameter("custom_time", time_sec)
		_ocean_mat.set_shader_parameter("tonemap_mode", atmosphere_controller.tonemap_mode)
		_ocean_mat.set_shader_parameter("exposure", atmosphere_controller.exposure)
		_ocean_mat.set_shader_parameter("white_point", atmosphere_controller.white_point)

	if atmosphere_controller._sky_material:
		atmosphere_controller._sky_material.set_shader_parameter("deep_water_color", Vector3(deep_water_color.r, deep_water_color.g, deep_water_color.b))

	if _underwater_mat:
		_underwater_mat.set_shader_parameter("sun_direction", sun_dir)
		_underwater_mat.set_shader_parameter("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b))
		_underwater_mat.set_shader_parameter("sun_intensity", effective_sun_energy)
		_underwater_mat.set_shader_parameter("custom_time", time_sec)

func _update_wind_direction() -> void:
	var rad = deg_to_rad(wave_wind_heading)
	var dir = Vector2(sin(rad), cos(rad)).normalized()
	_update_ocean_uniform("primary_wind_dir", dir)
	_update_underwater_uniform("primary_wind_dir", dir)

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
	_update_ocean_uniform("caustics_strength", caustics_strength)

	_update_underwater_uniform("water_scatter_color", Vector3(underwater_scatter_color.r, underwater_scatter_color.g, underwater_scatter_color.b))
	_update_underwater_uniform("turbidity", underwater_turbidity)
	_update_underwater_uniform("caustics_strength", caustics_strength)
	_update_underwater_uniform("max_visibility_meters", underwater_max_visibility)
	_update_underwater_uniform("godray_intensity", godray_intensity)
	_update_underwater_uniform("godray_sharpness", godray_sharpness)
	_update_underwater_uniform("refraction_strength", underwater_refraction_strength)
	_update_underwater_uniform("wave_amplitude", wave_amplitude)
	_update_underwater_uniform("wave_length", wave_length)
	_update_underwater_uniform("wave_speed", wave_speed)
	_update_underwater_uniform("wave_steepness", wave_steepness)

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
			deep_water_color = Color(0.005, 0.038, 0.090)
			water_clarity = 35.0
			surface_roughness = 0.03
			crest_foam_intensity = 0.2
			sss_intensity = 0.8
			underwater_turbidity = 0.012
			caustics_strength = 1.0

		OceanPreset.GENTLE_OCEAN:
			wave_amplitude = 1.1
			wave_length = 38.0
			wave_speed = 1.2
			wave_steepness = 0.55
			deep_water_color = Color(0.004, 0.026, 0.085)
			water_clarity = 22.0
			surface_roughness = 0.06
			crest_foam_threshold = 0.74
			crest_foam_intensity = 1.1
			sss_intensity = 0.9
			underwater_turbidity = 0.025
			caustics_strength = 0.8

		OceanPreset.ROUGH_SEAS:
			wave_amplitude = 2.6
			wave_length = 55.0
			wave_speed = 1.8
			wave_steepness = 0.72
			deep_water_color = Color(0.003, 0.022, 0.075)
			water_clarity = 15.0
			surface_roughness = 0.08
			crest_foam_threshold = 0.52
			crest_foam_intensity = 2.0
			sss_intensity = 1.1
			underwater_turbidity = 0.045
			caustics_strength = 0.5

		OceanPreset.STORMY_TEMPEST:
			wave_amplitude = 4.8
			wave_length = 80.0
			wave_speed = 2.5
			wave_steepness = 0.85
			deep_water_color = Color(0.003, 0.020, 0.055)
			water_clarity = 8.0
			surface_roughness = 0.15
			crest_foam_threshold = 0.40
			crest_foam_intensity = 2.6
			sss_intensity = 0.9
			underwater_turbidity = 0.075
			caustics_strength = 0.2

		OceanPreset.CUSTOM:
			pass

	_sync_all_uniforms()
