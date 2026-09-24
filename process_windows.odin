#+build windows
package vega

import "base:intrinsics"
import "core:log"
import "core:strings"
import windows "core:sys/windows"

running_child: uintptr

attach_console :: proc() {
	windows.AttachConsole(0xffffffff)
}

child_kill :: proc() -> bool {
	handle := intrinsics.atomic_load(&running_child)
	if handle == 0 {
		return false
	}
	return bool(windows.TerminateProcess(windows.HANDLE(handle), 1))
}

run_hidden :: proc(command_line: string, working_directory := "", allocator := context.allocator) -> (output: string, exit_code: u32, ok: bool) {
	security := windows.SECURITY_ATTRIBUTES {
		nLength        = size_of(windows.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	read_pipe, write_pipe: windows.HANDLE
	if !windows.CreatePipe(&read_pipe, &write_pipe, &security, 0) {
		log.errorf("could not create a pipe for: %s", command_line)
		return "", 0, false
	}
	defer windows.CloseHandle(read_pipe)
	windows.SetHandleInformation(read_pipe, windows.HANDLE_FLAG_INHERIT, 0)

	startup := windows.STARTUPINFOW {
		cb         = size_of(windows.STARTUPINFOW),
		dwFlags    = windows.STARTF_USESTDHANDLES,
		hStdOutput = write_pipe,
		hStdError  = write_pipe,
	}
	information: windows.PROCESS_INFORMATION
	wide_command := windows.utf8_to_wstring(command_line, context.temp_allocator)
	wide_directory: windows.wstring
	if working_directory != "" {
		wide_directory = windows.utf8_to_wstring(working_directory, context.temp_allocator)
	}

	created := windows.CreateProcessW(
		nil,
		wide_command,
		nil,
		nil,
		true,
		windows.CREATE_NO_WINDOW,
		nil,
		wide_directory,
		&startup,
		&information,
	)
	windows.CloseHandle(write_pipe)
	if !created {
		log.errorf("could not start: %s", command_line)
		return "", 0, false
	}
	defer windows.CloseHandle(information.hProcess)
	defer windows.CloseHandle(information.hThread)
	intrinsics.atomic_store(&running_child, uintptr(information.hProcess))
	defer intrinsics.atomic_store(&running_child, 0)

	builder := strings.builder_make(allocator)
	chunk: [4096]u8
	for {
		read: u32
		if !windows.ReadFile(read_pipe, &chunk[0], len(chunk), &read, nil) || read == 0 {
			break
		}
		strings.write_bytes(&builder, chunk[:read])
	}
	windows.WaitForSingleObject(information.hProcess, windows.INFINITE)
	windows.GetExitCodeProcess(information.hProcess, &exit_code)
	log.debugf("ran %s, exit %d, %d bytes", command_line, exit_code, strings.builder_len(builder))
	return strings.to_string(builder), exit_code, true
}
