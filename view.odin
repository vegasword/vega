package vega

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

Secondary_Cursor :: struct {
	x:      f32,
	y:      f32,
	offset: int,
}

Rect :: struct {
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}

View :: struct {
	buffer:        int,
	scroll_line:   int,
	scroll_x:      int,
	scroll_visual: f32,
	rect:          Rect,
	cursor_x:      f32,
	cursor_y:      f32,
	cursor_ready:  bool,
	cursor_target: [2]f32,
	image_zoom:    f32,
	last_buffer:   ^Buffer,
	last_rect:     Rect,
	secondary:     [dynamic]Secondary_Cursor,
}

editor_view :: proc(editor: ^Editor) -> ^View {
	editor.active_view = clamp(editor.active_view, 0, len(editor.views) - 1)
	return &editor.views[editor.active_view]
}

line_height_of :: proc(editor: ^Editor) -> f32 {
	return editor.painter.line_height * editor.config.line_spacing
}

status_height_of :: proc(editor: ^Editor) -> f32 {
	return line_height_of(editor)
}

top_bar_height_of :: proc(editor: ^Editor) -> f32 {
	return line_height_of(editor)
}

view_visible_lines :: proc(editor: ^Editor, view: ^View) -> int {
	rect := content_rect(editor, view)
	height := rect.height > 0 ? rect.height : f32(editor.height) - status_height_of(editor) - top_bar_height_of(editor)
	if view.rect.height > 0 {
		height = min(height, view.rect.height - math.max(0, rect.y - view.rect.y))
	}
	return max(1, int(height / line_height_of(editor)))
}

view_gutter_columns :: proc(editor: ^Editor, view: ^View) -> int {
	if !(.LineNumbers in editor.config.options) {
		return 2
	}
	digits := 1
	for count := buffer_line_count(editor.buffers[clamp(view.buffer, 0, len(editor.buffers) - 1)]); count >= 10; count /= 10 {
		digits += 1
	}
	return max(5, digits + 3)
}

view_text_columns :: proc(editor: ^Editor, view: ^View) -> int {
	rect := content_rect(editor, view)
	width := rect.width > 0 ? rect.width : f32(editor.width) - settings_panel_width(editor)
	return max(8, int(width / editor.painter.cell_width) - view_gutter_columns(editor, view))
}

line_visual_width :: proc(buffer: ^Buffer, line, tab_width: int) -> int {
	start, end := buffer_line_bounds(buffer, line)
	return visual_column(buffer, start, end, tab_width)
}

line_indent_columns :: proc(editor: ^Editor, view: ^View, buffer: ^Buffer, line: int) -> int {
	start, end := buffer_line_bounds(buffer, line)
	indent := 0
	for offset := start; offset < end; offset += 1 {
		character := buffer.text[offset]
		if character == ' ' {
			indent += 1
		} else if character == '\t' {
			indent += editor.config.indent_width - indent % editor.config.indent_width
		} else {
			break
		}
	}
	return min(indent, view_text_columns(editor, view) / 3)
}

wrap_place :: proc(column, columns, indent: int) -> (segment, screen_column: int) {
	if column < columns {
		return 0, column
	}
	room := max(1, columns - indent)
	rest := column - columns
	return 1 + rest / room, indent + rest % room
}

wrap_column :: proc(segment, within, columns, indent: int) -> int {
	if segment <= 0 {
		return within
	}
	room := max(1, columns - indent)
	return columns + (segment - 1) * room + clamp(within - indent, 0, room)
}

line_rows :: proc(editor: ^Editor, view: ^View, buffer: ^Buffer, line: int) -> int {
	if !(.SoftWrap in editor.config.options) {
		return 1
	}
	columns := view_text_columns(editor, view)
	width := line_visual_width(buffer, line, editor.config.indent_width)
	segment, _ := wrap_place(max(0, width - 1), columns, line_indent_columns(editor, view, buffer, line))
	return segment + 1
}

editor_ensure_visible :: proc(editor: ^Editor) {
	view := editor_view(editor)
	buffer := editor_buffer(editor)
	if view.last_buffer != buffer {
		view.last_buffer = buffer
		view.scroll_line = clamp(buffer.scroll, 0, max(0, buffer_line_count(buffer) - 1))
		view.scroll_visual = f32(view.scroll_line)
		view.cursor_ready = false
	}
	line := buffer_line_of(buffer, buffer_primary(buffer).head)
	rows := view_visible_lines(editor, view)
	margin := min(editor.config.scroll_off, rows / 3)

	view.scroll_line = min(view.scroll_line, max(0, line - margin))
	for {
		used := 0
		for scan in view.scroll_line ..= line {
			used += line_rows(editor, view, buffer, scan)
		}
		if used + margin <= rows || view.scroll_line >= line {
			break
		}
		view.scroll_line += 1
	}
	view.scroll_line = clamp(view.scroll_line, 0, max(0, buffer_line_count(buffer) - 1))
	buffer.scroll = view.scroll_line

	if (.SoftWrap in editor.config.options) {
		view.scroll_x = 0
		return
	}
	start, _ := buffer_line_bounds(buffer, line)
	column := visual_column(buffer, start, buffer_primary(buffer).head, editor.config.indent_width)
	columns := view_text_columns(editor, view)
	view.scroll_x = max(0, clamp(view.scroll_x, column - columns + 1, column))
}

editor_center_view :: proc(editor: ^Editor) {
	view := editor_view(editor)
	buffer := editor_buffer(editor)
	line := buffer_line_of(buffer, buffer_primary(buffer).head)
	view.scroll_line = max(0, line - view_visible_lines(editor, view) / 2)
	editor_ensure_visible(editor)
}

visual_column :: proc(buffer: ^Buffer, line_start, offset, tab_width: int) -> int {
	column := 0
	limit := clamp(offset, line_start, len(buffer.text))
	for index := line_start; index < limit; index += max(1, rune_size_at(buffer.text[:], index)) {
		character := buffer.text[index]
		if character == '\r' {
			continue
		}
		if character == '\t' {
			column += tab_width - column % tab_width
			continue
		}
		column += rune_columns(rune_at(buffer.text[:], index))
	}
	return column
}

offset_at_column :: proc(buffer: ^Buffer, line, target_column, tab_width: int) -> int {
	start, end := buffer_line_bounds(buffer, line)
	column := 0
	for offset := start; offset < end; offset += max(1, rune_size_at(buffer.text[:], offset)) {
		if column >= target_column {
			return offset
		}
		character := buffer.text[offset]
		if character == '\r' {
			continue
		}
		column += character == '\t' ? tab_width - column % tab_width : rune_columns(rune_at(buffer.text[:], offset))
	}
	return end
}

move_visual_vertical :: proc(editor: ^Editor, delta: int, extend: bool) {
	buffer := editor_buffer(editor)
	view := editor_view(editor)
	if !(.SoftWrap in editor.config.options) {
		move_vertical(buffer, delta, extend)
		return
	}
	columns := view_text_columns(editor, view)
	tab_width := editor.config.indent_width

	for &selection in buffer.selections {
		line := buffer_line_of(buffer, selection.head)
		start, _ := buffer_line_bounds(buffer, line)
		column := visual_column(buffer, start, selection.head, tab_width)
		segment, within := wrap_place(column, columns, line_indent_columns(editor, view, buffer, line))
		steps := abs(delta)
		direction := delta > 0 ? 1 : -1

		for _ in 0 ..< steps {
			segment += direction
			if segment < 0 {
				if line == 0 {
					segment = 0
					break
				}
				line -= 1
				segment = line_rows(editor, view, buffer, line) - 1
			} else if segment >= line_rows(editor, view, buffer, line) {
				if line >= buffer_line_count(buffer) - 1 {
					segment = line_rows(editor, view, buffer, line) - 1
					break
				}
				line += 1
				segment = 0
			}
		}
		target := wrap_column(segment, within, columns, line_indent_columns(editor, view, buffer, line))
		selection.head = offset_at_column(buffer, line, target, tab_width)
		log.debugf("visual move: columns %d line %d segment %d within %d head %d", columns, line, segment, within, selection.head)
		if !extend {
			selection.anchor = selection.head
		}
	}
	buffer_merge_selections(buffer)
}

token_at_offset :: proc(buffer: ^Buffer, offset: int) -> int {
	low, high := 0, len(buffer.tokens)
	for low < high {
		middle := (low + high) / 2
		if int(buffer.tokens[middle].end) <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

approach :: proc(current, target, speed, delta_time: f32) -> f32 {
	return current + (target - current) * (1 - math.exp(-speed * delta_time))
}

selection_covers :: proc(buffer: ^Buffer, offset: int) -> bool {
	for selection in buffer.selections {
		if offset >= range_low(selection) && offset < range_high(buffer, selection) {
			return true
		}
	}
	return false
}

draw_editor :: proc(editor: ^Editor, delta_time: f32) {
	theme_apply_options(editor)
	painter := &editor.painter
	theme := editor.active_theme
	push_rect(painter, 0, 0, f32(editor.width), f32(editor.height), theme[.Background])

	editor_layout(editor)
	for &view, index in editor.views {
		if view.rect.width <= 0 || view.rect.height <= 0 {
			continue
		}
		draw_view(editor, &view, index == editor.active_view, delta_time)
	}

	draw_top_bar(editor)
	draw_status_bar(editor)
}

Glyph_Placement :: struct {
	x:     f32,
	y:     f32,
	found: bool,
}

draw_view :: proc(editor: ^Editor, view: ^View, active: bool, delta_time: f32) {
	painter := &editor.painter
	theme := editor.active_theme
	view.buffer = clamp(view.buffer, 0, len(editor.buffers) - 1)
	buffer := editor.buffers[view.buffer]

	if view.image_zoom == 0 {
		view.image_zoom = 1
	}
	if buffer.kind == .Image {
		draw_image_view(editor, view, buffer, active)
		return
	}

	if view.last_buffer != buffer {
		if active && view.last_buffer != nil && view.last_buffer.path != "" {
			delete(editor.previous_path)
			editor.previous_path = strings.clone(view.last_buffer.path)
		}
		view.last_buffer = buffer
		view.scroll_line = clamp(buffer.scroll, 0, max(0, buffer_line_count(buffer) - 1))
		view.scroll_visual = f32(view.scroll_line)
		view.cursor_ready = false
		log.debugf("view moved to %s at line %d", filename_of(buffer.display), view.scroll_line + 1)
	}
	buffer.scroll = view.scroll_line
	if (.DiffGutter in editor.config.options) {
		buffer_refresh_hunks(buffer)
	}
	pane := view.rect
	rect := content_rect(editor, view)
	if (.Centered in editor.config.options) && rect != view.last_rect {
		view.last_rect = rect
		log.debugf("square %.0f x %.0f at %.0f,%.0f inside a %.0f x %.0f pane", rect.width, rect.height, rect.x, rect.y, pane.width, pane.height)
	}
	cell := painter.cell_width
	line_height := line_height_of(editor)
	gutter_columns := view_gutter_columns(editor, view)
	gutter := rect.x + f32(gutter_columns) * cell
	tab_width := editor.config.indent_width
	columns := view_text_columns(editor, view)
	visible := view_visible_lines(editor, view)
	cursor_line := buffer_line_of(buffer, buffer_primary(buffer).head)
	dim: f32 = 1

	view.scroll_visual = (.SmoothScroll in editor.config.options) ? approach(view.scroll_visual, f32(view.scroll_line), editor.config.scroll_speed, delta_time) : f32(view.scroll_line)
	if abs(view.scroll_visual - f32(view.scroll_line)) < 0.03 {
		view.scroll_visual = f32(view.scroll_line)
	}
	first := int(math.floor(view.scroll_visual))
	offset_y := (view.scroll_visual - f32(first)) * line_height

	if len(editor.views) > 1 {
		edge := active ? f32(2) : f32(1)
		color := active ? theme[.Accent] : theme[.Gutter]
		push_rect(painter, pane.x, pane.y, pane.width, edge, color)
		push_rect(painter, pane.x, pane.y + pane.height - edge, pane.width, edge, color)
		push_rect(painter, pane.x, pane.y, edge, pane.height, color)
		push_rect(painter, pane.x + pane.width - edge, pane.y, edge, pane.height, color)
	}
	painter_set_clip(painter, {i32(pane.x), i32(pane.y), i32(pane.width), i32(pane.height)})

	cursor_place := Glyph_Placement{}
	clear(&view.secondary)
	heads := make(map[int]bool, len(buffer.selections), context.temp_allocator)
	if len(buffer.selections) > 1 {
		for selection, index in buffer.selections {
			if index != buffer.primary {
				heads[selection.head] = true
			}
		}
	}
	in_code_block := false
	row := 0
	for line := first; line <= buffer_line_count(buffer) - 1 && row <= visible; line += 1 {
		start, end := buffer_line_bounds(buffer, line)
		markdown := buffer.kind == .Markdown ? draw_markdown_line(editor, buffer, line, &in_code_block) : [4]f32{}
		token_index := token_at_offset(buffer, start)
		line_top := rect.y + f32(row) * line_height - offset_y

		if (.CursorLine in editor.config.options) && line == cursor_line && active {
			push_rect(painter, gutter, line_top, rect.x + rect.width - gutter, line_height, theme[.CursorLine])
		}
		if (.LineNumbers in editor.config.options) {
			number := line + 1
			if (.RelativeNumbers in editor.config.options) && line != cursor_line {
				number = abs(line - cursor_line)
			}
			label := fmt.tprintf("%d", number)
			color := (line == cursor_line ? theme[.GutterActive] : theme[.Gutter]) * [4]f32{1, 1, 1, dim}
			push_text(painter, gutter - cell * f32(len(label) + 2), line_top, label, color)
		}
		if (.DiffGutter in editor.config.options) {
			if change := hunk_kind_of_line(buffer, line); change != .Unchanged {
				color := change == .Added ? theme[.String] : (change == .Deleted ? theme[.Directive] : theme[.Number])
				push_rect(painter, rect.x + cell * 0.4, line_top + 1, cell * 0.35, line_height - 2, color * [4]f32{1, 1, 1, dim})
			}
		}
		if len(editor.diagnostics) > 0 {
			draw_diagnostic_mark(editor, buffer, line, gutter, line_top, tab_width, view.scroll_x)
		}

		column := 0
		coloured_token := -1
		token_color := theme[.Text]
		token_bold := false
		indent := (.SoftWrap in editor.config.options) ? line_indent_columns(editor, view, buffer, line) : 0
		drawn_segment := 0
		run_start, run_end := 0, 0
		run_glyphs: []int
		for offset := start; offset < end; offset += max(1, rune_size_at(buffer.text[:], offset)) {
			codepoint, _ := utf8.decode_rune(buffer.text[offset:end])
			character := buffer.text[offset]
			width := character == '\r' ? 0 : (character == '\t' ? tab_width - column % tab_width : rune_columns(codepoint))
			segment, screen_column := 0, column - view.scroll_x
			if (.SoftWrap in editor.config.options) {
				segment, screen_column = wrap_place(column, columns, indent)
			}
			column += width

			y := line_top + f32(segment) * line_height
			if screen_column < 0 || row + segment > visible {
				continue
			}
			x := gutter + f32(screen_column) * cell

			if segment > drawn_segment {
				drawn_segment = segment
				if indent > 0 {
					push_glyph(painter, gutter + f32(indent - 1) * cell, y, '↪', theme[.Gutter] * [4]f32{1, 1, 1, dim * 0.5})
				}
			}

			if offset == buffer_primary(buffer).head {
				cursor_place = {x, y, true}
			} else if heads[offset] {
				append(&view.secondary, Secondary_Cursor{x, y, offset})
			}
			if character == '\r' {
				continue
			}
			if active && selection_covers(buffer, offset) {
				push_rect(painter, x, y, cell * f32(width), line_height, theme[.Selection])
			}

			if character == ' ' || character == '\t' {
				if (.RenderWhitespace in editor.config.options) {
					faint := theme[.Gutter] * [4]f32{1, 1, 1, dim * 0.35}
					middle := y + line_height * 0.5
					if character == ' ' {
						push_rect(painter, x + cell * 0.45, middle - 1, 2, 2, faint)
					} else {
						span := cell * f32(width)
						push_line(painter, x + cell * 0.25, middle, x + span - cell * 0.3, middle, 1, faint)
						push_line(painter, x + span - cell * 0.55, middle - cell * 0.22, x + span - cell * 0.3, middle, 1, faint)
						push_line(painter, x + span - cell * 0.55, middle + cell * 0.22, x + span - cell * 0.3, middle, 1, faint)
					}
				}
				continue
			}

			color := markdown
			bold := false
			if buffer.kind != .Markdown {
				for token_index < len(buffer.tokens) && int(buffer.tokens[token_index].end) <= offset {
					token_index += 1
				}
				color = theme[.Text]
				if token_index < len(buffer.tokens) && int(buffer.tokens[token_index].start) <= offset {
					token := buffer.tokens[token_index]
					if token_index != coloured_token {
						coloured_token = token_index
						token_color = theme[token_color_slot(token.kind)]
						token_bold = token.kind == .Function
						if token.kind == .Identifier && index_is_type(&editor.index, token_text(buffer.text[:], token)) {
							token_color = theme[.Type]
						}
					}
					color = token_color
					bold = token_bold
				}
			}

			if (.Ligatures in editor.config.options) && ligature_candidate(painter, character) {
				if offset >= run_end {
					run_end = offset
					for run_end < end && ligature_candidate(painter, buffer.text[run_end]) {
						run_end += 1
					}
					run_start = max(start, offset - LIGATURE_CONTEXT)
					window_end := min(end, run_end + LIGATURE_CONTEXT)
					run_glyphs = shaper_shape(painter, string(buffer.text[run_start:window_end]))
				}
				push_shaped(painter, x, y, run_glyphs[offset - run_start], color * [4]f32{1, 1, 1, dim}, bold)
				continue
			}
			push_glyph(painter, x, y, codepoint, color * [4]f32{1, 1, 1, dim}, bold)
		}

		if buffer_primary(buffer).head == end || heads[end] {
			segment, screen_column := 0, column - view.scroll_x
			if (.SoftWrap in editor.config.options) {
				segment, screen_column = wrap_place(column, columns, indent)
			}
			place := [2]f32{gutter + f32(max(0, screen_column)) * cell, line_top + f32(segment) * line_height}
			if buffer_primary(buffer).head == end {
				cursor_place = {place.x, place.y, true}
			} else {
				append(&view.secondary, Secondary_Cursor{place.x, place.y, end})
			}
		}
		row += line_rows(editor, view, buffer, line)
	}

	if active {
		draw_cursors(editor, view, buffer, cursor_place, delta_time)
		if editor.hover.open && editor.hover.view == editor.active_view {
			draw_hover(editor, view, buffer, cursor_place)
		}
		draw_output(editor, view, cursor_place)
	}
	painter_clear_clip(painter)
}

draw_cursors :: proc(editor: ^Editor, view: ^View, buffer: ^Buffer, place: Glyph_Placement, delta_time: f32) {
	painter := &editor.painter
	theme := editor.active_theme
	cell := painter.cell_width
	line_height := line_height_of(editor)
	shape := editor.mode == .Insert ? editor.config.insert_cursor : (editor.mode == .Select ? editor.config.select_cursor : editor.config.normal_cursor)

	if !place.found {
		return
	}
	target_x, target_y := place.x, place.y
	color := theme[.Cursor]

	if !view.cursor_ready || !(.CursorAnimation in editor.config.options) {
		view.cursor_x, view.cursor_y = target_x, target_y
		view.cursor_ready = true
	} else {
		view.cursor_x = approach(view.cursor_x, target_x, editor.config.cursor_speed, delta_time)
		view.cursor_y = approach(view.cursor_y, target_y, editor.config.cursor_speed, delta_time)
	}
	view.cursor_target = {target_x, target_y}
	target_x, target_y = view.cursor_x, view.cursor_y

	head := buffer_primary(buffer).head
	switch shape {
	case .Block:
		push_rect(painter, target_x, target_y, cell, line_height, color)
		if head < len(buffer.text) && buffer.text[head] != '\n' && buffer.text[head] != '\t' {
			push_glyph(painter, target_x, target_y, rune_at(buffer.text[:], head), theme[.Background])
		}
	case .Bar:
		push_rect(painter, target_x, target_y, max(2, cell * 0.16), line_height, color)
	case .Underline:
		push_rect(painter, target_x, target_y + line_height - 3, cell, 3, color)
	}

	for place in view.secondary {
		switch shape {
		case .Block:
			push_rect(painter, place.x, place.y, cell, line_height, color * [4]f32{1, 1, 1, 0.8})
			if place.offset < len(buffer.text) && buffer.text[place.offset] != '\n' && buffer.text[place.offset] != '\t' {
				push_glyph(painter, place.x, place.y, rune_at(buffer.text[:], place.offset), theme[.Background])
			}
		case .Bar:
			push_rect(painter, place.x, place.y, max(2, cell * 0.16), line_height, color)
		case .Underline:
			push_rect(painter, place.x, place.y + line_height - 3, cell, 3, color)
		}
	}
}

context_hints :: proc(editor: ^Editor) -> string {
	if editor.picker.kind != .None {
		switch editor.picker.kind {
		case .Menu:
			return "Press the key   or type to filter   tab next   enter run   esc cancel"
		case .Commands:
			return "Type a command and its argument   tab next   enter run   esc cancel"
		case .Themes:
			return "Tab and arrows preview live   enter keeps it   esc restores"
		case .Files:
			return "Type to fuzzy match   tab next   enter open   esc cancel"
		case .Buffers:
			return "Tab next   enter focus   esc cancel"
		case .Workspaces:
			return "Tab next   enter switch workspace   esc cancel"
		case .Diagnostics:
			return "Tab next   enter goes to the problem   esc back to where you were"
		case .Symbols:
			return "Type to fuzzy match   tab next   enter jump   esc cancel"
		case .GlobalSearch:
			return "Type at least two characters   tab next   enter jump   esc cancel"
		case .References:
			return "Tab next   enter jump   esc cancel"
		case .None:
		}
	}
	if editor.settings.open {
		section := fmt.tprintf("Settings   %v", editor.settings.section)
		if editor.settings.capturing {
			return "Press the new key   esc cancels"
		}
		if editor.settings.choosing {
			return "Type to filter   tab next   enter binds   esc cancels"
		}
		switch editor.settings.focus {
		case .Sections:
			return "Up and down pick a section   tab or right moves in   esc saves and closes"
		case .Fields:
			return "Up and down pick   left and right adjust   enter opens   esc saves and closes"
		case .Scheme:
			return "Arrows move on the keyboard   page up and down change layer   enter binds   delete unbinds"
		case .Bindings:
			return "Up and down pick a binding   enter captures a new key   tab back to the keyboard"
		}
	}
	if editor.hover.open {
		return "Lines point at the references   any key closes it"
	}
	if editor.prompt != .None {
		switch editor.prompt {
		case .Search:
			return "Type to search as you go   enter keeps it   esc cancels"
		case .SearchBackward:
			return "Type to search as you go   enter keeps it   esc cancels"
		case .Rename:
			return "Type the new name   enter rewrites every reference on disk"
		case .SelectMatches:
			return "Type a literal   enter selects every occurrence inside the selection"
		case .CommandLine:
			return "Enter runs   esc cancels"
		case .GotoLine:
			return "Type a line number   enter jumps   esc cancels"
		case .UserName:
			return "Type the name your todo comments are signed with   enter keeps it"
		case .None:
		}
	}
	buffer := editor_buffer(editor)
	if buffer.kind == .Image {
		return "Ctrl-+ and ctrl-- zoom   ctrl-0 resets   ctrl-l next buffer"
	}
	if editor.pending_prefix != 0 {
		return "Press the next key of the chord   esc cancels"
	}
	switch editor.mode {
	case .Insert:
		return "Esc or ctrl-i returns to normal   tab indents   enter keeps the indent"
	case .Select:
		return "Motions extend   esc collapses   d deletes   y yanks"
	case .Normal:
	}
	return "Space opens the menu   : runs a command   space k explains a symbol"
}

draw_top_bar :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	height := top_bar_height_of(editor)
	push_rect(painter, 0, 0, f32(editor.width), height, theme[.StatusBar])
	push_rect(painter, 0, height - 1, f32(editor.width), 1, theme[.Overlay])

	hints := context_hints(editor)
	text_y := (height - painter.line_height) / 2
	pen := draw_logo(editor, height)

	for buffer, index in editor.buffers {
		if buffer_hidden(buffer) {
			continue
		}
		if pen > f32(editor.width) * 0.45 {
			pen = push_text(painter, pen + painter.cell_width, text_y, fmt.tprintf("+%d", len(editor.buffers) - index), theme[.Gutter])
			break
		}
		label := fmt.tprintf(" %s%s ", filename_of(buffer.display), (.Modified in buffer.flags) ? "+" : "")
		focused := index == editor_view(editor).buffer
		if focused {
			push_rect(painter, pen + painter.cell_width, text_y, painter.cell_width * f32(len(label)), painter.line_height, theme[.Selection])
		}
		pen = push_text(painter, pen + painter.cell_width, text_y, label, focused ? theme[.Text] : theme[.Gutter])
	}

	color := theme[.Comment]
	if entry, troubled := diagnostic_under_cursor(editor); troubled {
		hints = entry.message
		color = diagnostic_color(entry)
	}
	buttons := painter.cell_width * 12
	room := max(0, int((f32(editor.width) - buttons - pen) / painter.cell_width) - 3)
	if room >= 16 {
		visible := hints[:min(room, len(hints))]
		push_text(painter, f32(editor.width) - buttons - painter.cell_width * f32(len(visible) + 1), text_y, visible, color)
	}
	draw_window_buttons(editor)
}

draw_status_bar :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	buffer := editor_buffer(editor)
	height := status_height_of(editor)
	y := f32(editor.height) - height
	push_rect(painter, 0, y, f32(editor.width), height, theme[.StatusBar])

	text_y := y + (height - painter.line_height) / 2
	mode_label := editor.mode == .Normal ? " NOR " : (editor.mode == .Insert ? " INS " : " SEL ")
	if (.ReadOnly in buffer.flags) {
		mode_label = " R/O "
	}
	mode_width := painter.cell_width * f32(len(mode_label))
	push_rect(painter, 0, y, mode_width, height, theme[.Accent])
	push_text(painter, 0, text_y, mode_label, theme[.Background])

	columns := max(0, int((f32(editor.width) - mode_width) / painter.cell_width))
	painter_set_clip(painter, {0, i32(y), editor.width, i32(height) + 1})
	defer painter_clear_clip(painter)

	if editor.prompt != .None {
		prefix := ""
		switch editor.prompt {
		case .Search:
			prefix = "/"
		case .SearchBackward:
			prefix = "?"
		case .Rename:
			prefix = "Rename to: "
		case .SelectMatches:
			prefix = "Select: "
		case .CommandLine:
			prefix = ":"
		case .GotoLine:
			prefix = "Goto line: "
		case .UserName:
			prefix = "Your name: "
		case .None:
		}
		input := string(editor.prompt_input[:])
		caret := clamp(editor.prompt_cursor, 0, len(input))
		typed := fmt.tprintf(" %s%s", prefix, input)
		if len(typed) > columns {
			typed = typed[len(typed) - columns:]
		}
		push_text(painter, mode_width, text_y, typed, theme[.Cursor])
		caret_x := mode_width + f32(len(typed) - len(input) + caret) * painter.cell_width
		push_rect(painter, caret_x, text_y, max(2, painter.cell_width * 0.16), painter.line_height, theme[.Cursor])
		return
	}

	line := buffer_line_of(buffer, buffer_primary(buffer).head)
	working := ""
	if shell_job != nil || index_job != nil {
		frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
		working = fmt.tprintf(" %s %s", frames[int(editor.time * 12) % len(frames)], shell_job != nil ? shell_job.command : "indexing")
	}
	left := fmt.tprintf(
		" %d sel | %d:%d | %d lines",
		len(buffer.selections),
		line + 1,
		buffer_column_of(buffer, buffer_primary(buffer).head) + 1,
		buffer_line_count(buffer),
	)
	right := fmt.tprintf("%v | %v | %d panes | %s ", buffer.kind, buffer.language, len(editor.views), editor.config.theme_name)
	center := fmt.tprintf("%s%s", project_relative(editor, buffer.display), (.Modified in buffer.flags) ? " +" : "")
	if len(center) > columns / 3 {
		center = fmt.tprintf("%s%s", filename_of(buffer.display), (.Modified in buffer.flags) ? " +" : "")
	}

	left = left[:min(len(left), columns / 3)]
	right = right[:min(len(right), columns / 3)]
	center = center[:min(len(center), max(0, columns - len(left) - len(right) - 2))]

	pen := push_text(painter, mode_width, text_y, left, theme[.StatusText])
	if working != "" {
		pen = push_text(painter, pen, text_y, working, theme[.Accent])
	}
	right_x := f32(editor.width) - painter.cell_width * f32(len(right))
	center_x := clamp(
		(f32(editor.width) - painter.cell_width * f32(len(center))) / 2,
		pen + painter.cell_width,
		max(pen + painter.cell_width, right_x - painter.cell_width * f32(len(center) + 1)),
	)
	push_text(painter, center_x, text_y, center, theme[.Text])
	push_text(painter, right_x, text_y, right, theme[.Gutter])
}

picker_rows :: proc(editor: ^Editor) -> int {
	return min(20, max(1, int((f32(editor.height) - status_height_of(editor)) / line_height_of(editor)) - 5))
}

draw_picker :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	picker := &editor.picker
	cell := painter.cell_width
	line_height := line_height_of(editor)
	margin := cell

	width := min(f32(editor.width) * 0.45, cell * 86)
	rows := clamp(len(picker.filtered), 1, picker_rows(editor))
	height := line_height * f32(rows + 1) + 14
	x := f32(editor.width) - width - margin
	bottom := f32(editor.height) - status_height_of(editor) - margin * 0.5
	y := bottom - height

	push_rect(painter, x - 2, y - 2, width + 4, height + 4, theme[.Accent])
	push_rect(painter, x, y, width, height, theme[.Overlay])
	painter_set_clip(painter, {i32(x), i32(y), i32(width), i32(height)})
	defer painter_clear_clip(painter)

	query_y := bottom - line_height - 6
	push_rect(painter, x, query_y - 3, width, line_height + 6, theme[.StatusBar])
	prompt := fmt.tprintf("%s> %s_", picker.title, string(picker.query[:]))
	push_text(painter, x + 8, query_y, prompt, theme[.Cursor])
	count := fmt.tprintf("%d/%d ", len(picker.filtered), len(picker.items))
	push_text(painter, x + width - cell * f32(len(count)), query_y, count, theme[.Comment])

	picker.scroll = clamp(picker.scroll, max(0, picker.cursor - rows + 1), max(0, picker.cursor))
	for row in 0 ..< rows {
		position := picker.scroll + row
		if position >= len(picker.filtered) {
			break
		}
		item := picker.items[picker.filtered[position]]
		item_y := y + 4 + line_height * f32(row)
		if position == picker.cursor {
			push_rect(painter, x, item_y, width, line_height, theme[.Selection])
		}
		detail_room := item.detail == "" ? 0 : min(len(item.detail), int(width / cell) / 3)
		detail_x := x + width - 8 - cell * f32(detail_room)
		room := max(0, int((detail_x - x - 16) / cell))
		push_text(painter, x + 8, item_y, item.label[:min(room, len(item.label))], position == picker.cursor ? theme[.Accent] : theme[.Text])
		if detail_room > 0 {
			shown := item.detail[:min(detail_room, len(item.detail))]
			push_text(painter, detail_x, item_y, shown, theme[.Comment])
		}
	}
}

editor_animating :: proc(editor: ^Editor) -> bool {
	if len(toasts) > 0 || dialog_open || editor.picker.preview_due != 0 || editor.picker.warming {
		return true
	}
	if (.ConfigDirty in editor.flags) || (.SessionDirty in editor.flags) {
		return true
	}
	for buffer in editor.buffers {
		if .BaselinePending in buffer.flags {
			return true
		}
	}
	for &view in editor.views {
		if abs(view.scroll_visual - f32(view.scroll_line)) > 0.02 {
			return true
		}
		if view.cursor_ready && (abs(view.cursor_x - view.cursor_target.x) > 0.4 || abs(view.cursor_y - view.cursor_target.y) > 0.4) {
			return true
		}
	}
	return false
}
