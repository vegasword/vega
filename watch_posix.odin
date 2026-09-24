#+build !windows
package vega

watch_start :: proc(root: string) {
}

watch_stop :: proc() {
}

watch_taken :: proc() -> bool {
	return false
}

watch_running :: proc() -> bool {
	return false
}
