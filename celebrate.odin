package vega

import "core:log"
import "core:math"
import "core:math/rand"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

baked_sprites := #load_directory("sprites")

CELEBRATION_LIFE :: 1.4
CELEBRATION_PARTICLES :: 220
CELEBRATION_POP :: 0.28

Particle :: struct {
	x:     f32,
	y:     f32,
	dx:    f32,
	dy:    f32,
	life:  f32,
	size:  f32,
	color: [4]f32,
}

Celebration :: struct {
	texture:   ^sdl.Texture,
	width:     int,
	height:    int,
	loaded:    bool,
	life:      f32,
	particles: [dynamic]Particle,
}

celebration: Celebration

celebration_sprite :: proc(name: string) -> []u8 {
	for entry in baked_sprites {
		if entry.name == name {
			return entry.data
		}
	}
	return nil
}

celebration_load :: proc(editor: ^Editor) {
	celebration.loaded = true
	data := celebration_sprite("todd.png")
	if len(data) == 0 {
		log.debug("no todd.png was baked in")
		return
	}
	width, height, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &width, &height, &channels, 4)
	if pixels == nil {
		log.warn("todd.png could not be decoded")
		return
	}
	defer stbi.image_free(pixels)
	surface := sdl.CreateSurfaceFrom(width, height, .ABGR8888, pixels, width * 4)
	if surface == nil {
		return
	}
	defer sdl.DestroySurface(surface)
	celebration.texture = sdl.CreateTextureFromSurface(editor.renderer, surface)
	sdl.SetTextureScaleMode(celebration.texture, .LINEAR)
	celebration.width = int(width)
	celebration.height = int(height)
	log.debugf("todd is %dx%d and ready", width, height)
}

celebration_start :: proc(editor: ^Editor) {
	if !celebration.loaded {
		celebration_load(editor)
	}
	celebration.life = CELEBRATION_LIFE
	clear(&celebration.particles)
	theme := editor.active_theme
	colors := [3][4]f32{theme[.Accent], theme[.String], theme[.Number]}
	middle_x := f32(editor.width) / 2
	middle_y := f32(editor.height) / 2
	for index in 0 ..< CELEBRATION_PARTICLES {
		angle := rand.float32() * math.TAU
		speed := 180 + rand.float32() * 620
		append(&celebration.particles, Particle {
			x     = middle_x,
			y     = middle_y,
			dx    = math.cos(angle) * speed,
			dy    = math.sin(angle) * speed,
			life  = 0.7 + rand.float32() * 1.3,
			size  = 2 + rand.float32() * 5,
			color = colors[index % len(colors)],
		})
	}
	log.info("it just works")
}

celebration_update :: proc(delta_time: f32) {
	if celebration.life <= 0 {
		return
	}
	celebration.life -= delta_time
	for &particle in celebration.particles {
		particle.life -= delta_time
		particle.x += particle.dx * delta_time
		particle.y += particle.dy * delta_time
		particle.dy += 900 * delta_time
		particle.dx *= 1 - 1.2 * delta_time
	}
}

draw_celebration :: proc(editor: ^Editor) {
	if celebration.life <= 0 {
		return
	}
	painter := &editor.painter
	theme := editor.active_theme
	fade := clamp(celebration.life / 0.4, 0, 1)
	grown := clamp((CELEBRATION_LIFE - celebration.life) / CELEBRATION_POP, 0, 1)
	zoom := 1 + 2.70158 * math.pow(grown - 1, 3) + 1.70158 * math.pow(grown - 1, 2)

	for particle in celebration.particles {
		if particle.life <= 0 {
			continue
		}
		alpha := clamp(particle.life, 0, 1) * fade
		push_rect(painter, particle.x, particle.y, particle.size, particle.size, particle.color * [4]f32{1, 1, 1, alpha})
	}

	title := "It just work !"
	cell := painter.cell_width * zoom
	line_height := line_height_of(editor) * zoom
	width := cell * f32(len(title))
	drawn_height := f32(editor.height) * 0.28 * zoom
	drawn_width := celebration.width > 0 ? drawn_height * f32(celebration.width) / f32(celebration.height) : 0
	middle_x := f32(editor.width) / 2
	middle_y := f32(editor.height) / 2

	if celebration.texture != nil {
		painter_flush(painter)
		sdl.SetTextureAlphaModFloat(celebration.texture, fade)
		destination := sdl.FRect{middle_x - drawn_width / 2, middle_y - drawn_height / 2, drawn_width, drawn_height}
		sdl.RenderTexture(editor.renderer, celebration.texture, nil, &destination)
	}
	title_y := middle_y + drawn_height / 2 + line_height * 0.5
	push_rect(painter, middle_x - width / 2 - cell, title_y - line_height * 0.2, width + cell * 2, line_height * 1.4, theme[.Overlay] * [4]f32{1, 1, 1, fade})
	push_text(painter, middle_x - width / 2, title_y, title, theme[.Accent] * [4]f32{1, 1, 1, fade}, true, zoom)
}
