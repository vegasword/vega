#+build !windows
package vega

child_kill :: proc() -> bool {
	return false
}

import "core:log"
import "core:os"

attach_console :: proc() {
}

run_hidden :: proc(command_line: string, working_directory := "", allocator := context.allocator) -> (output: string, exit_code: u32, ok: bool) {
	description := os.Process_Desc {
		command     = []string{"/bin/sh", "-c", command_line},
		working_dir = working_directory,
	}
	state, out, errors, error := os.process_exec(description, allocator)
	defer delete(errors, allocator)
	if error != nil {
		log.errorf("could not start: %s", command_line)
		return "", 0, false
	}
	log.debugf("ran %s, exit %d, %d bytes", command_line, state.exit_code, len(out))
	return string(out), u32(state.exit_code), true
}
