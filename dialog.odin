package vega

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

Dialog_Purpose :: enum u8 {
	Open,
	Save,
	Workspace,
}

dialog_results: [dynamic]string
dialog_open: bool
dialog_purpose: Dialog_Purpose
dialog_target: ^Buffer

dialog_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = dialog_context
	dialog_open = false
	if filelist == nil {
		log.error("the file dialog failed")
		return
	}
	for index := 0; filelist[index] != nil; index += 1 {
		append(&dialog_results, strings.clone(string(filelist[index])))
	}
	log.infof("file dialog returned %d path(s)", len(dialog_results))
}

save_file_dialog :: proc(editor: ^Editor, buffer: ^Buffer) {
	if dialog_open {
		return
	}
	dialog_open = true
	dialog_purpose = .Save
	dialog_target = buffer
	filters := []sdl.DialogFileFilter{{"every file", "*"}}
	log.info("opening the system save dialog for the scratch buffer")
	sdl.ShowSaveFileDialog(dialog_callback, editor, editor.window, raw_data(filters), i32(len(filters)), nil)
}

open_file_dialog :: proc(editor: ^Editor) {
	if dialog_open {
		return
	}
	dialog_open = true
	dialog_purpose = .Open
	filters := []sdl.DialogFileFilter{{"every file", "*"}}
	log.info("opening the system file dialog")
	sdl.ShowOpenFileDialog(dialog_callback, editor, editor.window, raw_data(filters), i32(len(filters)), nil, true)
}

open_folder_dialog :: proc(editor: ^Editor) {
	if dialog_open {
		return
	}
	dialog_open = true
	dialog_purpose = .Workspace
	log.info("opening the system folder dialog for a workspace")
	sdl.ShowOpenFolderDialog(dialog_callback, editor, editor.window, nil, false)
}

dialog_drain :: proc(editor: ^Editor) {
	if len(dialog_results) == 0 {
		return
	}
	if dialog_purpose == .Workspace {
		dialog_purpose = .Open
		workspace_open(editor, dialog_results[0])
		for path in dialog_results {
			delete(path)
		}
		clear(&dialog_results)
		return
	}
	if dialog_purpose == .Save {
		buffer := dialog_target
		dialog_target = nil
		dialog_purpose = .Open
		if buffer != nil {
			delete(buffer.path)
			delete(buffer.display)
			buffer.path = strings.clone(dialog_results[0])
			buffer.display = strings.clone(dialog_results[0])
			buffer.language = language_of_path(buffer.path)
			buffer.kind = content_kind_of_path(buffer.path)
			buffer_refresh(buffer)
			written := buffer_save(editor, buffer)
			notify(written ? fmt.tprintf("Wrote %s", filename_of(buffer.display)) : "Write failed", written ? .Info : .Error)
			project_files_invalidate()
			editor.flags += {.SessionDirty}
		}
		for path in dialog_results {
			delete(path)
		}
		clear(&dialog_results)
		return
	}
	for path in dialog_results {
		editor_open_file(editor, path)
		delete(path)
	}
	clear(&dialog_results)
	editor_ensure_visible(editor)
}
