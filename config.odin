package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

Color_Slot :: enum u8 {
	Background,
	Gutter,
	GutterActive,
	Text,
	Comment,
	Keyword,
	Type,
	String,
	Number,
	Function,
	Directive,
	Punctuation,
	Selection,
	Cursor,
	CursorLine,
	StatusBar,
	StatusText,
	Accent,
	Overlay,
	Match,
}

Theme :: [Color_Slot][4]f32

Cursor_Shape :: enum u8 {
	Block,
	Bar,
	Underline,
}

Option :: enum u8 {
	LineNumbers,
	RelativeNumbers,
	CursorLine,
	AutoIndent,
	Vsync,
	SoftWrap,
	RenderWhitespace,
	AutoPairs,
	PairParens,
	PairBrackets,
	PairBraces,
	PairQuotes,
	PairSingles,
	PairBackticks,
	ArrowKeys,
	DiffGutter,
	Fullscreen,
	CursorAnimation,
	SmoothScroll,
	Centered,
	KeyClicks,
	ClickNormal,
	ClickInsert,
	ClickSelect,
	MenuHints,
	TrueBlack,
	Ligatures,
	GitDiff,
}

Options :: bit_set[Option; u32]

option_names := [Option]string {
	.LineNumbers      = "line_numbers",
	.RelativeNumbers  = "relative_numbers",
	.CursorLine       = "cursor_line",
	.AutoIndent       = "auto_indent",
	.Vsync            = "vsync",
	.SoftWrap         = "soft_wrap",
	.RenderWhitespace = "render_whitespace",
	.AutoPairs        = "auto_pairs",
	.PairParens       = "pair_parens",
	.PairBrackets     = "pair_brackets",
	.PairBraces       = "pair_braces",
	.PairQuotes       = "pair_quotes",
	.PairSingles      = "pair_singles",
	.PairBackticks    = "pair_backticks",
	.ArrowKeys        = "arrow_keys",
	.DiffGutter       = "diff_gutter",
	.Fullscreen       = "fullscreen",
	.CursorAnimation  = "cursor_animation",
	.SmoothScroll     = "smooth_scroll",
	.Centered         = "centered",
	.KeyClicks        = "key_clicks",
	.ClickNormal      = "click_normal",
	.ClickInsert      = "click_insert",
	.ClickSelect      = "click_select",
	.MenuHints        = "menu_hints",
	.TrueBlack        = "true_black",
	.Ligatures        = "ligatures",
	.GitDiff          = "git_diff",
}

option_help := [Option]string {
	.LineNumbers      = "Show the gutter",
	.RelativeNumbers  = "Number lines from the cursor instead of the file start",
	.CursorLine       = "Highlight the line under the cursor",
	.AutoIndent       = "Keep the indent when opening a line",
	.Vsync            = "Synchronise presentation with the display",
	.SoftWrap         = "Wrap long lines instead of scrolling sideways",
	.RenderWhitespace = "Draw spaces and tabs",
	.AutoPairs        = "Close brackets as you type, never single quotes",
	.PairParens       = "Close ( as you type",
	.PairBrackets     = "Close [ as you type",
	.PairBraces       = "Close { as you type",
	.PairQuotes       = "Close a double quote as you type",
	.PairSingles      = "Close a single quote as you type",
	.PairBackticks    = "Close a backtick as you type",
	.ArrowKeys        = "Let the arrows move the cursor, off keeps you on the home row",
	.DiffGutter       = "Mark lines that differ from git HEAD",
	.Fullscreen       = "F11 or alt enter also toggles it",
	.CursorAnimation  = "Glide the cursor to its new position",
	.SmoothScroll     = "Animate the scroll instead of jumping",
	.Centered         = "Hold the text in a square centred in the pane",
	.KeyClicks        = "Play a keyboard click as you type",
	.ClickNormal      = "Click in normal mode",
	.ClickInsert      = "Click in insert mode",
	.ClickSelect      = "Click in select mode",
	.MenuHints        = "Show a menu when a prefix key is pressed",
	.TrueBlack        = "Force a dark theme background to pure black",
	.Ligatures        = "Let the font join -> and == into one glyph",
	.GitDiff          = "Diff against git HEAD rather than the file on disk",
}

Config :: struct {
	options:         Options,
	font_size:       f32,
	line_spacing:    f32,
	aspect_ratio:    f32,
	click_volume:    f32,
	click_kind:      u8,
	indent_width:    int,
	scroll_off:      int,
	cursor_speed:    f32,
	scroll_speed:    f32,
	normal_cursor:   Cursor_Shape,
	insert_cursor:   Cursor_Shape,
	select_cursor:   Cursor_Shape,
	theme_name:      string,
	theme:           Theme,
}

Named_Theme :: struct {
	name:   string,
	colors: Theme,
}

builtin_themes := []Named_Theme {
	{
		"midnight",
		{
			.Background = {0.071, 0.078, 0.098, 1},
			.Gutter = {0.30, 0.33, 0.40, 1},
			.GutterActive = {0.85, 0.87, 0.92, 1},
			.Text = {0.85, 0.87, 0.92, 1},
			.Comment = {0.38, 0.44, 0.52, 1},
			.Keyword = {0.78, 0.57, 0.92, 1},
			.Type = {0.45, 0.78, 0.98, 1},
			.String = {0.62, 0.85, 0.52, 1},
			.Number = {0.95, 0.68, 0.45, 1},
			.Function = {0.42, 0.82, 0.80, 1},
			.Directive = {0.92, 0.55, 0.60, 1},
			.Punctuation = {0.62, 0.66, 0.75, 1},
			.Selection = {0.20, 0.28, 0.45, 1},
			.Cursor = {0.95, 0.75, 0.30, 1},
			.CursorLine = {0.10, 0.11, 0.14, 1},
			.StatusBar = {0.12, 0.13, 0.17, 1},
			.StatusText = {0.72, 0.76, 0.84, 1},
			.Accent = {0.45, 0.78, 0.98, 1},
			.Overlay = {0.09, 0.10, 0.13, 1},
			.Match = {0.35, 0.32, 0.15, 1},
		},
	},
	{
		"ember",
		{
			.Background = {0.110, 0.094, 0.086, 1},
			.Gutter = {0.42, 0.36, 0.31, 1},
			.GutterActive = {0.95, 0.88, 0.76, 1},
			.Text = {0.92, 0.86, 0.74, 1},
			.Comment = {0.52, 0.46, 0.38, 1},
			.Keyword = {0.98, 0.49, 0.33, 1},
			.Type = {0.96, 0.76, 0.35, 1},
			.String = {0.70, 0.78, 0.40, 1},
			.Number = {0.85, 0.62, 0.86, 1},
			.Function = {0.55, 0.78, 0.72, 1},
			.Directive = {0.90, 0.45, 0.45, 1},
			.Punctuation = {0.70, 0.64, 0.55, 1},
			.Selection = {0.30, 0.24, 0.18, 1},
			.Cursor = {0.98, 0.72, 0.28, 1},
			.CursorLine = {0.14, 0.12, 0.11, 1},
			.StatusBar = {0.16, 0.14, 0.12, 1},
			.StatusText = {0.82, 0.76, 0.66, 1},
			.Accent = {0.96, 0.62, 0.28, 1},
			.Overlay = {0.13, 0.11, 0.10, 1},
			.Match = {0.36, 0.30, 0.14, 1},
		},
	},
	{
		"glacier",
		{
			.Background = {0.055, 0.075, 0.098, 1},
			.Gutter = {0.32, 0.40, 0.48, 1},
			.GutterActive = {0.86, 0.92, 0.96, 1},
			.Text = {0.84, 0.90, 0.95, 1},
			.Comment = {0.40, 0.50, 0.58, 1},
			.Keyword = {0.52, 0.72, 0.92, 1},
			.Type = {0.58, 0.86, 0.88, 1},
			.String = {0.56, 0.84, 0.72, 1},
			.Number = {0.86, 0.78, 0.52, 1},
			.Function = {0.72, 0.80, 0.96, 1},
			.Directive = {0.88, 0.62, 0.72, 1},
			.Punctuation = {0.64, 0.72, 0.80, 1},
			.Selection = {0.16, 0.28, 0.40, 1},
			.Cursor = {0.62, 0.90, 0.96, 1},
			.CursorLine = {0.08, 0.11, 0.14, 1},
			.StatusBar = {0.09, 0.13, 0.17, 1},
			.StatusText = {0.74, 0.82, 0.90, 1},
			.Accent = {0.52, 0.80, 0.94, 1},
			.Overlay = {0.07, 0.10, 0.13, 1},
			.Match = {0.20, 0.32, 0.36, 1},
		},
	},
	{
		"paper",
		{
			.Background = {0.976, 0.969, 0.949, 1},
			.Gutter = {0.66, 0.64, 0.60, 1},
			.GutterActive = {0.20, 0.20, 0.22, 1},
			.Text = {0.16, 0.17, 0.20, 1},
			.Comment = {0.55, 0.56, 0.54, 1},
			.Keyword = {0.55, 0.22, 0.62, 1},
			.Type = {0.12, 0.42, 0.70, 1},
			.String = {0.20, 0.50, 0.24, 1},
			.Number = {0.74, 0.40, 0.12, 1},
			.Function = {0.10, 0.48, 0.52, 1},
			.Directive = {0.72, 0.24, 0.32, 1},
			.Punctuation = {0.36, 0.38, 0.40, 1},
			.Selection = {0.80, 0.85, 0.94, 1},
			.Cursor = {0.85, 0.45, 0.10, 1},
			.CursorLine = {0.93, 0.92, 0.89, 1},
			.StatusBar = {0.89, 0.88, 0.85, 1},
			.StatusText = {0.24, 0.25, 0.27, 1},
			.Accent = {0.16, 0.45, 0.78, 1},
			.Overlay = {0.94, 0.93, 0.90, 1},
			.Match = {0.94, 0.88, 0.62, 1},
		},
	},
}

default_config :: proc() -> Config {
	return Config {
		options = {
			.LineNumbers,
			.CursorLine,
			.AutoIndent,
			.Vsync,
			.SoftWrap,
			.AutoPairs,
			.PairParens,
			.PairBrackets,
			.PairBraces,
			.PairQuotes,
			.DiffGutter,
			.CursorAnimation,
			.SmoothScroll,
			.MenuHints,
			.Ligatures,
			.KeyClicks,
			.ClickInsert,
			.GitDiff,
		},
		font_size = 18,
		line_spacing = 1.0,
		aspect_ratio = 1.2,
		click_volume = 0.6,
		click_kind = 0,
		indent_width = 4,
		scroll_off = 5,
		cursor_speed = 48,
		scroll_speed = 26,
		normal_cursor = .Block,
		insert_cursor = .Bar,
		select_cursor = .Underline,
		theme_name = strings.clone("earl_grey"),
		theme = builtin_themes[0].colors,
	}
}

theme_by_name :: proc(name: string) -> (Theme, bool) {
	for entry in builtin_themes {
		if entry.name == name {
			return entry.colors, true
		}
	}
	return builtin_themes[0].colors, false
}

token_color_slot :: proc(kind: Token_Kind) -> Color_Slot {
	switch kind {
	case .Keyword:
		return .Keyword
	case .Type:
		return .Type
	case .String:
		return .String
	case .Number:
		return .Number
	case .Comment:
		return .Comment
	case .Function:
		return .Function
	case .Directive:
		return .Directive
	case .Punct:
		return .Punctuation
	case .Identifier:
		return .Text
	}
	return .Text
}

parse_number :: proc(value: string) -> f32 {
	result, _ := strconv.parse_f64(value)
	return f32(result)
}

int_of :: proc(value: string) -> int {
	result, _ := strconv.parse_int(value)
	return result
}

enum_of :: proc(value: string, fallback: $T) -> T {
	for candidate in T {
		if fmt.tprintf("%v", candidate) == value {
			return candidate
		}
	}
	return fallback
}

config_load :: proc(editor: ^Editor) {
	config := &editor.config
	data, error := os.read_entire_file(config_path, context.temp_allocator)
	if error != nil {
		log.info("no config file, using defaults")
		return
	}
	remaining := string(data)
	for line in strings.split_lines_iterator(&remaining) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 {
			continue
		}
		key, value := fields[0], fields[1]
		switch key {
		case "font_size":
			config.font_size = parse_number(value)
		case "aspect_ratio":
			config.aspect_ratio = clamp(parse_number(value), 1, 2)
		case "click_volume":
			config.click_volume = clamp(parse_number(value), 0, 1)
		case "click_kind":
			config.click_kind = u8(int_of(value))
		case "line_spacing":
			config.line_spacing = parse_number(value)
		case "indent_width":
			config.indent_width = int_of(value)
		case "scroll_off":
			config.scroll_off = int_of(value)
			case "cursor_speed":
				config.cursor_speed = parse_number(value)
			case "scroll_speed":
				config.scroll_speed = parse_number(value)
		case "normal_cursor":
			config.normal_cursor = enum_of(value, Cursor_Shape.Block)
		case "insert_cursor":
			config.insert_cursor = enum_of(value, Cursor_Shape.Bar)
		case "select_cursor":
			config.select_cursor = enum_of(value, Cursor_Shape.Underline)
		case "theme":
			delete(config.theme_name)
			config.theme_name = strings.clone(value)
			if colors, found := theme_load(value); found {
				config.theme = colors
			}
		case "color":
			if len(fields) >= 5 {
				slot := enum_of(value, Color_Slot.Text)
				config.theme[slot] = {parse_number(fields[2]), parse_number(fields[3]), parse_number(fields[4]), 1}
			}
		case "bind":
			if len(fields) >= 5 {
				chord := Chord {
					prefix  = fields[1] == "none" ? 0 : fields[1][0],
					key     = fields[2][0],
					mods   = modifiers_from_label(fields[3]),
				}
				editor.keymap[chord] = enum_of(fields[4], Command.None)
			}
		case:
			for name, option in option_names {
				if name == key {
					if value == "true" {
						config.options += {option}
					} else {
						config.options -= {option}
					}
				}
			}
		}
	}
	log.infof("config loaded, theme %s", config.theme_name)
}

config_save :: proc(editor: ^Editor) {
	config := &editor.config
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "font_size %.1f\n", config.font_size)
	fmt.sbprintf(&builder, "line_spacing %.2f\n", config.line_spacing)
	fmt.sbprintf(&builder, "aspect_ratio %.2f\n", config.aspect_ratio)
	fmt.sbprintf(&builder, "click_volume %.2f\n", config.click_volume)
	fmt.sbprintf(&builder, "click_kind %d\n", config.click_kind)
	fmt.sbprintf(&builder, "indent_width %d\n", config.indent_width)
	fmt.sbprintf(&builder, "scroll_off %d\n", config.scroll_off)
	fmt.sbprintf(&builder, "cursor_speed %.1f\n", config.cursor_speed)
	fmt.sbprintf(&builder, "scroll_speed %.1f\n", config.scroll_speed)
	for name, option in option_names {
		fmt.sbprintf(&builder, "%s %v\n", name, option in config.options)
	}
	fmt.sbprintf(&builder, "normal_cursor %v\n", config.normal_cursor)
	fmt.sbprintf(&builder, "insert_cursor %v\n", config.insert_cursor)
	fmt.sbprintf(&builder, "select_cursor %v\n", config.select_cursor)
	fmt.sbprintf(&builder, "theme %s\n", config.theme_name)
	for slot in Color_Slot {
		color := config.theme[slot]
		fmt.sbprintf(&builder, "color %v %.3f %.3f %.3f\n", slot, color.r, color.g, color.b)
	}
	for chord, command in editor.keymap {
		if default_keymap[chord] == command {
			continue
		}
		prefix := chord.prefix == 0 ? "none" : string([]u8{chord.prefix})
		fmt.sbprintf(&builder, "bind %s %c %s %v\n", prefix, chord.key, modifiers_label(chord.mods), command)
	}
	if os.write_entire_file(config_path, transmute([]u8)strings.to_string(builder)) != nil {
		log.error("could not write vega.conf")
		return
	}
	log.info("config saved")
}
