package vega

import "core:strings"

shell_prefix :: proc() -> string {
	when ODIN_OS == .Windows {
		return "cmd.exe /c "
	} else {
		return "/bin/sh -c "
	}
}

project_script :: proc(name: string) -> string {
	when ODIN_OS == .Windows {
		return strings.concatenate({".\\", name, ".bat"}, context.temp_allocator)
	} else {
		return strings.concatenate({"./", name, ".sh"}, context.temp_allocator)
	}
}
