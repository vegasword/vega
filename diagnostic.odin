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
	editor.diagnostic_cursor = (editor.diagnostic_cursor + delta + len(editor.diagnostics)) % len(editor.diagnostics)
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

draw_diagnostic_mark :: proc(editor: ^Editor, buffer: ^Buffer, line: int, gutter, x, y: f32) {
	entry, found := diagnostic_at(editor, buffer, line)
	if !found {
		return
	}
	painter := &editor.painter
	cell := painter.cell_width
	line_height := line_height_of(editor)
	color := entry.warning ? editor.active_theme[.Number] : editor.active_theme[.Directive]
	push_rect(painter, gutter, y, x - gutter + cell, line_height, color * [4]f32{1, 1, 1, 0.12})
	push_rect(painter, gutter - cell * 1.6, y + 1, cell * 0.35, line_height - 2, color)
	if entry.column > 0 {
		wave := gutter + f32(entry.column - 1) * cell
		push_line(painter, wave, y + line_height - 2, min(wave + cell * 3, x), y + line_height - 2, 1.5, color)
	}
}

draw_diagnostic_message :: proc(editor: ^Editor, buffer: ^Buffer, line: int, gutter, x, y: f32, room: f32) {
	entry, found := diagnostic_at(editor, buffer, line)
	if !found {
		return
	}
	painter := &editor.painter
	theme := editor.active_theme
	cell := painter.cell_width
	line_height := line_height_of(editor)
	color := entry.warning ? theme[.Number] : theme[.Directive]
	right := x + room
	fits := int((right - gutter) / cell) - 4
	if fits < 4 {
		return
	}
	message := entry.message
	columns := len(message)
	if columns > fits {
		message = strings.concatenate({message[:fits - 1], "…"}, context.temp_allocator)
		columns = fits
	}
	start := right - f32(columns + 1) * cell
	push_rect(painter, start - cell, y, right - start + cell, line_height, theme[.Background])
	push_rect(painter, start - cell, y, cell * 0.2, line_height, color)
	push_text(painter, start, y, message, color)
}
