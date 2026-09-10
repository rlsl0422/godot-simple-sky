@tool
extends SceneTree

func _init() -> void:
	print("--- Running Inspector Parameter Preservation Test ---")
	var scene_res = load("res://scenes/main_showcase.tscn")
	if not scene_res:
		printerr("FAIL: Could not load main_showcase.tscn")
		quit(1)
		return
		
	var scene = scene_res.instantiate()
	root.add_child(scene)
	
	var controller = scene.get_node_or_null("AtmosphereCloudController")
	if not controller:
		printerr("FAIL: AtmosphereCloudController not found in main_showcase.tscn")
		quit(1)
		return
		
	# Verify that values loaded from .tscn are intact in _ready()
	print("Loaded weather_preset: ", controller.weather_preset, " (Expected 0 = CUSTOM)")
	assert(controller.weather_preset == 0, "weather_preset should be CUSTOM (0)")
	
	print("Loaded time_of_day: ", controller.time_of_day, " (Expected 12.95)")
	assert(abs(controller.time_of_day - 12.95) < 0.001, "time_of_day must be 12.95")
	
	print("Loaded cloud_coverage: ", controller.cloud_coverage, " (Expected 0.36)")
	assert(abs(controller.cloud_coverage - 0.36) < 0.001, "cloud_coverage must be 0.36")
	
	print("Loaded cloud_density: ", controller.cloud_density, " (Expected 0.7)")
	assert(abs(controller.cloud_density - 0.7) < 0.001, "cloud_density must be 0.7")
	
	print("Loaded cloud_bottom_altitude: ", controller.cloud_bottom_altitude, " (Expected 1000.0)")
	assert(abs(controller.cloud_bottom_altitude - 1000.0) < 0.001, "cloud_bottom_altitude must be 1000.0")
	
	print("Loaded cloud_thickness: ", controller.cloud_thickness, " (Expected 6000.0)")
	assert(abs(controller.cloud_thickness - 6000.0) < 0.001, "cloud_thickness must be 6000.0")
	
	print("Loaded cloud_scale: ", controller.cloud_scale, " (Expected 0.28)")
	assert(abs(controller.cloud_scale - 0.28) < 0.001, "cloud_scale must be 0.28")
	
	print("Loaded satellite_cloud_amount: ", controller.satellite_cloud_amount, " (Expected 0.8)")
	assert(abs(controller.satellite_cloud_amount - 0.8) < 0.001, "satellite_cloud_amount must be 0.8")
	
	print("Loaded zenith_sky_clearance: ", controller.zenith_sky_clearance, " (Expected 0.3)")
	assert(abs(controller.zenith_sky_clearance - 0.3) < 0.001, "zenith_sky_clearance must be 0.3")
	
	print("Loaded animate_time: ", controller.animate_time, " (Expected false)")
	assert(controller.animate_time == false, "animate_time should be false")
	
	# Test switching preset to FAIR_CUMULUS
	controller.weather_preset = 2 # FAIR_CUMULUS
	print("Switched to FAIR_CUMULUS. weather_preset is now: ", controller.weather_preset)
	assert(controller.weather_preset == 2, "weather_preset should be FAIR_CUMULUS (2)")
	
	# Test manual tweak switching back to CUSTOM
	controller.cloud_coverage = 0.55
	print("Tweaked cloud_coverage to 0.55. weather_preset is now: ", controller.weather_preset)
	assert(controller.weather_preset == 0, "weather_preset should have switched to CUSTOM (0)")
	
	print(">>> ALL PARAMETER PRESERVATION & CUSTOM TUNING TESTS PASSED! <<<")
	scene.queue_free()
	quit(0)
