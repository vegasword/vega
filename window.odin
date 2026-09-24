package vega

import "core:log"
import sdl "vendor:sdl3"

RESIZE_MARGIN :: 6

Window_Button :: enum u8 {
	None,
	Minimize,
	Maximize,
	Close,
}

window_hit_test :: proc "c" (window: ^sdl.Window, area: ^sdl.Point, data: rawptr) -> sdl.HitTestResult {
	editor := (^Editor)(data)
	width, height: i32
	sdl.GetWindowSize(window, &width, &height)
	left := area.x < RESIZE_MARGIN
	right := area.x > width - RESIZE_MARGIN
	top := area.y < RESIZE_MARGIN
	bottom := area.y > height - RESIZE_MARGIN

	switch {
	case top && left:
		return .RESIZE_TOPLEFT
	case top && right:
		return .RESIZE_TOPRIGHT
	case bottom && left:
		return .RESIZE_BOTTOMLEFT
	case bottom && right:
		return .RESIZE_BOTTOMRIGHT
	case top:
		return .RESIZE_TOP
	case bottom:
		return .RESIZE_BOTTOM
	case left:
		return .RESIZE_LEFT
	case right:
		return .RESIZE_RIGHT
	}
	if f32(area.y) < editor.top_bar_height && f32(area.x) < editor.buttons_left {
		return .DRAGGABLE
	}
	return .NORMAL
}

window_button_at :: proc(editor: ^Editor, x, y: f32) -> Window_Button {
	if y > editor.top_bar_height {
		return .None
	}
	width := editor.painter.cell_width * 4
	for button, index in ([]Window_Button{.Minimize, .Maximize, .Close}) {
		left := editor.buttons_left + f32(index) * width
		if x >= left && x < left + width {
			return button
		}
	}
	return .None
}

window_button_press :: proc(editor: ^Editor, button: Window_Button) {
	switch button {
	case .Minimize:
		sdl.MinimizeWindow(editor.window)
	case .Maximize:
		if .MAXIMIZED in sdl.GetWindowFlags(editor.window) {
			sdl.RestoreWindow(editor.window)
		} else {
			sdl.MaximizeWindow(editor.window)
		}
	case .Close:
		editor_quit(editor, false)
	case .None:
	}
	log.debugf("window button %v", button)
}

draw_window_buttons :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	cell := painter.cell_width
	height := top_bar_height_of(editor)
	width := cell * 4
	editor.top_bar_height = height
	editor.buttons_left = f32(editor.width) - width * 3

	for button, index in ([]Window_Button{.Minimize, .Maximize, .Close}) {
		left := editor.buttons_left + f32(index) * width
		hovered := editor.hovered_button == button
		if hovered {
			tint := button == .Close ? DIAGNOSTIC_RED : theme[.Selection]
			push_rect(painter, left, 0, width, height, tint)
		}
		color := hovered ? (button == .Close ? [4]f32{1, 1, 1, 1} : theme[.Text]) : theme[.Gutter]
		middle_x := left + width / 2
		middle_y := height / 2
		switch button {
		case .Minimize:
			push_rect(painter, middle_x - cell * 0.5, middle_y, cell, 1, color)
		case .Maximize:
			restore := .MAXIMIZED in sdl.GetWindowFlags(editor.window)
			box := cell * 0.9
			push_rect(painter, middle_x - box / 2, middle_y - box / 2, box, 1, color)
			push_rect(painter, middle_x - box / 2, middle_y + box / 2, box, 1, color)
			push_rect(painter, middle_x - box / 2, middle_y - box / 2, 1, box, color)
			push_rect(painter, middle_x + box / 2, middle_y - box / 2, 1, box + 1, color)
			if restore {
				push_rect(painter, middle_x - box / 2 + 3, middle_y - box / 2 - 3, box, 1, color * [4]f32{1, 1, 1, 0.6})
				push_rect(painter, middle_x + box / 2 + 3, middle_y - box / 2 - 3, 1, box, color * [4]f32{1, 1, 1, 0.6})
			}
		case .Close:
			reach := cell * 0.45
			push_line(painter, middle_x - reach, middle_y - reach, middle_x + reach, middle_y + reach, 1.4, color)
			push_line(painter, middle_x + reach, middle_y - reach, middle_x - reach, middle_y + reach, 1.4, color)
		case .None:
		}
	}
}
