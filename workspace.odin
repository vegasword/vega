package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
	index_start(&editor.index, full)
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
