@tool
class_name OceanNoiseGenerator
extends RefCounted

## Generates high-fidelity seamless normal map textures for ocean micro-waves and capillary ripples.

const CACHE_DIR := "res://assets/noises/"
const OCEAN_NORMAL_PATH := CACHE_DIR + "ocean_wave_normal.res"
const TEXTURE_SIZE := 512

static var _cached_ocean_normal: ImageTexture = null

static func get_or_create_ocean_normal() -> ImageTexture:
	if _cached_ocean_normal != null:
		return _cached_ocean_normal
	if ResourceLoader.exists(OCEAN_NORMAL_PATH):
		var res = ResourceLoader.load(OCEAN_NORMAL_PATH)
		if res is ImageTexture:
			_cached_ocean_normal = res
			return res
	_cached_ocean_normal = generate_ocean_normal(true)
	return _cached_ocean_normal

static func generate_ocean_normal(save_to_disk: bool = true) -> ImageTexture:
	print("[OceanNoiseGenerator] Generating %dx%d Seamless Simplex Ocean Wave Normal..." % [TEXTURE_SIZE, TEXTURE_SIZE])
	var start_time := Time.get_ticks_msec()
	var size := TEXTURE_SIZE

	var simplex := FastNoiseLite.new()
	simplex.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	simplex.frequency = 0.018
	simplex.fractal_octaves = 4
	simplex.fractal_lacunarity = 2.1
	simplex.fractal_gain = 0.50
	simplex.seed = 83921

	var height_data := PackedFloat32Array()
	height_data.resize(size * size)

	var f_size := float(size)
	for y in range(size):
		var fy := float(y)
		for x in range(size):
			var fx := float(x)
			var h_val := _sample_seamless_2d(simplex, fx, fy, f_size)
			height_data[y * size + x] = h_val

	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var bump_strength := 2.5 # Silky, soft ocean ripples without harsh faceting

	for y in range(size):
		var y_prev := (y - 1 + size) % size
		var y_next := (y + 1) % size
		for x in range(size):
			var x_prev := (x - 1 + size) % size
			var x_next := (x + 1) % size

			var h_l := height_data[y * size + x_prev]
			var h_r := height_data[y * size + x_next]
			var h_d := height_data[y_prev * size + x]
			var h_u := height_data[y_next * size + x]

			var dx := (h_r - h_l) * bump_strength
			var dy := (h_u - h_d) * bump_strength

			var len_sq := dx * dx + dy * dy + 1.0
			var inv_len := 1.0 / sqrt(len_sq)
			var nx := -dx * inv_len
			var ny := -dy * inv_len
			var nz := 1.0 * inv_len

			var r := int(clampf((nx * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			var g := int(clampf((ny * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			var b := int(clampf((nz * 0.5 + 0.5) * 255.0, 0.0, 255.0))

			img.set_pixel(x, y, Color8(r, g, b, 255))

	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var elapsed := Time.get_ticks_msec() - start_time
	print("[OceanNoiseGenerator] Seamless Ocean Wave Normal generated in %d ms." % elapsed)

	if save_to_disk:
		var dir := DirAccess.open("res://")
		if not dir.dir_exists(CACHE_DIR):
			dir.make_dir_recursive(CACHE_DIR)
		ResourceSaver.save(tex, OCEAN_NORMAL_PATH)
		print("[OceanNoiseGenerator] Saved Ocean Wave Normal to: %s" % OCEAN_NORMAL_PATH)

	return tex

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


