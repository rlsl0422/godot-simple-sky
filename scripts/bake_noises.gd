extends SceneTree

const CloudNoiseGen = preload("res://scripts/cloud_noise_generator.gd")

func _init() -> void:
	print("[BakeNoises] Starting 3D & 2D noise generation...")
	var t0 = Time.get_ticks_msec()
	
	# Generate Base Noise
	CloudNoiseGen.generate_base_noise(true)
	
	# Generate Detail Noise
	CloudNoiseGen.generate_detail_noise(true)
	
	# Generate Weather Map
	CloudNoiseGen.generate_weather_map(true)
	
	var elapsed = Time.get_ticks_msec() - t0
	print("[BakeNoises] Finished all noise baking in %d ms!" % elapsed)
	quit(0)
