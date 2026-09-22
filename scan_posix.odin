#+build !windows
package vega

import "core:os"
import "core:strings"
import "core:time"

scan_directory :: proc(path: string, allocator := context.temp_allocator) -> []Scanned {
	entries, error := os.read_all_directory_by_path(path, allocator)
	if error != nil {
		return nil
	}
	found := make([dynamic]Scanned, 0, len(entries), allocator)
	for entry in entries {
		append(&found, Scanned {
			name = strings.clone(entry.name, allocator),
			full = strings.clone(entry.fullpath, allocator),
			directory = entry.type == .Directory,
			size = i64(entry.size),
			modified = time.time_to_unix_nano(entry.modification_time),
		})
	}
	return found[:]
}

scan_stat :: proc(path: string) -> (modified: i64, ok: bool) {
	info, error := os.stat(path, context.temp_allocator)
	if error != nil {
		return 0, false
	}
	return time.time_to_unix_nano(info.modification_time), true
}

scan_map :: proc(path: string) -> ([]u8, bool) {
	return scan_read(path)
}

scan_unmap :: proc(view: []u8) {
	delete(view)
}

scan_read :: proc(path: string) -> ([]u8, bool) {
	data, error := os.read_entire_file(path, context.allocator)
	return data, error == nil
}
