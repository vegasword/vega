package vega

import "core:log"
import "core:os"
import sdl "vendor:sdl3"
import "core:slice"
import "core:strings"

Buffer_Flag :: enum u8 {
	Modified,
	ReadOnly,
	HunksDirty,
	Preview,
	BaselinePending,
	Sample,
}

Buffer_Flags :: bit_set[Buffer_Flag; u8]

Range :: struct {
	anchor: int,
	head:   int,
}

History_Entry :: struct {
	text:       string,
	selections: []Range,
}

Buffer :: struct {
	path:        string,
	display:     string,
	text:        [dynamic]u8,
	line_starts: [dynamic]int,
	tokens:      [dynamic]Token,
	language:    Language,
	selections:  [dynamic]Range,
	primary:     int,
	scroll:      int,
	flags:       Buffer_Flags,
	kind:        Content_Kind,
	baseline:    string,
	hunks:       [dynamic]Hunk,
	texture:     ^sdl.Texture,
	image_width: int,
	image_height: int,
	undo_stack:  [dynamic]History_Entry,
	redo_stack:  [dynamic]History_Entry,
	clean_depth: int,
	modified:    i64,
}

buffer_hidden :: proc(buffer: ^Buffer) -> bool {
	return .Preview in buffer.flags || .Sample in buffer.flags
}

range_low :: proc(range: Range) -> int {
	return min(range.anchor, range.head)
}

range_high :: proc(buffer: ^Buffer, range: Range) -> int {
	if range.head >= range.anchor {
		return next_rune_offset(buffer.text[:], range.head)
	}
	return next_rune_offset(buffer.text[:], range.anchor)
}

range_text :: proc(buffer: ^Buffer, range: Range) -> string {
	low, high := range_low(range), range_high(buffer, range)
	return string(buffer.text[low:high])
}

buffer_create :: proc(editor: ^Editor, path: string, flags: Buffer_Flags = {}, preloaded: []u8 = nil) -> ^Buffer {
	buffer := new(Buffer)
	buffer.flags = flags
	buffer.path = strings.clone(path)
	buffer.display = strings.clone(path if path != "" else "[scratch]")
	buffer.language = language_of_path(path)
	buffer.kind = content_kind_of_path(path)
	if path != "" {
		buffer.modified, _ = scan_stat(path)
	}
	if path != "" && buffer.kind == .Image {
		buffer.flags += {.ReadOnly}
		image_load(editor, buffer)
	} else if preloaded != nil {
		if buffer.kind == .Pdf {
			buffer.flags += {.ReadOnly}
			extracted := pdf_extract_text(preloaded, context.temp_allocator)
			resize(&buffer.text, len(extracted))
			copy(buffer.text[:], extracted)
		} else {
			resize(&buffer.text, len(preloaded))
			copy(buffer.text[:], preloaded)
		}
	} else if path != "" {
		if data, error := os.read_entire_file(path, context.allocator); error == nil {
			defer delete(data)
			if buffer.kind == .Pdf {
				buffer.flags += {.ReadOnly}
				extracted := pdf_extract_text(data, context.temp_allocator)
				resize(&buffer.text, len(extracted))
				copy(buffer.text[:], extracted)
			} else {
				resize(&buffer.text, len(data))
				copy(buffer.text[:], data)
			}
		}
	}
	if len(buffer.text) >= 3 && buffer.text[0] == 0xef && buffer.text[1] == 0xbb && buffer.text[2] == 0xbf {
		copy(buffer.text[:], buffer.text[3:])
		resize(&buffer.text, len(buffer.text) - 3)
		log.debugf("dropped the byte order mark of %s", filename_of(path))
	}
	append(&buffer.selections, Range{0, 0})
	buffer_refresh(buffer)
	if buffer_hidden(buffer) || path == "" {
		buffer.flags += {.HunksDirty}
	} else {
		buffer.flags += {.BaselinePending}
	}
	return buffer
}

buffer_refresh :: proc(buffer: ^Buffer) {
	clear(&buffer.line_starts)
	append(&buffer.line_starts, 0)
	for character, offset in buffer.text {
		if character == '\n' {
			append(&buffer.line_starts, offset + 1)
		}
	}
	tokenize(buffer.text[:], buffer.language, &buffer.tokens)
}

buffer_line_count :: proc(buffer: ^Buffer) -> int {
	return len(buffer.line_starts)
}

buffer_line_of :: proc(buffer: ^Buffer, offset: int) -> int {
	target := clamp(offset, 0, len(buffer.text))
	low, high := 0, len(buffer.line_starts) - 1
	for low < high {
		middle := (low + high + 1) / 2
		if buffer.line_starts[middle] <= target {
			low = middle
		} else {
			high = middle - 1
		}
	}
	return low
}

buffer_line_bounds :: proc(buffer: ^Buffer, line: int) -> (start, end: int) {
	index := clamp(line, 0, len(buffer.line_starts) - 1)
	start = buffer.line_starts[index]
	end = len(buffer.text)
	if index + 1 < len(buffer.line_starts) {
		end = buffer.line_starts[index + 1] - 1
	}
	return start, max(start, end)
}

buffer_line_text :: proc(buffer: ^Buffer, line: int) -> string {
	start, end := buffer_line_bounds(buffer, line)
	return string(buffer.text[start:end])
}

buffer_column_of :: proc(buffer: ^Buffer, offset: int) -> int {
	start, _ := buffer_line_bounds(buffer, buffer_line_of(buffer, offset))
	return offset - start
}

buffer_snapshot :: proc(buffer: ^Buffer) {
	entry := History_Entry {
		text       = strings.clone(string(buffer.text[:])),
		selections = slice.clone(buffer.selections[:]),
	}
	append(&buffer.undo_stack, entry)
	for entry in buffer.redo_stack {
		delete(entry.text)
		delete(entry.selections)
	}
	clear(&buffer.redo_stack)
	if len(buffer.undo_stack) > 512 {
		oldest := buffer.undo_stack[0]
		delete(oldest.text)
		delete(oldest.selections)
		ordered_remove(&buffer.undo_stack, 0)
		buffer.clean_depth = max(0, buffer.clean_depth - 1)
	}
}

buffer_commit :: proc(buffer: ^Buffer) {
	if len(buffer.undo_stack) == 0 {
		return
	}
	top := buffer.undo_stack[len(buffer.undo_stack) - 1]
	if top.text != string(buffer.text[:]) {
		return
	}
	delete(top.text)
	delete(top.selections)
	pop(&buffer.undo_stack)
	if len(buffer.undo_stack) == buffer.clean_depth {
		buffer.flags -= {.Modified}
	}
	log.debug("dropped an undo step that changed nothing")
}

buffer_restore :: proc(buffer: ^Buffer, from, to: ^[dynamic]History_Entry) {
	if len(from) == 0 {
		return
	}
	append(to, History_Entry{strings.clone(string(buffer.text[:])), slice.clone(buffer.selections[:])})
	entry := pop(from)
	resize(&buffer.text, len(entry.text))
	copy(buffer.text[:], entry.text)
	clear(&buffer.selections)
	append(&buffer.selections, ..entry.selections)
	buffer.primary = min(buffer.primary, len(buffer.selections) - 1)
	delete(entry.text)
	delete(entry.selections)
	buffer.flags += {.HunksDirty}
	if len(buffer.undo_stack) == buffer.clean_depth {
		buffer.flags -= {.Modified}
	} else {
		buffer.flags += {.Modified}
	}
	buffer_refresh(buffer)
}

buffer_insert :: proc(buffer: ^Buffer, offset: int, insertion: string) {
	position := clamp(offset, 0, len(buffer.text))
	resize(&buffer.text, len(buffer.text) + len(insertion))
	copy(buffer.text[position + len(insertion):], buffer.text[position:len(buffer.text) - len(insertion)])
	copy(buffer.text[position:], insertion)
	buffer.flags += {.Modified}
	buffer.flags += {.HunksDirty}
}

buffer_remove :: proc(buffer: ^Buffer, low, high: int) {
	start := clamp(low, 0, len(buffer.text))
	end := clamp(high, start, len(buffer.text))
	if start == end {
		return
	}
	copy(buffer.text[start:], buffer.text[end:])
	resize(&buffer.text, len(buffer.text) - (end - start))
	buffer.flags += {.Modified}
	buffer.flags += {.HunksDirty}
}

buffer_clamp_selections :: proc(buffer: ^Buffer) {
	limit := max(0, len(buffer.text))
	for &selection in buffer.selections {
		selection.anchor = clamp(selection.anchor, 0, limit)
		selection.head = clamp(selection.head, 0, limit)
	}
	buffer.primary = clamp(buffer.primary, 0, len(buffer.selections) - 1)
}

buffer_save :: proc(editor: ^Editor, buffer: ^Buffer) -> bool {
	if buffer.path == "" {
		return false
	}
	if os.write_entire_file(buffer.path, buffer.text[:]) != nil {
		return false
	}
	buffer.flags -= {.Modified}
	buffer.clean_depth = len(buffer.undo_stack)
	buffer.modified, _ = scan_stat(buffer.path)
	buffer_set_baseline(editor, buffer)
	return true
}

buffer_primary :: proc(buffer: ^Buffer) -> ^Range {
	buffer.primary = clamp(buffer.primary, 0, len(buffer.selections) - 1)
	return &buffer.selections[buffer.primary]
}

buffer_collapse_to_primary :: proc(buffer: ^Buffer) {
	primary := buffer_primary(buffer)^
	clear(&buffer.selections)
	append(&buffer.selections, primary)
	buffer.primary = 0
}

buffer_merge_selections :: proc(buffer: ^Buffer) {
	if len(buffer.selections) < 2 {
		return
	}
	primary_range := buffer_primary(buffer)^
	slice.sort_by(buffer.selections[:], proc(a, b: Range) -> bool {
		return min(a.anchor, a.head) < min(b.anchor, b.head)
	})
	merged := make([dynamic]Range, 0, len(buffer.selections))
	for selection in buffer.selections {
		if len(merged) > 0 {
			last := &merged[len(merged) - 1]
			if range_high(buffer, last^) > range_low(selection) {
				if range_high(buffer, selection) > range_high(buffer, last^) {
					last.head = selection.head
					last.anchor = min(last.anchor, selection.anchor)
				}
				continue
			}
		}
		append(&merged, selection)
	}
	delete(buffer.selections)
	buffer.selections = merged
	buffer.primary = 0
	for selection, index in buffer.selections {
		if range_low(selection) <= range_low(primary_range) {
			buffer.primary = index
		}
	}
}

buffer_destroy :: proc(buffer: ^Buffer) {
	if buffer.texture != nil {
		sdl.DestroyTexture(buffer.texture)
	}
	for entry in buffer.undo_stack {
		delete(entry.text)
		delete(entry.selections)
	}
	for entry in buffer.redo_stack {
		delete(entry.text)
		delete(entry.selections)
	}
	delete(buffer.undo_stack)
	delete(buffer.redo_stack)
	delete(buffer.baseline)
	delete(buffer.hunks)
	delete(buffer.selections)
	delete(buffer.tokens)
	delete(buffer.line_starts)
	delete(buffer.text)
	delete(buffer.display)
	delete(buffer.path)
	free(buffer)
}