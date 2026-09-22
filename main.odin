package vega

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

Editor_Flag :: enum u8 {
	ConfigDirty,
	SessionDirty,
	FontDirty,
	VsyncDirty,
	Quit,
	PendingReplace,
}

Editor_Flags :: bit_set[Editor_Flag; u8]

Mode :: enum u8 {
	Normal,
	Insert,
	Select,
}

Editor :: struct {
	window:          ^sdl.Window,
	renderer:        ^sdl.Renderer,
	painter:         Painter,
	logo:            Logo,
	config:          Config,
	active_theme:    Theme,
	top_bar_height:  f32,
	buttons_left:    f32,
	hovered_button:  Window_Button,
	index:           Project_Index,
	keymap:          map[Chord]Command,
	buffers:         [dynamic]^Buffer,
	views:           [dynamic]View,
	nodes:           [dynamic]Split_Node,
	root:            int,
	active_node:     int,
	active_view:     int,
	hover:           Hover,
	output:          Output,
	diagnostics:       [dynamic]Diagnostic,
	diagnostic_cursor: int,
	mode:            Mode,
	count:           int,
	pending_prefix:  u8,

	pending_find:    Pending_Find,
	last_find:       struct {
		character: u8,
		forward:   bool,
		till:      bool,
	},
	jumps:           [dynamic]Jump,
	jump_index:      int,
	registers:       [dynamic]string,
	search_pattern:  string,
	prompt:          Prompt_Kind,
	prompt_input:    [dynamic]u8,
	prompt_origin:   int,
	prompt_selections: [dynamic]Range,
	picker:          Picker,
	settings:        Settings,
	color_picker:    Color_Picker,
	flags:           Editor_Flags,
	save_timer:      f32,
	width:           i32,
	height:          i32,
	time:            f32,
}

active_painter: ^Painter
screenshot_path: string
frame_count: int
screenshot_delay := 20
dialog_context: runtime.Context

editor_buffer :: proc(editor: ^Editor) -> ^Buffer {
	view := editor_view(editor)
	view.buffer = clamp(view.buffer, 0, len(editor.buffers) - 1)
	return editor.buffers[view.buffer]
}

Jump :: struct {
	path:   string,
	offset: int,
}

jump_push :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	if buffer.path == "" || buffer_hidden(buffer) {
		return
	}
	here := Jump{buffer.path, buffer_primary(buffer).head}
	if editor.jump_index < len(editor.jumps) && editor.jumps[editor.jump_index] == here {
		return
	}
	for index in editor.jump_index ..< len(editor.jumps) {
		delete(editor.jumps[index].path)
	}
	resize(&editor.jumps, editor.jump_index)
	append(&editor.jumps, Jump{strings.clone(here.path), here.offset})
	editor.jump_index = len(editor.jumps)
	log.debugf("jump %d recorded at %s:%d", editor.jump_index, filename_of(here.path), here.offset)
}

jump_to :: proc(editor: ^Editor, delta: int) {
	if delta < 0 && editor.jump_index == len(editor.jumps) {
		jump_push(editor)
		editor.jump_index = len(editor.jumps) - 1
	}
	target := editor.jump_index + delta
	if target < 0 || target >= len(editor.jumps) {
		notify(delta < 0 ? "No earlier position" : "No later position")
		return
	}
	editor.jump_index = target
	jump := editor.jumps[target]
	editor_open_file(editor, jump.path)
	goto_offset(editor_buffer(editor), jump.offset, false)
	editor_center_view(editor)
	log.debugf("jumped to %s:%d (%d of %d)", filename_of(jump.path), buffer_line_of(editor_buffer(editor), jump.offset) + 1, target + 1, len(editor.jumps))
}

editor_status :: proc(editor: ^Editor, message: string, location := #caller_location) {
	notify(message, .Info, location)
}

editor_open_file :: proc(editor: ^Editor, path: string) {
	full, error := filepath.abs(path, context.temp_allocator)
	if error != nil {
		full = path
	}
	for buffer, position in editor.buffers {
		if buffer.path == full {
			editor_view(editor).buffer = position
			return
		}
	}
	append(&editor.buffers, buffer_create(editor, full))
	editor_view(editor).buffer = len(editor.buffers) - 1
	editor.flags += {.SessionDirty}
	log.infof("opened %s", full)
}

editor_close_buffer :: proc(editor: ^Editor, force: bool) {
	buffer := editor_buffer(editor)
	if (.Modified in buffer.flags) && !force {
		editor_status(editor, "Unsaved changes, use :bc! or :w first")
		return
	}
	closing := editor_view(editor).buffer
	ordered_remove(&editor.buffers, closing)
	if len(editor.buffers) == 0 {
		append(&editor.buffers, buffer_create(editor, ""))
	}
	for &view in editor.views {
		view.buffer = clamp(view.buffer > closing ? view.buffer - 1 : view.buffer, 0, len(editor.buffers) - 1)
	}
	editor.flags += {.SessionDirty}
	log.infof("closed %s", filename_of(buffer.display))
}

handle_event :: proc(editor: ^Editor, event: sdl.Event) {
	event := event
	#partial switch event.type {
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_MOTION:
		sdl.ConvertEventToRenderCoordinates(editor.renderer, &event)
	}
	#partial switch event.type {
	case .QUIT:
		editor.flags += {.Quit}
	case .KEY_DOWN:
		if sdl.CursorVisible() {
			_ = sdl.HideCursor()
		}
		handle_key(editor, event.key.key, event.key.mod, event.key.scancode)
	case .TEXT_INPUT:
		handle_text(editor, string(event.text.text))
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if editor.color_picker.open {
			color_picker_mouse(editor, event.button.x, event.button.y, event.type == .MOUSE_BUTTON_DOWN, event.type == .MOUSE_BUTTON_UP)
		}
		if event.type == .MOUSE_BUTTON_UP {
			if button := window_button_at(editor, event.button.x, event.button.y); button != .None {
				window_button_press(editor, button)
			}
		}
	case .MOUSE_WHEEL:
		if editor.output.open {
			output_scroll(editor, event.wheel.y > 0 ? -1 : 1)
		}
	case .MOUSE_MOTION:
		if !sdl.CursorVisible() && (event.motion.xrel != 0 || event.motion.yrel != 0) {
			_ = sdl.ShowCursor()
		}
		editor.hovered_button = window_button_at(editor, event.motion.x, event.motion.y)
		if editor.color_picker.open {
			color_picker_mouse(editor, event.motion.x, event.motion.y, false, false)
		}
	}
}

editor_write :: proc(editor: ^Editor, buffer: ^Buffer) -> bool {
	if buffer.path == "" {
		save_file_dialog(editor, buffer)
		return true
	}
	written := buffer_save(editor, buffer)
	notify(written ? fmt.tprintf("Wrote %s", filename_of(buffer.display)) : "Write failed", written ? .Info : .Error)
	return written
}

editor_write_all :: proc(editor: ^Editor) -> int {
	written := 0
	for buffer in editor.buffers {
		if .Modified in buffer.flags && buffer_save(editor, buffer) {
			written += 1
		}
	}
	notify(fmt.tprintf("Wrote %d buffer(s)", written))
	return written
}

editor_quit :: proc(editor: ^Editor, force: bool) {
	if !force {
		for buffer in editor.buffers {
			if .Modified in buffer.flags {
				notify(fmt.tprintf("%s has unsaved changes, use :qa! or :wqa", filename_of(buffer.display)), .Warning)
				return
			}
		}
	}
	editor.flags += {.Quit}
}

editor_reload :: proc(editor: ^Editor, buffer: ^Buffer) {
	if buffer.path == "" {
		return
	}
	data, error := os.read_entire_file(buffer.path, context.allocator)
	if error != nil {
		log.errorf("could not reload %s", buffer.path)
		return
	}
	resize(&buffer.text, len(data))
	copy(buffer.text[:], data)
	delete(data)
	buffer.flags -= {.Modified}
	buffer_refresh(buffer)
	buffer_clamp_selections(buffer)
	log.infof("reloaded %s", buffer.path)
}

editor_zoom :: proc(editor: ^Editor, direction: int) {
	view := editor_view(editor)
	if editor_buffer(editor).kind == .Image {
		view.image_zoom = direction == 0 ? 1 : clamp(view.image_zoom * (direction > 0 ? 1.25 : 0.8), 0.05, 20)
		log.debugf("image zoom %.0f%%", view.image_zoom * 100)
		return
	}
	editor.config.font_size = direction == 0 ? 18 : clamp(editor.config.font_size + f32(direction), 8, 64)
	editor.flags += {.FontDirty}
	editor.flags += {.ConfigDirty}
	log.debugf("font size %d", int(editor.config.font_size))
}

editor_goto_definition :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	word, _ := word_at(buffer.text[:], buffer_primary(buffer).head)
	if word == "" {
		return
	}
	definitions := index_definitions(&editor.index, word)
	if len(definitions) == 0 {
		editor_status(editor, index_job != nil ? "Still indexing" : fmt.tprintf("No definition for %s", word))
		return
	}
	nearest := -1
	here := buffer_primary(buffer).head
	log.debugf("goto definition of %q, %d candidate(s), buffer %s", word, len(definitions), buffer.path)
	for definition in definitions {
		symbol := editor.index.symbols[definition]
		if editor.index.files[symbol.file].path != buffer.path || symbol.offset > here {
			continue
		}
		if nearest < 0 || symbol.offset > editor.index.symbols[nearest].offset {
			nearest = definition
		}
	}
	if nearest >= 0 && editor.index.symbols[nearest].kind == .Variable {
		symbol := editor.index.symbols[nearest]
		goto_offset(buffer, symbol.offset, false)
		editor_center_view(editor)
		editor_status(editor, symbol.signature)
		return
	}
	if len(definitions) == 1 {
		symbol := editor.index.symbols[definitions[0]]
		editor_open_file(editor, editor.index.files[symbol.file].path)
		goto_offset(editor_buffer(editor), symbol.offset, false)
		editor_center_view(editor)
		editor_status(editor, symbol.signature)
		return
	}
	locations := make([dynamic]Location, 0, len(definitions), context.temp_allocator)
	for definition in definitions {
		symbol := editor.index.symbols[definition]
		append(&locations, Location{symbol.file, symbol.offset})
	}
	picker_add_locations(editor, locations[:], fmt.tprintf("definitions of %s", word))
}

editor_goto_references :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	word, _ := word_at(buffer.text[:], buffer_primary(buffer).head)
	if word == "" {
		return
	}
	locations := index_references(&editor.index, word)
	if len(locations) == 0 {
		editor_status(editor, index_job != nil ? "Still indexing" : fmt.tprintf("No references to %s", word))
		return
	}
	picker_add_locations(editor, locations, fmt.tprintf("references to %s", word))
}

editor_start_rename :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	word, _ := word_at(buffer.text[:], buffer_primary(buffer).head)
	if word == "" {
		editor_status(editor, "Place the cursor on an identifier")
		return
	}
	prompt_open(editor, .Rename)
}

editor_apply_rename :: proc(editor: ^Editor, new_name: string) {
	buffer := editor_buffer(editor)
	old_name, _ := word_at(buffer.text[:], editor.prompt_origin)
	if old_name == "" || new_name == "" || old_name == new_name {
		return
	}
	for open_buffer in editor.buffers {
		if .Modified in open_buffer.flags {
			buffer_save(editor, open_buffer)
		}
	}
	index_build(&editor.index, editor.index.root)
	changed := index_rename(&editor.index, old_name, new_name)
	index_build(&editor.index, editor.index.root)
	for open_buffer in editor.buffers {
		editor_reload(editor, open_buffer)
	}
	editor_status(editor, fmt.tprintf("Renamed %s to %s in %d places", old_name, new_name, changed))
}

main :: proc() {
	paths_prepare()
	log_file, log_error := os.open(log_path, {.Write, .Create, .Trunc, .Unbuffered_IO})
	context.logger = toasting_logger(log_error == nil ? log.create_file_logger(log_file, .Debug) : log.nil_logger())
	defer if log_error == nil {os.close(log_file)}

	editor := new(Editor)
	editor.config = default_config()
	keymap_reset(editor)
	config_load(editor)
	if colors, found := theme_load(editor.config.theme_name); found {
		editor.config.theme = colors
	}
	log.infof("vega starting, %d bindings", len(editor.keymap))

	if len(os.args) > 1 && os.args[1] == "--index" {
		attach_console()
		root, _ := os.get_working_directory(context.allocator)
		index_build(&editor.index, len(os.args) > 2 ? os.args[2] : root)
		fmt.printfln("%d files, %d symbols", len(editor.index.files), len(editor.index.symbols))
		for symbol in editor.index.symbols[:min(40, len(editor.index.symbols))] {
			fmt.printfln("%-10v %-28s %s", symbol.kind, symbol.name, symbol.signature)
		}
		return
	}

	if len(os.args) > 1 && os.args[1] == "--install-desktop" {
		attach_console()
		desktop_install()
		return
	}

	if len(os.args) > 1 && os.args[1] == "--bench" {
		attach_console()
		root, _ := os.get_working_directory(context.allocator)
		bench_run(editor, len(os.args) > 2 ? os.args[2] : root)
	}

	if !sdl.Init({.VIDEO, .AUDIO}) {
		log.fatalf("sdl init failed: %s", sdl.GetError())
		return
	}
	if !sdl.CreateWindowAndRenderer("vega", 1280, 800, {.RESIZABLE, .BORDERLESS, .MAXIMIZED, .HIGH_PIXEL_DENSITY}, &editor.window, &editor.renderer) {
		log.fatalf("window creation failed: %s", sdl.GetError())
		return
	}
	sdl.SetRenderVSync(editor.renderer, (.Vsync in editor.config.options) ? 1 : 0)
	_ = sdl.StartTextInput(editor.window)
	window_w, window_h: i32
	sdl.GetWindowSize(editor.window, &window_w, &window_h)
	output_w, output_h: i32
	sdl.GetRenderOutputSize(editor.renderer, &output_w, &output_h)
	log.infof("window %dx%d, render output %dx%d", window_w, window_h, output_w, output_h)
	sdl.SetWindowResizable(editor.window, true)
	sdl.SetWindowHitTest(editor.window, window_hit_test, editor)
	sdl.MaximizeWindow(editor.window)
	if (.Fullscreen in editor.config.options) {
		sdl.SetWindowFullscreen(editor.window, true)
	}

	editor.painter.renderer = editor.renderer
	active_painter = &editor.painter
	if !painter_load_font(&editor.painter, editor.config.font_size) {
		log.fatal("the embedded font could not be prepared")
		return
	}

	logo_load(editor)
	sfx_load(editor)

	working_directory, _ := os.get_working_directory(context.allocator)
	opening_files := false
	for argument, position in os.args[1:] {
		if strings.has_prefix(argument, "--") {
			continue
		}
		if position > 0 && (os.args[position] == "--screenshot" || os.args[position] == "--keys" || os.args[position] == "--delay" || os.args[position] == "--size") {
			continue
		}
		opening_files = true
	}
	workspace_prune()
	if known := workspace_list(); len(known) > 0 && !opening_files {
		if os.set_working_directory(known[0]) == nil {
			working_directory = strings.clone(known[0])
			log.infof("reopening the last workspace %s", working_directory)
		}
	}
	index_start(&editor.index, working_directory)

	append(&editor.views, View{})
	layout_reset(editor)
	sdl.GetRenderOutputSize(editor.renderer, &editor.width, &editor.height)

	scripted_keys := ""
	for argument, position in os.args[1:] {
		if argument == "--screenshot" && position + 2 < len(os.args) {
			screenshot_path = os.args[position + 2]
			continue
		}
		if argument == "--delay" && position + 2 < len(os.args) {
			screenshot_delay = int_of(os.args[position + 2])
			continue
		}
		if argument == "--size" && position + 2 < len(os.args) {
			cut := strings.index_byte(os.args[position + 2], 'x')
			if cut > 0 {
				sdl.RestoreWindow(editor.window)
				sdl.SetWindowSize(editor.window, i32(int_of(os.args[position + 2][:cut])), i32(int_of(os.args[position + 2][cut + 1:])))
				sdl.SyncWindow(editor.window)
				editor_layout(editor)
			}
			continue
		}
		if argument == "--keys" && position + 2 < len(os.args) {
			if !strings.has_prefix(os.args[position + 2], "--") {
				scripted_keys = os.args[position + 2]
			}
			continue
		}
		if position > 0 && (os.args[position] == "--screenshot" || os.args[position] == "--keys" || os.args[position] == "--delay" || os.args[position] == "--size") {
			continue
		}
		editor_open_file(editor, argument)
	}
	if len(editor.buffers) == 0 && len(workspace_list()) == 0 && scripted_keys == "" && screenshot_path == "" {
		notify("Pick a folder to make it a workspace")
		open_folder_dialog(editor)
	}
	if len(editor.buffers) == 0 && !session_restore(editor) {
		append(&editor.buffers, buffer_create(editor, ""))
	}
	project_files(editor)
	if scripted_keys != "" || screenshot_path != "" {
		index_wait(&editor.index)
	}

	scripted_cursor := 0
	feed_scripted_key :: proc(editor: ^Editor, scripted_keys: string, index: int) -> int {
		index := index
		if scripted_keys[index] == '\\' && index + 1 < len(scripted_keys) {
			index += 1
			switch scripted_keys[index] {
			case 'e':
				handle_key(editor, sdl.K_ESCAPE, {})
			case 'n':
				handle_key(editor, sdl.K_RETURN, {})
			case 't':
				handle_key(editor, sdl.K_TAB, {})
			case 'b':
				handle_key(editor, sdl.K_BACKSPACE, {})
			case 'd':
				handle_key(editor, sdl.K_DOWN, {})
			case 'u':
				handle_key(editor, sdl.K_UP, {})
			case 'r':
				handle_key(editor, sdl.K_RIGHT, {})
			case 'L':
				handle_key(editor, sdl.K_LEFT, {})
			case 'f':
				handle_key(editor, sdl.K_F11, {})
			case 'X':
				handle_key(editor, sdl.K_DELETE, {})
			case 'B':
				handle_key(editor, sdl.K_BACKSPACE, {.LCTRL})
			case 'Y':
				handle_key(editor, sdl.K_DELETE, {.LCTRL})
			case 'P':
				handle_key(editor, sdl.K_PAGEDOWN, {})
			case 'U':
				handle_key(editor, sdl.K_PAGEUP, {})
			case 'c':
				if index + 1 < len(scripted_keys) {
					index += 1
					pressed := sdl.Keycode(scripted_keys[index])
					handle_key(editor, pressed, {.LCTRL}, sdl.GetScancodeFromKey(pressed, nil))
				}
			case 'C':
				if index + 1 < len(scripted_keys) {
					index += 1
					pressed := sdl.Keycode(scripted_keys[index])
					handle_key(editor, pressed, {.LCTRL, .LSHIFT}, sdl.GetScancodeFromKey(pressed, nil))
				}
			case 'm', 'M', 'x':
				slot := scripted_keys[index] == 'm' ? 0 : (scripted_keys[index] == 'M' ? 1 : 2)
				click: sdl.Event
				click.type = .MOUSE_BUTTON_UP
				click.button.x = editor.buttons_left + (f32(slot) + 0.5) * editor.painter.cell_width * 4
				click.button.y = editor.top_bar_height / 2
				click.button.button = 1
				_ = sdl.PushEvent(&click)
			}
			return index + 1
		}
		handle_text(editor, scripted_keys[index:index + 1])
		return index + 1
	}

	dialog_context = context
	previous_ticks := sdl.GetTicks()
	for !(.Quit in editor.flags) {
		event: sdl.Event
		if !editor_animating(editor) && scripted_cursor >= len(scripted_keys) && screenshot_path == "" {
			if sdl.WaitEventTimeout(&event, 400) {
				handle_event(editor, event)
			}
			previous_ticks = sdl.GetTicks()
		}
		for sdl.PollEvent(&event) {
			handle_event(editor, event)
		}

		dialog_drain(editor)
		shell_poll(editor)
		index_poll(&editor.index)
		ticks := sdl.GetTicks()
		delta_time := clamp(f32(ticks - previous_ticks) / 1000, 0, 0.1)
		previous_ticks = ticks
		editor.time += delta_time

		if scripted_cursor < len(scripted_keys) {
			scripted_cursor = feed_scripted_key(editor, scripted_keys, scripted_cursor)
		}

		if editor.picker.preview_due != 0 && u64(sdl.GetTicks()) >= editor.picker.preview_due {
			picker_preview_apply(editor)
		}
		if editor.picker.kind != .None {
			preview_warm(editor)
		}

		if (.FontDirty in editor.flags) {
			editor.flags -= {.FontDirty}
			painter_load_font(&editor.painter, editor.config.font_size)
		}
		if (.VsyncDirty in editor.flags) {
			editor.flags -= {.VsyncDirty}
			sdl.SetRenderVSync(editor.renderer, (.Vsync in editor.config.options) ? 1 : 0)
			log.infof("vsync %v", (.Vsync in editor.config.options))
		}

		sdl.GetRenderOutputSize(editor.renderer, &editor.width, &editor.height)
		background := editor.config.theme[.Background]
		sdl.SetRenderDrawColorFloat(editor.renderer, background.r, background.g, background.b, 1)
		sdl.RenderClear(editor.renderer)

		toasts_update(delta_time)
		settings_preview_sync(editor)
		draw_editor(editor, delta_time)
		if editor.settings.open {
			draw_settings(editor)
		}
		if editor.picker.kind != .None {
			draw_picker(editor)
		}
		if editor.color_picker.open {
			draw_color_picker(editor)
		}
		draw_toasts(editor)
		painter_flush(&editor.painter)
		sdl.RenderPresent(editor.renderer)

		for buffer in editor.buffers {
			if .BaselinePending in buffer.flags {
				buffer_set_baseline(editor, buffer)
				break
			}
		}

		if u64(sdl.GetTicks()) > git_checked_ms + 1000 {
			git_checked_ms = u64(sdl.GetTicks())
			git_watch(editor)
		}

		if (.ConfigDirty in editor.flags) || (.SessionDirty in editor.flags) {
			editor.save_timer += delta_time
			if editor.save_timer > 0.1 {
				if (.ConfigDirty in editor.flags) {
					config_save(editor)
				}
				session_save(editor)
				editor.flags -= {.ConfigDirty}
				editor.flags -= {.SessionDirty}
				editor.save_timer = 0
			}
		} else {
			editor.save_timer = 0
		}

		frame_count += 1
		if screenshot_path != "" && scripted_cursor >= len(scripted_keys) && frame_count > len(scripted_keys) + screenshot_delay {
			surface := sdl.RenderReadPixels(editor.renderer, nil)
			sdl.SaveBMP(surface, strings.clone_to_cstring(screenshot_path, context.temp_allocator))
			sdl.DestroySurface(surface)
			editor.flags += {.Quit}
		}
		free_all(context.temp_allocator)
	}

	config_save(editor)
	session_save(editor)
	log.info("vega exiting")
	sdl.DestroyRenderer(editor.renderer)
	sdl.DestroyWindow(editor.window)
	sdl.Quit()
}
