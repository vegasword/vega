#+build !windows
package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

DESKTOP_ICON_SIDE :: 256

desktop_install :: proc() -> bool {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		log.error("no HOME, cannot install the desktop entry")
		return false
	}
	binary, error := filepath.abs("./vega", context.temp_allocator)
	if error != nil {
		binary = "vega"
	}

	icons := strings.concatenate({home, "/.local/share/icons/hicolor/256x256/apps"}, context.temp_allocator)
	applications := strings.concatenate({home, "/.local/share/applications"}, context.temp_allocator)
	os.make_directory_all(icons)
	os.make_directory_all(applications)

	width, height, channels: i32
	pixels := stbi.load_from_memory(raw_data(logo_png), i32(len(logo_png)), &width, &height, &channels, 4)
	if pixels == nil {
		log.error("the logo could not be decoded")
		return false
	}
	defer stbi.image_free(pixels)

	square := make([]u8, DESKTOP_ICON_SIDE * DESKTOP_ICON_SIDE * 4, context.temp_allocator)
	scale := min(f32(DESKTOP_ICON_SIDE) * 0.96 / f32(width), f32(DESKTOP_ICON_SIDE) * 0.96 / f32(height))
	drawn_width := int(f32(width) * scale)
	drawn_height := int(f32(height) * scale)
	left := (DESKTOP_ICON_SIDE - drawn_width) / 2
	top := (DESKTOP_ICON_SIDE - drawn_height) / 2
	for row in 0 ..< drawn_height {
		source_row := int(f32(row) / scale)
		for column in 0 ..< drawn_width {
			source_column := int(f32(column) / scale)
			source := (source_row * int(width) + source_column) * 4
			target := ((top + row) * DESKTOP_ICON_SIDE + left + column) * 4
			copy(square[target:target + 4], ([^]u8)(pixels)[source:source + 4])
		}
	}

	icon_path := strings.concatenate({icons, "/vega.png"}, context.temp_allocator)
	if stbi.write_png(strings.clone_to_cstring(icon_path, context.temp_allocator), DESKTOP_ICON_SIDE, DESKTOP_ICON_SIDE, 4, raw_data(square), DESKTOP_ICON_SIDE * 4) == 0 {
		log.errorf("could not write %s", icon_path)
		return false
	}

	entry := fmt.tprintf(
		"[Desktop Entry]\nType=Application\nName=vega\nComment=A Helix flavoured modal editor\nExec=%s %%F\nIcon=vega\nCategories=Development;TextEditor;\nTerminal=false\nStartupWMClass=vega\n",
		binary,
	)
	entry_path := strings.concatenate({applications, "/vega.desktop"}, context.temp_allocator)
	if os.write_entire_file(entry_path, transmute([]u8)entry) != nil {
		log.errorf("could not write %s", entry_path)
		return false
	}
	fmt.printfln("installed %s and %s", icon_path, entry_path)
	return true
}
