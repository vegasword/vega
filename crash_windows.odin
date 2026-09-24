#+build windows
package vega

import "core:os"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	SetStdHandle :: proc(which: win.DWORD, handle: win.HANDLE) -> win.BOOL ---
}

crash_reports_to :: proc(file: ^os.File) {
	handle := win.HANDLE(uintptr(os.fd(file)))
	SetStdHandle(win.STD_ERROR_HANDLE, handle)
	SetStdHandle(win.STD_OUTPUT_HANDLE, handle)
}
