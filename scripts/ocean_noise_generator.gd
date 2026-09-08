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
	print("[OceanNoiseGenerator] Generating %dx%d Ocean Wave Normal Texture..." % [TEXTURE_SIZE, TEXTURE_SIZE])
	var start_time := Time.get_ticks_msec()

	var simplex := FastNoiseLite.new()
	simplex.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	simplex.frequency = 0.02
	simplex.fractal_octaves = 4
	simplex.fractal_lacunarity = 2.1
	simplex.fractal_gain = 0.5

	var size := TEXTURE_SIZE
	var height_data := PackedFloat32Array()
	height_data.resize(size * size)

	for y in range(size):
		for x in range(size):
			var fx := float(x)
			var fy := float(y)
			var s_val := _sample_seamless_2d(simplex, fx, fy, size)
			height_data[y * size + x] = s_val

	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	var bump_strength := 5.0

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

			var norm := Vector3(-dx, -dy, 1.0).normalized()

			var r := int(clampf((norm.x * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			var g := int(clampf((norm.y * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			var b := int(clampf((norm.z * 0.5 + 0.5) * 255.0, 0.0, 255.0))

			img.set_pixel(x, y, Color8(r, g, b, 255))

	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var elapsed := Time.get_ticks_msec() - start_time
	print("[OceanNoiseGenerator] Ocean Wave Normal generated in %d ms." % elapsed)

	if save_to_disk:
		var dir := DirAccess.open("res://")
		if not dir.dir_exists(CACHE_DIR):
			dir.make_dir_recursive(CACHE_DIR)
		ResourceSaver.save(tex, OCEAN_NORMAL_PATH)
		print("[OceanNoiseGenerator] Saved Ocean Wave Normal to: %s" % OCEAN_NORMAL_PATH)

	return tex

static func _sample_seamless_2d(noise: FastNoiseLite, x: float, y: float, size: int) -> float:
	var nx := x / float(size)
	var ny := y / float(size)
	var pi2 := TAU
	var angle_x := nx * pi2
	var angle_y := ny * pi2
	var r := float(size) / (pi2 * 10.0)
	var x1 := r * cos(angle_x)
	var y1 := r * sin(angle_x)
	var x2 := r * cos(angle_y)
	var y2 := r * sin(angle_y)
	return (noise.get_noise_2d(x1, y1) + noise.get_noise_2d(x2 + 73.1, y2 + 91.7)) * 0.5
