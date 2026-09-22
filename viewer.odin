package vega

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

Content_Kind :: enum u8 {
	Text,
	Markdown,
	Image,
	Pdf,
	Shell,
}

content_kind_of_path :: proc(path: string) -> Content_Kind {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".md", ".markdown":
		return .Markdown
	case ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".gif", ".psd":
		return .Image
	case ".pdf":
		return .Pdf
	case ".sh", ".bash", ".zsh", ".ps1", ".bat", ".cmd":
		return .Shell
	}
	return .Text
}

image_load :: proc(editor: ^Editor, buffer: ^Buffer) {
	width, height, channels: i32
	pixels := stbi.load(strings.clone_to_cstring(buffer.path, context.temp_allocator), &width, &height, &channels, 4)
	if pixels == nil {
		log.errorf("could not decode the image %s", buffer.path)
		return
	}
	defer stbi.image_free(pixels)

	surface := sdl.CreateSurfaceFrom(width, height, .ABGR8888, pixels, width * 4)
	if surface == nil {
		log.errorf("could not wrap the image %s: %s", buffer.path, sdl.GetError())
		return
	}
	defer sdl.DestroySurface(surface)
	buffer.texture = sdl.CreateTextureFromSurface(editor.renderer, surface)
	sdl.SetTextureScaleMode(buffer.texture, .LINEAR)
	buffer.image_width = int(width)
	buffer.image_height = int(height)
	log.infof("image %s loaded, %dx%d with %d channels", buffer.path, width, height, channels)
}

pdf_extract_text :: proc(data: []u8, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	pages := strings.count(string(data), "/Type /Page") + strings.count(string(data), "/Type/Page")
	fmt.sbprintf(&builder, "%d bytes, about %d page(s), text extracted by vega\n\n", len(data), max(1, pages))

	cursor := 0
	streams := 0
	for {
		start := strings.index(string(data[cursor:]), "stream")
		if start < 0 {
			break
		}
		start += cursor + 6
		for start < len(data) && (data[start] == '\r' || data[start] == '\n') {
			start += 1
		}
		finish := strings.index(string(data[start:]), "endstream")
		if finish < 0 {
			break
		}
		finish += start
		cursor = finish + 9
		streams += 1

		payload := data[start:finish]
		decoded: []u8
		output: bytes.Buffer
		if zlib.inflate_from_byte_array(payload, &output) == nil {
			decoded = output.buf[:]
		} else {
			decoded = payload
		}
		defer bytes.buffer_destroy(&output)

		inside := false
		for index in 0 ..< len(decoded) {
			character := decoded[index]
			if character == '(' && (index == 0 || decoded[index - 1] != '\\') {
				inside = true
				continue
			}
			if character == ')' && (index == 0 || decoded[index - 1] != '\\') {
				inside = false
				strings.write_byte(&builder, ' ')
				continue
			}
			if inside && (character == '\n' || character >= 32) {
				strings.write_byte(&builder, character)
			}
		}
		if strings.builder_len(builder) > 0 {
			strings.write_string(&builder, "\n")
		}
	}
	log.infof("pdf text extracted from %d stream(s)", streams)
	return strings.to_string(builder)
}

Markdown_Role :: enum u8 {
	Body,
	Heading,
	Bullet,
	Quote,
	Code,
	Rule,
}

markdown_role :: proc(line: string, in_code: bool) -> Markdown_Role {
	trimmed := strings.trim_space(line)
	switch {
	case in_code || strings.has_prefix(trimmed, "```"):
		return .Code
	case strings.has_prefix(trimmed, "#"):
		return .Heading
	case strings.has_prefix(trimmed, ">"):
		return .Quote
	case strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") || strings.has_prefix(trimmed, "+ "):
		return .Bullet
	case len(trimmed) >= 3 && (strings.has_prefix(trimmed, "---") || strings.has_prefix(trimmed, "===")):
		return .Rule
	}
	return .Body
}

markdown_color :: proc(theme: Theme, role: Markdown_Role) -> [4]f32 {
	switch role {
	case .Heading:
		return theme[.Accent]
	case .Bullet:
		return theme[.Type]
	case .Quote:
		return theme[.Comment]
	case .Code:
		return theme[.String]
	case .Rule:
		return theme[.Gutter]
	case .Body:
	}
	return theme[.Text]
}

draw_image_view :: proc(editor: ^Editor, view: ^View, buffer: ^Buffer, active: bool) {
	painter := &editor.painter
	theme := editor.active_theme
	rect := view.rect
	push_rect(painter, rect.x, rect.y, rect.width, rect.height, theme[.Overlay])

	label := fmt.tprintf(" %s   %d x %d ", filename_of(buffer.display), buffer.image_width, buffer.image_height)
	push_text(painter, rect.x + painter.cell_width, rect.y + painter.line_height * 0.4, label, active ? theme[.Text] : theme[.Comment])
	if buffer.texture == nil {
		push_text(painter, rect.x + painter.cell_width, rect.y + painter.line_height * 2, "This image could not be decoded", theme[.Directive])
		return
	}

	area := Rect{rect.x + 8, rect.y + painter.line_height * 2, rect.width - 16, rect.height - painter.line_height * 3}
	scale := min(area.width / f32(buffer.image_width), area.height / f32(buffer.image_height))
	scale = min(scale, 1) * view.image_zoom
	width := f32(buffer.image_width) * scale
	height := f32(buffer.image_height) * scale
	destination := sdl.FRect {
		area.x + (area.width - width) / 2,
		area.y + (area.height - height) / 2,
		width,
		height,
	}
	painter_flush(painter)
	sdl.RenderTexture(editor.renderer, buffer.texture, nil, &destination)
}

draw_markdown_line :: proc(editor: ^Editor, buffer: ^Buffer, line: int, in_code: ^bool) -> [4]f32 {
	text := buffer_line_text(buffer, line)
	role := markdown_role(text, in_code^)
	if strings.has_prefix(strings.trim_space(text), "```") {
		in_code^ = !in_code^
	}
	return markdown_color(editor.config.theme, role)
}
