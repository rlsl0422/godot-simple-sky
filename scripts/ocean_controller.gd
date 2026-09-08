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
## 대기 및 태양 조명 파라미터를 동기화할 AtmosphereCloudController 노드
@export var atmosphere_controller: AtmosphereController
## 바다 표면 그리드 스냅 및 수중 렌더링 기준 카메라 (미지정 시 뷰포트 활성 카메라 자동 추적)
@export var camera: Camera3D
## 바다 표면 지오메트리를 렌더링하는 MeshInstance3D 노드
@export var ocean_mesh_instance: MeshInstance3D
## 수중 진입 시 화면 후처리(광학 산란, 굴절, 갓레이)를 담당하는 풀스크린 쿼드 MeshInstance3D
@export var underwater_quad: MeshInstance3D

# ==========================================
# EXPORTS: PRESETS
# ==========================================
@export_group("Preset")
## 바다 상태 프리셋 (CALM_LAKE: 잔잔한 호수, GENTLE_OCEAN: 평온한 대양, ROUGH_SEAS: 거친 파도, STORMY_TEMPEST: 폭풍우 대양)
@export var ocean_preset: OceanPreset = OceanPreset.GENTLE_OCEAN:
	set(val):
		ocean_preset = val
		_apply_ocean_preset(val)

# ==========================================
# EXPORTS: WAVE DYNAMICS
# ==========================================
@export_group("Wave Dynamics")
## 파도의 최대 수직 진폭(파고, 단위: 미터). 파도 능선의 최고점 높이를 결정합니다.
@export_range(0.0, 8.0, 0.05) var wave_amplitude: float = 1.1:
	set(val):
		wave_amplitude = val
		_update_ocean_uniform("wave_amplitude", val)
		_update_underwater_uniform("wave_amplitude", val)

## 기본 파장의 길이(단위: 미터). 값이 클수록 웅장하고 완만한 대양 너울이 형성되며, 작을수록 촘촘한 연안 파도가 생성됩니다.
@export_range(5.0, 150.0, 1.0) var wave_length: float = 38.0:
	set(val):
		wave_length = val
		_update_ocean_uniform("wave_length", val)
		_update_underwater_uniform("wave_length", val)

## 파도의 전파 속도 배율. 물리적 분산 관계에 기반한 파도의 이동 및 굴림 속도를 조절합니다.
@export_range(0.1, 4.0, 0.05) var wave_speed: float = 1.2:
	set(val):
		wave_speed = val
		_update_ocean_uniform("wave_speed", val)
		_update_underwater_uniform("wave_speed", val)

## 게르스트너(Gerstner) 파도 뾰족도(가파름). 0.0은 부드러운 사인파이며, 1.0에 가까울수록 날카롭게 솟아오르는 삼각 파도마루를 형성합니다.
@export_range(0.0, 1.0, 0.02) var wave_steepness: float = 0.55:
	set(val):
		wave_steepness = val
		_update_ocean_uniform("wave_steepness", val)
		_update_underwater_uniform("wave_steepness", val)

## 파도가 진행하는 바람의 방위각(0°~360°). 바다 파도가 이동하는 기본 방향을 설정합니다.
@export_range(0.0, 360.0, 1.0) var wave_wind_heading: float = 65.0:
	set(val):
		wave_wind_heading = val
		_update_wind_direction()

# ==========================================
# EXPORTS: WATER OPTICS & COLORS
# ==========================================
@export_group("Water Optics")
## 깊은 수심의 본체 색상. 태양광/하늘빛이 물속으로 투과되어 상향 산란(Upwelling)되는 대양 고유의 깊은 인디고/사파이어 블루를 결정합니다.
@export var deep_water_color: Color = Color(0.006, 0.040, 0.115):
	set(val):
		deep_water_color = val
		_update_ocean_uniform("deep_water_color", Vector3(val.r, val.g, val.b))

## 얕은 수심의 물 색상. 해안선이나 얕은 수중 물체 주변에서 투과율이 높을 때 나타나는 자연스러운 청록빛 틴트를 결정합니다.
@export var shallow_water_color: Color = Color(0.015, 0.12, 0.18):
	set(val):
		shallow_water_color = val
		_update_ocean_uniform("shallow_water_color", Vector3(val.r, val.g, val.b))

## 파도마루의 표면하 산란(SSS) 투과 색상. 태양 역광 시 얇은 파도 능선을 투과하는 자연스러운 에메랄드/아쿠아마린 색조를 설정합니다.
@export var sss_color: Color = Color(0.015, 0.16, 0.18):
	set(val):
		sss_color = val
		_update_ocean_uniform("sss_color", Vector3(val.r, val.g, val.b))

## 파도 능선의 표면하 산란(SSS) 투과광 강도. 역광 시 파도 정상이 은은하게 투명하게 빛나는 효과의 세기를 조절합니다.
@export_range(0.0, 5.0, 0.1) var sss_intensity: float = 1.0:
	set(val):
		sss_intensity = val
		_update_ocean_uniform("sss_intensity", val)

## 물의 가시적 투명도(단위: 미터). 물속의 물체나 해저면이 시각적으로 보일 수 있는 최대 침투 깊이입니다.
@export_range(2.0, 60.0, 1.0) var water_clarity: float = 22.0:
	set(val):
		water_clarity = val
		_update_ocean_uniform("water_clarity", val)

## 해수면 마이크로 거칠기. 톡스빅(Toksvig) 분산 필터링과 결합되어 잔물결 위의 부드럽고 앨리어싱 없는 태양 반사로(Glitter Lane)를 형성합니다.
@export_range(0.01, 0.4, 0.01) var surface_roughness: float = 0.06:
	set(val):
		surface_roughness = val
		_update_ocean_uniform("surface_roughness", val)

# ==========================================
# EXPORTS: FOAM & SHORELINE
# ==========================================
@export_group("Foam Dynamics")
## 백파(Whitecap) 발생 자코비안 임계값. 값이 낮을수록 완만한 파도에서도 거품이 발생하며, 높을수록 충돌하는 거친 정점에서만 거품이 형성됩니다.
@export_range(0.3, 1.0, 0.02) var crest_foam_threshold: float = 0.68:
	set(val):
		crest_foam_threshold = val
		_update_ocean_uniform("crest_foam_threshold", val)

## 절차적 세포형 기포 거품(Bubble Lace)의 밝기 및 가시성 강도.
@export_range(0.0, 3.0, 0.1) var crest_foam_intensity: float = 1.6:
	set(val):
		crest_foam_intensity = val
		_update_ocean_uniform("crest_foam_intensity", val)

## 해안선 및 수중 고체 오브젝트와의 접촉 거품 감지 거리(단위: 미터).
@export_range(0.05, 2.0, 0.05) var contact_foam_distance: float = 0.25:
	set(val):
		contact_foam_distance = val
		_update_ocean_uniform("contact_foam_distance", val)

# ==========================================
# EXPORTS: UNDERWATER OPTICS (Y < 0)
# ==========================================
@export_group("Underwater Optics")
## 수중 체적 인스캐터링(산란) 기본 색상. 수면 근처에서 햇빛이 산란되어 보이는 맑은 열대 에메랄드/청록 색상입니다.
@export var underwater_scatter_color: Color = Color(0.015, 0.45, 0.68):
	set(val):
		underwater_scatter_color = val
		_update_underwater_uniform("water_scatter_color", Vector3(val.r, val.g, val.b))

## 수중 탁도(Turbidity). 물속의 부유 입자 밀도를 결정합니다. (낮을수록 투명한 크리스탈 바다, 높을수록 흐린 수중)
@export_range(0.002, 0.05, 0.001) var underwater_turbidity: float = 0.010:
	set(val):
		underwater_turbidity = val
		_update_underwater_uniform("turbidity", val)

## 수중 지형 및 고체 오브젝트 표면에 투사되는 움직이는 태양 커스틱스(물결 무늬) 강도.
@export_range(0.0, 3.0, 0.1) var caustics_strength: float = 0.75:
	set(val):
		caustics_strength = val
		_update_underwater_uniform("caustics_strength", val)
		_update_ocean_uniform("caustics_strength", val)

## 수중 최대 가시거리(단위: 미터). 빛이 완전히 소멸되어 심해 암흑 또는 배경색으로 수렴하는 거리입니다.
@export_range(10.0, 150.0, 5.0) var underwater_max_visibility: float = 110.0:
	set(val):
		underwater_max_visibility = val
		_update_underwater_uniform("max_visibility_meters", val)

## 물속에서 외부(하늘, 구름, 태양)를 바라볼 때 파도에 의해 생기는 굴절 왜곡 및 울렁임(Wave Refraction Wobble)의 강도.
@export_range(0.0, 0.12, 0.002) var underwater_refraction_strength: float = 0.038:
	set(val):
		underwater_refraction_strength = val
		_update_underwater_uniform("refraction_strength", val)

# ==========================================
# EXPORTS: GODRAYS
# ==========================================
@export_group("Godrays")
## 수면을 투과하여 물속으로 쏟아지는 태양 광선 줄기(갓레이)의 밝기 강도.
@export_range(0.0, 5.0, 0.1) var godray_intensity: float = 1.1:
	set(val):
		godray_intensity = val
		_update_underwater_uniform("godray_intensity", val)

## 갓레이 광선 줄기의 날카로움(빔 두께). 높을수록 얇고 뚜렷한 빛줄기가 되며, 낮을수록 부드럽게 퍼지는 광선이 됩니다.
@export_range(1.0, 10.0, 0.5) var godray_sharpness: float = 3.5:
	set(val):
		godray_sharpness = val
		_update_underwater_uniform("godray_sharpness", val)

# ==========================================
# EXPORTS: HORIZON & DISTANCE FADE
# ==========================================
@export_group("Horizon & Distance Fade")
## 카메라로부터 파도 너울이 감쇠되기 시작하는 내부 반경(단위: 미터). 지평선과의 완벽한 수평선 정렬을 유도합니다.
@export_range(500.0, 4000.0, 50.0) var fade_inner_radius: float = 1400.0:
	set(val):
		fade_inner_radius = val
		_update_ocean_uniform("fade_inner_radius", val)

## 카메라로부터 바다 표면 그리드가 완전히 투명하게 소멸하는 외부 반경(단위: 미터). 사각형 그리드 경계가 보이지 않게 원형 페이드아웃 처리합니다.
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

	var sun_dir = atmosphere_controller._current_sun_direction
	var sun_col = atmosphere_controller.sun_color
	var sun_int = atmosphere_controller.sun_intensity
	var time_sec = Time.get_ticks_msec() * 0.001

	# Approximate sky ambient & horizon colors from solar elevation
	var sun_height = clampf(sun_dir.y, 0.0, 1.0)
	var sky_amb = Color(0.06, 0.22, 0.52).lerp(Color(0.85, 0.45, 0.20), clampf((0.2 - sun_dir.y) * 4.0, 0.0, 1.0))
	var sky_hor = Color(0.26, 0.52, 0.76).lerp(Color(0.95, 0.55, 0.25), clampf((0.2 - sun_dir.y) * 4.0, 0.0, 1.0))

	if _ocean_mat:
		_ocean_mat.set_shader_parameter("sun_direction", sun_dir)
		_ocean_mat.set_shader_parameter("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b))
		_ocean_mat.set_shader_parameter("sun_intensity", sun_int)
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
		_underwater_mat.set_shader_parameter("sun_intensity", sun_int)
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
			deep_water_color = Color(0.007, 0.045, 0.125)
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
			deep_water_color = Color(0.006, 0.040, 0.115)
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
