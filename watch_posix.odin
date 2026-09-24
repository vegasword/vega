#+build !windows
package vega

watch_start :: proc(root: string) {
}

watch_stop :: proc() {
}

watch_taken :: proc() -> bool {
	return false
}
