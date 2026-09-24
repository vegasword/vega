package vega

import "core:fmt"
import "core:log"
import "core:strings"

OUTPUT_LINES :: 10

Output :: struct {
	open:    bool,
	title:   string,
	lines:   [dynamic]string,
	failed:  bool,
	scroll:  int,
}

output_show :: proc(editor: ^Editor, title, text: string, failed: bool) {
	output := &editor.output
	output_close(editor)
	output.open = true
	output.failed = failed
	output.scroll = 0
	output.title = strings.clone(title)
	remaining := strings.trim_right_space(text)
	for line in strings.split_lines_iterator(&remaining) {
		append(&output.lines, strings.clone(strings.trim_right_space(line)))
	}
	if len(output.lines) == 0 {
		append(&output.lines, strings.clone(failed ? "No output" : "Done"))
	}
	log.debugf("output popup for %s with %d line(s)", title, len(output.lines))
}

output_close :: proc(editor: ^Editor) {
	output := &editor.output
	for line in output.lines {
		delete(line)
	}
	clear(&output.lines)
	delete(output.title)
	output.title = ""
	output.open = false
}

output_scroll :: proc(editor: ^Editor, delta: int) {
	output := &editor.output
	output.scroll = clamp(output.scroll + delta, 0, max(0, len(output.lines) - OUTPUT_LINES))
	log.debugf("output scrolled to %d of %d", output.scroll, len(output.lines))
}

draw_output :: proc(editor: ^Editor, view: ^View, place: Glyph_Placement) {
	output := &editor.output
	if !output.open {
		return
	}
	painter := &editor.painter
	theme := editor.active_theme
	cell := painter.cell_width
	line_height := line_height_of(editor)
	rect := view.rect

	room := max(16, int(rect.width / cell) - 6)
	wrapped := make([dynamic]string, 0, OUTPUT_LINES * 2, context.temp_allocator)
	for index in output.scroll ..< len(output.lines) {
		for piece in wrap_text(output.lines[index], room, context.temp_allocator) {
			append(&wrapped, piece)
		}
		if len(wrapped) >= OUTPUT_LINES {
			break
		}
	}
	shown := min(len(wrapped), OUTPUT_LINES)
	widest := len(output.title) + 12
	for index in 0 ..< shown {
		widest = max(widest, len(wrapped[index]))
	}
	widest = min(widest, room)

	width := cell * f32(widest + 4)
	height := line_height * (f32(shown) + 2)
	x := clamp(place.found ? place.x : rect.x + cell * 2, rect.x + cell, max(rect.x + cell, rect.x + rect.width - width - cell))
	y := place.found ? place.y + line_height : rect.y + line_height
	if y + height > rect.y + rect.height {
		y = max(rect.y, (place.found ? place.y : rect.y + rect.height) - height)
	}

	accent := output.failed ? theme[.Directive] : theme[.String]
	push_rect(painter, x - 2, y - 2, width + 4, height + 4, accent)
	push_rect(painter, x, y, width, height, theme[.Overlay])
	painter_set_clip(painter, {i32(x), i32(y), i32(width), i32(height)})
	defer painter_clear_clip(painter)

	more := len(output.lines) > output.scroll + shown ? " ..." : ""
	header := len(output.lines) > OUTPUT_LINES ? fmt.tprintf("  %d of %d, ctrl-d and ctrl-u scroll, esc closes", output.scroll + 1, len(output.lines)) : "  esc closes"
	push_text(painter, x + cell, y + line_height * 0.25, output.title, accent)
	push_text(painter, x + cell + f32(len(output.title)) * cell, y + line_height * 0.25, header, theme[.Comment])
	for index in 0 ..< shown {
		push_text(painter, x + cell, y + line_height * (f32(index) + 1.15), wrapped[index], theme[.Text])
	}
	if more != "" {
		push_text(painter, x + width - cell * 5, y + height - line_height, more, theme[.Comment])
	}
}
