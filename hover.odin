package vega

import "core:fmt"
import "core:log"
import "core:strings"

Hover :: struct {
	open:       bool,
	view:       int,
	name:       string,
	lines:      [dynamic]string,
	references: [dynamic]int,
}

hover_close :: proc(editor: ^Editor) {
	hover := &editor.hover
	if !hover.open {
		return
	}
	for line in hover.lines {
		delete(line)
	}
	clear(&hover.lines)
	clear(&hover.references)
	delete(hover.name)
	hover.name = ""
	hover.open = false
}

documentation_above :: proc(text: []u8, offset: int) -> []string {
	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	cursor := offset
	for cursor > 0 && text[cursor - 1] != '\n' {
		cursor -= 1
	}
	for cursor > 1 {
		end := cursor - 1
		start := end
		for start > 0 && text[start - 1] != '\n' {
			start -= 1
		}
		candidate := strings.trim_space(string(text[start:end]))
		if !strings.has_prefix(candidate, "//") && !strings.has_prefix(candidate, "#") && !strings.has_prefix(candidate, "*") {
			break
		}
		inject_at(&lines, 0, strings.trim_space(strings.trim_left(candidate, "/#* \t")))
		cursor = start
		if len(lines) >= 8 {
			break
		}
	}
	return lines[:]
}

hover_open :: proc(editor: ^Editor) {
	hover_close(editor)
	hover := &editor.hover
	buffer := editor_buffer(editor)
	word, _ := word_at(buffer.text[:], buffer_primary(buffer).head)
	if word == "" {
		editor_status(editor, "Place the cursor on an identifier")
		return
	}

	hover.name = strings.clone(word)
	hover.view = editor.active_view
	definitions := index_definitions(&editor.index, word)
	if len(definitions) > 0 {
		symbol := editor.index.symbols[definitions[0]]
		file := editor.index.files[symbol.file]
		for line in documentation_above(file.text, symbol.offset) {
			append(&hover.lines, strings.clone(line))
		}
		append(&hover.lines, strings.clone(symbol.signature))
		line := 1 + count_byte(file.text, symbol.offset, '\n')
		append(&hover.lines, strings.clone(fmt.tprintf("%v  %s:%d", symbol.kind, project_relative(editor, file.path), line)))
	} else {
		append(&hover.lines, strings.clone(fmt.tprintf("%s is not indexed as a definition", word)))
	}

	text := string(buffer.text[:])
	cursor := 0
	for len(hover.references) < 64 {
		hit := strings.index(text[cursor:], word)
		if hit < 0 {
			break
		}
		offset := cursor + hit
		cursor = offset + len(word)
		before_ok := offset == 0 || !is_word_byte(buffer.text[offset - 1])
		after_ok := cursor >= len(buffer.text) || !is_word_byte(buffer.text[cursor])
		if before_ok && after_ok {
			append(&hover.references, offset)
		}
	}
	append(&hover.lines, strings.clone(fmt.tprintf("%d reference(s) in this buffer", len(hover.references))))
	hover.open = true
	log.infof("hover on %s with %d references", word, len(hover.references))
}

screen_position :: proc(editor: ^Editor, view: ^View, buffer: ^Buffer, offset: int) -> (x, y: f32, visible: bool) {
	rect := content_rect(editor, view)
	line := buffer_line_of(buffer, offset)
	first := int(view.scroll_visual)
	if line < first {
		return 0, 0, false
	}
	rows := 0
	for scan in first ..< line {
		rows += line_rows(editor, view, buffer, scan)
	}
	if rows > view_visible_lines(editor, view) {
		return 0, 0, false
	}
	start, _ := buffer_line_bounds(buffer, line)
	column := visual_column(buffer, start, offset, editor.config.indent_width)
	columns := view_text_columns(editor, view)
	segment := (.SoftWrap in editor.config.options) ? column / columns : 0
	screen_column := (.SoftWrap in editor.config.options) ? column % columns : column - view.scroll_x
	if screen_column < 0 {
		return 0, 0, false
	}
	line_height := line_height_of(editor)
	x = rect.x + f32(view_gutter_columns(editor, view) + screen_column) * editor.painter.cell_width
	y = rect.y + (f32(rows + segment) - (view.scroll_visual - f32(first))) * line_height
	return x, y, true
}

draw_hover :: proc(editor: ^Editor, view: ^View, buffer: ^Buffer, place: Glyph_Placement) {
	painter := &editor.painter
	theme := editor.active_theme
	hover := &editor.hover
	cell := painter.cell_width
	line_height := painter.line_height
	rect := content_rect(editor, view)

	widest := 0
	for line in hover.lines {
		widest = max(widest, len(line))
	}
	width := min(f32(widest + 3) * cell, rect.width - cell * 2)
	height := line_height * f32(len(hover.lines)) + line_height
	x := clamp(place.x - cell, rect.x + cell, rect.x + rect.width - width - cell)
	y := place.y + line_height_of(editor) + 4
	if y + height > rect.y + rect.height {
		y = max(rect.y, place.y - height - 4)
	}

	for offset in hover.references {
		reference_x, reference_y, visible := screen_position(editor, view, buffer, offset)
		if !visible {
			continue
		}
		target_x := reference_x + cell * f32(len(hover.name)) * 0.5
		target_y := reference_y + line_height_of(editor) * 0.5
		inside := target_x > x && target_x < x + width && target_y > y && target_y < y + height
		if inside {
			continue
		}
		anchor_y := clamp(target_y, y, y + height)
		anchor_x := target_x < x ? x : x + width
		push_line(painter, anchor_x, anchor_y, target_x, target_y, 1.5, theme[.Accent] * [4]f32{1, 1, 1, 0.35})
		push_rect(painter, reference_x, reference_y, cell * f32(len(hover.name)), line_height_of(editor), theme[.Match] * [4]f32{1, 1, 1, 0.45})
	}

	push_rect(painter, x - 2, y - 2, width + 4, height + 4, theme[.Accent] * [4]f32{1, 1, 1, 0.9})
	push_rect(painter, x, y, width, height, theme[.Overlay])
	for line, index in hover.lines {
		color := theme[.Comment]
		if index == len(hover.lines) - 3 {
			color = theme[.Text]
		}
		if index >= len(hover.lines) - 2 {
			color = theme[.Gutter]
		}
		room := int(width / cell) - 2
		push_text(painter, x + cell, y + line_height * (f32(index) + 0.5), line[:min(room, len(line))], color)
	}
}
