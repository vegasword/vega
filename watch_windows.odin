#+build windows
package vega

import "base:intrinsics"
import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import win "core:sys/windows"

WATCH_BUFFER :: 64 << 10

Watcher :: struct {
	root:    string,
	handle:  win.HANDLE,
	worker:  ^thread.Thread,
	touched: bool,
	stop:    bool,
}

watcher: ^Watcher

watch_worker :: proc(worker: ^thread.Thread) {
	watch := (^Watcher)(worker.data)
	buffer := make([]u8, WATCH_BUFFER)
	defer delete(buffer)
	for !intrinsics.atomic_load(&watch.stop) {
		written: win.DWORD
		filter := win.DWORD(win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_SIZE)
		if !win.ReadDirectoryChangesW(watch.handle, raw_data(buffer), win.DWORD(len(buffer)), true, filter, &written, nil, nil) {
			return
		}
		if written > 0 && watch_worth_it(buffer[:written]) {
			intrinsics.atomic_store(&watch.touched, true)
		}
	}
}

FILE_NOTIFY_INFORMATION :: struct {
	NextEntryOffset: win.DWORD,
	Action:          win.DWORD,
	FileNameLength:  win.DWORD,
	FileName:        [1]u16,
}

watch_worth_it :: proc(records: []u8) -> bool {
	cursor := 0
	for cursor + size_of(FILE_NOTIFY_INFORMATION) <= len(records) {
		entry := (^FILE_NOTIFY_INFORMATION)(raw_data(records[cursor:]))
		letters := (cast([^]u16)&entry.FileName)[:entry.FileNameLength / 2]
		name, error := win.utf16_to_utf8(letters, context.temp_allocator)
		if error == nil && watch_interesting(name) {
			log.debugf("the watcher cares about %s", name)
			return true
		}
		if entry.NextEntryOffset == 0 {
			break
		}
		cursor += int(entry.NextEntryOffset)
	}
	return false
}

watch_interesting :: proc(name: string) -> bool {
	remaining := name
	for {
		cut := max(strings.index_byte(remaining, '/'), strings.index_byte(remaining, '\\'))
		if cut < 0 {
			break
		}
		folder := remaining[:cut]
		if word_in_set(skipped_directories, folder) || strings.has_prefix(folder, ".") {
			return false
		}
		remaining = remaining[cut + 1:]
	}
	if remaining == "" {
		return true
	}
	extension := strings.to_lower(filepath.ext(remaining), context.temp_allocator)
	if extension == "" {
		return true
	}
	switch extension {
	case ".exe", ".pdb", ".obj", ".lib", ".ilk", ".dll", ".bmp", ".png", ".log", ".tmp", ".writing":
		return false
	}
	return true
}

watch_start :: proc(root: string) {
	watch_stop()
	handle := win.CreateFileW(
		win.utf8_to_wstring(root),
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		log.warnf("the workspace %s could not be watched", root)
		return
	}
	watch := new(Watcher)
	watch.root = strings.clone(root)
	watch.handle = handle
	watch.worker = thread.create(watch_worker)
	if watch.worker == nil {
		win.CloseHandle(handle)
		delete(watch.root)
		free(watch)
		return
	}
	watch.worker.data = watch
	watch.worker.init_context = context
	watcher = watch
	thread.start(watch.worker)
	log.debugf("watching %s for changes", root)
}

watch_stop :: proc() {
	if watcher == nil {
		return
	}
	intrinsics.atomic_store(&watcher.stop, true)
	win.CancelIoEx(watcher.handle, nil)
	win.CloseHandle(watcher.handle)
	thread.join(watcher.worker)
	thread.destroy(watcher.worker)
	delete(watcher.root)
	free(watcher)
	watcher = nil
}

watch_running :: proc() -> bool {
	return watcher != nil
}

watch_taken :: proc() -> bool {
	if watcher == nil {
		return false
	}
	if !intrinsics.atomic_load(&watcher.touched) {
		return false
	}
	intrinsics.atomic_store(&watcher.touched, false)
	return true
}
