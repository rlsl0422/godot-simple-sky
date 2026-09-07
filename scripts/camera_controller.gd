class_name FreeFlyCamera
extends Camera3D

## Free-fly camera with smooth controls, high altitude boost,
## and quick hotkeys for weather presets and performance switching.

const CloudController = preload("res://scripts/atmosphere_cloud_controller.gd")

@export var move_speed: float = 40.0
@export var boost_speed: float = 400.0
@export var look_sensitivity: float = 0.003
@export var controller_node: Node

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
	if event is InputEventKey and event.pressed and not event.echo:
		if controller_node:
			match event.keycode:
				KEY_1:
					controller_node.weather_preset = CloudController.WeatherPreset.CLEAR_SKY
				KEY_2:
					controller_node.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
				KEY_3:
					controller_node.weather_preset = CloudController.WeatherPreset.GOLDEN_HOUR
				KEY_4:
					controller_node.weather_preset = CloudController.WeatherPreset.DRAMATIC_OVERCAST
				KEY_5:
					controller_node.weather_preset = CloudController.WeatherPreset.STORMY_EVENING
				KEY_6:
					controller_node.performance_mode = CloudController.PerformanceMode.LOW
				KEY_7:
					controller_node.performance_mode = CloudController.PerformanceMode.MEDIUM
				KEY_8:
					controller_node.performance_mode = CloudController.PerformanceMode.HIGH
				KEY_9:
					controller_node.performance_mode = CloudController.PerformanceMode.ULTRA
				KEY_SPACE:
					controller_node.animate_time = !controller_node.animate_time
				KEY_P:
					_capture_screenshot()

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
	var forward = -transform.basis.z
	var right = transform.basis.x
	var up = Vector3.UP
	
	var move_vec = (forward * -input_dir.z + right * input_dir.x + up * input_dir.y).normalized()
	global_position += move_vec * current_speed * delta
	global_position.y = maxf(global_position.y, 2.0)

func _capture_screenshot() -> void:
	if not DirAccess.dir_exists_absolute("res://screenshots"):
		DirAccess.make_dir_absolute("res://screenshots")
	var img = get_viewport().get_texture().get_image()
	var filename = "res://screenshots/manual_capture_%d.png" % Time.get_ticks_msec()
	img.save_png(filename)
	print("[FreeFlyCamera] Screenshot captured: ", filename)
