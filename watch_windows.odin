#+build windows
package vega

import "base:intrinsics"
import "core:log"
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
		if written > 0 {
			intrinsics.atomic_store(&watch.touched, true)
			log.debugf("the watcher saw %d byte(s) of changes", written)
		}
	}
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
