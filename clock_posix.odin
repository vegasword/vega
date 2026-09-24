#+build !windows
package vega

import "core:time"

local_clock :: proc() -> (year, month, day, hour, minute, second: int) {
	now := time.now()
	years, months, days := time.date(now)
	hours, minutes, seconds := time.clock_from_time(now)
	return years, int(months), days, hours, minutes, seconds
}
