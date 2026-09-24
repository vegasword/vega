package vega

import "core:log"
import "core:os"
import "core:strings"

PREVIEW_CACHE_BUDGET :: 32 << 20
PREVIEW_WARM_RADIUS :: 12
PREVIEW_WARM_PER_FRAME :: 3

Preview_Entry :: struct {
	path: string,
	text: []u8,
	age:  int,
}

preview_cache: [dynamic]Preview_Entry
preview_clock: int

preview_cached :: proc(path: string) -> ([]u8, bool) {
	for &entry in preview_cache {
		if entry.path == path {
			preview_clock += 1
			entry.age = preview_clock
			return entry.text, true
		}
	}
	return nil, false
}

preview_cache_add :: proc(path: string, text: []u8) {
	preview_clock += 1
	append(&preview_cache, Preview_Entry{strings.clone(path), text, preview_clock})
	total := 0
	for entry in preview_cache {
		total += len(entry.text)
	}
	for total > PREVIEW_CACHE_BUDGET && len(preview_cache) > 1 {
		oldest := 0
		for entry, index in preview_cache {
			if entry.age < preview_cache[oldest].age {
				oldest = index
			}
		}
		total -= len(preview_cache[oldest].text)
		delete(preview_cache[oldest].text)
		delete(preview_cache[oldest].path)
		ordered_remove(&preview_cache, oldest)
	}
}

preview_cache_clear :: proc() {
	for entry in preview_cache {
		delete(entry.text)
		delete(entry.path)
	}
	clear(&preview_cache)
}

preview_warm :: proc(editor: ^Editor) {
	picker := &editor.picker
	picker.warming = false
	switch picker.kind {
	case .Files, .Symbols, .GlobalSearch, .References:
	case .Buffers, .Menu, .Commands, .Themes, .Workspaces, .Diagnostics, .None:
		return
	}
	read := 0
	for distance in 0 ..= PREVIEW_WARM_RADIUS {
		for direction in ([]int{1, -1}) {
			position := picker.cursor + distance * direction
			if distance == 0 && direction < 0 || position < 0 || position >= len(picker.filtered) {
				continue
			}
			path := picker.items[picker.filtered[position]].path
			if path == "" || !previewable(path) {
				continue
			}
			if _, cached := preview_cached(path); cached {
				continue
			}
			data, error := os.read_entire_file(path, context.allocator)
			if error != nil {
				continue
			}
			preview_cache_add(path, data)
			read += 1
			if read >= PREVIEW_WARM_PER_FRAME {
				picker.warming = true
				log.debugf("preview cache warmed to %d files around %d", len(preview_cache), picker.cursor)
				return
			}
		}
	}
}

preview_show :: proc(editor: ^Editor, path: string, offset: int) {
	for buffer, index in editor.buffers {
		if buffer.path == path && !(.Preview in buffer.flags) {
			editor_view(editor).buffer = index
			if offset > 0 {
				goto_offset(buffer, offset, false)
			}
			editor_center_view(editor)
			return
		}
	}

	preloaded, cached := preview_cached(path)
	if !cached {
		if data, error := os.read_entire_file(path, context.allocator); error == nil {
			preview_cache_add(path, data)
			preloaded = data
		}
	}

	slot := preview_slot(editor)
	if slot < 0 {
		append(&editor.buffers, buffer_create(editor, path, {.Preview, .ReadOnly}, preloaded))
		slot = len(editor.buffers) - 1
	} else if editor.buffers[slot].path != path {
		buffer_destroy(editor.buffers[slot])
		editor.buffers[slot] = buffer_create(editor, path, {.Preview, .ReadOnly}, preloaded)
	}
	editor_view(editor).buffer = slot
	goto_offset(editor.buffers[slot], offset, false)
	editor_center_view(editor)
}

preview_slot :: proc(editor: ^Editor) -> int {
	for buffer, index in editor.buffers {
		if .Preview in buffer.flags {
			return index
		}
	}
	return -1
}

preview_discard :: proc(editor: ^Editor) -> bool {
	slot := preview_slot(editor)
	if slot < 0 {
		return false
	}
	buffer_destroy(editor.buffers[slot])
	ordered_remove(&editor.buffers, slot)
	for &view in editor.views {
		view.buffer = clamp(view.buffer > slot ? view.buffer - 1 : view.buffer, 0, max(0, len(editor.buffers) - 1))
	}
	log.debug("preview buffer released")
	return true
}
