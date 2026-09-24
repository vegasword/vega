package vega

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

Char_Class :: enum u8 {
	Whitespace,
	Word,
	Punctuation,
}

char_class :: proc(character: u8) -> Char_Class {
	if character == ' ' || character == '\t' || character == '\r' || character == '\n' {
		return .Whitespace
	}
	return .Word if is_word_byte(character) else .Punctuation
}

class_at :: proc(text: []u8, offset: int, long: bool) -> Char_Class {
	if offset < 0 || offset >= len(text) {
		return .Whitespace
	}
	class := char_class(text[offset])
	if long && class == .Punctuation {
		return .Word
	}
	return class
}

next_word_start :: proc(text: []u8, offset: int, long: bool) -> int {
	position := offset
	starting := class_at(text, position, long)
	for position < len(text) && class_at(text, position, long) == starting && starting != .Whitespace {
		position += 1
	}
	for position < len(text) && class_at(text, position, long) == .Whitespace {
		position += 1
	}
	return min(position, len(text))
}

next_word_end :: proc(text: []u8, offset: int, long: bool) -> int {
	position := offset
	for position < len(text) && class_at(text, position, long) == .Whitespace {
		position += 1
	}
	starting := class_at(text, position, long)
	for position < len(text) && class_at(text, position, long) == starting {
		position += 1
	}
	return clamp(position - 1, 0, max(0, len(text) - 1))
}

previous_word_start :: proc(text: []u8, offset: int, long: bool) -> int {
	position := offset
	for position > 0 && class_at(text, position - 1, long) == .Whitespace {
		position -= 1
	}
	starting := class_at(text, position - 1, long)
	for position > 0 && class_at(text, position - 1, long) == starting {
		position -= 1
	}
	return max(position, 0)
}

Positioned_Selection :: struct {
	low:   int,
	index: int,
}

selections_descending :: proc(buffer: ^Buffer) -> []Positioned_Selection {
	order := make([]Positioned_Selection, len(buffer.selections), context.temp_allocator)
	for selection, index in buffer.selections {
		order[index] = {range_low(selection), index}
	}
	slice.sort_by(order, proc(a, b: Positioned_Selection) -> bool { return a.low > b.low })
	return order
}

shift_position :: proc(position, low, high, delta: int) -> int {
	if position >= high {
		return position + delta
	}
	if position > low {
		return low
	}
	return position
}

apply_replace :: proc(buffer: ^Buffer, low, high: int, insertion: string) {
	buffer_remove(buffer, low, high)
	if len(insertion) > 0 {
		buffer_insert(buffer, low, insertion)
	}
	delta := len(insertion) - (high - low)
	for &selection in buffer.selections {
		selection.anchor = shift_position(selection.anchor, low, high, delta)
		selection.head = shift_position(selection.head, low, high, delta)
	}
}

move_horizontal :: proc(buffer: ^Buffer, delta: int, extend: bool) {
	for &selection in buffer.selections {
		position := selection.head
		for _ in 0 ..< abs(delta) {
			position = delta > 0 ? next_rune_offset(buffer.text[:], position) : previous_rune_offset(buffer.text[:], position)
		}
		selection.head = clamp(position, 0, max(0, len(buffer.text) - 1))
		if !extend {
			selection.anchor = selection.head
		}
	}
	buffer_merge_selections(buffer)
}

move_vertical :: proc(buffer: ^Buffer, delta: int, extend: bool) {
	for &selection in buffer.selections {
		line := buffer_line_of(buffer, selection.head)
		column := selection.head - buffer.line_starts[line]
		target := clamp(line + delta, 0, buffer_line_count(buffer) - 1)
		start, end := buffer_line_bounds(buffer, target)
		selection.head = clamp(start + column, start, max(start, end - 1 if end > start else end))
		if !extend {
			selection.anchor = selection.head
		}
	}
	buffer_merge_selections(buffer)
}

run_bounds :: proc(text: []u8, offset: int, long: bool) -> (start, end: int) {
	if len(text) == 0 {
		return 0, 0
	}
	position := clamp(offset, 0, len(text) - 1)
	class := class_at(text, position, long)
	start = position
	for start > 0 && class_at(text, start - 1, long) == class {
		start -= 1
	}
	end = position
	for end + 1 < len(text) && class_at(text, end + 1, long) == class {
		end += 1
	}
	return start, end
}

move_word :: proc(buffer: ^Buffer, direction: int, stop_at_end: bool, long: bool, extend: bool) {
	for &selection in buffer.selections {
		origin := selection.head
		target: int
		if direction > 0 {
			target = stop_at_end ? next_word_end(buffer.text[:], origin + 1, long) : next_word_start(buffer.text[:], origin, long)
		} else {
			target = previous_word_start(buffer.text[:], origin, long)
		}
		start, end := run_bounds(buffer.text[:], target, long)
		head := direction > 0 ? end : start
		tail := direction > 0 ? start : end
		selection.head = clamp(head, 0, max(0, len(buffer.text) - 1))
		if !extend {
			selection.anchor = clamp(tail, 0, max(0, len(buffer.text) - 1))
		}
	}
	buffer_merge_selections(buffer)
}

select_lines :: proc(buffer: ^Buffer, extend: bool) {
	for &selection in buffer.selections {
		first := buffer_line_of(buffer, range_low(selection))
		last := buffer_line_of(buffer, max(range_low(selection), range_high(buffer, selection) - 1))
		_, reached := buffer_line_bounds(buffer, last)
		if extend && range_high(buffer, selection) >= reached {
			last = min(last + 1, buffer_line_count(buffer) - 1)
		}
		start, _ := buffer_line_bounds(buffer, first)
		_, finish := buffer_line_bounds(buffer, last)
		selection.anchor = start
		selection.head = max(start, finish - 1)
	}
	buffer_merge_selections(buffer)
}

buffer_line_bounds_end :: proc(buffer: ^Buffer, line: int) -> int {
	_, end := buffer_line_bounds(buffer, line)
	return min(len(buffer.text), end + 1)
}

goto_line_edge :: proc(buffer: ^Buffer, which: enum {
		Start,
		End,
	}, extend: bool) {
	for &selection in buffer.selections {
		line := buffer_line_of(buffer, selection.head)
		start, end := buffer_line_bounds(buffer, line)
		target := start
		switch which {
		case .Start:
			target = start
		case .End:
			target = max(start, end - 1)
		}
		selection.head = target
		if !extend {
			selection.anchor = target
		}
	}
}

goto_first_non_blank :: proc(buffer: ^Buffer) {
	for &selection in buffer.selections {
		line := buffer_line_of(buffer, selection.head)
		start, end := buffer_line_bounds(buffer, line)
		target := start
		for target < end && (buffer.text[target] == ' ' || buffer.text[target] == '\t') {
			target += 1
		}
		selection.head = target
		selection.anchor = target
	}
}

goto_offset :: proc(buffer: ^Buffer, offset: int, extend: bool) {
	buffer_collapse_to_primary(buffer)
	selection := buffer_primary(buffer)
	selection.head = clamp(offset, 0, max(0, len(buffer.text) - 1))
	if !extend {
		selection.anchor = selection.head
	}
}

delete_selections :: proc(editor: ^Editor, buffer: ^Buffer, yank: bool) {
	if yank {
		yank_selections(editor, buffer)
	}
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		apply_replace(buffer, range_low(selection), range_high(buffer, selection), "")
	}
	buffer_clamp_selections(buffer)
	for &selection in buffer.selections {
		selection.head = clamp(selection.head, 0, max(0, len(buffer.text) - 1))
		selection.anchor = selection.head
	}
	buffer_refresh(buffer)
	buffer_merge_selections(buffer)
}

yank_selections :: proc(editor: ^Editor, buffer: ^Buffer) {
	for entry in editor.registers {
		delete(entry)
	}
	clear(&editor.registers)
	for selection in buffer.selections {
		append(&editor.registers, strings.clone(range_text(buffer, selection)))
	}
}

yank_to_clipboard :: proc(editor: ^Editor, buffer: ^Buffer) {
	builder := strings.builder_make(context.temp_allocator)
	for selection, index in buffer.selections {
		if index > 0 {
			strings.write_byte(&builder, '\n')
		}
		strings.write_string(&builder, range_text(buffer, selection))
	}
	text := strings.to_string(builder)
	if !sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator)) {
		notify(fmt.tprintf("The clipboard refused the text: %s", sdl.GetError()), .Error)
		return
	}
	notify(fmt.tprintf("Copied %d byte(s) to the clipboard", len(text)))
}

paste_from_clipboard :: proc(editor: ^Editor, buffer: ^Buffer, after: bool) {
	if !sdl.HasClipboardText() {
		notify("The clipboard is empty")
		return
	}
	text := sdl.GetClipboardText()
	defer sdl.free(text)
	content := string(cstring(text))
	if content == "" {
		return
	}
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		line_wise := content[len(content) - 1] == '\n'
		position: int
		if line_wise {
			line := buffer_line_of(buffer, after ? range_high(buffer, selection) - 1 : range_low(selection))
			position = after ? buffer_line_bounds_end(buffer, line) : buffer.line_starts[line]
		} else {
			position = after ? range_high(buffer, selection) : range_low(selection)
		}
		apply_replace(buffer, position, position, content)
		buffer.selections[entry.index].anchor = position
		buffer.selections[entry.index].head = max(position, position + len(content) - 1)
	}
	buffer_refresh(buffer)
	log.debugf("%d byte(s) from the clipboard", len(content))
}

paste :: proc(editor: ^Editor, buffer: ^Buffer, after: bool) {
	if len(editor.registers) == 0 {
		return
	}
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		content := editor.registers[min(entry.index, len(editor.registers) - 1)]
		line_wise := len(content) > 0 && content[len(content) - 1] == '\n'
		position: int
		if line_wise {
			line := buffer_line_of(buffer, after ? range_high(buffer, selection) - 1 : range_low(selection))
			position = after ? buffer_line_bounds_end(buffer, line) : buffer.line_starts[line]
		} else {
			position = after ? range_high(buffer, selection) : range_low(selection)
		}
		apply_replace(buffer, position, position, content)
		buffer.selections[entry.index].anchor = position
		buffer.selections[entry.index].head = max(position, position + len(content) - 1)
	}
	buffer_refresh(buffer)
}

replace_with_register :: proc(editor: ^Editor, buffer: ^Buffer) {
	if len(editor.registers) == 0 {
		return
	}
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		content := editor.registers[min(entry.index, len(editor.registers) - 1)]
		low, high := range_low(selection), range_high(buffer, selection)
		apply_replace(buffer, low, high, content)
		buffer.selections[entry.index].anchor = low
		buffer.selections[entry.index].head = max(low, low + len(content) - 1)
	}
	buffer_refresh(buffer)
}

replace_characters :: proc(buffer: ^Buffer, character: u8) {
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		low, high := range_low(selection), range_high(buffer, selection)
		replacement := strings.repeat(string([]u8{character}), high - low, context.temp_allocator)
		for index in low ..< high {
			if buffer.text[index] == '\n' {
				replacement = string(buffer.text[low:high])
				break
			}
		}
		apply_replace(buffer, low, high, replacement)
		buffer.selections[entry.index].anchor = low
		buffer.selections[entry.index].head = max(low, high - 1)
	}
	buffer_refresh(buffer)
}

Case_Change :: enum u8 {
	Switch,
	Upper,
	Lower,
}

case_selections :: proc(buffer: ^Buffer, change: Case_Change) {
	buffer_snapshot(buffer)
	for selection in buffer.selections {
		for index in range_low(selection) ..< range_high(buffer, selection) {
			character := buffer.text[index]
			lower := character >= 'a' && character <= 'z'
			upper := character >= 'A' && character <= 'Z'
			switch change {
			case .Switch:
				buffer.text[index] = lower ? character - 32 : (upper ? character + 32 : character)
			case .Upper:
				buffer.text[index] = lower ? character - 32 : character
			case .Lower:
				buffer.text[index] = upper ? character + 32 : character
			}
		}
	}
	buffer.flags += {.Modified, .HunksDirty}
	buffer_refresh(buffer)
}

drop_selection :: proc(buffer: ^Buffer, first: bool) {
	if len(buffer.selections) < 2 {
		return
	}
	target := 0
	for selection, index in buffer.selections {
		edge := range_low(selection)
		known := range_low(buffer.selections[target])
		if first ? edge < known : edge > known {
			target = index
		}
	}
	ordered_remove(&buffer.selections, target)
	buffer.primary = clamp(buffer.primary >= target ? buffer.primary - 1 : buffer.primary, 0, len(buffer.selections) - 1)
	log.debugf("%d selection(s) left", len(buffer.selections))
}

comment_prefix :: proc(language: Language) -> string {
	switch language {
	case .Odin, .C, .GLSL:
		return "//"
	case .Shell:
		return "#"
	case .Plain:
	}
	return "#"
}

insert_tagged_comment :: proc(editor: ^Editor, buffer: ^Buffer, tag: string) {
	if .ReadOnly in buffer.flags {
		return
	}
	who := editor.config.user_name == "" ? "me" : editor.config.user_name
	head := buffer_primary(buffer).head
	line := buffer_line_of(buffer, head)
	start, end := buffer_line_bounds(buffer, line)
	blank := strings.trim_space(buffer_line_text(buffer, line)) == ""
	spacing := blank ? "" : " "
	comment := fmt.tprintf("%s%s%s(%s): ", spacing, comment_prefix(buffer.language), tag, who)
	buffer_snapshot(buffer)
	goto_offset(buffer, blank ? start : end, false)
	insert_text(buffer, comment)
	editor.mode = .Insert
	editor_ensure_visible(editor)
	log.debugf("%s comment inserted on line %d", tag, line + 1)
}

comment_selections :: proc(buffer: ^Buffer) {
	prefix := comment_prefix(buffer.language)
	lines := make([dynamic]int, 0, 16, context.temp_allocator)
	for selection in buffer.selections {
		first := buffer_line_of(buffer, range_low(selection))
		last := buffer_line_of(buffer, max(range_low(selection), range_high(buffer, selection) - 1))
		for line in first ..= last {
			if !slice.contains(lines[:], line) {
				append(&lines, line)
			}
		}
	}

	commented := true
	touched := 0
	for line in lines {
		text := strings.trim_space(buffer_line_text(buffer, line))
		if text == "" {
			continue
		}
		touched += 1
		if !strings.has_prefix(text, prefix) {
			commented = false
		}
	}
	if touched == 0 {
		return
	}

	buffer_snapshot(buffer)
	slice.sort(lines[:])
	for index := len(lines) - 1; index >= 0; index -= 1 {
		line := lines[index]
		start, end := buffer_line_bounds(buffer, line)
		text := string(buffer.text[start:end])
		if strings.trim_space(text) == "" {
			continue
		}
		blank := 0
		for blank < len(text) && (text[blank] == ' ' || text[blank] == '\t') {
			blank += 1
		}
		if commented {
			cut := start + blank + len(prefix)
			if cut < len(buffer.text) && buffer.text[cut] == ' ' {
				cut += 1
			}
			apply_replace(buffer, start + blank, cut, "")
		} else {
			apply_replace(buffer, start + blank, start + blank, strings.concatenate({prefix, " "}, context.temp_allocator))
		}
	}
	buffer_refresh(buffer)
	buffer_clamp_selections(buffer)
	log.debugf("%s %d line(s)", commented ? "uncommented" : "commented", touched)
}

join_lines :: proc(buffer: ^Buffer) {
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		line := buffer_line_of(buffer, max(range_low(selection), range_high(buffer, selection) - 1))
		if line + 1 >= buffer_line_count(buffer) {
			continue
		}
		_, end := buffer_line_bounds(buffer, line)
		next_start := buffer.line_starts[line + 1]
		trailing := next_start
		for trailing < len(buffer.text) && (buffer.text[trailing] == ' ' || buffer.text[trailing] == '\t') {
			trailing += 1
		}
		apply_replace(buffer, end, trailing, " ")
	}
	buffer_refresh(buffer)
}

indent_selections :: proc(editor: ^Editor, buffer: ^Buffer, outward: bool) {
	buffer_snapshot(buffer)
	indent := strings.repeat(" ", editor.config.indent_width, context.temp_allocator)
	touched := make(map[int]bool, context.temp_allocator)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		first := buffer_line_of(buffer, range_low(selection))
		last := buffer_line_of(buffer, max(range_low(selection), range_high(buffer, selection) - 1))
		for line := last; line >= first; line -= 1 {
			if line in touched {
				continue
			}
			touched[line] = true
			start, end := buffer_line_bounds(buffer, line)
			if outward {
				apply_replace(buffer, start, start, indent)
			} else {
				removal := start
				for removal < end &&
				    removal - start < editor.config.indent_width &&
				    (buffer.text[removal] == ' ' || buffer.text[removal] == '\t') {
					removal += 1
					if buffer.text[removal - 1] == '\t' {
						break
					}
				}
				apply_replace(buffer, start, removal, "")
			}
		}
	}
	buffer_refresh(buffer)
}

open_line :: proc(editor: ^Editor, buffer: ^Buffer, below: bool) {
	buffer_snapshot(buffer)
	for entry in selections_descending(buffer) {
		selection := buffer.selections[entry.index]
		line := buffer_line_of(buffer, below ? max(range_low(selection), range_high(buffer, selection) - 1) : range_low(selection))
		start, end := buffer_line_bounds(buffer, line)
		indent_end := start
		for indent_end < end && (buffer.text[indent_end] == ' ' || buffer.text[indent_end] == '\t') {
			indent_end += 1
		}
		indent := string(buffer.text[start:indent_end])
		position := below ? end : start
		insertion := below ? strings.concatenate({"\n", indent}, context.temp_allocator) : strings.concatenate({indent, "\n"}, context.temp_allocator)
		apply_replace(buffer, position, position, insertion)
		cursor := below ? position + len(insertion) : position + len(indent)
		buffer.selections[entry.index] = {cursor, cursor}
	}
	buffer_refresh(buffer)
	editor.mode = .Insert
}

insert_text :: proc(buffer: ^Buffer, insertion: string) {
	for entry in selections_descending(buffer) {
		position := buffer.selections[entry.index].head
		apply_replace(buffer, position, position, insertion)
		cursor := position + len(insertion)
		buffer.selections[entry.index] = {cursor, cursor}
	}
	buffer_refresh(buffer)
}

insert_newline :: proc(editor: ^Editor, buffer: ^Buffer) {
	for entry in selections_descending(buffer) {
		position := buffer.selections[entry.index].head
		line := buffer_line_of(buffer, position)
		start, _ := buffer_line_bounds(buffer, line)
		indent_end := start
		for indent_end < position && (buffer.text[indent_end] == ' ' || buffer.text[indent_end] == '\t') {
			indent_end += 1
		}
		indent := string(buffer.text[start:indent_end])
		extra := ""
		if (.AutoIndent in editor.config.options) && position > 0 {
			previous := buffer.text[position - 1]
			if previous == '{' || previous == '(' || previous == '[' {
				extra = strings.repeat(" ", editor.config.indent_width, context.temp_allocator)
			}
		}
		insertion := strings.concatenate({"\n", indent, extra}, context.temp_allocator)
		apply_replace(buffer, position, position, insertion)
		cursor := position + len(insertion)
		buffer.selections[entry.index] = {cursor, cursor}
	}
	buffer_refresh(buffer)
}

delete_backward :: proc(editor: ^Editor, buffer: ^Buffer) {
	for entry in selections_descending(buffer) {
		position := buffer.selections[entry.index].head
		if position == 0 {
			continue
		}
		start := previous_rune_offset(buffer.text[:], position)
		line_start, _ := buffer_line_bounds(buffer, buffer_line_of(buffer, position))
		if buffer.text[start] == ' ' && position - line_start >= editor.config.indent_width {
			blank := true
			for index in line_start ..< position {
				if buffer.text[index] != ' ' {
					blank = false
				}
			}
			if blank && (position - line_start) % editor.config.indent_width == 0 {
				start = position - editor.config.indent_width
			}
		}
		apply_replace(buffer, start, position, "")
		buffer.selections[entry.index] = {start, start}
	}
	buffer_refresh(buffer)
}

delete_forward :: proc(buffer: ^Buffer) {
	for entry in selections_descending(buffer) {
		position := buffer.selections[entry.index].head
		if position >= len(buffer.text) {
			continue
		}
		apply_replace(buffer, position, next_rune_offset(buffer.text[:], position), "")
		buffer.selections[entry.index] = {position, position}
	}
	buffer_refresh(buffer)
}

delete_word :: proc(buffer: ^Buffer, forward: bool) {
	for entry in selections_descending(buffer) {
		position := buffer.selections[entry.index].head
		low, high := position, position
		if forward {
			high = next_word_start(buffer.text[:], position, false)
			if high <= position {
				high = min(len(buffer.text), position + 1)
			}
		} else {
			low = previous_word_start(buffer.text[:], position, false)
			if low >= position {
				low = max(0, position - 1)
			}
		}
		if low == high {
			continue
		}
		apply_replace(buffer, low, high, "")
		buffer.selections[entry.index] = {low, low}
	}
	buffer_refresh(buffer)
}

enter_insert :: proc(editor: ^Editor, buffer: ^Buffer, at_end: bool) {
	buffer_snapshot(buffer)
	for &selection in buffer.selections {
		position := at_end ? range_high(buffer, selection) : range_low(selection)
		selection = {position, position}
	}
	editor.mode = .Insert
}

leave_insert :: proc(editor: ^Editor, buffer: ^Buffer) {
	buffer_commit(buffer)
	editor.mode = .Normal
	for &selection in buffer.selections {
		selection.anchor = selection.head
	}
	buffer_clamp_selections(buffer)
}

add_cursor :: proc(buffer: ^Buffer, below: bool) {
	primary := buffer_primary(buffer)^
	line := buffer_line_of(buffer, primary.head)
	column := primary.head - buffer.line_starts[line]
	target := line + (1 if below else -1)
	if target < 0 || target >= buffer_line_count(buffer) {
		return
	}
	start, end := buffer_line_bounds(buffer, target)
	position := clamp(start + column, start, max(start, end - 1))
	append(&buffer.selections, Range{position, position})
	buffer.primary = len(buffer.selections) - 1
}

find_character :: proc(buffer: ^Buffer, character: u8, forward: bool, till: bool, extend: bool) {
	for &selection in buffer.selections {
		origin := selection.head
		found := -1
		if forward {
			for index := origin + 1; index < len(buffer.text); index += 1 {
				if buffer.text[index] == '\n' {
					break
				}
				if buffer.text[index] == character {
					found = index
					break
				}
			}
			if found >= 0 && till {
				found -= 1
			}
		} else {
			for index := origin - 1; index >= 0; index -= 1 {
				if buffer.text[index] == '\n' {
					break
				}
				if buffer.text[index] == character {
					found = index
					break
				}
			}
			if found >= 0 && till {
				found += 1
			}
		}
		if found >= 0 {
			selection.head = found
			if !extend {
				selection.anchor = origin
			}
		}
	}
}

match_bracket :: proc(buffer: ^Buffer) {
	opens := "([{"
	closes := ")]}"
	for &selection in buffer.selections {
		position := clamp(selection.head, 0, max(0, len(buffer.text) - 1))
		if position >= len(buffer.text) {
			continue
		}
		character := buffer.text[position]
		open_index := strings.index_byte(opens, character)
		close_index := strings.index_byte(closes, character)
		if open_index >= 0 {
			depth := 0
			for index in position ..< len(buffer.text) {
				if buffer.text[index] == character {
					depth += 1
				} else if buffer.text[index] == closes[open_index] {
					depth -= 1
					if depth == 0 {
						selection.head = index
						selection.anchor = position
						break
					}
				}
			}
		} else if close_index >= 0 {
			depth := 0
			for index := position; index >= 0; index -= 1 {
				if buffer.text[index] == character {
					depth += 1
				} else if buffer.text[index] == opens[close_index] {
					depth -= 1
					if depth == 0 {
						selection.head = index
						selection.anchor = position
						break
					}
				}
			}
		}
	}
}

select_matches_in_selections :: proc(buffer: ^Buffer, pattern: string) {
	if pattern == "" {
		return
	}
	found := make([dynamic]Range, 0, 16)
	for selection in buffer.selections {
		low, high := range_low(selection), range_high(buffer, selection)
		haystack := string(buffer.text[low:high])
		cursor := 0
		for {
			hit := strings.index(haystack[cursor:], pattern)
			if hit < 0 {
				break
			}
			start := low + cursor + hit
			append(&found, Range{start, start + len(pattern) - 1})
			cursor += hit + max(1, len(pattern))
			if cursor > len(haystack) {
				break
			}
		}
	}
	if len(found) == 0 {
		delete(found)
		return
	}
	delete(buffer.selections)
	buffer.selections = found
	buffer.primary = 0
}

search_in_buffer :: proc(buffer: ^Buffer, pattern: string, forward: bool) -> bool {
	if pattern == "" {
		return false
	}
	text := string(buffer.text[:])
	origin := buffer_primary(buffer).head
	if forward {
		start := min(origin + 1, len(text))
		hit := strings.index(text[start:], pattern)
		if hit < 0 {
			hit = strings.index(text, pattern)
			start = 0
		}
		if hit < 0 {
			return false
		}
		goto_offset(buffer, start + hit, false)
	} else {
		hit := strings.last_index(text[:max(0, origin)], pattern)
		if hit < 0 {
			hit = strings.last_index(text, pattern)
		}
		if hit < 0 {
			return false
		}
		goto_offset(buffer, hit, false)
	}
	selection := buffer_primary(buffer)
	selection.anchor = selection.head
	selection.head = min(len(buffer.text) - 1, selection.head + len(pattern) - 1)
	return true
}
