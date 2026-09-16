extends SceneTree

## Builds a seamless, opaque terrain tile from the road-track decal texture,
## so the track-dirt look can be used as the Terrain3D ground material.
##
## Steps (per texture):
##   1. Fill transparent border pixels by interpolating the nearest opaque
##      pixels on each row (decals carry alpha; RGB under alpha is black).
##   2. Crop to the opaque bounding box.
##   3. Blend edge bands toward the mirrored opposite edge, so left/right and
##      top/bottom tile without seams.
##   4. Stack the tile with its vertical mirror to get a square texture
##      (the source is 2:1; Terrain3D tiles are square).
##   5. Normal map: renormalize every pixel after blending.
##
## Usage: godot --headless --path . --script res://tools/make_dirt_terrain_texture.gd

const SRC_DIR := "res://maps/construction/Construction_Site/Textures/Decals/Road_Tracks_01/Straight/"
const OUT_DIR := "res://maps/construction/Construction_Site/Textures/Tileable/Site_Dirt_Tracks/"
const ALPHA_THRESHOLD := 200
const BLEND_BAND := 16
const CROP_MARGIN := 4
## Terrain tiles are sampled up close; 2048 keeps ~51 px/m at a 40 m tile.
const OUTPUT_SIZE := 2048

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var albedo := _process_image(SRC_DIR + "T_Road_Decal_Straight_01_Decal.png", false)
	if albedo == null:
		quit(1)
		return
	var normal := _process_image(SRC_DIR + "T_Road_Decal_Straight_01_normal.png", true)
	if normal == null:
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var alb_path := OUT_DIR + "T_Site_Dirt_Tracks_BaseColor.png"
	var nrm_path := OUT_DIR + "T_Site_Dirt_Tracks_Normal.png"
	var e1 := albedo.save_png(ProjectSettings.globalize_path(alb_path))
	var e2 := normal.save_png(ProjectSettings.globalize_path(nrm_path))
	print("DIRTTEX saved albedo=", e1, " ", alb_path, " ", albedo.get_width(), "x", albedo.get_height())
	print("DIRTTEX saved normal=", e2, " ", nrm_path, " ", normal.get_width(), "x", normal.get_height())
	quit(0 if e1 == OK and e2 == OK else 1)

func _process_image(path: String, is_normal: bool) -> Image:
	var src := Image.load_from_file(ProjectSettings.globalize_path(path))
	if src == null:
		push_error("DIRTTEX cannot load " + path)
		return null
	src.convert(Image.FORMAT_RGBA8)
	print("DIRTTEX source ", path.get_file(), " ", src.get_width(), "x", src.get_height())
	# Locate the opaque content on a small proxy, then crop the full-resolution
	# source to a square window around it. The decal's transparent margins must
	# never reach the fill step or row interpolation smears them into streaks.
	var proxy := src.duplicate()
	proxy.resize(OUTPUT_SIZE, OUTPUT_SIZE, Image.INTERPOLATE_BILINEAR)
	var bbox := _opaque_bbox(proxy)
	if bbox.size.x <= 0 or bbox.size.y <= 0:
		push_error("DIRTTEX no opaque pixels")
		return null
	var side := mini(bbox.size.x, bbox.size.y)
	var win := Rect2i(
		bbox.position.x + (bbox.size.x - side) / 2,
		bbox.position.y + (bbox.size.y - side) / 2, side, side)
	var k := float(src.get_width()) / float(OUTPUT_SIZE)
	var src_rect := Rect2i(
		roundi(win.position.x * k), roundi(win.position.y * k),
		roundi(win.size.x * k), roundi(win.size.y * k))
	src_rect = src_rect.intersection(Rect2i(0, 0, src.get_width(), src.get_height()))
	var crop := Image.create(src_rect.size.x, src_rect.size.y, false, Image.FORMAT_RGBA8)
	crop.blit_rect(src, src_rect, Vector2i.ZERO)
	crop.resize(OUTPUT_SIZE, OUTPUT_SIZE, Image.INTERPOLATE_LANCZOS)
	_fill_alpha(crop)
	_blend_edges(crop)
	if is_normal:
		_renormalize(crop)
	return crop

func _opaque_bbox(img: Image) -> Rect2i:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var minx := w
	var miny := h
	var maxx := -1
	var maxy := -1
	for y in h:
		var row := y * w * 4
		for x in w:
			if data[row + x * 4 + 3] >= ALPHA_THRESHOLD:
				if x < minx:
					minx = x
				if x > maxx:
					maxx = x
				miny = mini(miny, y)
				maxy = y
	if maxx < 0:
		return Rect2i()
	return Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)

## Replaces pixels with alpha < ALPHA_THRESHOLD by interpolating the nearest
## opaque pixels on the same row.
func _fill_alpha(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	for y in h:
		var row := y * w * 4
		var x := 0
		while x < w:
			if data[row + x * 4 + 3] >= ALPHA_THRESHOLD:
				x += 1
				continue
			var xs := x
			while x < w and data[row + x * 4 + 3] < ALPHA_THRESHOLD:
				x += 1
			var xe := x
			var has_l := xs > 0
			var has_r := xe < w
			for xi in range(xs, xe):
				var t := 0.5 if not has_l else (float(xi - xs + 1) / float(xe - xs + 1) if has_r else 0.0)
				for c in 3:
					var v := 0.0
					if has_l and has_r:
						v = data[row + (xs - 1) * 4 + c] * (1.0 - t) + data[row + xe * 4 + c] * t
					elif has_l:
						v = data[row + (xs - 1) * 4 + c]
					elif has_r:
						v = data[row + xe * 4 + c]
					data[row + xi * 4 + c] = int(clampf(v, 0.0, 255.0))
				data[row + xi * 4 + 3] = 255
	img.set_data(w, h, img.has_mipmaps(), img.get_format(), data)

## Blends the BLEND_BAND-wide border toward the mirrored opposite edge so the
## texture tiles without seams. Weight peaks at the very edge pixel.
func _blend_edges(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	for y in h:
		var row := y * w * 4
		for x in BLEND_BAND:
			var t := 0.85 * (1.0 - float(x) / float(BLEND_BAND))
			for c in 3:
				var a := data[row + x * 4 + c]
				var b := data[row + (w - 1 - x) * 4 + c]
				data[row + x * 4 + c] = int(a * (1.0 - t) + b * t)
				data[row + (w - 1 - x) * 4 + c] = int(b * (1.0 - t) + a * t)
	for x in w:
		var col := x * 4
		for y in BLEND_BAND:
			var t := 0.85 * (1.0 - float(y) / float(BLEND_BAND))
			for c in 3:
				var a := data[y * w * 4 + col + c]
				var b := data[(h - 1 - y) * w * 4 + col + c]
				data[y * w * 4 + col + c] = int(a * (1.0 - t) + b * t)
				data[(h - 1 - y) * w * 4 + col + c] = int(b * (1.0 - t) + a * t)
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)

func _renormalize(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	for i in w * h:
		var o := i * 4
		var nx := data[o] / 255.0 * 2.0 - 1.0
		var ny := data[o + 1] / 255.0 * 2.0 - 1.0
		var nz := data[o + 2] / 255.0 * 2.0 - 1.0
		var l := sqrt(nx * nx + ny * ny + nz * nz)
		if l < 0.0001:
			continue
		data[o] = int(clampf((nx / l * 0.5 + 0.5) * 255.0, 0.0, 255.0))
		data[o + 1] = int(clampf((ny / l * 0.5 + 0.5) * 255.0, 0.0, 255.0))
		data[o + 2] = int(clampf((nz / l * 0.5 + 0.5) * 255.0, 0.0, 255.0))
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)
