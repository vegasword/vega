package vega

import "core:c"
import "core:log"
import "core:math"
import "core:os"
import sdl "vendor:sdl3"
import stbtt "vendor:stb/truetype"

ATLAS_SIDE :: 1024

victor_mono_medium := #load("fonts/VictorMono-Medium.ttf")
victor_mono_bold := #load("fonts/VictorMono-Bold.ttf")

fallback_font_paths := []string {
	"C:/Windows/Fonts/seguisym.ttf",
	"C:/Windows/Fonts/malgun.ttf",
	"C:/Windows/Fonts/msgothic.ttc",
}

Face :: struct {
	info:  stbtt.fontinfo,
	data:  []u8,
	owned: bool,
	scale: f32,
}

Glyph :: struct {
	u0, v0, u1, v1: f32,
	offset_x:       f32,
	offset_y:       f32,
	width:          f32,
	height:         f32,
	missing:        bool,
}

Glyph_Key :: struct {
	codepoint: rune,
	index:     int,
	bold:      bool,
}

Painter :: struct {
	renderer:    ^sdl.Renderer,
	texture:     ^sdl.Texture,
	atlas:       ^sdl.Surface,
	faces:       [dynamic]Face,
	glyphs:      map[Glyph_Key]Glyph,
	shaper:      Shaper,
	pen_x:       i32,
	pen_y:       i32,
	row_height:  i32,
	white_u:     f32,
	white_v:     f32,
	cell_width:  f32,
	line_height: f32,
	ascent:      f32,
	vertices:    [dynamic]sdl.Vertex,
	indices:     [dynamic]c.int,
	clip:        sdl.Rect,
}

face_open :: proc(painter: ^Painter, data: []u8, owned: bool, size: f32) -> bool {
	face: Face
	face.data = data
	face.owned = owned
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), 0)
	if !stbtt.InitFont(&face.info, raw_data(data), offset) {
		if owned {
			delete(data)
		}
		return false
	}
	face.scale = stbtt.ScaleForPixelHeight(&face.info, size)
	append(&painter.faces, face)
	return true
}

painter_load_font :: proc(painter: ^Painter, size: f32) -> bool {
	for face in painter.faces {
		if face.owned {
			delete(face.data)
		}
	}
	clear(&painter.faces)
	clear(&painter.glyphs)

	if !face_open(painter, victor_mono_medium, false, size) || !face_open(painter, victor_mono_bold, false, size) {
		log.fatal("the embedded font failed to parse")
		return false
	}
	for path in fallback_font_paths {
		if data, error := os.read_entire_file(path, context.allocator); error == nil {
			if !face_open(painter, data, true, size) {
				log.warnf("fallback %s could not be parsed", path)
			}
		}
	}

	primary := &painter.faces[0]
	ascent, descent, line_gap: c.int
	stbtt.GetFontVMetrics(&primary.info, &ascent, &descent, &line_gap)
	advance, bearing: c.int
	stbtt.GetCodepointHMetrics(&primary.info, 'M', &advance, &bearing)
	painter.ascent = f32(ascent) * primary.scale
	painter.line_height = math.ceil(f32(ascent - descent + line_gap) * primary.scale)
	painter.cell_width = math.ceil(f32(advance) * primary.scale)

	if painter.atlas == nil {
		painter.atlas = sdl.CreateSurface(ATLAS_SIDE, ATLAS_SIDE, .RGBA32)
		if painter.atlas == nil {
			return false
		}
	}
	sdl.FillSurfaceRect(painter.atlas, nil, sdl.MapSurfaceRGBA(painter.atlas, 0, 0, 0, 0))
	white_block := sdl.Rect{0, 0, 4, 4}
	sdl.FillSurfaceRect(painter.atlas, &white_block, sdl.MapSurfaceRGBA(painter.atlas, 255, 255, 255, 255))
	painter.white_u = 2.0 / f32(ATLAS_SIDE)
	painter.white_v = 2.0 / f32(ATLAS_SIDE)
	painter.pen_x, painter.pen_y, painter.row_height = 8, 0, 4

	if painter.texture != nil {
		sdl.DestroyTexture(painter.texture)
	}
	painter.texture = sdl.CreateTextureFromSurface(painter.renderer, painter.atlas)
	if painter.texture == nil {
		return false
	}
	sdl.SetTextureBlendMode(painter.texture, sdl.BLENDMODE_BLEND)
	sdl.SetTextureScaleMode(painter.texture, .LINEAR)

	for code in 32 ..= 126 {
		painter_glyph(painter, rune(code))
	}
	if len(painter.shaper.order) == 0 {
		shaper_build(&painter.shaper, &painter.faces[0])
	}
	log.infof("victor mono medium and bold at %.0fpt, cell %.0fx%.0f, %d faces", size, painter.cell_width, painter.line_height, len(painter.faces))
	return true
}

painter_glyph :: proc(painter: ^Painter, codepoint: rune, bold := false, index := 0) -> Glyph {
	key := Glyph_Key{codepoint, index, bold}
	if glyph, found := painter.glyphs[key]; found {
		return glyph
	}
	if len(painter.faces) < 2 {
		return {missing = true}
	}

	face: ^Face
	glyph_index := c.int(index)
	if index != 0 {
		face = &painter.faces[bold ? 1 : 0]
	} else {
		for &candidate, position in painter.faces {
			if position == (bold ? 0 : 1) {
				continue
			}
			if found := stbtt.FindGlyphIndex(&candidate.info, codepoint); found != 0 {
				face = &candidate
				glyph_index = found
				break
			}
		}
	}
	if face == nil {
		painter.glyphs[key] = {missing = true}
		return painter.glyphs[key]
	}

	width, height, offset_x, offset_y: c.int
	pixels := stbtt.GetGlyphBitmap(&face.info, face.scale, face.scale, glyph_index, &width, &height, &offset_x, &offset_y)
	defer if pixels != nil {stbtt.FreeBitmap(pixels, nil)}

	glyph := Glyph {
		offset_x = f32(offset_x),
		offset_y = painter.ascent + f32(offset_y),
		width    = f32(width),
		height   = f32(height),
	}
	if pixels == nil || width == 0 || height == 0 {
		painter.glyphs[key] = glyph
		return glyph
	}

	if painter.pen_x + width + 1 >= ATLAS_SIDE {
		painter.pen_x = 0
		painter.pen_y += painter.row_height + 1
		painter.row_height = 0
	}
	if painter.pen_y + height >= ATLAS_SIDE {
		log.warn("the glyph atlas is full, recycling it")
		clear(&painter.glyphs)
		sdl.FillSurfaceRect(painter.atlas, nil, sdl.MapSurfaceRGBA(painter.atlas, 0, 0, 0, 0))
		white_block := sdl.Rect{0, 0, 4, 4}
		sdl.FillSurfaceRect(painter.atlas, &white_block, sdl.MapSurfaceRGBA(painter.atlas, 255, 255, 255, 255))
		painter.pen_x, painter.pen_y, painter.row_height = 8, 0, 4
	}

	destination := ([^]u32)(painter.atlas.pixels)
	stride := int(painter.atlas.pitch / 4)
	for row in 0 ..< int(height) {
		for column in 0 ..< int(width) {
			alpha := u32(pixels[row * int(width) + column])
			destination[(int(painter.pen_y) + row) * stride + int(painter.pen_x) + column] = 0x00ffffff | (alpha << 24)
		}
	}
	region := sdl.Rect{painter.pen_x, painter.pen_y, width, height}
	corner := &destination[int(painter.pen_y) * stride + int(painter.pen_x)]
	sdl.UpdateTexture(painter.texture, &region, corner, painter.atlas.pitch)

	glyph.u0 = f32(painter.pen_x) / f32(ATLAS_SIDE)
	glyph.v0 = f32(painter.pen_y) / f32(ATLAS_SIDE)
	glyph.u1 = f32(painter.pen_x + width) / f32(ATLAS_SIDE)
	glyph.v1 = f32(painter.pen_y + height) / f32(ATLAS_SIDE)
	painter.pen_x += width + 1
	painter.row_height = max(painter.row_height, height)
	painter.glyphs[key] = glyph
	return glyph
}

rune_columns :: proc(codepoint: rune) -> int {
	switch {
	case codepoint < 0x1100:
		return 1
	case codepoint >= 0x1100 && codepoint <= 0x115f,
	     codepoint >= 0x2e80 && codepoint <= 0xa4cf,
	     codepoint >= 0xac00 && codepoint <= 0xd7a3,
	     codepoint >= 0xf900 && codepoint <= 0xfaff,
	     codepoint >= 0xfe30 && codepoint <= 0xfe6f,
	     codepoint >= 0xff00 && codepoint <= 0xff60,
	     codepoint >= 0xffe0 && codepoint <= 0xffe6,
	     codepoint >= 0x1f300 && codepoint <= 0x1f9ff:
		return 2
	}
	return 1
}

push_quad :: proc(painter: ^Painter, x, y, width, height: f32, u0, v0, u1, v1: f32, color: [4]f32) {
	base := c.int(len(painter.vertices))
	tint := sdl.FColor{color.r, color.g, color.b, color.a}
	append(&painter.vertices, sdl.Vertex{{x, y}, tint, {u0, v0}})
	append(&painter.vertices, sdl.Vertex{{x + width, y}, tint, {u1, v0}})
	append(&painter.vertices, sdl.Vertex{{x + width, y + height}, tint, {u1, v1}})
	append(&painter.vertices, sdl.Vertex{{x, y + height}, tint, {u0, v1}})
	append(&painter.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

push_rect :: proc(painter: ^Painter, x, y, width, height: f32, color: [4]f32) {
	if width <= 0 || height <= 0 {
		return
	}
	push_quad(painter, x, y, width, height, painter.white_u, painter.white_v, painter.white_u, painter.white_v, color)
}

push_glyph :: proc(painter: ^Painter, x, y: f32, codepoint: rune, color: [4]f32, bold := false) {
	glyph := painter_glyph(painter, codepoint, bold)
	if glyph.missing {
		push_rect(painter, x + 1, y + painter.line_height * 0.25, painter.cell_width - 2, painter.line_height * 0.5, color * [4]f32{1, 1, 1, 0.25})
		return
	}
	if glyph.width == 0 {
		return
	}
	allowed := painter.cell_width * f32(rune_columns(codepoint))
	scale := glyph.width > allowed ? allowed / glyph.width : 1
	push_quad(
		painter,
		x + glyph.offset_x * scale,
		y + glyph.offset_y * scale,
		glyph.width * scale,
		glyph.height * scale,
		glyph.u0,
		glyph.v0,
		glyph.u1,
		glyph.v1,
		color,
	)
}

push_line :: proc(painter: ^Painter, from_x, from_y, to_x, to_y, thickness: f32, color: [4]f32) {
	direction_x := to_x - from_x
	direction_y := to_y - from_y
	length := math.sqrt(direction_x * direction_x + direction_y * direction_y)
	if length < 0.5 {
		return
	}
	offset_x := -direction_y / length * thickness * 0.5
	offset_y := direction_x / length * thickness * 0.5
	base := c.int(len(painter.vertices))
	tint := sdl.FColor{color.r, color.g, color.b, color.a}
	uv := sdl.FPoint{painter.white_u, painter.white_v}
	append(&painter.vertices, sdl.Vertex{{from_x + offset_x, from_y + offset_y}, tint, uv})
	append(&painter.vertices, sdl.Vertex{{to_x + offset_x, to_y + offset_y}, tint, uv})
	append(&painter.vertices, sdl.Vertex{{to_x - offset_x, to_y - offset_y}, tint, uv})
	append(&painter.vertices, sdl.Vertex{{from_x - offset_x, from_y - offset_y}, tint, uv})
	append(&painter.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

push_text :: proc(painter: ^Painter, x, y: f32, text: string, color: [4]f32, bold := false) -> f32 {
	pen := x
	for codepoint in text {
		if codepoint == '\t' {
			pen += painter.cell_width * 4
			continue
		}
		push_glyph(painter, pen, y, codepoint, color, bold)
		pen += painter.cell_width * f32(rune_columns(codepoint))
	}
	return pen
}

push_shaped :: proc(painter: ^Painter, x, y: f32, index: int, color: [4]f32, bold := false) {
	glyph := painter_glyph(painter, 0, bold, index)
	if glyph.missing || glyph.width == 0 {
		return
	}
	push_quad(
		painter,
		x + glyph.offset_x,
		y + glyph.offset_y,
		glyph.width,
		glyph.height,
		glyph.u0,
		glyph.v0,
		glyph.u1,
		glyph.v1,
		color,
	)
}

painter_flush :: proc(painter: ^Painter) {
	if len(painter.indices) > 0 {
		sdl.RenderGeometry(
			painter.renderer,
			painter.texture,
			raw_data(painter.vertices),
			c.int(len(painter.vertices)),
			raw_data(painter.indices),
			c.int(len(painter.indices)),
		)
	}
	clear(&painter.vertices)
	clear(&painter.indices)
}

painter_set_clip :: proc(painter: ^Painter, rect: sdl.Rect) {
	painter_flush(painter)
	painter.clip = rect
	sdl.SetRenderClipRect(painter.renderer, &painter.clip)
}

painter_clear_clip :: proc(painter: ^Painter) {
	painter_flush(painter)
	sdl.SetRenderClipRect(painter.renderer, nil)
}

