package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"


session_save :: proc(editor: ^Editor) {
	builder := strings.builder_make(context.temp_allocator)
	for buffer in editor.buffers {
		if buffer.path == "" || buffer_hidden(buffer) {
			continue
		}
		fmt.sbprintf(&builder, "buffer %d %d %s\n", buffer_primary(buffer).head, buffer.scroll, buffer.path)
	}
	fmt.sbprintf(&builder, "focus %s\n", editor_buffer(editor).path)
	if os.write_entire_file(workspace_session_path(editor.index.root), transmute([]u8)strings.to_string(builder)) != nil {
		log.error("could not write the session")
		return
	}
	log.debugf("session saved with %d buffers and %d views", len(editor.buffers), len(editor.views))
}

session_restore :: proc(editor: ^Editor) -> bool {
	data, error := os.read_entire_file(workspace_session_path(editor.index.root), context.temp_allocator)
	if error != nil {
		return false
	}
	cursors := make(map[string]int, context.temp_allocator)
	scrolls := make(map[string]int, context.temp_allocator)
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "buffer":
			if len(fields) >= 4 && os.exists(fields[3]) {
				editor_open_file(editor, fields[3])
				path := strings.clone(fields[3], context.temp_allocator)
				cursors[path] = int_of(fields[1])
				scrolls[path] = int_of(fields[2])
			}
		case "focus":
			for buffer, index in editor.buffers {
				if buffer.path == fields[1] {
					editor_view(editor).buffer = index
				}
			}
		}
	}
	for buffer in editor.buffers {
		if offset, found := cursors[buffer.path]; found {
			goto_offset(buffer, offset, false)
		}
	}
	for buffer in editor.buffers {
		if scroll, found := scrolls[buffer.path]; found {
			buffer.scroll = scroll
		}
	}
	if len(editor.buffers) == 0 {
		return false
	}
	log.infof("restored %d file(s) from the last session", len(editor.buffers))
	return true
}
