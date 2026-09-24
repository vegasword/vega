#+build windows
package vega

import "core:os"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	FindFirstFileExW :: proc(name: win.LPCWSTR, level: i32, data: rawptr, search: i32, filter: rawptr, flags: win.DWORD) -> win.HANDLE ---
}

FIND_INFO_BASIC :: 1
FIND_SEARCH_NAME_MATCH :: 0
FIND_LARGE_FETCH :: 2

scan_directory :: proc(path: string, allocator := context.temp_allocator) -> []Scanned {
	pattern := strings.concatenate({path, "\\*"}, context.temp_allocator)
	data: win.WIN32_FIND_DATAW
	handle := FindFirstFileExW(win.utf8_to_wstring(pattern), FIND_INFO_BASIC, &data, FIND_SEARCH_NAME_MATCH, nil, FIND_LARGE_FETCH)
	if handle == win.INVALID_HANDLE_VALUE {
		return nil
	}
	defer win.FindClose(handle)
	found := make([dynamic]Scanned, 0, 64, allocator)
	for {
		name, error := win.wstring_to_utf8(win.wstring(&data.cFileName[0]), -1, allocator)
		if error == nil && name != "." && name != ".." {
			append(&found, Scanned {
				name = name,
				full = strings.concatenate({path, "\\", name}, allocator),
				directory = (data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY) != 0,
				size = i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow),
				modified = i64(data.ftLastWriteTime.dwHighDateTime) << 32 | i64(data.ftLastWriteTime.dwLowDateTime),
			})
		}
		if !win.FindNextFileW(handle, &data) {
			break
		}
	}
	return found[:]
}

scan_replace :: proc(path: string, data: []u8) -> bool {
	temporary := strings.concatenate({path, ".writing"}, context.temp_allocator)
	if os.write_entire_file(temporary, data) != nil {
		return false
	}
	if !win.MoveFileExW(win.utf8_to_wstring(temporary), win.utf8_to_wstring(path), win.MOVEFILE_REPLACE_EXISTING) {
		os.remove(temporary)
		return false
	}
	return true
}

scan_stat :: proc(path: string) -> (modified: i64, ok: bool) {
	data: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(win.utf8_to_wstring(path), win.GetFileExInfoStandard, &data) {
		return 0, false
	}
	return i64(data.ftLastWriteTime.dwHighDateTime) << 32 | i64(data.ftLastWriteTime.dwLowDateTime), true
}

scan_map :: proc(path: string) -> ([]u8, bool) {
	file := win.CreateFileW(win.utf8_to_wstring(path), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE {
		return nil, false
	}
	defer win.CloseHandle(file)
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(file, &size) || size <= 0 {
		return nil, false
	}
	mapping := win.CreateFileMappingW(file, nil, win.PAGE_READONLY, 0, 0, nil)
	if mapping == nil {
		return nil, false
	}
	defer win.CloseHandle(mapping)
	view := win.MapViewOfFile(mapping, win.FILE_MAP_READ, 0, 0, 0)
	if view == nil {
		return nil, false
	}
	return (cast([^]u8)view)[:int(size)], true
}

scan_unmap :: proc(view: []u8) {
	if len(view) > 0 {
		win.UnmapViewOfFile(win.LPVOID(raw_data(view)))
	}
}

scan_read :: proc(path: string) -> ([]u8, bool) {
	handle := win.CreateFileW(
		win.utf8_to_wstring(path),
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_SEQUENTIAL_SCAN,
		nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		return nil, false
	}
	defer win.CloseHandle(handle)
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(handle, &size) || size <= 0 {
		return nil, false
	}
	text := make([]u8, int(size))
	filled := 0
	for filled < len(text) {
		read: win.DWORD
		if !win.ReadFile(handle, raw_data(text[filled:]), win.DWORD(len(text) - filled), &read, nil) || read == 0 {
			delete(text)
			return nil, false
		}
		filled += int(read)
	}
	return text, true
}
