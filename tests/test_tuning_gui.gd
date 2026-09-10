@tool
extends SceneTree

func _init() -> void:
	print("--- Running Tuning GUI Integration Test ---")
	var scene_res = load("res://scenes/main_showcase.tscn")
	if not scene_res:
		printerr("FAIL: Could not load main_showcase.tscn")
		quit(1)
		return
		
	var scene = scene_res.instantiate()
	root.add_child(scene)
	await process_frame
	
	var controller = scene.get_node_or_null("AtmosphereCloudController")
	var gui = scene.get_node_or_null("CanvasLayer/TuningGUI")
	
	if not controller:
		printerr("FAIL: AtmosphereCloudController not found")
		quit(1)
		return
	if not gui:
		printerr("FAIL: TuningGUI not found in CanvasLayer")
		quit(1)
		return
		
	print("TuningGUI found and attached successfully!")
	
	# Verify sliders created
	print("Slider entries count: ", gui._slider_entries.size(), " (Expected >= 14)")
	assert(gui._slider_entries.size() >= 14, "Must have at least 14 slider entries")
	
	# Test slider sync from controller
	var cov_entry: Dictionary
	for entry in gui._slider_entries:
		if entry.name == "Cloud Coverage":
			cov_entry = entry
			break
	assert(not cov_entry.is_empty(), "Cloud Coverage slider entry must exist")
	print("Cloud Coverage slider value: ", cov_entry.slider.value, " (Expected 0.36)")
	assert(abs(cov_entry.slider.value - 0.36) < 0.001, "Coverage slider must be 0.36")
	
	# Test changing slider value
	print("Simulating user dragging Cloud Coverage slider to 0.48...")
	gui._is_user_dragging = true
	cov_entry.slider.value = 0.48
	gui._is_user_dragging = false
	
	print("Controller cloud_coverage is now: ", controller.cloud_coverage)
	assert(abs(controller.cloud_coverage - 0.48) < 0.001, "Controller cloud_coverage should update to 0.48")
	assert(controller.weather_preset == 0, "Weather preset should remain CUSTOM (0)")
	
	# Test collapse toggle
	print("Testing collapse toggle...")
	assert(gui._is_collapsed == false, "Initially not collapsed")
	gui._toggle_collapse()
	assert(gui._is_collapsed == true, "Should be collapsed")
	gui._toggle_collapse()
	assert(gui._is_collapsed == false, "Should be expanded again")
	
	# Test weather preset OptionButton
	print("Testing weather preset dropdown...")
	gui._on_weather_preset_selected(2) # FAIR_CUMULUS
	assert(controller.weather_preset == 2, "Controller weather_preset should be 2")
	
	# Test reset to defaults
	print("Testing reset to defaults...")
	gui._reset_to_saved_defaults()
	print("After reset, cloud_coverage = ", controller.cloud_coverage, " (Expected 0.36)")
	assert(abs(controller.cloud_coverage - 0.36) < 0.001, "Should restore 0.36")
	
	print(">>> ALL TUNING GUI INTEGRATION TESTS PASSED! <<<")
	scene.queue_free()
	quit(0)
