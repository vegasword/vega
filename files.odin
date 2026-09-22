package vega

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

project_file_cache: [dynamic]string
project_file_root: string

project_files :: proc(editor: ^Editor) -> []string {
	if project_file_root == editor.index.root && len(project_file_cache) > 0 {
		return project_file_cache[:]
	}
	started := time.tick_now()
	for entry in project_file_cache {
		delete(entry)
	}
	clear(&project_file_cache)
	delete(project_file_root)
	project_file_root = strings.clone(editor.index.root)

	listing, exit_code, ok := run_hidden("git ls-files --cached --others --exclude-standard", editor.index.root, context.temp_allocator)
	if ok && exit_code == 0 && len(listing) > 0 {
		remaining := listing
		for line in strings.split_lines_iterator(&remaining) {
			trimmed := strings.trim_space(line)
			if trimmed != "" {
				append(&project_file_cache, strings.clone(trimmed))
			}
		}
		log.infof("%d files from git, ignored paths left out", len(project_file_cache))
	} else {
		walker := os.walker_create(editor.index.root)
		defer os.walker_destroy(&walker)
		for info in os.walker_walk(&walker) {
			if info.type == .Directory {
				if word_in_set(skipped_directories, info.name) || strings.has_prefix(info.name, ".") {
					os.walker_skip_dir(&walker)
				}
				continue
			}
			relative, error := filepath.rel(editor.index.root, info.fullpath, context.temp_allocator)
			if error != nil {
				continue
			}
			append(&project_file_cache, strings.clone(strings.trim_left(relative, "/\\")))
		}
		log.infof("%d files from the directory walk, no git repository here", len(project_file_cache))
	}
	slice.sort(project_file_cache[:])
	log.infof("project listing of %d files took %.2f ms", len(project_file_cache), time.duration_milliseconds(time.tick_since(started)))
	return project_file_cache[:]
}

project_files_invalidate :: proc() {
	delete(project_file_root)
	project_file_root = ""
	preview_cache_clear()
}