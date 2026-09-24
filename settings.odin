package vega

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

Settings_Section :: enum u8 {
	Editor,
	View,
	Cursor,
	Audio,
	Appearance,
	Keys,
}

Settings_Focus :: enum u8 {
	Sections,
	Fields,
	Scheme,
	Bindings,
}

Settings :: struct {
	open:            bool,
	section:         Settings_Section,
	focus:           Settings_Focus,
	field:           int,
	layer:           int,
	scheme_row:      int,
	scheme_column:   int,
	binding:         int,
	capturing:       bool,
	pending_command: Command,
	choosing:        bool,
	chooser_index:   int,
	chooser_query:   [dynamic]u8,
	saved_buffer:    int,
}

Field_Kind :: enum u8 {
	Toggle,
	Number,
	Real,
	Choice,
	Text,
	Action,
}

Field :: struct {
	label:   string,
	help:    string,
	kind:    Field_Kind,
	option:  Option,
	number:  ^int,
	real:    ^f32,
	choice:  ^u8,
	choices: []string,
	low:     f32,
	high:    f32,
	step:    f32,
	action:  Command,
}

keyboard_scancodes := [][]sdl.Scancode {
	{._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9, ._0, .MINUS, .EQUALS},
	{.Q, .W, .E, .R, .T, .Y, .U, .I, .O, .P, .LEFTBRACKET, .RIGHTBRACKET},
	{.A, .S, .D, .F, .G, .H, .J, .K, .L, .SEMICOLON, .APOSTROPHE},
	{.Z, .X, .C, .V, .B, .N, .M, .COMMA, .PERIOD, .SLASH},
	{.SPACE},
}

Keymap_Layer :: struct {
	prefix: u8,
	mods:   Key_Modifiers,
	name:   string,
}

keymap_layers := []Keymap_Layer {
	{0, {}, "plain"},
	{0, {.Shift}, "shift"},
	{0, {.Ctrl}, "ctrl"},
	{0, {.Alt}, "alt"},
	{0, {.Ctrl, .Shift}, "ctrl shift"},
	{0, {.Ctrl, .Alt}, "ctrl alt"},
	{0, {.Alt, .Shift}, "alt shift"},
	{0, {.Ctrl, .Alt, .Shift}, "ctrl alt shift"},
	{'g', {}, "g"},
	{'m', {}, "m"},
	{'z', {}, "z"},
	{' ', {}, "space"},
	{'w', {}, "ctrl-w window"},
}

layout_key :: proc(row, column: int, shifted: bool) -> u8 {
	scancodes := keyboard_scancodes[clamp(row, 0, len(keyboard_scancodes) - 1)]
	scancode := scancodes[clamp(column, 0, len(scancodes) - 1)]
	keycode := sdl.GetKeyFromScancode(scancode, shifted ? sdl.KMOD_LSHIFT : {}, false)
	if keycode >= 32 && keycode < 127 {
		return u8(keycode)
	}
	return 0
}

keyboard_layout_name :: proc() -> string {
	top_left := layout_key(1, 0, false)
	home := layout_key(2, 0, false)
	switch {
	case top_left == 'a':
		return "azerty"
	case top_left == 'q' && home == 'a':
		return "qwerty"
	case top_left == 'q' && home == 'o':
		return "dvorak"
	case top_left == 'q':
		return "qwertz"
	}
	return "custom"
}

layout_key_name :: proc(row, column: int, shifted: bool) -> string {
	character := layout_key(row, column, shifted)
	if character == ' ' {
		return "space"
	}
	if character == 0 {
		return string(sdl.GetScancodeName(keyboard_scancodes[row][column]))
	}
	return fmt.tprintf("%c", character)
}

settings_panel_width :: proc(editor: ^Editor) -> f32 {
	if !editor.settings.open {
		return 0
	}
	previewing := editor.settings.section == .Appearance
	return previewing ? f32(editor.width) * 0.6 : f32(editor.width)
}

sample_source := `package vega

Editor :: struct {
	buffers: [dynamic]^Buffer,
	options: Options,
	zoom:    f32,
}

editor_open :: proc(editor: ^Editor, path: string) -> bool {
	if path == "" || len(editor.buffers) >= 4096 {
		return false
	}
	for buffer, index in editor.buffers {
		if buffer.path == path {
			editor.active = index
			return true
		}
	}
	count := 0x1F + 42 - 7
	message := "opened \"%s\" with %d lines"
	append(&editor.buffers, buffer_create(editor, path))
	log.infof(message, path, count)
	return true
}
`

settings_sample :: proc(editor: ^Editor) -> int {
	for buffer, index in editor.buffers {
		if .Sample in buffer.flags {
			return index
		}
	}
	buffer := buffer_create(editor, "sample.odin", {.Sample, .ReadOnly}, transmute([]u8)sample_source)
	delete(buffer.display)
	buffer.display = strings.clone("Preview")
	append(&editor.buffers, buffer)
	log.debug("sample buffer created for the appearance preview")
	return len(editor.buffers) - 1
}

settings_preview_sync :: proc(editor: ^Editor) {
	settings := &editor.settings
	previewing := settings.open && settings.section == .Appearance
	view := editor_view(editor)
	if previewing {
		slot := settings_sample(editor)
		if view.buffer != slot {
			settings.saved_buffer = view.buffer
			view.buffer = slot
		}
		return
	}
	for buffer, index in editor.buffers {
		if .Sample in buffer.flags {
			if view.buffer == index {
				view.buffer = clamp(settings.saved_buffer, 0, len(editor.buffers) - 1)
			}
			buffer_destroy(buffer)
			ordered_remove(&editor.buffers, index)
			for &other in editor.views {
				other.buffer = clamp(other.buffer > index ? other.buffer - 1 : other.buffer, 0, max(0, len(editor.buffers) - 1))
			}
			return
		}
	}
}

settings_open :: proc(editor: ^Editor) {
	editor.settings.open = true
	editor.settings.focus = .Sections
	log.info("settings opened")
}

settings_close :: proc(editor: ^Editor) {
	editor.settings.open = false
	editor.settings.capturing = false
	editor.settings.choosing = false
	config_save(editor)
	log.info("settings closed")
}

enum_names :: proc($T: typeid) -> []string {
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	for value in T {
		append(&names, fmt.tprintf("%v", value))
	}
	return names[:]
}

settings_fields :: proc(editor: ^Editor) -> []Field {
	config := &editor.config
	fields := make([dynamic]Field, 0, 24, context.temp_allocator)
	switch editor.settings.section {
	case .Editor:
		append(&fields, Field{label = "Indent width", help = "Spaces inserted by tab and >", kind = .Number, number = &config.indent_width, low = 1, high = 8})
		append(&fields, Field{label = "Scroll off", help = "Lines kept above and below the cursor", kind = .Number, number = &config.scroll_off, low = 0, high = 24})
		append(&fields, Field{label = "Auto indent", help = option_help[.AutoIndent], kind = .Toggle, option = .AutoIndent})
		append(&fields, Field{label = "Line numbers", help = option_help[.LineNumbers], kind = .Toggle, option = .LineNumbers})
		append(&fields, Field{label = "Relative numbers", help = option_help[.RelativeNumbers], kind = .Toggle, option = .RelativeNumbers})
		append(&fields, Field{label = "Cursor line", help = option_help[.CursorLine], kind = .Toggle, option = .CursorLine})
		append(&fields, Field{label = "Menu hints", help = option_help[.MenuHints], kind = .Toggle, option = .MenuHints})
		append(&fields, Field{label = "Auto pairs", help = option_help[.AutoPairs], kind = .Toggle, option = .AutoPairs})
		append(&fields, Field{label = "Pair ( )", help = option_help[.PairParens], kind = .Toggle, option = .PairParens})
		append(&fields, Field{label = "Pair [ ]", help = option_help[.PairBrackets], kind = .Toggle, option = .PairBrackets})
		append(&fields, Field{label = "Pair { }", help = option_help[.PairBraces], kind = .Toggle, option = .PairBraces})
		append(&fields, Field{label = "Pair quotes", help = option_help[.PairQuotes], kind = .Toggle, option = .PairQuotes})
		append(&fields, Field{label = "Pair single quotes", help = option_help[.PairSingles], kind = .Toggle, option = .PairSingles})
		append(&fields, Field{label = "Pair backticks", help = option_help[.PairBackticks], kind = .Toggle, option = .PairBackticks})
		append(&fields, Field{label = "Your name", help = "Signs the todo and note comments of ctrl-t and ctrl-n", kind = .Text, action = .None})
	case .View:
		append(&fields, Field{label = "Centred square", help = option_help[.Centered], kind = .Toggle, option = .Centered})
		append(&fields, Field{label = "Square ratio", help = "How much taller than wide the pane may be before the square shrinks", kind = .Real, real = &config.aspect_ratio, low = 1, high = 2, step = 0.05})
		append(&fields, Field{label = "Soft wrap", help = option_help[.SoftWrap], kind = .Toggle, option = .SoftWrap})
		append(&fields, Field{label = "Show whitespace", help = option_help[.RenderWhitespace], kind = .Toggle, option = .RenderWhitespace})
		append(&fields, Field{label = "Diff gutter", help = option_help[.DiffGutter], kind = .Toggle, option = .DiffGutter})
		append(&fields, Field{label = "Arrow keys", help = option_help[.ArrowKeys], kind = .Toggle, option = .ArrowKeys})
		append(&fields, Field{label = "Fullscreen", help = option_help[.Fullscreen], kind = .Toggle, option = .Fullscreen})
		append(&fields, Field{label = "Smooth scroll", help = option_help[.SmoothScroll], kind = .Toggle, option = .SmoothScroll})
		append(&fields, Field{label = "Scroll speed", help = "Higher settles the scroll faster", kind = .Real, real = &config.scroll_speed, low = 6, high = 60, step = 2})
		append(&fields, Field{label = "Line spacing", help = "Multiplies the line height", kind = .Real, real = &config.line_spacing, low = 0.8, high = 2.0, step = 0.05})
		append(&fields, Field{label = "Vsync", help = option_help[.Vsync], kind = .Toggle, option = .Vsync})
		append(&fields, Field{label = "Git diff", help = option_help[.GitDiff], kind = .Toggle, option = .GitDiff})
	case .Cursor:
		append(&fields, Field{label = "Animation", help = option_help[.CursorAnimation], kind = .Toggle, option = .CursorAnimation})
		append(&fields, Field{label = "Animation speed", help = "Higher is snappier, the cursor glides to its new spot", kind = .Real, real = &config.cursor_speed, low = 8, high = 90, step = 2})
		append(&fields, Field{label = "Normal shape", help = "The cursor in normal mode", kind = .Choice, choice = (^u8)(&config.normal_cursor), choices = enum_names(Cursor_Shape)})
		append(&fields, Field{label = "Insert shape", help = "The cursor in insert mode", kind = .Choice, choice = (^u8)(&config.insert_cursor), choices = enum_names(Cursor_Shape)})
		append(&fields, Field{label = "Select shape", help = "The cursor in select mode", kind = .Choice, choice = (^u8)(&config.select_cursor), choices = enum_names(Cursor_Shape)})
	case .Audio:
		append(&fields, Field{label = "Key clicks", help = option_help[.KeyClicks], kind = .Toggle, option = .KeyClicks})
		append(&fields, Field{label = "Volume", help = "How loud each key click is", kind = .Real, real = &config.click_volume, low = 0, high = 1, step = 0.05})
		append(&fields, Field{label = "Click kind", help = "Which keyboard the clicks are sampled from", kind = .Choice, choice = &config.click_kind, choices = sfx_family_names()})
		append(&fields, Field{label = "Click in normal", help = option_help[.ClickNormal], kind = .Toggle, option = .ClickNormal})
		append(&fields, Field{label = "Click in insert", help = option_help[.ClickInsert], kind = .Toggle, option = .ClickInsert})
		append(&fields, Field{label = "Click in select", help = option_help[.ClickSelect], kind = .Toggle, option = .ClickSelect})
		append(&fields, Field{label = "Delete sound", help = option_help[.DeleteSound], kind = .Toggle, option = .DeleteSound})
		append(&fields, Field{label = "Delete volume", help = "How loud a deletion is", kind = .Real, real = &config.delete_volume, low = 0, high = 1, step = 0.05})
		append(&fields, Field{label = "Brown noise", help = option_help[.BrownNoise], kind = .Toggle, option = .BrownNoise})
		append(&fields, Field{label = "Noise volume", help = "How loud the brown noise is", kind = .Real, real = &config.noise_volume, low = 0, high = 1, step = 0.05})
		append(&fields, Field{label = "Noise tone", help = "Sweeps the corner from 50 Hz to 800 Hz, the middle of the slider being 200 Hz", kind = .Real, real = &config.noise_tone, low = 0, high = 1, step = 0.05})
	case .Appearance:
		append(&fields, Field{label = "Font size", help = "Rebuilds the glyph atlas live", kind = .Real, real = &config.font_size, low = 8, high = 48, step = 1})
		append(&fields, Field{label = "Theme preset", help = "Browse the themes with a live preview", kind = .Action, action = .None})
		append(&fields, Field{label = "Ligatures", help = option_help[.Ligatures], kind = .Toggle, option = .Ligatures})
		append(&fields, Field{label = "True black", help = option_help[.TrueBlack], kind = .Toggle, option = .TrueBlack})
	case .Keys:
	}
	return fields[:]
}

field_value_text :: proc(editor: ^Editor, field: Field) -> string {
	switch field.kind {
	case .Toggle:
			return field.option in editor.config.options ? "on" : "off"
	case .Number:
		return fmt.tprintf("%d", field.number^)
	case .Real:
		return fmt.tprintf("%.2f", field.real^)
	case .Choice:
		return field.choices[min(int(field.choice^), len(field.choices) - 1)]
	case .Text:
		return editor.config.user_name == "" ? "unset" : editor.config.user_name
	case .Action:
		return "open"
	}
	return ""
}

field_adjust :: proc(editor: ^Editor, field: Field, delta: int) {
	switch field.kind {
	case .Toggle:
		editor.config.options ~= {field.option}
		if field.option == .Vsync {
			editor.flags += {.VsyncDirty}
		}
		if field.option == .Fullscreen {
			sdl.SetWindowFullscreen(editor.window, .Fullscreen in editor.config.options)
		}
		if field.option == .TrueBlack {
			editor.flags += {.FontDirty}
			theme_apply_options(editor)
		}
	case .Number:
		field.number^ = clamp(field.number^ + delta, int(field.low), int(field.high))
	case .Real:
		field.real^ = clamp(field.real^ + f32(delta) * field.step, field.low, field.high)
		if field.real == &editor.config.font_size {
			editor.flags += {.FontDirty}
		}
	case .Choice:
		count := u8(len(field.choices))
		field.choice^ = u8((int(field.choice^) + delta + len(field.choices)) % int(count))
	case .Text, .Action:
	}
	editor.flags += {.ConfigDirty}
	log.debugf("setting %s is now %s", field.label, field_value_text(editor, field))
}

field_activate :: proc(editor: ^Editor, field: Field) {
	switch field.kind {
	case .Text:
		settings_close(editor)
		prompt_open(editor, .UserName)
		clear(&editor.prompt_input)
		append(&editor.prompt_input, editor.config.user_name)
		editor.prompt_cursor = len(editor.prompt_input)
	case .Action:
		if field.label == "Theme preset" {
			picker_open(editor, .Themes, "Theme")
		}
	case .Toggle, .Number, .Real, .Choice:
		field_adjust(editor, field, 1)
	}
}

settings_text :: proc(editor: ^Editor, text: string) {
	settings := &editor.settings
	if settings.choosing {
		append(&settings.chooser_query, text)
		settings.chooser_index = 0
		return
	}
	if settings.capturing {
		keymap_bind(editor, Chord{keymap_layers[settings.layer].prefix, text[0], keymap_layers[settings.layer].mods}, settings.pending_command)
		settings.capturing = false
		return
	}
	if text[0] == 'q' {
		settings_close(editor)
	}
}

settings_key :: proc(editor: ^Editor, key: sdl.Keycode, shift, control, alt: bool) {
	settings := &editor.settings

	if settings.choosing {
		commands := chooser_commands(editor)
		switch key {
		case sdl.K_ESCAPE:
			settings.choosing = false
		case sdl.K_RETURN:
			if len(commands) > 0 {
				chord := scheme_chord(editor)
				keymap_bind(editor, chord, commands[clamp(settings.chooser_index, 0, len(commands) - 1)])
			}
			settings.choosing = false
		case sdl.K_BACKSPACE:
			if len(settings.chooser_query) > 0 {
				resize(&settings.chooser_query, len(settings.chooser_query) - 1)
			}
		case sdl.K_DOWN, sdl.K_TAB:
			settings.chooser_index = clamp(settings.chooser_index + (shift ? -1 : 1), 0, max(0, len(commands) - 1))
		case sdl.K_UP:
			settings.chooser_index = max(0, settings.chooser_index - 1)
		}
		return
	}

	if settings.capturing {
		if key == sdl.K_ESCAPE {
			settings.capturing = false
			return
		}
		if (control || alt) && key >= 32 && key < 127 {
			mods: Key_Modifiers
			if control {
				mods += {.Ctrl}
			}
			if alt {
				mods += {.Alt}
			}
			if shift {
				mods += {.Shift}
			}
			keymap_bind(editor, Chord{keymap_layers[settings.layer].prefix, u8(key), mods}, settings.pending_command)
			settings.capturing = false
		}
		return
	}

	switch key {
	case sdl.K_ESCAPE:
		settings_close(editor)
		return
	case sdl.K_TAB:
		order := settings.section == .Keys ? []Settings_Focus{.Sections, .Scheme, .Bindings} : []Settings_Focus{.Sections, .Fields}
		current := 0
		for focus, index in order {
			if focus == settings.focus {
				current = index
			}
		}
		settings.focus = order[(current + (shift ? len(order) - 1 : 1)) % len(order)]
		return
	}

	switch settings.focus {
	case .Sections:
		switch key {
		case sdl.K_DOWN:
			settings.section = Settings_Section((int(settings.section) + 1) % len(Settings_Section))
			settings.field = 0
		case sdl.K_UP:
			settings.section = Settings_Section((int(settings.section) + len(Settings_Section) - 1) % len(Settings_Section))
			settings.field = 0
		case sdl.K_RETURN, sdl.K_RIGHT:
			settings.focus = settings.section == .Keys ? .Scheme : .Fields
		}
	case .Fields:
		fields := settings_fields(editor)
		if len(fields) == 0 {
			return
		}
		settings.field = clamp(settings.field, 0, len(fields) - 1)
		switch key {
		case sdl.K_DOWN:
			settings.field = min(settings.field + 1, len(fields) - 1)
		case sdl.K_UP:
			settings.field = max(settings.field - 1, 0)
		case sdl.K_LEFT:
			field_adjust(editor, fields[settings.field], -1)
		case sdl.K_RIGHT:
			field_adjust(editor, fields[settings.field], 1)
		case sdl.K_RETURN:
			field_activate(editor, fields[settings.field])
		}
	case .Scheme:
		row := keyboard_scancodes[settings.scheme_row]
		switch key {
		case sdl.K_DOWN:
			settings.scheme_row = min(settings.scheme_row + 1, len(keyboard_scancodes) - 1)
		case sdl.K_UP:
			settings.scheme_row = max(settings.scheme_row - 1, 0)
		case sdl.K_LEFT:
			settings.scheme_column = max(settings.scheme_column - 1, 0)
		case sdl.K_RIGHT:
			settings.scheme_column = min(settings.scheme_column + 1, len(row) - 1)
		case sdl.K_PAGEDOWN:
			settings.layer = (settings.layer + 1) % len(keymap_layers)
		case sdl.K_PAGEUP:
			settings.layer = (settings.layer + len(keymap_layers) - 1) % len(keymap_layers)
		case sdl.K_RETURN:
			settings.choosing = true
			settings.chooser_index = 0
			clear(&settings.chooser_query)
		case sdl.K_DELETE:
			delete_key(&editor.keymap, scheme_chord(editor))
		}
		settings.scheme_column = min(settings.scheme_column, len(keyboard_scancodes[settings.scheme_row]) - 1)
	case .Bindings:
		bindings := layer_bindings(editor)
		switch key {
		case sdl.K_DOWN:
			settings.binding = min(settings.binding + 1, max(0, len(bindings) - 1))
		case sdl.K_UP:
			settings.binding = max(settings.binding - 1, 0)
		case sdl.K_PAGEDOWN:
			settings.layer = (settings.layer + 1) % len(keymap_layers)
		case sdl.K_PAGEUP:
			settings.layer = (settings.layer + len(keymap_layers) - 1) % len(keymap_layers)
		case sdl.K_RETURN:
			if len(bindings) > 0 {
				settings.capturing = true
				settings.pending_command = bindings[clamp(settings.binding, 0, len(bindings) - 1)].command
			}
		}
	}
}

scheme_chord :: proc(editor: ^Editor) -> Chord {
	settings := editor.settings
	layer := keymap_layers[settings.layer]
	shifted := .Shift in layer.mods
	return Chord {
		prefix = layer.prefix,
		key = layout_key(settings.scheme_row, settings.scheme_column, shifted),
		mods = layer.mods - {.Shift},
	}
}

Layer_Binding :: struct {
	chord:   Chord,
	command: Command,
}

layer_bindings :: proc(editor: ^Editor) -> []Layer_Binding {
	layer := keymap_layers[editor.settings.layer]
	bindings := make([dynamic]Layer_Binding, 0, 64, context.temp_allocator)
	for chord, command in editor.keymap {
		if chord.prefix == layer.prefix && chord.mods == layer.mods {
			append(&bindings, Layer_Binding{chord, command})
		}
	}
	for outer in 0 ..< len(bindings) {
		for inner in outer + 1 ..< len(bindings) {
			if bindings[inner].chord.key < bindings[outer].chord.key {
				bindings[outer], bindings[inner] = bindings[inner], bindings[outer]
			}
		}
	}
	return bindings[:]
}

chooser_commands :: proc(editor: ^Editor) -> []Command {
	query := strings.to_lower(string(editor.settings.chooser_query[:]), context.temp_allocator)
	commands := make([dynamic]Command, 0, len(Command), context.temp_allocator)
	for command in Command {
		name := fmt.tprintf("%v", command)
		if _, matched := fuzzy_score(name, strings.to_lower(name, context.temp_allocator), query); matched {
			append(&commands, command)
		}
	}
	return commands[:]
}

command_at_chord :: proc(editor: ^Editor, chord: Chord) -> Command {
	if command, found := editor.keymap[chord]; found {
		return command
	}
	return .None
}

draw_settings :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	settings := &editor.settings
	cell := painter.cell_width
	line_height := painter.line_height

	panel := settings_panel_width(editor)
	previewing := panel < f32(editor.width)
	push_rect(painter, 0, 0, panel, f32(editor.height), theme[.Overlay])
	push_rect(painter, 0, f32(editor.height) - line_height * 1.8, panel, line_height * 1.8, theme[.StatusBar])
	push_rect(painter, 0, 0, panel, line_height * 1.6, theme[.StatusBar])
	push_rect(painter, panel - 2, 0, 2, f32(editor.height), theme[.Accent])
	push_text(painter, cell * 2, line_height * 0.3, previewing ? "Settings - preview right" : "Settings", theme[.Accent])
	hint := "Tab focus   arrows adjust   enter activate   esc save and close"
	hint_x := panel - cell * f32(len(hint) + 2)
	if hint_x > cell * 30 {
		push_text(painter, hint_x, line_height * 0.3, hint, theme[.Comment])
	}

	sidebar := cell * 18
	top := line_height * 2.4
	for section, index in Settings_Section {
		y := top + f32(index) * line_height * 1.4
		selected := section == settings.section
		if selected {
			push_rect(painter, cell, y, sidebar - cell * 2, line_height * 1.2, settings.focus == .Sections ? theme[.Selection] : theme[.CursorLine])
		}
		push_text(painter, cell * 2, y + line_height * 0.1, fmt.tprintf("%v", section), selected ? theme[.Accent] : theme[.Text])
	}

	if settings.section == .Keys {
		draw_keymap_editor(editor, sidebar, top)
		return
	}

	fields := settings_fields(editor)
	settings.field = clamp(settings.field, 0, max(0, len(fields) - 1))
	for field, index in fields {
		y := top + f32(index) * line_height * 1.4
		selected := index == settings.field && settings.focus == .Fields
		if selected {
			push_rect(painter, sidebar, y, panel - sidebar - cell, line_height * 1.2, theme[.Selection])
		}
		push_text(painter, sidebar + cell, y + line_height * 0.1, field.label, selected ? theme[.Accent] : theme[.Text])
		value_x := sidebar + cell * 24
		push_text(painter, value_x, y + line_height * 0.1, field_value_text(editor, field), theme[.String])

		switch field.kind {
		case .Real, .Number:
			low := field.kind == .Real ? field.low : f32(int(field.low))
			high := field.kind == .Real ? field.high : f32(int(field.high))
			value := field.kind == .Real ? field.real^ : f32(field.number^)
			track := cell * 20
			push_rect(painter, value_x + cell * 10, y + line_height * 0.5, track, 2, theme[.Gutter])
			ratio := clamp((value - low) / max(0.001, high - low), 0, 1)
			push_rect(painter, value_x + cell * 10 + track * ratio - 2, y + line_height * 0.2, 4, line_height * 0.8, theme[.Accent])
		case .Toggle, .Choice, .Text, .Action:
		}
	}

	if len(fields) > 0 {
		push_text(painter, cell * 2, f32(editor.height) - line_height * 1.4, fields[settings.field].help, theme[.Comment])
	}
}

draw_keymap_editor :: proc(editor: ^Editor, sidebar, top: f32) {
	painter := &editor.painter
	theme := editor.active_theme
	settings := &editor.settings
	cell := painter.cell_width
	line_height := painter.line_height
	layer := keymap_layers[settings.layer]
	shifted := .Shift in layer.mods

	push_text(
		painter,
		sidebar + cell,
		top,
		fmt.tprintf("layer %s   page up and page down change layer   %s keyboard", layer.name, keyboard_layout_name()),
		theme[.Accent],
	)

	widest := 0
	for row in keyboard_scancodes {
		widest = max(widest, len(row))
	}
	available := f32(editor.width) - sidebar - cell * 3 - f32(len(keyboard_scancodes)) * cell * 1.2
	key_width := min(cell * 9, available / f32(widest) - 4)
	key_height := line_height * 2.6
	origin_x := sidebar + cell
	origin_y := top + line_height * 1.8

	for row, row_index in keyboard_scancodes {
		for column in 0 ..< len(row) {
			character := layout_key(row_index, column, shifted)
			width := character == ' ' ? key_width * 6 : key_width
			x := origin_x + f32(column) * (key_width + 4) + f32(row_index) * cell * 1.2
			y := origin_y + f32(row_index) * (key_height + 4)
			command := command_at_chord(editor, Chord{layer.prefix, character, layer.mods - {.Shift}})
			selected := settings.focus == .Scheme && row_index == settings.scheme_row && column == settings.scheme_column

			border := command != .None ? theme[.Accent] : theme[.Gutter]
			fill := command != .None ? theme[.CursorLine] : theme[.Overlay]
			if selected {
				border, fill = theme[.Cursor], theme[.Selection]
			}
			if character == 0 {
				border = theme[.Gutter] * [4]f32{1, 1, 1, 0.4}
			}
			push_rect(painter, x, y, width, key_height, border)
			push_rect(painter, x + 2, y + 2, width - 4, key_height - 4, fill)
			push_text(painter, x + 6, y + 4, layout_key_name(row_index, column, shifted), selected ? theme[.Accent] : theme[.Text])
			if command != .None {
				name := fmt.tprintf("%v", command)
				room := int(width / cell) - 1
				push_text(painter, x + 6, y + line_height + 2, name[:min(room, len(name))], theme[.Comment])
			}
		}
	}

	list_y := origin_y + f32(len(keyboard_scancodes)) * (key_height + 4) + line_height
	bindings := layer_bindings(editor)
	settings.binding = clamp(settings.binding, 0, max(0, len(bindings) - 1))
	visible := max(1, int((f32(editor.height) - list_y - line_height * 2) / line_height))
	start := max(0, min(settings.binding - visible / 2, len(bindings) - visible))
	for index in start ..< min(len(bindings), start + visible) {
		entry := bindings[index]
		y := list_y + f32(index - start) * line_height
		if index == settings.binding && settings.focus == .Bindings {
			push_rect(painter, sidebar, y, f32(editor.width) - sidebar - cell * 2, line_height, theme[.Selection])
		}
		push_text(painter, sidebar + cell, y, fmt.tprintf("%-12s %v", chord_label(entry.chord), entry.command), theme[.Text])
		push_text(painter, sidebar + cell * 40, y, command_help[entry.command], theme[.Comment])
	}

	footer := "enter on a key picks a command, enter on a binding captures a new key, delete unbinds, page up and down switch layer"
	if settings.capturing {
		footer = fmt.tprintf("press the new key for %v, hold ctrl alt or shift for a modifier chord, esc to cancel", settings.pending_command)
	}
	push_text(painter, cell * 2, f32(editor.height) - line_height * 1.4, footer, settings.capturing ? theme[.Cursor] : theme[.Comment])

	if settings.choosing {
		draw_command_chooser(editor)
	}
}

draw_command_chooser :: proc(editor: ^Editor) {
	painter := &editor.painter
	theme := editor.active_theme
	settings := &editor.settings
	cell := painter.cell_width
	line_height := painter.line_height
	commands := chooser_commands(editor)
	settings.chooser_index = clamp(settings.chooser_index, 0, max(0, len(commands) - 1))

	width := cell * 60
	rows := min(16, max(1, len(commands)))
	height := line_height * f32(rows + 2)
	x := (f32(editor.width) - width) / 2
	y := (f32(editor.height) - height) / 2

	push_rect(painter, x - 2, y - 2, width + 4, height + 4, theme[.Accent])
	push_rect(painter, x, y, width, height, theme[.Overlay])
	chord := scheme_chord(editor)
	push_text(painter, x + cell, y + 4, fmt.tprintf("Bind %s to> %s_", chord_label(chord), string(settings.chooser_query[:])), theme[.Cursor])

	start := max(0, min(settings.chooser_index - rows / 2, len(commands) - rows))
	for index in start ..< min(len(commands), start + rows) {
		row_y := y + line_height * f32(index - start + 1) + 6
		if index == settings.chooser_index {
			push_rect(painter, x, row_y, width, line_height, theme[.Selection])
		}
		push_text(painter, x + cell, row_y, fmt.tprintf("%v", commands[index]), theme[.Text])
		push_text(painter, x + cell * 26, row_y, command_help[commands[index]], theme[.Comment])
	}
}

