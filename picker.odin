package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

Picker_Kind :: enum u8 {
	None,
	Files,
	Buffers,
	Symbols,
	GlobalSearch,
	References,
	Menu,
	Commands,
	Themes,
	Workspaces,
	Diagnostics,
	Processes,
}

Picker_Item :: struct {
	label:   string,
	lowered: string,
	detail:  string,
	path:    string,
	value:   string,
	command: Command,
	offset:  int,
	buffer:  int,
}

Picker :: struct {
	kind:        Picker_Kind,
	title:       string,
	prefix:      u8,
	query:       [dynamic]u8,
	items:       [dynamic]Picker_Item,
	filtered:    [dynamic]int,
	cursor:      int,
	scroll:      int,
	last_query:   string,
	search_capped: bool,
	warming:      bool,
	preview_due:  u64,
	saved_theme:  Theme,
	saved_buffer: int,
	saved_offset: int,
	saved_scroll: int,
}

fuzzy_score :: proc(candidate, lowered, query: string) -> (score: int, matched: bool) {
	if query == "" {
		return 0, true
	}
	if len(query) > len(lowered) {
		return 0, false
	}
	query_index := 0
	previous_hit := -2
	for index in 0 ..< len(lowered) {
		if query_index >= len(query) {
			break
		}
		if lowered[index] == query[query_index] {
			score += 10
			if index == previous_hit + 1 {
				score += 15
			}
			if index == 0 || candidate[index - 1] == '/' || candidate[index - 1] == '\\' || candidate[index - 1] == '_' {
				score += 8
			}
			previous_hit = index
			query_index += 1
		}
	}
	if query_index < len(query) {
		return 0, false
	}
	return score - len(candidate) / 8, true
}

path_split_query :: proc(query: string) -> (folder, tail: string) {
	cut := max(strings.last_index_byte(query, '/'), strings.last_index_byte(query, '\\'))
	if cut < 0 {
		return "", query
	}
	return query[:cut + 1], query[cut + 1:]
}

path_score :: proc(candidate, lowered, folder, tail: string) -> (score: int, matched: bool) {
	if len(folder) > len(lowered) {
		return 0, false
	}
	for index in 0 ..< len(folder) {
		wanted := folder[index] == '\\' ? '/' : folder[index]
		found := lowered[index] == '\\' ? '/' : lowered[index]
		if wanted != found {
			return 0, false
		}
	}
	rest := candidate[len(folder):]
	inner := lowered[len(folder):]
	if strings.index_byte(inner, '/') >= 0 || strings.index_byte(inner, '\\') >= 0 {
		score -= 20
	}
	inner_score, hit := fuzzy_score(rest, inner, tail)
	return score + inner_score + 40, hit
}

to_lower_byte :: proc(character: u8) -> u8 {
	return character + 32 if character >= 'A' && character <= 'Z' else character
}

picker_clear :: proc(picker: ^Picker) {
	for item in picker.items {
		delete(item.label)
		delete(item.lowered)
		delete(item.detail)
		delete(item.value)
		delete(item.path)
	}
	delete(picker.title)
	picker.title = ""
	delete(picker.last_query)
	picker.last_query = ""
	clear(&picker.items)
	clear(&picker.filtered)
	picker.cursor = 0
	picker.scroll = 0
}

picker_add :: proc(picker: ^Picker, item: Picker_Item) {
	entry := item
	entry.label = strings.clone(item.label)
	entry.lowered = strings.clone(item.label)
	lowered_bytes := transmute([]u8)entry.lowered
	for index in 0 ..< len(lowered_bytes) {
		lowered_bytes[index] = to_lower_byte(lowered_bytes[index])
	}
	entry.detail = strings.clone(item.detail)
	entry.value = strings.clone(item.value)
	entry.path = strings.clone(item.path)
	append(&picker.items, entry)
}

picker_open :: proc(editor: ^Editor, kind: Picker_Kind, name: string) {
	picker := &editor.picker
	started := time.tick_now()
	picker_clear(picker)
	clear(&picker.query)
	picker.kind = kind
	picker.prefix = 0
	picker.title = strings.clone(name)
	picker.saved_theme = editor.config.theme
	picker.saved_buffer = editor_view(editor).buffer
	picker.saved_offset = buffer_primary(editor_buffer(editor)).head
	picker.saved_scroll = editor_view(editor).scroll_line
	picker.search_capped = false
	picker.preview_due = 0

	switch kind {
	case .Files:
		for path in project_files(editor) {
			picker_add(picker, {label = path, path = strings.concatenate({editor.index.root, "/", path}, context.temp_allocator)})
		}
	case .Buffers:
		for buffer, position in editor.buffers {
			if buffer_hidden(buffer) {
				continue
			}
			picker_add(picker, {label = buffer.display, detail = (.Modified in buffer.flags) ? "Modified" : "", buffer = position})
		}
	case .Symbols:
		for symbol in editor.index.symbols {
			detail := fmt.tprintf("%v  %s", symbol.kind, project_relative(editor, editor.index.files[symbol.file].path))
			picker_add(picker, {label = symbol.name, detail = detail, path = editor.index.files[symbol.file].path, offset = symbol.offset})
		}
	case .Commands:
		for entry in ex_commands {
			picker_add(picker, {label = entry.name, detail = entry.help})
		}
	case .Themes:
		for name in theme_names(context.temp_allocator) {
			picker_add(picker, {label = name, detail = "Theme", value = name})
		}
	case .Workspaces:
		for root in workspace_list() {
			open, typing := workspace_spent(root)
			detail := fmt.tprintf("%s open, %s typing   %s", spent_label(open), spent_label(typing), root)
			picker_add(picker, {label = filename_of(root), detail = detail, value = root})
		}
	case .Processes:
		for job, position in background_jobs(editor) {
			picker_add(picker, {label = job.name, detail = job.kind, buffer = position})
		}
	case .Diagnostics:
		for entry, position in editor.diagnostics {
			detail := fmt.tprintf("%s  %s:%d", entry.warning ? "warning" : "error", filename_of(entry.path), entry.line)
			picker_add(picker, {label = entry.message, detail = detail, buffer = position})
		}
	case .Menu, .GlobalSearch, .References, .None:
	}
	log.infof("picker %v opened with %d items in %.2f ms", kind, len(picker.items), time.duration_milliseconds(time.tick_since(started)))
	picker_filter(editor)
}

filename_of :: proc(path: string) -> string {
	cut := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return path[cut + 1:]
}

editor_open_prefix :: proc(editor: ^Editor, prefix: u8, name: string) {
	editor.pending_prefix = prefix
	if !(.MenuHints in editor.config.options) {
		return
	}
	picker := &editor.picker
	picker_clear(picker)
	clear(&picker.query)
	picker.kind = .Menu
	picker.prefix = prefix
	picker.title = strings.clone(name)
	for chord, command in editor.keymap {
		if chord.prefix != prefix {
			continue
		}
		picker_add(picker, {label = fmt.tprintf("%-10s %v", chord_label(chord), command), detail = command_help[command], command = command})
	}
	slice.sort_by(picker.items[:], proc(a, b: Picker_Item) -> bool { return a.label < b.label })
	picker_filter(editor)
}

picker_add_locations :: proc(editor: ^Editor, locations: []Location, title: string) {
	picker := &editor.picker
	picker_clear(picker)
	clear(&picker.query)
	picker.kind = .References
	picker.title = strings.clone(title)
	for location in locations {
		file := editor.index.files[location.file]
		line := 1 + count_byte(file.text, location.offset, '\n')
		picker_add(picker, {
			label  = trimmed_line_around(file.text, location.offset),
			detail = fmt.tprintf("%s:%d", project_relative(editor, file.path), line),
			path   = file.path,
			offset = location.offset,
		})
	}
	picker_filter(editor)
}

picker_filter :: proc(editor: ^Editor) {
	picker := &editor.picker
	query := string(picker.query[:])
	started := time.tick_now()
	lowered_query := strings.to_lower(query, context.temp_allocator)
	narrowing := picker.last_query != "" && strings.has_prefix(query, picker.last_query)
	considered := 0

	if picker.kind == .GlobalSearch {
		narrowing = narrowing && len(picker.last_query) >= 2
		if narrowing && !picker.search_capped {
			kept := make([dynamic]Picker_Item, 0, len(picker.filtered), context.temp_allocator)
			for index in picker.filtered {
				item := picker.items[index]
				text := editor.index.files[item.buffer].text
				considered += 1
				if strings.has_prefix(string(text[item.offset:]), query) {
					append(&kept, item)
				}
			}
			picker_retain(picker, kept[:])
		} else {
			picker_clear(picker)
			if len(query) >= 2 {
				for file, file_index in editor.index.files {
					cursor := 0
					counted := 0
					line := 1
					for len(picker.items) < 500 {
						hit := strings.index(string(file.text[cursor:]), query)
						if hit < 0 {
							break
						}
						offset := cursor + hit
						considered += 1
						line += count_byte(file.text[counted:offset], offset - counted, '\n')
						counted = offset
						picker_add(picker, {
							label  = trimmed_line_around(file.text, offset),
							detail = fmt.tprintf("%s:%d", project_relative(editor, file.path), line),
							path   = file.path,
							offset = offset,
							buffer = file_index,
						})
						cursor = offset + len(query)
					}
				}
			}
			clear(&picker.filtered)
			for index in 0 ..< len(picker.items) {
				append(&picker.filtered, index)
			}
		}
		picker.search_capped = len(picker.items) >= 500
	} else {
		Scored :: struct {
			score: int,
			index: int,
		}
		folder, tail := path_split_query(lowered_query)
		by_folder := picker.kind == .Files && folder != ""
		pool := narrowing ? slice.clone(picker.filtered[:], context.temp_allocator) : nil
		scored := make([dynamic]Scored, 0, narrowing ? len(pool) : len(picker.items), context.temp_allocator)
		clear(&picker.filtered)
		if narrowing {
			for index in pool {
				considered += 1
				item := picker.items[index]
				score, matched := fuzzy_score(item.label, item.lowered, lowered_query)
				if by_folder {
					score, matched = path_score(item.label, item.lowered, folder, tail)
				}
				if matched {
					append(&scored, Scored{score, index})
				}
			}
		} else {
			for item, index in picker.items {
				considered += 1
				score, matched := fuzzy_score(item.label, item.lowered, lowered_query)
				if by_folder {
					score, matched = path_score(item.label, item.lowered, folder, tail)
				}
				if matched {
					append(&scored, Scored{score, index})
				}
			}
		}
		slice.sort_by(scored[:], proc(a, b: Scored) -> bool { return a.score != b.score ? a.score > b.score : a.index < b.index })
		for entry in scored {
			append(&picker.filtered, entry.index)
		}
		if picker.kind == .Workspaces && query == "" {
			clear(&picker.filtered)
			for index in 0 ..< len(picker.items) {
				append(&picker.filtered, index)
			}
		}
	}

	delete(picker.last_query)
	picker.last_query = strings.clone(query)
	picker.cursor = clamp(picker.cursor, 0, max(0, len(picker.filtered) - 1))
	picker_preview(editor)
	log.debugf("picker filtered %q to %d of %d, %d considered, %.2f ms", query, len(picker.filtered), len(picker.items), considered, time.duration_milliseconds(time.tick_since(started)))
}

picker_retain :: proc(picker: ^Picker, survivors: []Picker_Item) {
	keeping := make(map[rawptr]bool, len(survivors), context.temp_allocator)
	for item in survivors {
		keeping[raw_data(item.label)] = true
	}
	for item in picker.items {
		if !keeping[raw_data(item.label)] {
			delete(item.label)
			delete(item.lowered)
			delete(item.detail)
			delete(item.value)
			delete(item.path)
		}
	}
	clear(&picker.items)
	clear(&picker.filtered)
	for item in survivors {
		append(&picker.items, item)
		append(&picker.filtered, len(picker.items) - 1)
	}
}

picker_selected :: proc(picker: ^Picker) -> (Picker_Item, bool) {
	if len(picker.filtered) == 0 {
		return {}, false
	}
	return picker.items[picker.filtered[clamp(picker.cursor, 0, len(picker.filtered) - 1)]], true
}

PREVIEW_DELAY_MS :: 90

picker_preview :: proc(editor: ^Editor) {
	if item, found := picker_selected(&editor.picker); found && item.path != "" {
		if _, cached := preview_cached(item.path); cached {
			picker_preview_apply(editor)
			return
		}
	}
	editor.picker.preview_due = u64(sdl.GetTicks()) + PREVIEW_DELAY_MS
}

picker_preview_apply :: proc(editor: ^Editor) {
	picker := &editor.picker
	picker.preview_due = 0
	started := time.tick_now()
	item, found := picker_selected(picker)
	if !found {
		return
	}
	switch picker.kind {
	case .Themes:
		if colors, exists := theme_load(item.value); exists {
			editor.config.theme = colors
		}
	case .Files, .Symbols, .GlobalSearch, .References:
		if item.path == "" || !previewable(item.path) {
			return
		}
		preview_show(editor, item.path, item.offset)
		log.debugf("previewed %s in %.2f ms", filename_of(item.path), time.duration_milliseconds(time.tick_since(started)))
	case .Diagnostics:
		diagnostic_show(editor, item.buffer)
	case .Buffers, .Commands, .Menu, .Workspaces, .Processes, .None:
	}
}

picker_close :: proc(editor: ^Editor, restore: bool) {
	picker := &editor.picker
	if restore {
		if picker.kind == .Themes {
			editor.config.theme = picker.saved_theme
		}
		wandered := false
		switch picker.kind {
		case .Files, .Symbols, .GlobalSearch, .References, .Diagnostics:
			wandered = true
		case .Buffers, .Commands, .Menu, .Themes, .Workspaces, .Processes, .None:
		}
		preview_discard(editor)
		if wandered {
			view := editor_view(editor)
			view.buffer = clamp(picker.saved_buffer, 0, len(editor.buffers) - 1)
			view.scroll_line = picker.saved_scroll
			goto_offset(editor_buffer(editor), picker.saved_offset, false)
			log.debugf("picker left the buffer as it was, back to %d", view.buffer)
		}
	}
	picker.preview_due = 0
	picker.kind = .None
	editor.pending_prefix = 0
}

picker_text :: proc(editor: ^Editor, text: string) {
	picker := &editor.picker
	if picker.kind == .Menu {
		if picker.prefix == 'g' && text[0] >= '0' && text[0] <= '9' {
			picker_close(editor, false)
			prompt_open(editor, .GotoLine)
			append(&editor.prompt_input, text[0])
			return
		}
		if command, found := editor.keymap[Chord{picker.prefix, text[0], {}}]; found {
			picker_close(editor, false)
			execute_command(editor, command, 0)
			return
		}
	}
	append(&picker.query, text)
	picker.cursor = 0
	picker.scroll = 0
	picker_filter(editor)
}

picker_key :: proc(editor: ^Editor, key: sdl.Keycode, shift, control: bool) {
	picker := &editor.picker
	rows := picker_rows(editor)
	switch key {
	case sdl.K_ESCAPE:
		picker_close(editor, true)
	case sdl.K_RETURN:
		picker_confirm(editor)
	case sdl.K_BACKSPACE:
		if len(picker.query) > 0 {
			resize(&picker.query, len(picker.query) - 1)
			picker.cursor = 0
			picker.scroll = 0
			picker_filter(editor)
		}
	case sdl.K_TAB:
		picker_move(editor, shift ? -1 : 1)
	case sdl.K_DOWN:
		picker_move(editor, 1)
	case sdl.K_UP:
		picker_move(editor, -1)
	case sdl.K_PAGEDOWN:
		picker_move(editor, rows)
	case sdl.K_PAGEUP:
		picker_move(editor, -rows)
	case sdl.K_DELETE:
		if picker.kind == .Processes {
			if item, chosen := picker_selected(picker); chosen {
				jobs := background_jobs(editor)
				if item.buffer < len(jobs) {
					background_kill(jobs[item.buffer])
				}
			}
			picker_close(editor, false)
		}
	}
}

picker_move :: proc(editor: ^Editor, delta: int) {
	picker := &editor.picker
	picker.cursor = clamp(picker.cursor + delta, 0, max(0, len(picker.filtered) - 1))
	picker_preview(editor)
}

picker_confirm :: proc(editor: ^Editor) {
	picker := &editor.picker
	query := strings.clone(string(picker.query[:]), context.temp_allocator)
	item, found := picker_selected(picker)
	kind := picker.kind
	if !found && kind != .Commands {
		picker_close(editor, true)
		return
	}
	picker_close(editor, false)
	preview_discard(editor)
	editor_view(editor).buffer = clamp(picker.saved_buffer, 0, len(editor.buffers) - 1)
	log.infof("picker %v confirmed %s", kind, item.label)

	switch kind {
	case .Menu:
		execute_command(editor, item.command, 0)
	case .Commands:
		run_command(editor, strings.contains(query, " ") || !found ? query : item.label)
	case .Themes:
		delete(editor.config.theme_name)
		editor.config.theme_name = strings.clone(item.value)
		editor.flags += {.ConfigDirty}
		log.infof("theme %s", item.value)
	case .Buffers:
		editor_view(editor).buffer = clamp(item.buffer, 0, len(editor.buffers) - 1)
	case .Workspaces:
		workspace_open(editor, item.value)
	case .Diagnostics:
		diagnostic_show(editor, item.buffer)
	case .Processes:
		notify("Delete kills the one you pick")
	case .Files, .Symbols, .GlobalSearch, .References:
		jump_push(editor)
		editor_open_file(editor, item.path)
		if item.offset > 0 {
			goto_offset(editor_buffer(editor), item.offset, false)
			editor_center_view(editor)
		}
	case .None:
	}
}

previewable :: proc(path: string) -> bool {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".exe", ".dll", ".lib", ".obj", ".pdb", ".zip", ".7z", ".gz", ".ttf", ".otf", ".ico", ".bin", ".o", ".a":
		return false
	}
	if info, error := os.stat(path, context.temp_allocator); error == nil && info.size > 4 << 20 {
		return false
	}
	return true
}

project_relative :: proc(editor: ^Editor, path: string) -> string {
	if strings.has_prefix(path, editor.index.root) {
		return strings.trim_left(path[len(editor.index.root):], "/\\")
	}
	return path
}
