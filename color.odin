package vega

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

Color_Picker :: struct {
	open:        bool,
	target:      ^[4]f32,
	label:       string,
	hue:         f32,
	saturation:  f32,
	value:       f32,
	hex:         [dynamic]u8,
	square:      Rect,
	strip:       Rect,
	dragging:    enum {
		None,
		Square,
		Strip,
	},
}

rgb_to_hsv :: proc(color: [4]f32) -> (hue, saturation, value: f32) {
	high := max(color.r, max(color.g, color.b))
	low := min(color.r, min(color.g, color.b))
	span := high - low
	value = high
	saturation = high > 0 ? span / high : 0
	if span <= 0 {
		return 0, saturation, value
	}
	switch high {
	case color.r:
		hue = 60 * (((color.g - color.b) / span) + (color.g < color.b ? 6 : 0))
	case color.g:
		hue = 60 * (((color.b - color.r) / span) + 2)
	case:
		hue = 60 * (((color.r - color.g) / span) + 4)
	}
	return hue, saturation, value
}

hsv_to_rgb :: proc(hue, saturation, value: f32) -> [4]f32 {
	sector := math.mod(math.mod(hue, 360) + 360, 360) / 60
	chroma := value * saturation
	second := chroma * (1 - abs(math.mod(sector, 2) - 1))
	offset := value - chroma
	switch int(sector) {
	case 0:
		return {chroma + offset, second + offset, offset, 1}
	case 1:
		return {second + offset, chroma + offset, offset, 1}
	case 2:
		return {offset, chroma + offset, second + offset, 1}
	case 3:
		return {offset, second + offset, chroma + offset, 1}
	case 4:
		return {second + offset, offset, chroma + offset, 1}
	}
	return {chroma + offset, offset, second + offset, 1}
}

color_picker_open :: proc(editor: ^Editor, target: ^[4]f32, label: string) {
	picker := &editor.color_picker
	picker.open = true
	picker.target = target
	delete(picker.label)
	picker.label = strings.clone(label)
	picker.hue, picker.saturation, picker.value = rgb_to_hsv(target^)
	clear(&picker.hex)
	append(&picker.hex, color_to_hex(target^, context.temp_allocator))
	log.infof("color picker opened for %s at %s", label, string(picker.hex[:]))
}

color_picker_apply :: proc(editor: ^Editor) {
	picker := &editor.color_picker
	picker.target^ = hsv_to_rgb(picker.hue, picker.saturation, picker.value)
	clear(&picker.hex)
	append(&picker.hex, color_to_hex(picker.target^, context.temp_allocator))
	editor.flags += {.ConfigDirty}
}

color_picker_text :: proc(editor: ^Editor, text: string) {
	picker := &editor.color_picker
	character := text[0]
	if character == '#' && len(picker.hex) > 0 {
		clear(&picker.hex)
	}
	is_digit := (character >= '0' && character <= '9') || (to_lower_byte(character) >= 'a' && to_lower_byte(character) <= 'f')
	if !is_digit && character != '#' {
		return
	}
	if len(picker.hex) == 0 {
		append(&picker.hex, '#')
	}
	if character != '#' && len(picker.hex) < 7 {
		append(&picker.hex, character)
	}
	if len(picker.hex) == 7 {
		if color, valid := color_from_hex(string(picker.hex[:])); valid {
			picker.target^ = color
			picker.hue, picker.saturation, picker.value = rgb_to_hsv(color)
			editor.flags += {.ConfigDirty}
		}
	}
}

color_picker_key :: proc(editor: ^Editor, key: sdl.Keycode, shift: bool) {
	picker := &editor.color_picker
	step: f32 = shift ? 0.1 : 0.02
	switch key {
	case sdl.K_ESCAPE, sdl.K_RETURN:
		picker.open = false
		log.infof("color picker closed on %s", string(picker.hex[:]))
	case sdl.K_BACKSPACE:
		if len(picker.hex) > 0 {
			resize(&picker.hex, len(picker.hex) - 1)
		}
	case sdl.K_LEFT:
		picker.hue = math.mod(picker.hue - (shift ? 20 : 4) + 360, 360)
		color_picker_apply(editor)
	case sdl.K_RIGHT:
		picker.hue = math.mod(picker.hue + (shift ? 20 : 4), 360)
		color_picker_apply(editor)
	case sdl.K_UP:
		picker.value = clamp(picker.value + step, 0, 1)
		color_picker_apply(editor)
	case sdl.K_DOWN:
		picker.value = clamp(picker.value - step, 0, 1)
		color_picker_apply(editor)
	case sdl.K_TAB:
		picker.saturation = clamp(picker.saturation + (shift ? -step : step), 0, 1)
		color_picker_apply(editor)
	}
}

color_picker_mouse :: proc(editor: ^Editor, x, y: f32, pressed, released: bool) {
	picker := &editor.color_picker
	inside :: proc(rect: Rect, x, y: f32) -> bool {
		return x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height
	}
	if released {
		picker.dragging = .None
		return
	}
	if pressed {
		if inside(picker.square, x, y) {
			picker.dragging = .Square
		} else if inside(picker.strip, x, y) {
			picker.dragging = .Strip
		}
	}
	switch picker.dragging {
	case .Square:
		picker.saturation = clamp((x - picker.square.x) / picker.square.width, 0, 1)
		picker.value = 1 - clamp((y - picker.square.y) / picker.square.height, 0, 1)
		color_picker_apply(editor)
	case .Strip:
		picker.hue = clamp((y - picker.strip.y) / picker.strip.height, 0, 1) * 360
		color_picker_apply(editor)
	case .None:
	}
}

draw_color_picker :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	picker := &editor.color_picker
	cell := painter.cell_width
	line_height := painter.line_height

	width := cell * 40
	height := line_height * 16
	x := (f32(editor.width) - width) / 2
	y := (f32(editor.height) - height) / 2
	push_rect(painter, x - 2, y - 2, width + 4, height + 4, theme[.Accent])
	push_rect(painter, x, y, width, height, theme[.Overlay])
	push_text(painter, x + cell, y + line_height * 0.4, picker.label, theme[.Accent])

	picker.square = {x + cell, y + line_height * 2, width - cell * 8, height - line_height * 5}
	picker.strip = {x + width - cell * 6, y + line_height * 2, cell * 4, height - line_height * 5}

	steps := 24
	for column in 0 ..< steps {
		for row in 0 ..< steps {
			saturation := f32(column) / f32(steps - 1)
			value := 1 - f32(row) / f32(steps - 1)
			push_rect(
				painter,
				picker.square.x + picker.square.width * f32(column) / f32(steps),
				picker.square.y + picker.square.height * f32(row) / f32(steps),
				picker.square.width / f32(steps) + 1,
				picker.square.height / f32(steps) + 1,
				hsv_to_rgb(picker.hue, saturation, value),
			)
		}
	}
	for row in 0 ..< 48 {
		push_rect(
			painter,
			picker.strip.x,
			picker.strip.y + picker.strip.height * f32(row) / 48,
			picker.strip.width,
			picker.strip.height / 48 + 1,
			hsv_to_rgb(f32(row) / 48 * 360, 1, 1),
		)
	}

	marker_x := picker.square.x + picker.square.width * picker.saturation
	marker_y := picker.square.y + picker.square.height * (1 - picker.value)
	push_rect(painter, marker_x - 5, marker_y - 1, 10, 2, theme[.Text])
	push_rect(painter, marker_x - 1, marker_y - 5, 2, 10, theme[.Text])
	hue_y := picker.strip.y + picker.strip.height * picker.hue / 360
	push_rect(painter, picker.strip.x - 3, hue_y - 1, picker.strip.width + 6, 3, theme[.Text])

	swatch_y := y + height - line_height * 2.4
	push_rect(painter, x + cell, swatch_y, cell * 8, line_height * 1.4, picker.target^)
	push_text(painter, x + cell * 10, swatch_y + line_height * 0.2, fmt.tprintf("%-8s type hex, drag the square, arrows and tab adjust, enter closes", string(picker.hex[:])), theme[.StatusText])
}
