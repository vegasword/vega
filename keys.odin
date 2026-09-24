package vega

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

Pending_Find :: enum u8 {
	None,
	FindForward,
	TillForward,
	FindBackward,
	TillBackward,
}

Prompt_Kind :: enum u8 {
	None,
	Search,
	SearchBackward,
	Rename,
	SelectMatches,
	CommandLine,
	GotoLine,
	UserName,
}

handle_text :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 {
		return
	}
	workspace_typed()
	sfx_click(editor)
	if editor.hover.open {
		hover_close(editor)
	}
	if editor.picker.kind != .None {
		picker_text(editor, text)
		return
	}
	if editor.settings.open {
		settings_text(editor, text)
		return
	}
	if editor.prompt != .None {
		if editor.prompt == .GotoLine {
			for character in text {
				if character < '0' || character > '9' {
					return
				}
			}
		}
		editor.prompt_cursor = clamp(editor.prompt_cursor, 0, len(editor.prompt_input))
		inject_at(&editor.prompt_input, editor.prompt_cursor, text)
		editor.prompt_cursor += len(text)
		prompt_preview(editor)
		return
	}
	buffer := editor_buffer(editor)
	if editor.mode == .Insert {
		insert_in_insert_mode(editor, buffer, text)
		editor_ensure_visible(editor)
		return
	}
	normal_text(editor, buffer, text[0])
}

Pair :: struct {
	opener: u8,
	closer: u8,
	option: Option,
}

pairs := []Pair {
	{'(', ')', .PairParens},
	{'[', ']', .PairBrackets},
	{'{', '}', .PairBraces},
	{'"', '"', .PairQuotes},
	{'\'', '\'', .PairSingles},
	{'`', '`', .PairBackticks},
}

pair_for :: proc(editor: ^Editor, character: u8) -> (Pair, bool) {
	for pair in pairs {
		if pair.opener == character && pair.option in editor.config.options {
			return pair, true
		}
	}
	return {}, false
}

pair_closes :: proc(editor: ^Editor, character: u8) -> bool {
	for pair in pairs {
		if pair.closer == character && pair.option in editor.config.options {
			return true
		}
	}
	return false
}

insert_in_insert_mode :: proc(editor: ^Editor, buffer: ^Buffer, text: string) {
	if !(.AutoPairs in editor.config.options) || len(text) != 1 {
		insert_text(buffer, text)
		return
	}
	head := buffer_primary(buffer).head
	next := head < len(buffer.text) ? buffer.text[head] : 0
	if next == text[0] && pair_closes(editor, text[0]) {
		move_horizontal(buffer, 1, false)
		return
	}
	pair, paired := pair_for(editor, text[0])
	if paired && (next == 0 || next == '\n' || next == ' ' || next == ')' || next == ']' || next == '}') {
		insert_text(buffer, text)
		insert_text(buffer, string([]u8{pair.closer}))
		move_horizontal(buffer, -1, false)
		return
	}
	insert_text(buffer, text)
}

normal_text :: proc(editor: ^Editor, buffer: ^Buffer, key: u8) {
	if (.PendingReplace in editor.flags) {
		editor.flags -= {.PendingReplace}
		replace_characters(buffer, key)
		return
	}
	if editor.pending_find != .None {
		forward := editor.pending_find == .FindForward || editor.pending_find == .TillForward
		till := editor.pending_find == .TillForward || editor.pending_find == .TillBackward
		editor.pending_find = .None
		editor.last_find = {key, forward, till}
		find_character(buffer, key, forward, till, editor.mode == .Select)
		editor_ensure_visible(editor)
		return
	}
	if editor.pending_prefix != 0 {
		prefix := editor.pending_prefix
		editor.pending_prefix = 0
		if prefix == 'g' && key >= '0' && key <= '9' {
			editor.picker.kind = .None
			prompt_open(editor, .GotoLine)
			append(&editor.prompt_input, key)
			editor.count = 0
			return
		}
		if command, found := editor.keymap[Chord{prefix, key, {}}]; found {
			execute_command(editor, command, editor.count)
		}
		editor.count = 0
		return
	}
	if key >= '1' && key <= '9' || (key == '0' && editor.count > 0) {
		editor.count = editor.count * 10 + int(key - '0')
		return
	}
	count := editor.count
	editor.count = 0
	if command, found := editor.keymap[Chord{0, key, {}}]; found {
		execute_command(editor, command, count)
		return
	}
	log.debugf("unbound key %c", key)
}

handle_key :: proc(editor: ^Editor, key: sdl.Keycode, mods: sdl.Keymod, scancode := sdl.Scancode.UNKNOWN) {
	control := .LCTRL in mods || .RCTRL in mods
	shift := .LSHIFT in mods || .RSHIFT in mods
	alt := .LALT in mods || .RALT in mods

	if key == sdl.K_F11 || (alt && key == sdl.K_RETURN) {
		execute_command(editor, .ToggleFullscreen, 1)
		return
	}
	modifier_only := key == sdl.K_LSHIFT || key == sdl.K_RSHIFT || key == sdl.K_LCTRL || key == sdl.K_RCTRL || key == sdl.K_LALT || key == sdl.K_RALT
	if !modifier_only && (key == sdl.K_BACKSPACE || key == sdl.K_RETURN || key == sdl.K_TAB || key == sdl.K_DELETE || key == sdl.K_ESCAPE) {
		sfx_click(editor)
	}
	if editor.hover.open && !modifier_only {
		hover_close(editor)
	}
	if editor.output.open && key == sdl.K_ESCAPE {
		output_close(editor)
		return
	}

	if editor.picker.kind != .None {
		picker_key(editor, key, shift, control)
		return
	}
	if editor.settings.open {
		settings_key(editor, key, shift, control, alt)
		return
	}

	if editor.prompt != .None {
		editor.prompt_cursor = clamp(editor.prompt_cursor, 0, len(editor.prompt_input))
		if control && (key == sdl.K_BACKSPACE || key == sdl.K_DELETE) {
			prompt_delete_word(editor, key == sdl.K_DELETE)
			return
		}
		switch key {
		case sdl.K_ESCAPE:
			prompt_restore(editor)
			editor.prompt = .None
			clear(&editor.prompt_input)
		case sdl.K_RETURN:
			prompt_confirm(editor)
			editor_ensure_visible(editor)
		case sdl.K_BACKSPACE:
			if editor.prompt_cursor > 0 {
				ordered_remove(&editor.prompt_input, editor.prompt_cursor - 1)
				editor.prompt_cursor -= 1
				prompt_preview(editor)
			}
		case sdl.K_DELETE:
			if editor.prompt_cursor < len(editor.prompt_input) {
				ordered_remove(&editor.prompt_input, editor.prompt_cursor)
				prompt_preview(editor)
			}
		case sdl.K_LEFT:
			editor.prompt_cursor = max(0, editor.prompt_cursor - 1)
		case sdl.K_RIGHT:
			editor.prompt_cursor = min(len(editor.prompt_input), editor.prompt_cursor + 1)
		case sdl.K_HOME:
			editor.prompt_cursor = 0
		case sdl.K_END:
			editor.prompt_cursor = len(editor.prompt_input)
		}
		return
	}

	if control && (key == sdl.K_BACKSPACE || key == sdl.K_DELETE) {
		buffer := editor_buffer(editor)
		if !(.ReadOnly in buffer.flags) {
			buffer_snapshot(buffer)
			delete_word(buffer, key == sdl.K_DELETE)
			editor_ensure_visible(editor)
		}
		return
	}

	if control || alt {
		letters := [4]u8{}
		letters[0] = u8(key) if key >= 32 && key < 127 else 0
		switch key {
		case sdl.K_KP_MINUS:
			letters[0] = '-'
		case sdl.K_KP_PLUS:
			letters[0] = '+'
		case sdl.K_KP_0:
			letters[0] = '0'
		case sdl.K_KP_MULTIPLY:
			letters[0] = '*'
		case sdl.K_KP_DIVIDE:
			letters[0] = '/'
		}
		if scancode != .UNKNOWN {
			plain := sdl.GetKeyFromScancode(scancode, {}, false)
			shifted := sdl.GetKeyFromScancode(scancode, {.LSHIFT}, false)
			letters[1] = u8(plain) if plain >= 32 && plain < 127 else 0
			letters[2] = u8(shifted) if shifted >= 32 && shifted < 127 else 0
		}
		mods: Key_Modifiers
		if control {
			mods += {.Ctrl}
		}
		if alt {
			mods += {.Alt}
		}
		if shift {
			mods += {.Shift}
		}
		for letter in letters {
			if letter == 0 {
				continue
			}
			command, found := editor.keymap[Chord{editor.pending_prefix, letter, mods}]
			if !found && shift {
				command, found = editor.keymap[Chord{editor.pending_prefix, letter, mods - {.Shift}}]
			}
			if found {
				editor.pending_prefix = 0
				execute_command(editor, command, editor.count)
				editor.count = 0
				return
			}
		}
		log.debugf("unbound chord: %s %s (keycode %v, layout %c%c)", modifiers_label(mods), sdl.GetKeyName(key), key, letters[1] == 0 ? ' ' : rune(letters[1]), letters[2] == 0 ? ' ' : rune(letters[2]))
		return
	}

	buffer := editor_buffer(editor)
	switch key {
	case sdl.K_ESCAPE:
		if editor.mode == .Insert {
			leave_insert(editor, buffer)
		} else {
			editor.mode = .Normal
			editor.count = 0
			editor.pending_find = .None
			editor.flags -= {.PendingReplace}
			buffer_collapse_to_primary(buffer)
		}
	case sdl.K_TAB:
		if editor.mode == .Insert {
			insert_text(buffer, strings.repeat(" ", editor.config.indent_width, context.temp_allocator))
		} else {
			jump_to(editor, shift ? -1 : 1)
		}
	case sdl.K_BACKSPACE:
		if editor.mode == .Insert {
			delete_backward(editor, buffer)
		} else {
			move_horizontal(buffer, -1, editor.mode == .Select)
		}
	case sdl.K_DELETE:
		if .ReadOnly in buffer.flags {
			break
		}
		if editor.mode == .Insert {
			buffer_snapshot(buffer)
			delete_forward(buffer)
		} else {
			delete_selections(editor, buffer, false)
		}
	case sdl.K_RETURN:
		if editor.mode == .Insert {
			insert_newline(editor, buffer)
		}
	case sdl.K_LEFT:
		if (.ArrowKeys in editor.config.options) {move_horizontal(buffer, -1, editor.mode == .Select)}
	case sdl.K_RIGHT:
		if (.ArrowKeys in editor.config.options) {move_horizontal(buffer, 1, editor.mode == .Select)}
	case sdl.K_UP:
		if (.ArrowKeys in editor.config.options) {move_vertical(buffer, -1, editor.mode == .Select)}
	case sdl.K_DOWN:
		if (.ArrowKeys in editor.config.options) {move_vertical(buffer, 1, editor.mode == .Select)}
	case sdl.K_PAGEDOWN:
		move_vertical(buffer, view_visible_lines(editor, editor_view(editor)), editor.mode == .Select)
	case sdl.K_PAGEUP:
		move_vertical(buffer, -view_visible_lines(editor, editor_view(editor)), editor.mode == .Select)
	case sdl.K_HOME:
		goto_line_edge(buffer, .Start, editor.mode == .Select)
	case sdl.K_END:
		goto_line_edge(buffer, .End, editor.mode == .Select)
	}
	editor_ensure_visible(editor)
}

prompt_open :: proc(editor: ^Editor, kind: Prompt_Kind) {
	editor.prompt = kind
	clear(&editor.prompt_input)
	editor.prompt_origin = buffer_primary(editor_buffer(editor)).head
	clear(&editor.prompt_selections)
	append(&editor.prompt_selections, ..editor_buffer(editor).selections[:])
	if kind == .Rename {
		word, _ := word_at(editor_buffer(editor).text[:], editor.prompt_origin)
		append(&editor.prompt_input, word)
	}
	editor.prompt_cursor = len(editor.prompt_input)
	log.debugf("prompt %v opened", kind)
}

prompt_delete_word :: proc(editor: ^Editor, forward: bool) {
	input := editor.prompt_input[:]
	cursor := editor.prompt_cursor
	edge := cursor
	if forward {
		for edge < len(input) && !is_word_byte(input[edge]) {
			edge += 1
		}
		for edge < len(input) && is_word_byte(input[edge]) {
			edge += 1
		}
		remove_range(&editor.prompt_input, cursor, edge)
	} else {
		for edge > 0 && !is_word_byte(input[edge - 1]) {
			edge -= 1
		}
		for edge > 0 && is_word_byte(input[edge - 1]) {
			edge -= 1
		}
		remove_range(&editor.prompt_input, edge, cursor)
		editor.prompt_cursor = edge
	}
	prompt_preview(editor)
}

prompt_restore :: proc(editor: ^Editor) {
	if len(editor.prompt_selections) == 0 {
		return
	}
	buffer := editor_buffer(editor)
	clear(&buffer.selections)
	append(&buffer.selections, ..editor.prompt_selections[:])
	buffer.primary = 0
}

prompt_preview :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	switch editor.prompt {
	case .Search, .SearchBackward:
		goto_offset(buffer, editor.prompt_origin, false)
		search_in_buffer(buffer, string(editor.prompt_input[:]), editor.prompt == .Search)
		editor_center_view(editor)
	case .SelectMatches:
		prompt_restore(editor)
		select_matches_in_selections(buffer, string(editor.prompt_input[:]))
		editor_ensure_visible(editor)
		log.debugf("select preview %q matches %d", string(editor.prompt_input[:]), len(buffer.selections))
	case .GotoLine:
		line := clamp(int_of(string(editor.prompt_input[:])) - 1, 0, buffer_line_count(buffer) - 1)
		start, _ := buffer_line_bounds(buffer, line)
		goto_offset(buffer, start, false)
		editor_center_view(editor)
	case .Rename, .CommandLine, .UserName, .None:
	}
}

prompt_confirm :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	input := strings.clone(string(editor.prompt_input[:]), context.temp_allocator)
	kind := editor.prompt
	editor.prompt = .None
	clear(&editor.prompt_input)

	switch kind {
	case .Search, .SearchBackward:
		delete(editor.search_pattern)
		editor.search_pattern = strings.clone(input)
		editor_center_view(editor)
	case .SelectMatches:
		prompt_restore(editor)
		select_matches_in_selections(buffer, input)
		log.debugf("%d selections", len(buffer.selections))
	case .Rename:
		editor_apply_rename(editor, input)
	case .CommandLine:
		run_command(editor, input)
	case .UserName:
		delete(editor.config.user_name)
		editor.config.user_name = strings.clone(input)
		editor.flags += {.ConfigDirty}
		notify(fmt.tprintf("Comments will be signed %s", input))
	case .GotoLine:
		jump_push(editor)
		line := clamp(int_of(input) - 1, 0, buffer_line_count(buffer) - 1)
		start, _ := buffer_line_bounds(buffer, line)
		goto_offset(buffer, start, false)
		editor_center_view(editor)
		log.debugf("line %d", line + 1)
	case .None:
	}
}
