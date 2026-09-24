package vega

import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:strings"

Diagnostic :: struct {
	path:    string,
	line:    int,
	column:  int,
	message: string,
	warning: bool,
}

diagnostics_clear :: proc(editor: ^Editor) {
	for entry in editor.diagnostics {
		delete(entry.path)
		delete(entry.message)
	}
	clear(&editor.diagnostics)
	editor.diagnostic_cursor = 0
}

diagnostic_line :: proc(text: string) -> (entry: Diagnostic, ok: bool) {
	open := strings.index_byte(text, '(')
	close := strings.index_byte(text, ')')
	if open > 0 && close > open {
		place := text[open + 1:close]
		divider := strings.index_byte(place, ':')
		rest := strings.trim_space(text[close + 1:])
		if divider > 0 && (strings.has_prefix(rest, "Error:") || strings.has_prefix(rest, "Warning:")) {
			entry.path = strings.trim_space(text[:open])
			entry.line = int_of(place[:divider])
			entry.column = int_of(place[divider + 1:])
			entry.warning = strings.has_prefix(rest, "Warning:")
			entry.message = strings.trim_space(rest[strings.index_byte(rest, ':') + 1:])
			return entry, entry.line > 0
		}
	}
	cut := strings.index(text, ": error: ")
	if cut < 0 {
		cut = strings.index(text, ": warning: ")
	}
	if cut > 0 {
		head := text[:cut]
		entry.warning = strings.contains(text[cut:], "warning")
		entry.message = strings.trim_space(text[cut + (entry.warning ? len(": warning: ") : len(": error: ")):])
		column_cut := strings.last_index_byte(head, ':')
		if column_cut > 0 {
			line_cut := strings.last_index_byte(head[:column_cut], ':')
			if line_cut > 0 {
				entry.path = head[:line_cut]
				entry.line = int_of(head[line_cut + 1:column_cut])
				entry.column = int_of(head[column_cut + 1:])
				return entry, entry.line > 0
			}
			entry.path = head[:column_cut]
			entry.line = int_of(head[column_cut + 1:])
			return entry, entry.line > 0
		}
	}
	return {}, false
}

diagnostics_collect :: proc(editor: ^Editor, output: string) {
	diagnostics_clear(editor)
	remaining := output
	for text in strings.split_lines_iterator(&remaining) {
		entry, ok := diagnostic_line(strings.trim_space(text))
		if !ok {
			continue
		}
		full, error := filepath.abs(entry.path, context.temp_allocator)
		if error != nil {
			full = entry.path
		}
		append(&editor.diagnostics, Diagnostic{strings.clone(full), entry.line, entry.column, strings.clone(entry.message), entry.warning})
	}
	if len(editor.diagnostics) > 0 {
		log.infof("%d diagnostic(s) parsed, first at %s:%d", len(editor.diagnostics), filename_of(editor.diagnostics[0].path), editor.diagnostics[0].line)
	}
}

diagnostic_at :: proc(editor: ^Editor, buffer: ^Buffer, line: int) -> (Diagnostic, bool) {
	for entry in editor.diagnostics {
		if entry.line - 1 == line && entry.path == buffer.path {
			return entry, true
		}
	}
	return {}, false
}

diagnostic_go :: proc(editor: ^Editor, delta: int) {
	if len(editor.diagnostics) == 0 {
		notify("No errors to visit")
		return
	}
	diagnostic_show(editor, (editor.diagnostic_cursor + delta + len(editor.diagnostics)) % len(editor.diagnostics))
}

diagnostic_show :: proc(editor: ^Editor, index: int) {
	if len(editor.diagnostics) == 0 {
		return
	}
	editor.diagnostic_cursor = clamp(index, 0, len(editor.diagnostics) - 1)
	entry := editor.diagnostics[editor.diagnostic_cursor]
	output_close(editor)
	jump_push(editor)
	editor_open_file(editor, entry.path)
	buffer := editor_buffer(editor)
	start, end := buffer_line_bounds(buffer, clamp(entry.line - 1, 0, buffer_line_count(buffer) - 1))
	goto_offset(buffer, clamp(start + max(0, entry.column - 1), start, end), false)
	editor_center_view(editor)
	notify(fmt.tprintf("%d of %d  %s", editor.diagnostic_cursor + 1, len(editor.diagnostics), entry.message))
}

DIAGNOSTIC_RED :: [4]f32{0.91, 0.27, 0.31, 1}
DIAGNOSTIC_AMBER :: [4]f32{0.93, 0.68, 0.24, 1}

diagnostic_color :: proc(entry: Diagnostic) -> [4]f32 {
	return entry.warning ? DIAGNOSTIC_AMBER : DIAGNOSTIC_RED
}

diagnostic_span :: proc(buffer: ^Buffer, line, column: int) -> (start, end: int) {
	first, last := buffer_line_bounds(buffer, line)
	if column > 0 && first + column - 1 < last {
		word, at := word_at(buffer.text[:], first + column - 1)
		if word != "" {
			return at - first, at - first + len(word)
		}
	}
	text := string(buffer.text[first:last])
	indent := 0
	for indent < len(text) && (text[indent] == ' ' || text[indent] == '\t') {
		indent += 1
	}
	return indent, len(text)
}

draw_diagnostic_mark :: proc(editor: ^Editor, buffer: ^Buffer, line: int, gutter, y: f32, tab_width, scroll_x: int) {
	entry, found := diagnostic_at(editor, buffer, line)
	if !found {
		return
	}
	painter := &editor.painter
	cell := painter.cell_width
	line_height := line_height_of(editor)
	color := diagnostic_color(entry)
	push_rect(painter, gutter - cell * 1.6, y + 1, cell * 0.35, line_height - 2, color)

	start, end := diagnostic_span(buffer, line, entry.column)
	first, _ := buffer_line_bounds(buffer, line)
	from := visual_column(buffer, first, first + start, tab_width) - scroll_x
	to := visual_column(buffer, first, first + end, tab_width) - scroll_x
	if to <= 0 || to <= from {
		return
	}
	left := gutter + f32(max(0, from)) * cell
	push_line(painter, left, y + line_height - 1.5, gutter + f32(to) * cell, y + line_height - 1.5, 1.5, color)
}

diagnostic_under_cursor :: proc(editor: ^Editor) -> (Diagnostic, bool) {
	if len(editor.diagnostics) == 0 {
		return {}, false
	}
	buffer := editor_buffer(editor)
	return diagnostic_at(editor, buffer, buffer_line_of(buffer, buffer_primary(buffer).head))
}
