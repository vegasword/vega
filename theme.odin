#+feature dynamic-literals
package vega

import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

THEMES_DIRECTORY :: "themes"

Scope_Style :: struct {
	foreground: [4]f32,
	background: [4]f32,
	has_foreground: bool,
	has_background: bool,
	dim: bool,
}

ansi_colors := map[string][4]f32 {
	"black"   = {0.10, 0.10, 0.12, 1},
	"red"     = {0.85, 0.35, 0.35, 1},
	"green"   = {0.45, 0.75, 0.45, 1},
	"yellow"  = {0.90, 0.78, 0.45, 1},
	"blue"    = {0.40, 0.65, 0.92, 1},
	"magenta" = {0.75, 0.50, 0.88, 1},
	"purple"  = {0.75, 0.50, 0.88, 1},
	"cyan"    = {0.40, 0.78, 0.82, 1},
	"gray"    = {0.45, 0.47, 0.52, 1},
	"grey"    = {0.45, 0.47, 0.52, 1},
	"white"   = {0.88, 0.90, 0.93, 1},
}

color_from_hex :: proc(text: string) -> ([4]f32, bool) {
	digits := strings.trim_prefix(strings.trim_space(text), "#")
	if len(digits) != 6 && len(digits) != 8 {
		return {}, false
	}
	value, ok := strconv.parse_u64_of_base(digits[:6], 16)
	if !ok {
		return {}, false
	}
	return {f32((value >> 16) & 0xff) / 255, f32((value >> 8) & 0xff) / 255, f32(value & 0xff) / 255, 1}, true
}


baked_themes := #load_directory("themes")

theme_source :: proc(name: string) -> ([]u8, bool) {
	path := strings.concatenate({THEMES_DIRECTORY, "/", name, ".toml"}, context.temp_allocator)
	if data, error := os.read_entire_file(path, context.temp_allocator); error == nil {
		return data, true
	}
	file := strings.concatenate({name, ".toml"}, context.temp_allocator)
	for entry in baked_themes {
		if entry.name == file {
			return entry.data, true
		}
	}
	return nil, false
}

theme_names :: proc(allocator := context.allocator) -> []string {
	names := make([dynamic]string, 0, 256, allocator)
	seen := make(map[string]bool, 256, context.temp_allocator)
	for entry in baked_themes {
		if strings.has_suffix(entry.name, ".toml") {
			seen[entry.name] = true
			append(&names, strings.clone(entry.name[:len(entry.name) - 5], allocator))
		}
	}
	if infos, error := os.read_all_directory_by_path(THEMES_DIRECTORY, context.temp_allocator); error == nil {
		for info in infos {
			if strings.has_suffix(info.name, ".toml") && !seen[info.name] {
				append(&names, strings.clone(info.name[:len(info.name) - 5], allocator))
			}
		}
	}
	slice.sort(names[:])
	return names[:]
}

theme_cache: map[string]Theme

theme_load :: proc(name: string, depth := 0) -> (theme: Theme, ok: bool) {
	if depth > 4 {
		return {}, false
	}
	if cached, found := theme_cache[name]; found {
		return cached, true
	}
	data, found := theme_source(name)
	if !found {
		if colors, built_in := theme_by_name(name); built_in {
			return colors, true
		}
		log.warnf("theme %s not found", name)
		return {}, false
	}

	palette := make(map[string][4]f32, context.temp_allocator)
	scopes := make(map[string]Scope_Style, context.temp_allocator)
	parent := ""
	in_palette := false

	palette_pass := string(data)
	in_palette_section := false
	for raw_line in strings.split_lines_iterator(&palette_pass) {
		line := strings.trim_space(raw_line)
		if strings.has_prefix(line, "[") {
			in_palette_section = strings.has_prefix(line, "[palette]")
			continue
		}
		equals := strings.index_byte(line, '=')
		if !in_palette_section || equals < 0 || strings.has_prefix(line, "#") {
			continue
		}
		key := strings.trim(strings.trim_space(line[:equals]), "\"")
		if color, valid := color_from_hex(strings.trim(strings.trim_space(line[equals + 1:]), "\"")); valid {
			palette[strings.clone(key, context.temp_allocator)] = color
		}
	}

	remaining := string(data)
	for raw_line in strings.split_lines_iterator(&remaining) {
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		if strings.has_prefix(line, "[") {
			in_palette = strings.has_prefix(line, "[palette]")
			continue
		}
		equals := strings.index_byte(line, '=')
		if equals < 0 {
			continue
		}
		key := strings.trim_space(strings.trim(strings.trim_space(line[:equals]), "\""))
		value := strings.trim_space(line[equals + 1:])
		if key == "inherits" {
			parent = strings.trim(value, "\"")
			continue
		}
		if in_palette {
			if color, valid := color_from_hex(strings.trim(value, "\"")); valid {
				palette[strings.clone(key, context.temp_allocator)] = color
			}
			continue
		}
		scopes[strings.clone(key, context.temp_allocator)] = parse_scope_style(value, palette)
	}

	theme = builtin_themes[0].colors
	rooted := true
	if parent != "" {
		if inherited, found := theme_load(parent, depth + 1); found {
			theme = inherited
			rooted = false
		}
	}
	theme_apply_scopes(&theme, scopes, rooted)
	theme_cache[strings.clone(name)] = theme
	log.infof("theme %s loaded, %d scopes, parent %s", name, len(scopes), parent == "" ? "none" : parent)
	return theme, true
}

parse_scope_style :: proc(value: string, palette: map[string][4]f32) -> Scope_Style {
	style: Scope_Style
	resolve :: proc(text: string, palette: map[string][4]f32) -> ([4]f32, bool) {
		name := strings.trim(strings.trim_space(text), "\"")
		if color, found := palette[name]; found {
			return color, true
		}
		if color, valid := color_from_hex(name); valid {
			return color, true
		}
		if color, found := ansi_colors[strings.trim_prefix(name, "bright-")]; found {
			return color, true
		}
		return {}, false
	}

	if !strings.has_prefix(value, "{") {
		if color, found := resolve(value, palette); found {
			style.foreground = color
			style.has_foreground = true
		}
		return style
	}
	style.dim = strings.contains(value, "\"dim\"")
	body := strings.trim(value, "{} ")
	for part in strings.split(body, ",", context.temp_allocator) {
		equals := strings.index_byte(part, '=')
		if equals < 0 {
			continue
		}
		field := strings.trim_space(part[:equals])
		if color, found := resolve(part[equals + 1:], palette); found {
			if field == "fg" {
				style.foreground = color
				style.has_foreground = true
			} else if field == "bg" {
				style.background = color
				style.has_background = true
			}
		}
	}
	return style
}

theme_apply_scopes :: proc(theme: ^Theme, scopes: map[string]Scope_Style, rooted: bool) {
	take :: proc(scopes: map[string]Scope_Style, names: []string, background: bool) -> ([4]f32, bool) {
		for name in names {
			if style, found := scopes[name]; found {
				if background && style.has_background {
					return style.background, true
				}
				if !background && style.has_foreground {
					return style.foreground, true
				}
			}
		}
		return {}, false
	}

	assign :: proc(target: ^[4]f32, color: [4]f32, found: bool) {
		if found {
			target^ = color
		}
	}

	assign(&theme[.Background], take(scopes, {"ui.background"}, true))
	assign(&theme[.Text], take(scopes, {"ui.text", "ui.background"}, false))

	if rooted {
		for slot in ([]Color_Slot{.Comment, .Keyword, .Type, .String, .Number, .Function, .Directive, .Punctuation, .GutterActive}) {
			theme[slot] = theme[.Text]
		}
	}
	assign(&theme[.Gutter], take(scopes, {"ui.linenr", "ui.virtual"}, false))
	assign(&theme[.GutterActive], take(scopes, {"ui.linenr.selected", "ui.text"}, false))
	assign(&theme[.Comment], take(scopes, {"comment", "comment.line"}, false))
	assign(&theme[.Keyword], take(scopes, {"keyword", "keyword.control"}, false))
	assign(&theme[.Type], take(scopes, {"type", "type.builtin"}, false))
	assign(&theme[.String], take(scopes, {"string"}, false))
	assign(&theme[.Number], take(scopes, {"constant.numeric", "constant"}, false))
	assign(&theme[.Function], take(scopes, {"function", "function.method"}, false))
	assign(&theme[.Directive], take(scopes, {"keyword.directive", "special", "attribute"}, false))
	assign(&theme[.Punctuation], take(scopes, {"punctuation", "operator", "ui.text"}, false))
	assign(&theme[.Selection], take(scopes, {"ui.selection.primary", "ui.selection"}, true))
	assign(&theme[.Cursor], take(scopes, {"ui.cursor.primary", "ui.cursor"}, true))
	assign(&theme[.CursorLine], take(scopes, {"ui.cursorline.primary", "ui.cursorline"}, true))
	assign(&theme[.StatusBar], take(scopes, {"ui.statusline"}, true))
	assign(&theme[.StatusText], take(scopes, {"ui.statusline"}, false))
	assign(&theme[.Accent], take(scopes, {"ui.statusline.normal", "keyword", "function"}, true))
	assign(&theme[.Overlay], take(scopes, {"ui.popup", "ui.menu", "ui.background"}, true))
	assign(&theme[.Match], take(scopes, {"ui.cursor.match", "ui.highlight"}, true))

	if style, found := scopes["comment"]; found && style.dim && !style.has_foreground {
		theme[.Comment] = {theme[.Text].r * 0.6, theme[.Text].g * 0.6, theme[.Text].b * 0.6, 1}
	}
	if cursor, found := take(scopes, {"ui.cursor.primary", "ui.cursor"}, false); found && theme[.Cursor] == theme[.Background] {
		theme[.Cursor] = cursor
	}
	if accent, found := take(scopes, {"keyword", "function"}, false); found && theme[.Accent] == theme[.Background] {
		theme[.Accent] = accent
	}
}

theme_set :: proc(editor: ^Editor, name: string) -> bool {
	colors, found := theme_load(name)
	if !found {
		return false
	}
	editor.config.theme = colors
	delete(editor.config.theme_name)
	editor.config.theme_name = strings.clone(name)
	editor.flags += {.ConfigDirty}
	return true
}

theme_apply_options :: proc(editor: ^Editor) {
	editor.active_theme = editor.config.theme
	if !(.TrueBlack in editor.config.options) {
		return
	}
	background := editor.config.theme[.Background]
	if background.r + background.g + background.b > 1.5 {
		return
	}
	editor.active_theme[.Background] = {0, 0, 0, 1}
	for slot in Color_Slot {
		if slot == .Overlay || slot == .StatusBar || slot == .CursorLine {
			editor.active_theme[slot] = editor.config.theme[slot] * [4]f32{0.45, 0.45, 0.45, 1}
		}
	}
}