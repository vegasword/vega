package vega

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

bench_queries := []string{"v", "vi", "vie", "view", "view.o", "odin", "picker", "zzz"}

bench_run :: proc(editor: ^Editor, root: string) {
	report :: proc(label: string, started: time.Tick, detail: string) {
		fmt.printfln("%-28s %8.2f ms  %s", label, time.duration_milliseconds(time.tick_since(started)), detail)
	}

	started := time.tick_now()
	index_build(&editor.index, root)
	report("index build", started, fmt.tprintf("%d files, %d symbols", len(editor.index.files), len(editor.index.symbols)))

	started = time.tick_now()
	index_build(&editor.index, root)
	report("index build warm", started, fmt.tprintf("%d files, %d symbols", len(editor.index.files), len(editor.index.symbols)))

	index_trusting = true
	started = time.tick_now()
	index_build(&editor.index, root)
	report("index build trusted", started, fmt.tprintf("%d files, %d symbols", len(editor.index.files), len(editor.index.symbols)))
	index_trusting = false

	started = time.tick_now()
	folders := make([dynamic]string, 0, 256, context.temp_allocator)
	append(&folders, root)
	entries_seen := 0
	for position := 0; position < len(folders); position += 1 {
		for entry in scan_directory(folders[position]) {
			entries_seen += 1
			if entry.directory && !word_in_set(skipped_directories, entry.name) && !strings.has_prefix(entry.name, ".") {
				append(&folders, strings.clone(entry.full, context.temp_allocator))
			}
		}
	}
	report("enumerate the tree", started, fmt.tprintf("%d folders, %d entries", len(folders), entries_seen))

	scratch := make([dynamic]Token, 0, 4096)
	volume := 0
	started = time.tick_now()
	for file in editor.index.files {
		tokenize(file.text, file.language, &scratch)
		volume += len(file.text)
	}
	report("tokenize everything", started, fmt.tprintf("%.0f MB/s over %d MB", f64(volume) / 1e6 / time.duration_seconds(time.tick_since(started)), volume / 1e6))

	project_files_invalidate()
	started = time.tick_now()
	files := project_files(editor)
	report("file listing cold", started, fmt.tprintf("%d files", len(files)))

	started = time.tick_now()
	files = project_files(editor)
	report("file listing warm", started, fmt.tprintf("%d files", len(files)))

	append(&editor.views, View{})
	layout_reset(editor)
	append(&editor.buffers, buffer_create(editor, ""))

	started = time.tick_now()
	picker_open(editor, .Files, "files")
	report("file picker open", started, fmt.tprintf("%d items", len(editor.picker.items)))

	for query in bench_queries {
		clear(&editor.picker.query)
		append(&editor.picker.query, query)
		started = time.tick_now()
		picker_filter(editor)
		report(fmt.tprintf("filter %q", query), started, fmt.tprintf("%d matches", len(editor.picker.filtered)))
	}

	clear(&editor.picker.query)
	append(&editor.picker.query, "view.odin")
	picker_filter(editor)
	started = time.tick_now()
	picker_preview_apply(editor)
	report("preview load", started, fmt.tprintf("%d buffers", len(editor.buffers)))

	started = time.tick_now()
	picker_preview_apply(editor)
	report("preview reload", started, fmt.tprintf("%d buffers", len(editor.buffers)))

	sample := editor.index.files[0].path
	started = time.tick_now()
	opened := buffer_create(editor, sample)
	report("buffer open", started, sample)

	started = time.tick_now()
	buffer_set_baseline(editor, opened)
	report("deferred git baseline", started, sample)
	buffer_destroy(opened)

	started = time.tick_now()
	buffer_destroy(buffer_create(editor, sample, {.Preview, .ReadOnly}))
	report("preview buffer, no git", started, sample)

	picker_close(editor, true)
	picker_open(editor, .GlobalSearch, "search")
	search_queries := []string{"buffer", "buffer_", "buffer_cr"}
	for query in search_queries {
		clear(&editor.picker.query)
		append(&editor.picker.query, query)
		started = time.tick_now()
		picker_filter(editor)
		report(fmt.tprintf("search %q", query), started, fmt.tprintf("%d hits", len(editor.picker.filtered)))
	}
	free_all(context.temp_allocator)
	os.exit(0)
}
