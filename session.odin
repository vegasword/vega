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
	for node in editor.nodes {
		fmt.sbprintf(&builder, "node %v %d %d %d %d %.3f\n", node.kind, node.parent, node.first, node.second, node.view, node.ratio)
	}
	fmt.sbprintf(&builder, "root %d %d\n", editor.root, editor.active_node)
	for view in editor.views {
		path := editor.buffers[clamp(view.buffer, 0, len(editor.buffers) - 1)].path
		fmt.sbprintf(&builder, "view %d %s\n", view.scroll_line, path)
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
	nodes := make([dynamic]Split_Node, 0, 8, context.temp_allocator)
	panes := make([dynamic]View, 0, 8, context.temp_allocator)
	root, active_node := 0, 0
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
		case "node":
			if len(fields) >= 7 {
				kind := Split_Kind.Leaf
				for candidate in Split_Kind {
					if fmt.tprintf("%v", candidate) == fields[1] {
						kind = candidate
					}
				}
				append(&nodes, Split_Node{kind, int_of(fields[2]), int_of(fields[3]), int_of(fields[4]), int_of(fields[5]), parse_number(fields[6])})
			}
		case "root":
			if len(fields) >= 3 {
				root, active_node = int_of(fields[1]), int_of(fields[2])
			}
		case "view":
			pane := View{scroll_line = int_of(fields[1])}
			for buffer, index in editor.buffers {
				if len(fields) >= 3 && buffer.path == fields[2] {
					pane.buffer = index
				}
			}
			append(&panes, pane)
		case "focus":
			for buffer, index in editor.buffers {
				if buffer.path == fields[1] {
					editor_view(editor).buffer = index
				}
			}
		}
	}
	if len(editor.buffers) > 0 && layout_sound(nodes[:], len(panes), root, 0) {
		focused := editor_view(editor).buffer
		clear(&editor.views)
		append(&editor.views, ..panes[:])
		clear(&editor.nodes)
		append(&editor.nodes, ..nodes[:])
		editor.root = root
		editor.active_node = clamp(active_node, 0, len(editor.nodes) - 1)
		editor.active_view = clamp(editor.nodes[editor.active_node].view, 0, len(editor.views) - 1)
		editor_view(editor).buffer = clamp(focused, 0, len(editor.buffers) - 1)
		log.debugf("restored %d pane(s) from the workspace", len(editor.views))
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
