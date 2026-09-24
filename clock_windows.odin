#+build windows
package vega

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetLocalTime :: proc(stamp: ^win.SYSTEMTIME) ---
}

local_clock :: proc() -> (year, month, day, hour, minute, second: int) {
	stamp: win.SYSTEMTIME
	GetLocalTime(&stamp)
	return int(stamp.year), int(stamp.month), int(stamp.day), int(stamp.hour), int(stamp.minute), int(stamp.second)
}
