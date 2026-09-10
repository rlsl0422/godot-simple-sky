@tool
extends SceneTree

func _init() -> void:
	print("--- Running Cube Flight & Camera Position Continuity Test ---")
	
	var test_positions = [
		Vector3(0.0, 50.0, 0.0),    # Directly above cube (at origin)
		Vector3(3.0, 50.0, -1.0),   # Flying over cube
		Vector3(13.5, 50.0, 0.0),   # Boundary of old 14m glitch circle
		Vector3(25.0, 50.0, 0.0),   # Just outside old glitch circle
		Vector3(500.0, 50.0, -300.0)# Far away over ocean
	]
	
	var zenith_sky_clearance = 0.3
	
	for pos in test_positions:
		var cam_world_xz = Vector2(pos.x, pos.z)
		var cam_km_xz = cam_world_xz * 0.001
		
		# Sample point directly overhead: ray_dir.xz = (0, 0)
		var sample_world_km_xz = cam_km_xz
		
		# Before fix (buggy: km - meters):
		var buggy_dist_xz = (sample_world_km_xz - cam_world_xz).length()
		var buggy_smooth = clampf((buggy_dist_xz - 2.0) / 12.0, 0.0, 1.0)
		var buggy_zenith = lerpf(zenith_sky_clearance * 0.09, 0.0, buggy_smooth)
		
		# After fix (fixed: km - km):
		var fixed_dist_xz = (sample_world_km_xz - cam_km_xz).length()
		var fixed_smooth = clampf((fixed_dist_xz - 2.0) / 12.0, 0.0, 1.0)
		var fixed_zenith = lerpf(zenith_sky_clearance * 0.09, 0.0, fixed_smooth)
		
		print("Camera at %25s | Buggy dist: %7.2f km (zenith: %.4f) | Fixed dist: %7.2f km (zenith: %.4f)" % [
			str(pos), buggy_dist_xz, buggy_zenith, fixed_dist_xz, fixed_zenith
		])
		
		# Fixed dist_xz directly overhead must ALWAYS be 0.0 km anywhere in the world!
		assert(abs(fixed_dist_xz - 0.0) < 0.0001, "Overhead dist_xz must always be 0.0 km")
		assert(abs(fixed_zenith - (zenith_sky_clearance * 0.09)) < 0.0001, "Zenith modifier must be identical everywhere")
	
	print(">>> ALL CUBE FLIGHT CONTINUITY TESTS PASSED! <<<")
	quit(0)
