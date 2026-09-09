class_name BenchmarkHarness
extends Node

## Autonomous verification harness that captures multi-angle screenshots
## and records detailed frame-time and performance metrics (FPS, 1% low, memory).

const CloudController = preload("res://scripts/atmosphere_cloud_controller.gd")

@export var controller: Node
@export var camera: Node3D
@export var auto_benchmark: bool = true
@export var overlay_label: Label

var _frames_recorded: int = 0
var _frame_times: Array[float] = []
var _benchmark_phase: int = 0
var _metrics_data: Dictionary = {}

var _is_coverage_test: bool = false
var _coverage_test_steps: Array[float] = [0.32, 0.35, 0.38, 0.41, 0.44]
var _cov_step_idx: int = 0
var _cov_step_frames: int = 0

func _ready() -> void:
	# Check command line args
	var args = OS.get_cmdline_args()
	var user_args = OS.get_cmdline_user_args()
	if "--coverage-test" in args or "--coverage-test" in user_args:
		_is_coverage_test = true
		auto_benchmark = false
		print("[BenchmarkHarness] Activated --coverage-test mode!")
	elif "--no-benchmark" in args or "--no-benchmark" in user_args:
		auto_benchmark = false
	if "--benchmark" in args or "--benchmark" in user_args or "--benchmark-auto" in args or "--benchmark-auto" in user_args:
		auto_benchmark = true
	print("[BenchmarkHarness] auto_benchmark = ", auto_benchmark)
		
	if not DirAccess.dir_exists_absolute("res://screenshots"):
		DirAccess.make_dir_absolute("res://screenshots")

func _process(delta: float) -> void:
	var fps = Engine.get_frames_per_second()
	var frame_time_ms = delta * 1000.0
	
	if overlay_label and controller:
		overlay_label.text = "FPS: %d (%.2f ms) | Preset: %s | Mode: %s | Time: %.1fh\n[1-5] Weather | [F1-F4] Ocean Presets | [6-9] Perf | [WASD/QE] Move | [Shift] Boost" % [
			fps,
			frame_time_ms,
			CloudController.WeatherPreset.keys()[controller.weather_preset],
			CloudController.PerformanceMode.keys()[controller.performance_mode],
			controller.time_of_day
		]
	
	if _is_coverage_test:
		_process_coverage_test()
		return
		
	if not auto_benchmark:
		return
		
	_frame_times.append(frame_time_ms)
	_frames_recorded += 1
	
	# Phase 0: Warmup (30 frames)
	if _benchmark_phase == 0 and _frames_recorded >= 30:
		_benchmark_phase = 1
		_setup_phase_1_noon_cumulus()
		
	# Phase 1: Capture Fair Cumulus at Noon (60 frames)
	elif _benchmark_phase == 1 and _frames_recorded >= 90:
		_capture_screenshot("01_noon_cumulus.png")
		_benchmark_phase = 2
		_setup_phase_2_sun_silver_lining()
		
	# Phase 2: Capture Sun Backlight & Silver Lining (60 frames)
	elif _benchmark_phase == 2 and _frames_recorded >= 150:
		_capture_screenshot("02_sun_silver_lining.png")
		_benchmark_phase = 3
		_setup_phase_3_golden_sunset()
		
	# Phase 3: Capture Golden Hour Sunset (60 frames)
	elif _benchmark_phase == 3 and _frames_recorded >= 210:
		_capture_screenshot("03_golden_sunset.png")
		_benchmark_phase = 4
		_setup_phase_4_above_clouds()
		
	# Phase 4: Capture Above Clouds View (60 frames)
	elif _benchmark_phase == 4 and _frames_recorded >= 270:
		_capture_screenshot("04_above_clouds.png")
		_benchmark_phase = 5
		_setup_phase_5_downward_ground_and_contour()
		
	# Phase 5: Capture Downward Ground & Cloud Contour (60 frames)
	elif _benchmark_phase == 5 and _frames_recorded >= 330:
		_capture_screenshot("05_ground_and_contour_fix.png")
		_benchmark_phase = 6
		_setup_phase_6_ocean_view()

	# Phase 6: Capture Infinite Ocean Surface & Golden Hour Specular (60 frames)
	elif _benchmark_phase == 6 and _frames_recorded >= 390:
		_capture_screenshot("06_infinite_ocean_sunset.png")
		_benchmark_phase = 7
		_setup_phase_7_underwater_view()

	# Phase 7: Capture Underwater Physical Scattering & Soft Godrays (60 frames)
	elif _benchmark_phase == 7 and _frames_recorded >= 450:
		_capture_screenshot("07_underwater_optics.png")
		_benchmark_phase = 8
		_setup_phase_8_underwater_antisolar()

	# Phase 8: Capture Underwater Anti-Solar View (zero radial artifacts) (60 frames)
	elif _benchmark_phase == 8 and _frames_recorded >= 510:
		_capture_screenshot("08_underwater_antisolar.png")
		_benchmark_phase = 9
		_setup_phase_9_underwater_deep_extinction()

	# Phase 9: Capture Deep Ocean Extinction (depth -75m, sunlight extinguished) (60 frames)
	elif _benchmark_phase == 9 and _frames_recorded >= 570:
		_capture_screenshot("09_underwater_deep_extinction.png")
		_benchmark_phase = 10
		auto_benchmark = false
		_finalize_benchmark()

func _setup_phase_1_noon_cumulus() -> void:
	print("[BenchmarkHarness] Phase 1: Setting up Noon Cumulus (14.5h, MEDIUM mode)...")
	controller.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 14.5
	camera.global_position = Vector3(0.0, 50.0, 0.0)
	var look_dir = Vector3(0.12, 0.10, -0.99).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _setup_phase_2_sun_silver_lining() -> void:
	print("[BenchmarkHarness] Phase 2: Setting up Sun Silver Lining backlight...")
	controller.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 10.5
	camera.global_position = Vector3(800.0, 50.0, -500.0)
	var sun_dir = controller._current_sun_direction
	camera.look_at_from_position(camera.global_position, camera.global_position + sun_dir, Vector3.UP)

func _setup_phase_3_golden_sunset() -> void:
	print("[BenchmarkHarness] Phase 3: Setting up Golden Hour Sunset in LOW mode...")
	controller.weather_preset = CloudController.WeatherPreset.GOLDEN_HOUR
	controller.performance_mode = CloudController.PerformanceMode.LOW
	controller.time_of_day = 17.6
	camera.global_position = Vector3(0.0, 50.0, 0.0)
	var sun_dir = controller._current_sun_direction
	camera.look_at_from_position(camera.global_position, camera.global_position + sun_dir + Vector3(0.0, 0.08, 0.0), Vector3.UP)

func _setup_phase_4_above_clouds() -> void:
	print("[BenchmarkHarness] Phase 4: Flying above clouds (4800m) overlooking cloud ocean...")
	controller.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 15.0
	camera.global_position = Vector3(0.0, 4800.0, 0.0)
	var look_dir = Vector3(0.4, -0.25, -0.8).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _setup_phase_5_downward_ground_and_contour() -> void:
	print("[BenchmarkHarness] Phase 5: Testing downward ocean blending and contour at 50m (14.5h)...")
	controller.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 14.5
	camera.global_position = Vector3(0.0, 50.0, 0.0)
	var look_dir = Vector3(0.0, -0.26, -1.0).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _setup_phase_6_ocean_view() -> void:
	print("[BenchmarkHarness] Phase 6: Infinite Ocean Wave & Specular Reflection test (matching user view)...")
	controller.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 14.5
	camera.global_position = Vector3(0.0, 45.0, 0.0)
	var sun_dir = controller._current_sun_direction
	var look_dir = Vector3(sun_dir.x, -0.32, sun_dir.z).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _setup_phase_7_underwater_view() -> void:
	print("[BenchmarkHarness] Phase 7: Near-surface underwater optics & godrays (-2.5m, FAIR_CUMULUS 14.5h)...")
	controller.weather_preset = CloudController.WeatherPreset.FAIR_CUMULUS
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 14.5
	camera.global_position = Vector3(0.0, -2.5, 0.0)
	var sun_dir = controller._current_sun_direction
	var look_dir = (sun_dir * 0.75 + Vector3(0.0, 0.45, 0.0)).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _setup_phase_8_underwater_antisolar() -> void:
	print("[BenchmarkHarness] Phase 8: Underwater Anti-Solar (away from sun) test...")
	controller.weather_preset = CloudController.WeatherPreset.CLEAR_SKY
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 13.0
	camera.global_position = Vector3(0.0, -8.0, 0.0)
	var sun_dir = controller._current_sun_direction
	var look_dir = (-sun_dir + Vector3(0.0, 0.15, 0.0)).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _setup_phase_9_underwater_deep_extinction() -> void:
	print("[BenchmarkHarness] Phase 9: Deep Ocean Extinction (-75m) test...")
	controller.weather_preset = CloudController.WeatherPreset.CLEAR_SKY
	controller.performance_mode = CloudController.PerformanceMode.MEDIUM
	controller.time_of_day = 13.0
	camera.global_position = Vector3(0.0, -75.0, 0.0)
	var sun_dir = controller._current_sun_direction
	var look_dir = (sun_dir * 0.75 + Vector3(0.0, 0.45, 0.0)).normalized()
	camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)

func _capture_screenshot(file_name: String) -> void:
	var vp = get_viewport()
	if not vp:
		return
	var tex = vp.get_texture()
	if not tex:
		return
	var img = tex.get_image()
	if not img:
		return
	var path = "res://screenshots/" + file_name
	var abs_path = ProjectSettings.globalize_path(path)
	img.save_png(abs_path)
	print("[BenchmarkHarness] Captured: ", abs_path)

func _finalize_benchmark() -> void:
	print("[BenchmarkHarness] Computing performance metrics...")
	
	var total_time := 0.0
	var min_ft := 99999.0
	var max_ft := 0.0
	
	for ft in _frame_times:
		total_time += ft
		if ft < min_ft: min_ft = ft
		if ft > max_ft: max_ft = ft
		
	var avg_ft = total_time / float(_frame_times.size())
	var avg_fps = 1000.0 / maxf(avg_ft, 0.001)
	
	# Compute 1% Low (99th percentile frame time)
	var sorted_times = _frame_times.duplicate()
	sorted_times.sort()
	var p99_index = int(sorted_times.size() * 0.99)
	var p99_ft = sorted_times[clamp(p99_index, 0, sorted_times.size() - 1)]
	var p99_fps = 1000.0 / maxf(p99_ft, 0.001)
	
	_metrics_data = {
		"total_frames": _frame_times.size(),
		"avg_fps": avg_fps,
		"avg_frame_time_ms": avg_ft,
		"min_frame_time_ms": min_ft,
		"max_frame_time_ms": max_ft,
		"percentile_99_frame_time_ms": p99_ft,
		"percentile_1_low_fps": p99_fps,
		"renderer": RenderingServer.get_video_adapter_name(),
		"timestamp": Time.get_datetime_string_from_system()
	}
	
	var json_str = JSON.stringify(_metrics_data, "\t")
	var metrics_path = ProjectSettings.globalize_path("res://screenshots/perf_metrics.json")
	var file = FileAccess.open(metrics_path, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()
		print("[BenchmarkHarness] Performance metrics saved to: ", metrics_path)
		
	print("\n================ BENCHMARK RESULTS ================")
	print("Video Adapter: ", _metrics_data["renderer"])
	print("Average FPS: %.1f FPS (%.2f ms)" % [avg_fps, avg_ft])
	print("1%% Low FPS:  %.1f FPS (%.2f ms)" % [p99_fps, p99_ft])
	print("===================================================\n")
	
	# Check if launched in headless or auto-exit mode
	var args = OS.get_cmdline_args()
	var user_args = OS.get_cmdline_user_args()
	if "--benchmark-auto" in args or "--quit-after-benchmark" in args or "--benchmark-auto" in user_args or "--quit-after-benchmark" in user_args:
		print("[BenchmarkHarness] Exiting automatically as requested...")
		get_tree().quit()

func _process_coverage_test() -> void:
	if _cov_step_idx >= _coverage_test_steps.size():
		print("[BenchmarkHarness] All coverage step captures complete! Exiting...")
		get_tree().quit()
		return
		
	var cov = _coverage_test_steps[_cov_step_idx]
	if _cov_step_frames == 0:
		print("[BenchmarkHarness] Running Coverage Test Step %d: coverage = %.2f" % [_cov_step_idx + 1, cov])
		controller.cloud_coverage = cov
		controller.cloud_density = 0.65
		controller.cloud_scale = 0.29
		controller.detail_fluffiness = 0.27
		controller.cloud_curvature_radius_km = 150.0
		controller.satellite_cloud_amount = 0.45
		controller.zenith_sky_clearance = 0.55
		controller.time_of_day = 14.5
		controller.sun_latitude = 12.0
		controller.sun_intensity = 10.0
		camera.global_position = Vector3(0.0, 50.0, 0.0)
		var look_dir = Vector3(0.08, 0.14, -0.99).normalized()
		camera.look_at_from_position(camera.global_position, camera.global_position + look_dir, Vector3.UP)
		controller.animate_time = false
		
	if controller._sky_material:
		controller._sky_material.set_shader_parameter("custom_time", 353.461)
		
	_cov_step_frames += 1
	# Allow 25 frames for shader compilation and temporal settling
	if _cov_step_frames >= 25:
		var fname = "coverage_%.2f.png" % cov
		_capture_screenshot(fname)
		print("[BenchmarkHarness] Saved %s successfully!" % fname)
		_cov_step_idx += 1
		_cov_step_frames = 0

