@tool
class_name CloudNoiseGenerator
extends RefCounted

## Generates 3D and 2D noise textures for volumetric cloud rendering.
## Automatically caches textures to disk for instantaneous loading on subsequent runs.

const CACHE_DIR := "res://assets/noises/"
const BASE_NOISE_PATH := CACHE_DIR + "cloud_base_shape_3d.res"
const DETAIL_NOISE_PATH := CACHE_DIR + "cloud_detail_3d.res"
const WEATHER_MAP_PATH := CACHE_DIR + "weather_map_2d.res"

const BASE_SIZE := 36
const DETAIL_SIZE := 24
const WEATHER_SIZE := 128

static var _cached_base_noise: ImageTexture3D = null
static var _cached_detail_noise: ImageTexture3D = null
static var _cached_weather_map: ImageTexture = null

static func get_or_create_base_noise() -> ImageTexture3D:
	if _cached_base_noise != null:
		return _cached_base_noise
	if ResourceLoader.exists(BASE_NOISE_PATH):
		var res = ResourceLoader.load(BASE_NOISE_PATH)
		if res is ImageTexture3D:
			_cached_base_noise = res
			return res
	_cached_base_noise = generate_base_noise(true)
	return _cached_base_noise

static func get_or_create_detail_noise() -> ImageTexture3D:
	if _cached_detail_noise != null:
		return _cached_detail_noise
	if ResourceLoader.exists(DETAIL_NOISE_PATH):
		var res = ResourceLoader.load(DETAIL_NOISE_PATH)
		if res is ImageTexture3D:
			_cached_detail_noise = res
			return res
	_cached_detail_noise = generate_detail_noise(true)
	return _cached_detail_noise

static func get_or_create_weather_map() -> ImageTexture:
	if _cached_weather_map != null:
		return _cached_weather_map
	if ResourceLoader.exists(WEATHER_MAP_PATH):
		var res = ResourceLoader.load(WEATHER_MAP_PATH)
		if res is ImageTexture:
			_cached_weather_map = res
			return res
	_cached_weather_map = generate_weather_map(true)
	return _cached_weather_map

## Generate seamless 128x128x128 Base Shape 3D Texture
## R: Perlin-Worley (billowy cloud base)
## G: Worley octave 1
## B: Worley octave 2
## A: Worley octave 3
static func generate_base_noise(save_to_disk: bool = true) -> ImageTexture3D:
	print("[CloudNoiseGenerator] Generating %dx%dx%d Base Shape 3D Noise..." % [BASE_SIZE, BASE_SIZE, BASE_SIZE])
	var start_time := Time.get_ticks_msec()
	
	# FastNoiseLite setups for native C++ speed
	var perlin := FastNoiseLite.new()
	perlin.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	perlin.frequency = 0.035
	perlin.fractal_octaves = 4
	perlin.fractal_gain = 0.5
	
	var worley1 := FastNoiseLite.new()
	worley1.noise_type = FastNoiseLite.TYPE_CELLULAR
	worley1.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	worley1.frequency = 0.04
	
	var worley2 := FastNoiseLite.new()
	worley2.noise_type = FastNoiseLite.TYPE_CELLULAR
	worley2.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	worley2.frequency = 0.08
	
	var worley3 := FastNoiseLite.new()
	worley3.noise_type = FastNoiseLite.TYPE_CELLULAR
	worley3.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	worley3.frequency = 0.16
	
	var images: Array[Image] = []
	var size := BASE_SIZE
	
	for z in range(size):
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in range(size):
			for x in range(size):
				# Seamless 3D coordinates using modular sampling
				var fx := float(x)
				var fy := float(y)
				var fz := float(z)
				
				# Seamless distance wrap
				var p_val: float = _sample_seamless_3d(perlin, fx, fy, fz, size)
				var w1_val: float = _sample_seamless_3d(worley1, fx, fy, fz, size)
				var w2_val: float = _sample_seamless_3d(worley2, fx, fy, fz, size)
				var w3_val: float = _sample_seamless_3d(worley3, fx, fy, fz, size)
				
				# Remap [ -1, 1 ] to [ 0, 1 ]
				p_val = clampf((p_val + 1.0) * 0.5, 0.0, 1.0)
				w1_val = clampf((w1_val + 1.0) * 0.5, 0.0, 1.0)
				w2_val = clampf((w2_val + 1.0) * 0.5, 0.0, 1.0)
				w3_val = clampf((w3_val + 1.0) * 0.5, 0.0, 1.0)
				
				# Invert worley for billowy tops
				var inv_w1 := 1.0 - w1_val
				var inv_w2 := 1.0 - w2_val
				var inv_w3 := 1.0 - w3_val
				
				# Combine Perlin and Worley for base cloud shape (Schneider 2015)
				var pw := _remap(p_val, inv_w1 * 0.4, 1.0, 0.0, 1.0)
				
				var r := int(clampf(pw, 0.0, 1.0) * 255.0)
				var g := int(inv_w1 * 255.0)
				var b := int(inv_w2 * 255.0)
				var a := int(inv_w3 * 255.0)
				
				img.set_pixel(x, y, Color8(r, g, b, a))
		images.append(img)
	
	var tex3d := ImageTexture3D.new()
	var err := tex3d.create(Image.FORMAT_RGBA8, size, size, size, false, images)
	if err != OK:
		printerr("[CloudNoiseGenerator] Failed to create ImageTexture3D: ", err)
		return null
		
	var elapsed := Time.get_ticks_msec() - start_time
	print("[CloudNoiseGenerator] Base 3D Noise generated in ", elapsed, " ms.")
	
	if save_to_disk:
		_ensure_cache_dir()
		ResourceSaver.save(tex3d, BASE_NOISE_PATH)
		print("[CloudNoiseGenerator] Saved Base 3D Noise to: ", BASE_NOISE_PATH)
		
	return tex3d

## Generate seamless 32x32x32 Detail Shape 3D Texture
## High-frequency Worley noise for erosion
static func generate_detail_noise(save_to_disk: bool = true) -> ImageTexture3D:
	print("[CloudNoiseGenerator] Generating 32x32x32 Detail 3D Noise...")
	var start_time := Time.get_ticks_msec()
	
	var w1 := FastNoiseLite.new()
	w1.noise_type = FastNoiseLite.TYPE_CELLULAR
	w1.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	w1.frequency = 0.08
	
	var w2 := FastNoiseLite.new()
	w2.noise_type = FastNoiseLite.TYPE_CELLULAR
	w2.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	w2.frequency = 0.16
	
	var w3 := FastNoiseLite.new()
	w3.noise_type = FastNoiseLite.TYPE_CELLULAR
	w3.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	w3.frequency = 0.32
	
	var images: Array[Image] = []
	var size := DETAIL_SIZE
	
	for z in range(size):
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in range(size):
			for x in range(size):
				var fx := float(x)
				var fy := float(y)
				var fz := float(z)
				
				var v1: float = _sample_seamless_3d(w1, fx, fy, fz, size)
				var v2: float = _sample_seamless_3d(w2, fx, fy, fz, size)
				var v3: float = _sample_seamless_3d(w3, fx, fy, fz, size)
				
				v1 = clampf(1.0 - (v1 + 1.0) * 0.5, 0.0, 1.0)
				v2 = clampf(1.0 - (v2 + 1.0) * 0.5, 0.0, 1.0)
				v3 = clampf(1.0 - (v3 + 1.0) * 0.5, 0.0, 1.0)
				
				# High-frequency FBM
				var detail_fbm := v1 * 0.625 + v2 * 0.25 + v3 * 0.125
				
				var r := int(v1 * 255.0)
				var g := int(v2 * 255.0)
				var b := int(v3 * 255.0)
				var a := int(clampf(detail_fbm, 0.0, 1.0) * 255.0)
				
				img.set_pixel(x, y, Color8(r, g, b, a))
		images.append(img)
		
	var tex3d := ImageTexture3D.new()
	var err := tex3d.create(Image.FORMAT_RGBA8, size, size, size, false, images)
	if err != OK:
		printerr("[CloudNoiseGenerator] Failed to create Detail 3D: ", err)
		return null
		
	var elapsed := Time.get_ticks_msec() - start_time
	print("[CloudNoiseGenerator] Detail 3D Noise generated in ", elapsed, " ms.")
	
	if save_to_disk:
		_ensure_cache_dir()
		ResourceSaver.save(tex3d, DETAIL_NOISE_PATH)
		print("[CloudNoiseGenerator] Saved Detail 3D Noise to: ", DETAIL_NOISE_PATH)
		
	return tex3d

## Generate seamless 512x512 2D Weather Map
## R: Coverage (cloud amount)
## G: Cloud Type (0: Stratus, 0.5: Stratocumulus, 1: Cumulus)
## B: Density/Thickness
static func generate_weather_map(save_to_disk: bool = true) -> ImageTexture:
	print("[CloudNoiseGenerator] Generating %dx%d Weather Map..." % [WEATHER_SIZE, WEATHER_SIZE])
	var start_time := Time.get_ticks_msec()
	
	var coverage_noise := FastNoiseLite.new()
	coverage_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	coverage_noise.frequency = 0.005
	coverage_noise.fractal_octaves = 4
	
	var type_noise := FastNoiseLite.new()
	type_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	type_noise.frequency = 0.003
	type_noise.fractal_octaves = 3
	
	var density_noise := FastNoiseLite.new()
	density_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	density_noise.frequency = 0.008
	density_noise.fractal_octaves = 3
	
	var size := WEATHER_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	
	for y in range(size):
		for x in range(size):
			var fx := float(x)
			var fy := float(y)
			
			var cov := _sample_seamless_2d(coverage_noise, fx, fy, size)
			var typ := _sample_seamless_2d(type_noise, fx, fy, size)
			var den := _sample_seamless_2d(density_noise, fx, fy, size)
			
			cov = clampf((cov + 1.0) * 0.5, 0.0, 1.0)
			typ = clampf((typ + 1.0) * 0.5, 0.0, 1.0)
			den = clampf((den + 1.0) * 0.5, 0.0, 1.0)
			
			var r := int(cov * 255.0)
			var g := int(typ * 255.0)
			var b := int(den * 255.0)
			var a := 255
			
			img.set_pixel(x, y, Color8(r, g, b, a))
			
	var tex := ImageTexture.create_from_image(img)
	var elapsed := Time.get_ticks_msec() - start_time
	print("[CloudNoiseGenerator] Weather map generated in ", elapsed, " ms.")
	
	if save_to_disk:
		_ensure_cache_dir()
		ResourceSaver.save(tex, WEATHER_MAP_PATH)
		print("[CloudNoiseGenerator] Saved Weather map to: ", WEATHER_MAP_PATH)
		
	return tex

## Helper: 100% C1-smooth boundary-blended seamless 3D sampling
static func _sample_seamless_3d(noise: FastNoiseLite, x: float, y: float, z: float, size: float) -> float:
	var u := x / size
	var v := y / size
	var w := z / size
	# Quintic C1 polynomial: 6t^5 - 15t^4 + 10t^3
	var su := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
	var sv := v * v * v * (v * (v * 6.0 - 15.0) + 10.0)
	var sw := w * w * w * (w * (w * 6.0 - 15.0) + 10.0)
	
	var n000 := noise.get_noise_3d(x, y, z)
	var n100 := noise.get_noise_3d(x - size, y, z)
	var n010 := noise.get_noise_3d(x, y - size, z)
	var n110 := noise.get_noise_3d(x - size, y - size, z)
	var n001 := noise.get_noise_3d(x, y, z - size)
	var n101 := noise.get_noise_3d(x - size, y, z - size)
	var n011 := noise.get_noise_3d(x, y - size, z - size)
	var n111 := noise.get_noise_3d(x - size, y - size, z - size)
	
	var c00 := lerpf(n000, n100, su)
	var c10 := lerpf(n010, n110, su)
	var c01 := lerpf(n001, n101, su)
	var c11 := lerpf(n011, n111, su)
	
	var c0 := lerpf(c00, c10, sv)
	var c1 := lerpf(c01, c11, sv)
	
	return lerpf(c0, c1, sw)

## Helper: 100% C1-smooth boundary-blended seamless 2D sampling
static func _sample_seamless_2d(noise: FastNoiseLite, x: float, y: float, size: float) -> float:
	var u := x / size
	var v := y / size
	# Quintic C1 polynomial: 6t^5 - 15t^4 + 10t^3
	var su := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
	var sv := v * v * v * (v * (v * 6.0 - 15.0) + 10.0)
	
	var n00 := noise.get_noise_2d(x, y)
	var n10 := noise.get_noise_2d(x - size, y)
	var n01 := noise.get_noise_2d(x, y - size)
	var n11 := noise.get_noise_2d(x - size, y - size)
	
	var top := lerpf(n00, n10, su)
	var bot := lerpf(n01, n11, su)
	return lerpf(top, bot, sv)

static func _remap(value: float, old_min: float, old_max: float, new_min: float, new_max: float) -> float:
	if absf(old_max - old_min) < 0.00001:
		return new_min
	return new_min + (((value - old_min) / (old_max - old_min)) * (new_max - new_min))

static func _ensure_cache_dir() -> void:
	if not DirAccess.dir_exists_absolute("res://assets"):
		DirAccess.make_dir_absolute("res://assets")
	if not DirAccess.dir_exists_absolute("res://assets/noises"):
		DirAccess.make_dir_absolute("res://assets/noises")
