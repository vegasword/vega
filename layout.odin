package vega

import "core:log"
import "core:math"

Split_Kind :: enum u8 {
	Leaf,
	Columns,
	Rows,
}

Split_Node :: struct {
	kind:   Split_Kind,
	parent: int,
	first:  int,
	second: int,
	view:   int,
	ratio:  f32,
}

layout_reset :: proc(editor: ^Editor) {
	clear(&editor.nodes)
	append(&editor.nodes, Split_Node{kind = .Leaf, parent = -1, view = 0, ratio = 0.5})
	editor.root = 0
	editor.active_node = 0
}

layout_leaves :: proc(editor: ^Editor, node: int, out: ^[dynamic]int) {
	entry := editor.nodes[node]
	if entry.kind == .Leaf {
		append(out, node)
		return
	}
	layout_leaves(editor, entry.first, out)
	layout_leaves(editor, entry.second, out)
}

layout_ordered_leaves :: proc(editor: ^Editor) -> []int {
	leaves := make([dynamic]int, 0, len(editor.nodes), context.temp_allocator)
	layout_leaves(editor, editor.root, &leaves)
	return leaves[:]
}

layout_split :: proc(editor: ^Editor, kind: Split_Kind) {
	active := editor.active_node
	source := editor.nodes[active]
	if source.kind != .Leaf {
		return
	}

	append(&editor.views, View{buffer = editor.views[source.view].buffer, scroll_line = editor.views[source.view].scroll_line})
	append(&editor.nodes, Split_Node{kind = .Leaf, parent = active, view = source.view, ratio = 0.5})
	first := len(editor.nodes) - 1
	append(&editor.nodes, Split_Node{kind = .Leaf, parent = active, view = len(editor.views) - 1, ratio = 0.5})
	second := len(editor.nodes) - 1

	editor.nodes[active] = {kind = kind, parent = source.parent, first = first, second = second, ratio = 0.5}
	editor.active_node = second
	editor.active_view = editor.nodes[second].view
	editor.flags += {.SessionDirty}
	log.infof("split %v, %d panes", kind, len(layout_ordered_leaves(editor)))
}

layout_close :: proc(editor: ^Editor) {
	active := editor.active_node
	parent := editor.nodes[active].parent
	if parent < 0 {
		editor_status(editor, "Only one pane")
		return
	}
	sibling := editor.nodes[parent].first == active ? editor.nodes[parent].second : editor.nodes[parent].first
	grandparent := editor.nodes[parent].parent
	editor.nodes[parent] = editor.nodes[sibling]
	editor.nodes[parent].parent = grandparent
	if editor.nodes[parent].kind != .Leaf {
		editor.nodes[editor.nodes[parent].first].parent = parent
		editor.nodes[editor.nodes[parent].second].parent = parent
	}
	editor.active_node = layout_first_leaf(editor, parent)
	editor.active_view = editor.nodes[editor.active_node].view
	editor.flags += {.SessionDirty}
	log.infof("closed a pane, %d left", len(layout_ordered_leaves(editor)))
}

layout_only :: proc(editor: ^Editor) {
	keep := editor.views[editor.active_view]
	clear(&editor.views)
	append(&editor.views, keep)
	layout_reset(editor)
	editor.active_view = 0
	editor.flags += {.SessionDirty}
	log.info("kept a single pane")
}

layout_first_leaf :: proc(editor: ^Editor, node: int) -> int {
	entry := editor.nodes[node]
	return entry.kind == .Leaf ? node : layout_first_leaf(editor, entry.first)
}

layout_focus :: proc(editor: ^Editor, delta: int) {
	leaves := layout_ordered_leaves(editor)
	current := 0
	for leaf, index in leaves {
		if leaf == editor.active_node {
			current = index
		}
	}
	editor.active_node = leaves[(current + delta + len(leaves)) % len(leaves)]
	editor.active_view = editor.nodes[editor.active_node].view
}

layout_resize :: proc(editor: ^Editor, amount: f32) {
	parent := editor.nodes[editor.active_node].parent
	if parent < 0 {
		return
	}
	growing := editor.nodes[parent].first == editor.active_node ? amount : -amount
	editor.nodes[parent].ratio = clamp(editor.nodes[parent].ratio + growing, 0.15, 0.85)
}

layout_sound :: proc(nodes: []Split_Node, views, root, depth: int) -> bool {
	if root < 0 || root >= len(nodes) || depth > len(nodes) {
		return false
	}
	entry := nodes[root]
	if entry.kind == .Leaf {
		return entry.view >= 0 && entry.view < views
	}
	if entry.first == root || entry.second == root {
		return false
	}
	return layout_sound(nodes, views, entry.first, depth + 1) && layout_sound(nodes, views, entry.second, depth + 1)
}

layout_assign :: proc(editor: ^Editor, node: int, area: Rect) {
	entry := editor.nodes[node]
	if entry.kind == .Leaf {
		editor.views[entry.view].rect = area
		return
	}
	if entry.kind == .Columns {
		width := area.width * entry.ratio
		layout_assign(editor, entry.first, {area.x, area.y, width - 1, area.height})
		layout_assign(editor, entry.second, {area.x + width, area.y, area.width - width, area.height})
	} else {
		height := area.height * entry.ratio
		layout_assign(editor, entry.first, {area.x, area.y, area.width, height - 1})
		layout_assign(editor, entry.second, {area.x, area.y + height, area.width, area.height - height})
	}
}

editor_layout :: proc(editor: ^Editor) {
	reserved := settings_panel_width(editor)
	top := top_bar_height_of(editor)
	for &view in editor.views {
		view.rect = {}
	}
	layout_assign(editor, editor.root, {reserved, top, f32(editor.width) - reserved, f32(editor.height) - status_height_of(editor) - top})
}

content_rect :: proc(editor: ^Editor, view: ^View) -> Rect {
	rect := view.rect
	if !(.Centered in editor.config.options) || rect.width <= 0 || rect.height <= 0 || rect.width < rect.height {
		return rect
	}
	line_height := line_height_of(editor)
	side := min(rect.width, rect.height * editor.config.aspect_ratio)
	rows := max(1, int(side / line_height))
	side = f32(rows) * line_height
	return {
		rect.x + math.floor((rect.width - side) * 0.5),
		rect.y + math.max(0, math.floor((rect.height - side) * 0.5)),
		side,
		side,
	}
}
