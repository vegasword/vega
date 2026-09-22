package vega

import "core:log"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

logo_png := #load("icons/logo.png")

Logo :: struct {
	texture: ^sdl.Texture,
	width:   int,
	height:  int,
}

logo_load :: proc(editor: ^Editor) {
	width, height, channels: i32
	pixels := stbi.load_from_memory(raw_data(logo_png), i32(len(logo_png)), &width, &height, &channels, 4)
	if pixels == nil {
		log.error("the logo could not be decoded")
		return
	}
	defer stbi.image_free(pixels)

	surface := sdl.CreateSurfaceFrom(width, height, .ABGR8888, pixels, width * 4)
	if surface == nil {
		log.errorf("the logo could not be wrapped: %s", sdl.GetError())
		return
	}
	defer sdl.DestroySurface(surface)

	editor.logo.texture = sdl.CreateTextureFromSurface(editor.renderer, surface)
	sdl.SetTextureScaleMode(editor.logo.texture, .LINEAR)
	editor.logo.width = int(width)
	editor.logo.height = int(height)

	side := i32(f32(max(width, height)) * 1.04)
	square := make([]u32, int(side * side))
	defer delete(square)
	left := (side - width) / 2
	top := (side - height) / 2
	source := ([^]u32)(pixels)
	for row in 0 ..< height {
		for column in 0 ..< width {
			square[(top + row) * side + left + column] = source[row * width + column]
		}
	}
	icon := sdl.CreateSurfaceFrom(side, side, .ABGR8888, raw_data(square), side * 4)
	if icon == nil {
		log.errorf("the window icon could not be built: %s", sdl.GetError())
		return
	}
	defer sdl.DestroySurface(icon)
	_ = sdl.SetWindowIcon(editor.window, icon)
	log.infof("logo loaded, %dx%d, window icon padded to %dx%d", width, height, side, side)
}

draw_logo :: proc(editor: ^Editor, height: f32) -> f32 {
	margin := editor.painter.cell_width
	if editor.logo.texture == nil {
		return margin
	}
	drawn_height := height * 0.46
	drawn_width := drawn_height * f32(editor.logo.width) / f32(editor.logo.height)
	destination := sdl.FRect{margin, (height - drawn_height) / 2, drawn_width, drawn_height}
	tint := editor.active_theme[.Accent]
	painter_flush(&editor.painter)
	sdl.SetTextureColorModFloat(editor.logo.texture, tint.r, tint.g, tint.b)
	sdl.RenderTexture(editor.renderer, editor.logo.texture, nil, &destination)
	return destination.x + drawn_width + margin
}
