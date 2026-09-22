package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

Hunk_Kind :: enum u8 {
	Unchanged,
	Added,
	Modified,
	Deleted,
}

Hunk :: struct {
	line:      int,
	count:     int,
	old_line:  int,
	old_count: int,
	kind:      Hunk_Kind,
}

git_stamp: i64
git_checked_ms: u64

git_watch :: proc(editor: ^Editor) {
	stamp: i64
	for name in ([]string{"/.git/index", "/.git/HEAD"}) {
		path := strings.concatenate({editor.index.root, name}, context.temp_allocator)
		if info, error := os.stat(path, context.temp_allocator); error == nil {
			stamp += i64(info.modification_time._nsec)
		}
	}
	if stamp == git_stamp {
		return
	}
	if git_stamp != 0 {
		refreshed := 0
		for buffer in editor.buffers {
			if buffer.path == "" || buffer_hidden(buffer) {
				continue
			}
			buffer.flags += {.BaselinePending}
			refreshed += 1
		}
		log.debugf("git moved, %d baseline(s) to refetch", refreshed)
	}
	git_stamp = stamp
}

buffer_set_baseline :: proc(editor: ^Editor, buffer: ^Buffer) {
	delete(buffer.baseline)
	buffer.baseline = ""
	buffer.flags += {.HunksDirty}
	buffer.flags -= {.BaselinePending}
	if buffer_hidden(buffer) {
		return
	}

	if .GitDiff in editor.config.options && buffer.path != "" {
		cut := max(strings.last_index_byte(buffer.path, '/'), strings.last_index_byte(buffer.path, '\\'))
		directory := cut > 0 ? buffer.path[:cut] : "."
		command := fmt.tprintf("git show HEAD:./%s", filename_of(buffer.path))
		if output, exit_code, ok := run_hidden(command, directory); ok && exit_code == 0 {
			buffer.baseline = output
			log.debugf("baseline for %s came from git HEAD", filename_of(buffer.path))
			return
		}
	}
	buffer.baseline = strings.clone(string(buffer.text[:]))
}

buffer_refresh_hunks :: proc(buffer: ^Buffer) {
	if !(.HunksDirty in buffer.flags) {
		return
	}
	buffer.flags -= {.HunksDirty}
	clear(&buffer.hunks)
	if buffer.baseline == "" {
		return
	}

	old_lines := strings.split_lines(buffer.baseline, context.temp_allocator)
	new_lines := strings.split_lines(string(buffer.text[:]), context.temp_allocator)
	diff_region(&buffer.hunks, old_lines, 0, len(old_lines), new_lines, 0, len(new_lines), 0)
	log.debugf("%d hunk(s) against the file on disk", len(buffer.hunks))
}

diff_region :: proc(hunks: ^[dynamic]Hunk, old_lines: []string, old_from, old_to: int, new_lines: []string, new_from, new_to: int, depth: int) {
	old_from, old_to, new_from, new_to := old_from, old_to, new_from, new_to
	for old_from < old_to && new_from < new_to && old_lines[old_from] == new_lines[new_from] {
		old_from += 1
		new_from += 1
	}
	for old_to > old_from && new_to > new_from && old_lines[old_to - 1] == new_lines[new_to - 1] {
		old_to -= 1
		new_to -= 1
	}
	if old_from == old_to && new_from == new_to {
		return
	}
	if new_from == new_to {
		append(hunks, Hunk{max(0, new_from - 1), 1, old_from, old_to - old_from, .Deleted})
		return
	}
	if old_from == old_to {
		append(hunks, Hunk{new_from, new_to - new_from, old_from, 0, .Added})
		return
	}

	anchor_old, anchor_new := -1, -1
	if depth < 12 {
		occurrences := make(map[string][2]int, context.temp_allocator)
		for index in old_from ..< old_to {
			entry := occurrences[old_lines[index]]
			entry[0] += 1
			occurrences[old_lines[index]] = entry
		}
		for index in new_from ..< new_to {
			entry := occurrences[new_lines[index]]
			entry[1] += 1
			occurrences[new_lines[index]] = entry
		}
		for index in new_from ..< new_to {
			line := new_lines[index]
			counts := occurrences[line]
			if strings.trim_space(line) == "" || counts[0] != 1 || counts[1] != 1 {
				continue
			}
			for scan in old_from ..< old_to {
				if old_lines[scan] == line {
					anchor_old, anchor_new = scan, index
					break
				}
			}
			break
		}
	}
	if anchor_new < 0 {
		append(hunks, Hunk{new_from, new_to - new_from, old_from, old_to - old_from, .Modified})
		return
	}
	diff_region(hunks, old_lines, old_from, anchor_old, new_lines, new_from, anchor_new, depth + 1)
	diff_region(hunks, old_lines, anchor_old + 1, old_to, new_lines, anchor_new + 1, new_to, depth + 1)
}


hunk_kind_of_line :: proc(buffer: ^Buffer, line: int) -> Hunk_Kind {
	for hunk in buffer.hunks {
		if line >= hunk.line && line < hunk.line + hunk.count {
			return hunk.kind
		}
	}
	return .Unchanged
}

reset_change :: proc(editor: ^Editor) {
	buffer := editor_buffer(editor)
	if .ReadOnly in buffer.flags {
		notify("This buffer is read only", .Warning)
		return
	}
	buffer_refresh_hunks(buffer)
	if buffer.baseline == "" || len(buffer.hunks) == 0 {
		notify("Nothing to reset here")
		return
	}

	line := buffer_line_of(buffer, buffer_primary(buffer).head)
	found := -1
	for hunk, index in buffer.hunks {
		if line >= hunk.line && line < hunk.line + max(1, hunk.count) {
			found = index
		}
	}
	if found < 0 {
		notify("No change under the cursor")
		return
	}

	hunk := buffer.hunks[found]
	old_lines := strings.split_lines(buffer.baseline, context.temp_allocator)
	first := clamp(hunk.old_line, 0, len(old_lines))
	last := clamp(hunk.old_line + hunk.old_count, first, len(old_lines))
	restored := strings.join(old_lines[first:last], "\n", context.temp_allocator)

	buffer_snapshot(buffer)
	if hunk.kind == .Deleted {
		_, end := buffer_line_bounds(buffer, hunk.line)
		apply_replace(buffer, end, end, strings.concatenate({"\n", restored}, context.temp_allocator))
	} else {
		start, _ := buffer_line_bounds(buffer, hunk.line)
		_, stop := buffer_line_bounds(buffer, min(hunk.line + hunk.count - 1, buffer_line_count(buffer) - 1))
		apply_replace(buffer, start, stop, restored)
	}
	buffer_refresh(buffer)
	buffer_clamp_selections(buffer)
	buffer.flags += {.HunksDirty}
	goto_offset(buffer, buffer.line_starts[clamp(hunk.line, 0, buffer_line_count(buffer) - 1)], false)
	editor_ensure_visible(editor)
	notify(fmt.tprintf("Reset a %v change of %d line(s) at line %d", hunk.kind, max(hunk.count, hunk.old_count), hunk.line + 1))
}

goto_change :: proc(editor: ^Editor, forward: bool) {
	buffer := editor_buffer(editor)
	buffer_refresh_hunks(buffer)
	if len(buffer.hunks) == 0 {
		editor_status(editor, "No changes against git HEAD")
		return
	}
	current := buffer_line_of(buffer, buffer_primary(buffer).head)
	target := -1
	for hunk in buffer.hunks {
		if forward && hunk.line > current && (target < 0 || hunk.line < target) {
			target = hunk.line
		}
		if !forward && hunk.line < current && hunk.line > target {
			target = hunk.line
		}
	}
	if target < 0 {
		target = forward ? buffer.hunks[0].line : buffer.hunks[len(buffer.hunks) - 1].line
	}
	start, _ := buffer_line_bounds(buffer, target)
	goto_offset(buffer, start, false)
	editor_center_view(editor)
	log.debugf("change %d of %d", target + 1, len(buffer.hunks))
}

goto_function :: proc(editor: ^Editor, forward: bool) {
	buffer := editor_buffer(editor)
	current := buffer_primary(buffer).head
	best := -1
	depth := 0
	for token, position in buffer.tokens {
		if token.kind == .Punct {
			switch buffer.text[token.start] {
			case '{', '(', '[':
				depth += 1
			case '}', ')', ']':
				depth = max(0, depth - 1)
			}
			continue
		}
		if depth != 0 || position + 2 >= len(buffer.tokens) {
			continue
		}
		offset := int(token.start)
		is_definition := false
		switch buffer.language {
		case .Odin:
			first, second := buffer.tokens[position + 1], buffer.tokens[position + 2]
			is_definition =
				(token.kind == .Identifier || token.kind == .Function) &&
				punct_is(buffer.text[:], first, ':') &&
				punct_is(buffer.text[:], second, ':')
		case .C, .GLSL, .Shell:
			is_definition = token.kind == .Function && punct_is(buffer.text[:], buffer.tokens[position + 1], '(')
		case .Plain:
		}
		if !is_definition {
			continue
		}
		if forward && offset > current && (best < 0 || offset < best) {
			best = offset
		}
		if !forward && offset < current && offset > best {
			best = offset
		}
	}
	if best < 0 {
		editor_status(editor, forward ? "No function below" : "No function above")
		return
	}
	goto_offset(buffer, best, false)
	editor_center_view(editor)
}
