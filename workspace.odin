package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

workspaces_path: string

workspace_session_path :: proc(root: string, allocator := context.temp_allocator) -> string {
	hash: u32 = 2166136261
	for index in 0 ..< len(root) {
		hash = (hash ~ u32(to_lower_byte(root[index]))) * 16777619
	}
	folder := strings.concatenate({pref_path, "sessions"}, context.temp_allocator)
	os.make_directory(folder)
	name := filename_of(root)
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, folder)
	strings.write_byte(&builder, '/')
	for index in 0 ..< len(name) {
		character := name[index]
		letter := (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9')
		strings.write_byte(&builder, letter ? character : '_')
	}
	fmt.sbprintf(&builder, "-%08x.session", hash)
	return strings.to_string(builder)
}

workspace_list :: proc(allocator := context.temp_allocator) -> []string {
	data, error := os.read_entire_file(workspaces_path, context.temp_allocator)
	if error != nil {
		return nil
	}
	roots := make([dynamic]string, 0, 16, allocator)
	remaining := strings.trim_prefix(string(data), "\xef\xbb\xbf")
	for line in strings.split_lines_iterator(&remaining) {
		root := strings.trim_space(line)
		if root != "" && os.exists(root) {
			append(&roots, strings.clone(root, allocator))
		}
	}
	return roots[:]
}

workspace_prune :: proc() {
	data, error := os.read_entire_file(workspaces_path, context.temp_allocator)
	if error != nil {
		return
	}
	kept := workspace_list()
	lines := 0
	remaining := strings.trim_prefix(string(data), "\xef\xbb\xbf")
	for line in strings.split_lines_iterator(&remaining) {
		if strings.trim_space(line) != "" {
			lines += 1
		}
	}
	if lines == len(kept) {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	for root in kept {
		fmt.sbprintf(&builder, "%s\n", root)
	}
	if os.write_entire_file(workspaces_path, transmute([]u8)strings.to_string(builder)) != nil {
		log.error("could not write the workspace list")
		return
	}
	log.infof("dropped %d workspace(s) that no longer exist", lines - len(kept))
}

workspace_remember :: proc(root: string) {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "%s\n", root)
	for known in workspace_list() {
		if !strings.equal_fold(known, root) {
			fmt.sbprintf(&builder, "%s\n", known)
		}
	}
	if os.write_entire_file(workspaces_path, transmute([]u8)strings.to_string(builder)) != nil {
		log.error("could not write the workspace list")
	}
}

workspace_due: u64

Workspace_Clock :: struct {
	open:    f64,
	typing:  f64,
	stamped: u64,
}

workspace_clock: Workspace_Clock

workspace_tick :: proc(delta_time: f32) {
	workspace_clock.open += f64(delta_time)
	if u64(sdl.GetTicks()) < workspace_clock.stamped + 2000 {
		workspace_clock.typing += f64(delta_time)
	}
}

workspace_typed :: proc() {
	workspace_clock.stamped = u64(sdl.GetTicks())
}

workspace_clock_load :: proc(root: string) {
	workspace_clock = {}
	data, error := os.read_entire_file(workspace_clock_path(root), context.temp_allocator)
	if error != nil {
		return
	}
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) >= 2 {
		workspace_clock.open = f64(parse_number(fields[0]))
		workspace_clock.typing = f64(parse_number(fields[1]))
	}
}

workspace_clock_save :: proc(root: string) {
	text := fmt.tprintf("%.1f %.1f\n", workspace_clock.open, workspace_clock.typing)
	if os.write_entire_file(workspace_clock_path(root), transmute([]u8)text) != nil {
		log.debug("the workspace clock could not be written")
	}
}

workspace_clock_path :: proc(root: string, allocator := context.temp_allocator) -> string {
	session := workspace_session_path(root, context.temp_allocator)
	return strings.concatenate({session[:len(session) - len(".session")], ".clock"}, allocator)
}

workspace_spent :: proc(root: string) -> (open, typing: f64) {
	if root == workspace_current {
		return workspace_clock.open, workspace_clock.typing
	}
	data, error := os.read_entire_file(workspace_clock_path(root), context.temp_allocator)
	if error != nil {
		return 0, 0
	}
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) < 2 {
		return 0, 0
	}
	return f64(parse_number(fields[0])), f64(parse_number(fields[1]))
}

workspace_current: string

spent_label :: proc(seconds: f64, allocator := context.temp_allocator) -> string {
	hours := int(seconds) / 3600
	minutes := (int(seconds) % 3600) / 60
	if hours > 0 {
		return fmt.aprintf("%dh%02d", hours, minutes, allocator = allocator)
	}
	return fmt.aprintf("%dm", max(1, minutes), allocator = allocator)
}

workspace_poll :: proc(editor: ^Editor) {
	if watch_taken() {
		workspace_due = u64(sdl.GetTicks()) + 400
	}
	if workspace_due == 0 {
		return
	}
	if u64(sdl.GetTicks()) < workspace_due || index_job != nil {
		return
	}
	workspace_due = 0
	project_files_invalidate()
	index_start(&editor.index, editor.index.root)
	for buffer in editor.buffers {
		if buffer.path == "" || (.Modified in buffer.flags) || buffer_hidden(buffer) {
			continue
		}
		if modified, ok := scan_stat(buffer.path); ok && modified != buffer.modified {
			editor_reload(editor, buffer)
		}
	}
	log.debug("the workspace changed on disk, reindexing")
}

workspace_pick :: proc(editor: ^Editor) {
	workspace_prune()
	if len(workspace_list()) == 0 {
		notify("Pick a folder to make it a workspace")
		open_folder_dialog(editor)
		return
	}
	picker_open(editor, .Workspaces, "Workspace")
}

workspace_open :: proc(editor: ^Editor, root: string) {
	full, error := filepath.abs(root, context.temp_allocator)
	if error != nil {
		full = root
	}
	if !os.exists(full) {
		notify("That workspace no longer exists")
		return
	}
	if strings.equal_fold(full, editor.index.root) {
		workspace_remember(full)
		notify(fmt.tprintf("Workspace %s", filename_of(full)))
		return
	}
	session_save(editor)
	if os.set_working_directory(full) != nil {
		notify("Could not enter that folder")
		return
	}
	workspace_clock_save(editor.index.root)
	index_start(&editor.index, full)
	delete(workspace_current)
	workspace_current = strings.clone(full)
	workspace_clock_load(full)
	preview_cache_clear()
	for buffer in editor.buffers {
		buffer_destroy(buffer)
	}
	clear(&editor.buffers)
	for &view in editor.views {
		view.buffer = 0
		view.last_buffer = nil
	}
	if !session_restore(editor) {
		append(&editor.buffers, buffer_create(editor, ""))
	}
	project_files(editor)
	workspace_remember(full)
	editor.flags += {.SessionDirty}
	notify(fmt.tprintf("Workspace %s", filename_of(full)))
	log.infof("workspace switched to %s with %d buffer(s)", full, len(editor.buffers))
}
