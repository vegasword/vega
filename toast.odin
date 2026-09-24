package vega

import "core:log"
import "core:strings"

TOAST_LIFETIME :: 4.5
TOAST_FADE :: 0.8

Toast :: struct {
	text:  string,
	level: log.Level,
	age:   f32,
}

toasts: [dynamic]Toast
file_logger: log.Logger

toast_push :: proc(level: log.Level, text: string) {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return
	}
	if len(toasts) > 0 && toasts[len(toasts) - 1].text == trimmed {
		toasts[len(toasts) - 1].age = 0
		return
	}
	append(&toasts, Toast{strings.clone(trimmed), level, 0})
	for len(toasts) > 6 {
		delete(toasts[0].text)
		ordered_remove(&toasts, 0)
	}
}

notify :: proc(message: string, level := log.Level.Info, location := #caller_location) {
	log.log(level, message, location = location)
	toast_push(level, message)
}

toasting_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	inner := (^log.Logger)(data)
	if inner.procedure != nil && level >= inner.lowest_level {
		inner.procedure(inner.data, level, text, options, location)
	}
	if level >= .Warning {
		toast_push(level, text)
	}
}

toasting_logger :: proc(inner: log.Logger) -> log.Logger {
	file_logger = inner
	return log.Logger{toasting_logger_proc, &file_logger, .Debug, inner.options}
}

toasts_update :: proc(delta_time: f32) {
	for index := len(toasts) - 1; index >= 0; index -= 1 {
		toasts[index].age += delta_time
		if toasts[index].age > TOAST_LIFETIME {
			delete(toasts[index].text)
			ordered_remove(&toasts, index)
		}
	}
}

draw_toasts :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	cell := painter.cell_width
	line_height := painter.line_height
	room := max(16, int(f32(editor.width) / cell) - 12)
	bottom := f32(editor.height) - status_height_of(editor) - line_height * 0.6

	for index := len(toasts) - 1; index >= 0; index -= 1 {
		toast := toasts[index]
		fade := clamp((TOAST_LIFETIME - toast.age) / TOAST_FADE, 0, 1) * clamp(toast.age / 0.12, 0, 1)
		accent := theme[.Accent]
		switch toast.level {
		case .Warning:
			accent = theme[.Number]
		case .Error, .Fatal:
			accent = theme[.Directive]
		case .Debug, .Info:
		}

		lines := make([dynamic]string, 0, 4, context.temp_allocator)
		widest := 0
		remaining := toast.text
		for raw in strings.split_lines_iterator(&remaining) {
			for piece in wrap_text(strings.trim_right_space(raw), room, context.temp_allocator) {
				append(&lines, piece)
				widest = max(widest, len(piece))
				if len(lines) >= 8 {
					break
				}
			}
			if len(lines) >= 8 {
				break
			}
		}
		if len(lines) == 0 {
			continue
		}

		width := cell * f32(widest + 3)
		height := line_height * (f32(len(lines)) + 0.5)
		x := f32(editor.width) - width - cell
		push_rect(painter, x, bottom - height, width, height, theme[.Overlay] * [4]f32{1, 1, 1, fade})
		push_rect(painter, x, bottom - height, 3, height, accent * [4]f32{1, 1, 1, fade})
		for line, row in lines {
			push_text(painter, x + cell, bottom - height + line_height * (f32(row) + 0.25), line, theme[.Text] * [4]f32{1, 1, 1, fade})
		}
		bottom -= height + line_height * 0.2
	}
}

