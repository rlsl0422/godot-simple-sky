class_name FreeFlyCamera
extends Camera3D

## Free-fly camera with smooth controls, high altitude boost,
## and quick hotkeys for weather presets and performance switching.

const CloudController = preload("res://scripts/atmosphere_cloud_controller.gd")
const OceanControllerClass = preload("res://scripts/ocean_controller.gd")

@export var move_speed: float = 40.0
@export var boost_speed: float = 400.0
@export var look_sensitivity: float = 0.003
@export var controller_node: Node
@export var ocean_controller: Node

var _yaw: float = 0.0
var _pitch: float = 0.0
var _is_mouse_captured: bool = false

func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x

func _input(event: InputEvent) -> void:
	# Mouse look
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_is_mouse_captured = true
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_is_mouse_captured = false
				
	elif event is InputEventMouseMotion and _is_mouse_captured:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)
		
	# Hotkeys for Presets & Testing
	if event is InputEventKey and event.pressed:
		if controller_node:
			match event.keycode:
				KEY_0:
					if not event.echo:
						controller_node.weather_preset = CloudController.WeatherPreset.CUSTOM
				KEY_1:
					if not event.echo:
						controller_node.weather_preset = CloudController.WeatherPreset.CLEAR_SKY
				KEY_2:
					if not event.echo:
						controller_node.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
				KEY_3:
					if not event.echo:
						controller_node.weather_preset = CloudController.WeatherPreset.GOLDEN_HOUR
				KEY_4:
					if not event.echo:
						controller_node.weather_preset = CloudController.WeatherPreset.DRAMATIC_OVERCAST
				KEY_5:
					if not event.echo:
						controller_node.weather_preset = CloudController.WeatherPreset.STORMY_EVENING
				KEY_6:
					if not event.echo:
						controller_node.performance_mode = CloudController.PerformanceMode.LOW
				KEY_7:
					if not event.echo:
						controller_node.performance_mode = CloudController.PerformanceMode.MEDIUM
				KEY_8:
					if not event.echo:
						controller_node.performance_mode = CloudController.PerformanceMode.HIGH
				KEY_9:
					if not event.echo:
						controller_node.performance_mode = CloudController.PerformanceMode.ULTRA
				KEY_SPACE:
					if not event.echo:
						controller_node.animate_time = !controller_node.animate_time
				KEY_BRACKETLEFT:
					var step = 0.1 if Input.is_key_pressed(KEY_SHIFT) else 0.5
					controller_node.time_of_day = fposmod(controller_node.time_of_day - step, 24.0)
				KEY_BRACKETRIGHT:
					var step = 0.1 if Input.is_key_pressed(KEY_SHIFT) else 0.5
					controller_node.time_of_day = fposmod(controller_node.time_of_day + step, 24.0)
				KEY_MINUS:
					controller_node.cloud_coverage = clampf(controller_node.cloud_coverage - 0.02, 0.0, 1.0)
				KEY_EQUAL:
					controller_node.cloud_coverage = clampf(controller_node.cloud_coverage + 0.02, 0.0, 1.0)
				KEY_COMMA:
					controller_node.cloud_density = clampf(controller_node.cloud_density - 0.05, 0.05, 3.0)
				KEY_PERIOD:
					controller_node.cloud_density = clampf(controller_node.cloud_density + 0.05, 0.05, 3.0)
				KEY_SEMICOLON:
					controller_node.cloud_scale = clampf(controller_node.cloud_scale - 0.01, 0.05, 1.0)
				KEY_APOSTROPHE:
					controller_node.cloud_scale = clampf(controller_node.cloud_scale + 0.01, 0.05, 1.0)
				KEY_P:
					if not event.echo:
						_capture_screenshot()
				KEY_F1:
					if ocean_controller and not event.echo: ocean_controller.ocean_preset = OceanControllerClass.OceanPreset.CALM_LAKE
				KEY_F2:
					if ocean_controller and not event.echo: ocean_controller.ocean_preset = OceanControllerClass.OceanPreset.GENTLE_OCEAN
				KEY_F3:
					if ocean_controller and not event.echo: ocean_controller.ocean_preset = OceanControllerClass.OceanPreset.ROUGH_SEAS
				KEY_F4:
					if ocean_controller and not event.echo: ocean_controller.ocean_preset = OceanControllerClass.OceanPreset.STORMY_TEMPEST

func _process(delta: float) -> void:
	# Movement
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S): input_dir.z += 1.0
	if Input.is_key_pressed(KEY_A): input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D): input_dir.x += 1.0
	if Input.is_key_pressed(KEY_E): input_dir.y += 1.0
	if Input.is_key_pressed(KEY_Q): input_dir.y -= 1.0
	
	var current_speed = boost_speed if Input.is_key_pressed(KEY_SHIFT) else move_speed
	if global_position.y < 0.0:
		# Viscous fluid drag while submerged
		current_speed *= 0.65
	
	var forward = -transform.basis.z
	var right = transform.basis.x
	var up = Vector3.UP
	
	var move_vec = (forward * -input_dir.z + right * input_dir.x + up * input_dir.y).normalized()
	global_position += move_vec * current_speed * delta
	global_position.y = maxf(global_position.y, -500.0)

func _capture_screenshot() -> void:
	if not DirAccess.dir_exists_absolute("res://screenshots"):
		DirAccess.make_dir_absolute("res://screenshots")
	var img = get_viewport().get_texture().get_image()
	var filename = "res://screenshots/manual_capture_%d.png" % Time.get_ticks_msec()
	img.save_png(filename)
	print("[FreeFlyCamera] Screenshot captured: ", filename)
