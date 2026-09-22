package vega

import "core:strings"
import sdl "vendor:sdl3"

config_path: string
log_path: string
pref_path: string

paths_prepare :: proc() {
	folder := sdl.GetPrefPath("vega", "vega")
	pref_path = folder == nil ? "" : strings.clone(string(cstring(folder)))
	if folder != nil {
		sdl.free(folder)
	}
	config_path = strings.concatenate({pref_path, "vega.conf"})
	workspaces_path = strings.concatenate({pref_path, "vega.workspaces"})
	log_path = strings.concatenate({pref_path, "vega.log"})
}
