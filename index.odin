package vega

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import cpu_info "core:sys/info"
import "core:thread"
import "core:time"

Symbol_Kind :: enum u8 {
	Function,
	Type,
	Constant,
	Variable,
	Macro,
}

Symbol :: struct {
	name:      string,
	signature: string,
	file:      int,
	offset:    int,
	kind:      Symbol_Kind,
}

Location :: struct {
	file:   int,
	offset: int,
}

Indexed_File :: struct {
	path:     string,
	text:     []u8,
	language: Language,
	modified: i64,
	owned:    bool,
}

Scanned :: struct {
	name:      string,
	full:      string,
	directory: bool,
	size:      i64,
	modified:  i64,
}

Project_Index :: struct {
	root:        string,
	files:       [dynamic]Indexed_File,
	symbols:     [dynamic]Symbol,
	definitions: map[string][dynamic]int,
	references:  map[string][dynamic]Location,
	base_symbol: int,
	base_file:   int,
	shards:      [dynamic]^Project_Index,
	blob:        []u8,
	arenas:      [dynamic]^virtual.Arena,
	units:       [dynamic]Index_Unit,
	records:     map[string][]u8,
	folders:     map[string]i64,
}

index_cache: map[string]Cached_File
index_cache_languages: map[string]Language
index_cache_folders: map[string]i64
index_cache_children: map[string][dynamic]string
index_cache_folder_children: map[string][dynamic]string
index_cache_generation: i64
index_trusting: bool
index_trusted: int

index_definitions :: proc(index: ^Project_Index, name: string, allocator := context.temp_allocator) -> []int {
	found := make([dynamic]int, 0, 8, allocator)
	for shard in index.shards {
		list, exists := shard.definitions[name]
		if !exists {
			continue
		}
		for value in list {
			append(&found, value + shard.base_symbol)
		}
	}
	for unit in index.units {
		entry, exists := unit_find(unit, name)
		if !exists {
			continue
		}
		for value in unit.definitions[entry.definition_start:][:entry.definition_count] {
			append(&found, unit.base_symbol + int(value))
		}
	}
	return found[:]
}

index_references :: proc(index: ^Project_Index, name: string, allocator := context.temp_allocator) -> []Location {
	found := make([dynamic]Location, 0, 16, allocator)
	for shard in index.shards {
		list, exists := shard.references[name]
		if !exists {
			continue
		}
		for location in list {
			append(&found, Location{location.file + shard.base_file, location.offset})
		}
	}
	for unit in index.units {
		entry, exists := unit_find(unit, name)
		if !exists {
			continue
		}
		for offset in unit.references[entry.reference_start:][:entry.reference_count] {
			append(&found, Location{unit.base_file, int(offset)})
		}
	}
	return found[:]
}

indexable_extensions := []string {
	".odin", ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".inl",
	".glsl", ".vert", ".frag", ".comp", ".geom", ".tesc", ".tese", ".vs", ".fs",
}

skipped_directories := []string{".git", "build", "target", "node_modules", ".cache", "vendor"}

index_destroy :: proc(index: ^Project_Index) {
	scan_unmap(index.blob)
	index.blob = nil
	clear(&index.files)
	clear(&index.symbols)
	clear(&index.shards)
	clear(&index.units)
	clear(&index.records)
	clear(&index.folders)
	for arena in index.arenas {
		virtual.arena_destroy(arena)
		free(arena)
	}
	clear(&index.arenas)
}

Index_Task :: struct {
	path:    string,
	chunk:   ^Project_Index,
	next:    ^Index_Task,
	sibling: ^Index_Task,
}

Index_Share :: struct {
	stack:   ^Index_Task,
	all:     ^Index_Task,
	running: int,
	arenas:  ^Index_Arena,
	home:    runtime.Allocator,
}

Index_Arena :: struct {
	arena: ^virtual.Arena,
	next:  ^Index_Arena,
}

index_push :: proc(share: ^Index_Share, path: string) {
	task := new(Index_Task, share.home)
	task.path = strings.clone(path, share.home)
	task.chunk = new(Project_Index, share.home)
	intrinsics.atomic_add(&share.running, 1)
	for {
		task.sibling = intrinsics.atomic_load(&share.all)
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&share.all, task.sibling, task); swapped {
			break
		}
	}
	for {
		task.next = intrinsics.atomic_load(&share.stack)
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&share.stack, task.next, task); swapped {
			return
		}
	}
}

index_claim :: proc(share: ^Index_Share) -> ^Index_Task {
	for {
		top := intrinsics.atomic_load(&share.stack)
		if top == nil {
			return nil
		}
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&share.stack, top, top.next); swapped {
			return top
		}
	}
}

index_adopt :: proc(chunk: ^Project_Index, path: string, cached: Cached_File, modified: i64) {
	unit := cached.unit
	unit.base_symbol = len(chunk.symbols)
	unit.base_file = len(chunk.files)
	for symbol in cached.symbols {
		append(&chunk.symbols, Symbol {
			name      = string(cached.text[symbol.name_offset:][:symbol.name_length]),
			signature = string(cached.text[symbol.signature_off:][:symbol.signature_len]),
			file      = unit.base_file,
			offset    = int(symbol.offset),
			kind      = Symbol_Kind(symbol.kind),
		})
	}
	append(&chunk.units, unit)
	kept := strings.clone(path)
	chunk.records[kept] = cached.record
	append(&chunk.files, Indexed_File{kept, cached.text, index_cache_languages[path], modified, false})
}

index_trusted_branch :: proc(share: ^Index_Share, path: string, chunk: ^Project_Index) -> bool {
	if !index_trusting {
		return false
	}
	remembered, known := index_cache_folders[path]
	if !known {
		return false
	}
	modified, ok := scan_stat(path)
	if !ok || modified != remembered {
		return false
	}
	if folders, listed := index_cache_folder_children[path]; listed {
		for child in folders {
			index_push(share, child)
		}
	}
	if files, listed := index_cache_children[path]; listed {
		for child in files {
			cached, held := index_cache[child]
			if !held {
				return false
			}
			index_adopt(chunk, child, cached, cached.modified)
		}
	}
	chunk.folders[strings.clone(path)] = modified
	intrinsics.atomic_add(&index_trusted, 1)
	return true
}

index_branch :: proc(share: ^Index_Share, path: string, chunk: ^Project_Index, tokens: ^[dynamic]Token) {
	if index_trusted_branch(share, path, chunk) {
		return
	}
	entries := scan_directory(path)
	if modified, ok := scan_stat(path); ok {
		chunk.folders[strings.clone(path)] = modified
	}
	for entry in entries {
		if !entry.directory || word_in_set(skipped_directories, entry.name) || strings.has_prefix(entry.name, ".") {
			continue
		}
		index_push(share, entry.full)
	}
	for entry in entries {
		if entry.directory || !word_in_set(indexable_extensions, filepath.ext(entry.name)) || entry.size > 8 << 20 {
			continue
		}
		if cached, known := index_cache[entry.full]; known && cached.modified == entry.modified && len(cached.text) == int(entry.size) {
			index_adopt(chunk, entry.full, cached, entry.modified)
			continue
		}
		data, ok := scan_read(entry.full)
		if !ok {
			continue
		}
		language := language_of_path(entry.name)
		path := strings.clone(entry.full)
		append(&chunk.files, Indexed_File{path, data, language, entry.modified, true})
		tokenize(data, language, tokens)
		first_symbol := len(chunk.symbols)
		index_collect(chunk, len(chunk.files) - 1, data, language, tokens[:])
		chunk.records[path] = cache_record(path, data, entry.modified, language, chunk.symbols[first_symbol:], tokens[:])
	}
}

index_share_first :: proc(share: ^Index_Share) {
	context.allocator = index_share_arena(share)
	tokens := make([dynamic]Token, 0, 4096, context.temp_allocator)
	task := index_claim(share)
	if task == nil {
		return
	}
	index_branch(share, task.path, task.chunk, &tokens)
	intrinsics.atomic_add(&share.running, -1)
}

index_share_arena :: proc(share: ^Index_Share) -> runtime.Allocator {
	arena := new(virtual.Arena)
	if virtual.arena_init_growing(arena) != nil {
		free(arena)
		return context.allocator
	}
	link := new(Index_Arena)
	link.arena = arena
	for {
		link.next = intrinsics.atomic_load(&share.arenas)
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&share.arenas, link.next, link); swapped {
			break
		}
	}
	return virtual.arena_allocator(arena)
}

index_share_run :: proc(share: ^Index_Share) {
	context.allocator = index_share_arena(share)
	tokens := make([dynamic]Token, 0, 4096, context.temp_allocator)
	patience := 0
	for {
		task := index_claim(share)
		if task == nil {
			if intrinsics.atomic_load(&share.running) == 0 {
				return
			}
			patience += 1
			if patience > 256 {
				thread.yield()
				patience = 0
			} else {
				intrinsics.cpu_relax()
			}
			continue
		}
		patience = 0
		index_branch(share, task.path, task.chunk, &tokens)
		intrinsics.atomic_add(&share.running, -1)
	}
}

index_worker :: proc(worker: ^thread.Thread) {
	index_share_run((^Index_Share)(worker.data))
}

Index_Build :: struct {
	root:     string,
	staging:  Project_Index,
	finished: bool,
	checked:  Project_Index,
	rechecked: bool,
	worker:   ^thread.Thread,
	taken:    bool,
}

index_job: ^Index_Build

index_builder :: proc(worker: ^thread.Thread) {
	job := (^Index_Build)(worker.data)
	index_trusting = true
	index_build(&job.staging, job.root)
	trusted := index_trusted
	stale := make([]Indexed_File, len(job.staging.files))
	copy(stale, job.staging.files[:])
	intrinsics.atomic_store(&job.finished, true)
	if trusted == 0 {
		delete(stale)
		intrinsics.atomic_store(&job.rechecked, true)
		return
	}
	index_trusting = false
	index_build(&job.checked, job.root)
	matched := len(job.checked.files) == len(stale)
	for file, position in job.checked.files {
		if !matched {
			break
		}
		matched = file.path == stale[position].path && file.modified == stale[position].modified
	}
	delete(stale)
	if matched {
		index_destroy(&job.checked)
		log.debugf("the trusted index matched the full scan of %d files", len(job.staging.files))
	} else {
		log.infof("the full scan corrected the trusted index to %d files", len(job.checked.files))
	}
	intrinsics.atomic_store(&job.rechecked, true)
}

index_start :: proc(index: ^Project_Index, root: string) {
	if index_job != nil {
		return
	}
	if index.root != root {
		delete(index.root)
		index.root = strings.clone(root)
	}
	job := new(Index_Build)
	job.root = strings.clone(root)
	job.worker = thread.create(index_builder)
	if job.worker == nil {
		free(job)
		index_build(index, root)
		return
	}
	job.worker.data = job
	job.worker.init_context = context
	index_job = job
	started := time.tick_now()
	thread.start(job.worker)
	log.debugf("indexing %s in the background, handed over in %.3f ms", root, time.duration_milliseconds(time.tick_since(started)))
}

index_wait :: proc(index: ^Project_Index) {
	for index_job != nil {
		if !index_poll(index) {
			thread.yield()
		}
	}
}

index_adopt_staging :: proc(index: ^Project_Index, staging: ^Project_Index) {
	root := index.root
	index.root = ""
	index_destroy(index)
	delete(index.files)
	delete(index.symbols)
	delete(index.shards)
	delete(index.units)
	delete(index.records)
	delete(index.folders)
	delete(root)
	index^ = staging^
}

index_poll :: proc(index: ^Project_Index) -> bool {
	job := index_job
	if job == nil {
		return false
	}
	if !job.taken {
		if !intrinsics.atomic_load(&job.finished) {
			return false
		}
		job.taken = true
		index_adopt_staging(index, &job.staging)
		log.infof("index ready with %d files and %d symbols", len(index.files), len(index.symbols))
		return true
	}
	if !intrinsics.atomic_load(&job.rechecked) {
		return false
	}
	thread.join(job.worker)
	thread.destroy(job.worker)
	index_job = nil
	if len(job.checked.files) > 0 {
		index_adopt_staging(index, &job.checked)
		log.infof("index corrected to %d files and %d symbols", len(index.files), len(index.symbols))
	}
	delete(job.root)
	free(job)
	return true
}

index_build :: proc(index: ^Project_Index, root: string) {
	index_destroy(index)
	if index.root != root {
		delete(index.root)
		index.root = strings.clone(root)
	}
	started := time.tick_now()
	clear(&index_cache)
	clear(&index_cache_languages)
	clear(&index_cache_folders)
	for _, list in index_cache_children {
		delete(list)
	}
	for _, list in index_cache_folder_children {
		delete(list)
	}
	clear(&index_cache_children)
	clear(&index_cache_folder_children)
	index_trusted = 0
	blob, slot := index_cache_load(root)
	cached := time.tick_since(started)
	share: Index_Share
	share.home = context.allocator
	index_push(&share, root)

	index_share_first(&share)
	queued := 0
	for task := share.stack; task != nil; task = task.next {
		queued += 1
	}

	_, cores, known := cpu_info.cpu_core_count()
	workers := clamp(min((known ? cores : 4) * 2, queued), 1, index_trusting ? 8 : 48)
	threads := make([]^thread.Thread, workers, context.temp_allocator)
	for position in 1 ..< workers {
		threads[position] = thread.create(index_worker)
		if threads[position] == nil {
			continue
		}
		threads[position].data = &share
		thread.start(threads[position])
	}
	index_share_run(&share)
	for spawned in threads[1:] {
		if spawned == nil {
			continue
		}
		thread.join(spawned)
		thread.destroy(spawned)
	}

	scanned := time.tick_since(started)
	order := make([dynamic]^Index_Task, 0, 256, context.temp_allocator)
	for task := share.all; task != nil; task = task.sibling {
		append(&order, task)
	}
	slice.sort_by(order[:], proc(a, b: ^Index_Task) -> bool { return a.path < b.path })
	for placed in order {
		job := placed.chunk
		job.base_file = len(index.files)
		job.base_symbol = len(index.symbols)
		append(&index.files, ..job.files[:])
		for &symbol in job.symbols {
			symbol.file += job.base_file
		}
		append(&index.symbols, ..job.symbols[:])
		for unit in job.units {
			moved := unit
			moved.base_symbol += job.base_symbol
			moved.base_file += job.base_file
			append(&index.units, moved)
		}
		for path, record in job.records {
			index.records[path] = record
		}
		for path, modified in job.folders {
			index.folders[path] = modified
		}
		append(&index.shards, job)
	}
	for task := share.all; task != nil; {
		next := task.sibling
		delete(task.path, share.home)
		free(task, share.home)
		task = next
	}
	for link := share.arenas; link != nil; {
		next := link.next
		append(&index.arenas, link.arena)
		free(link)
		link = next
	}
	reused := 0
	for file in index.files {
		if !file.owned {
			reused += 1
		}
	}
	index.blob = blob
	if reused != len(index.files) || len(index_cache_folders) == 0 {
		index_cache_save(index, root, slot)
	}
	clear(&index_cache)
	clear(&index_cache_languages)
	log.debugf("indexed %d files (%d from the cache) across %d branches with %d worker(s), %.0f ms cache, %.0f ms scanning, %.0f ms total", len(index.files), reused, len(order), workers, time.duration_milliseconds(cached), time.duration_milliseconds(scanned), time.duration_milliseconds(time.tick_since(started)))
}

index_collect :: proc(index: ^Project_Index, file_index: int, text: []u8, language: Language, tokens: []Token) {
	odin := language == .Odin
	c_like := language == .C || language == .GLSL
	depth := 0
	for token, position in tokens {
		named := token.kind == .Identifier || token.kind == .Function
		name := named ? token_text(text, token) : ""
		if named {
			list, found := &index.references[name]
			if !found {
				index.references[name] = make([dynamic]Location, 0, 8)
				list = &index.references[name]
			}
			append(list, Location{file_index, int(token.start)})
		}
		if token.kind == .Punct {
			switch text[token.start] {
			case '{', '(', '[':
				depth += 1
			case '}', ')', ']':
				depth = max(0, depth - 1)
			}
		}
		if odin {
			if named {
				index_collect_odin(index, file_index, text, tokens, position, depth, name)
			}
		} else if c_like && depth == 0 {
			index_collect_c(index, file_index, text, tokens, position, name)
		}
	}
}

index_add :: proc(index: ^Project_Index, symbol: Symbol) {
	append(&index.symbols, symbol)
	list, found := &index.definitions[symbol.name]
	if !found {
		index.definitions[symbol.name] = make([dynamic]int)
		list = &index.definitions[symbol.name]
	}
	append(list, len(index.symbols) - 1)
}

signature_from :: proc(text: []u8, offset: int) -> string {
	start := offset
	for start > 0 && text[start - 1] != '\n' {
		start -= 1
	}
	end := offset
	for end < len(text) && text[end] != '\n' && text[end] != '{' {
		end += 1
	}
	return strings.trim_space(string(text[start:end]))
}

index_collect_odin :: proc(index: ^Project_Index, file_index: int, text: []u8, tokens: []Token, position: int, depth: int, name: string) {
	token := tokens[position]
	if position + 2 >= len(tokens) {
		return
	}
	first, second := tokens[position + 1], tokens[position + 2]
	if !punct_is(text, first, ':') {
		return
	}
	if depth > 0 {
		if !punct_is(text, second, ':') {
			index_add(index, Symbol{name, signature_from(text, int(token.start)), file_index, int(token.start), .Variable})
		}
		return
	}
	if punct_is(text, second, ':') && second.start == first.end {
		kind := Symbol_Kind.Constant
		if position + 3 < len(tokens) {
			switch token_text(text, tokens[position + 3]) {
			case "proc":
				kind = .Function
			case "struct", "enum", "union", "bit_set", "bit_field", "distinct":
				kind = .Type
			}
		}
		index_add(index, Symbol{name, signature_from(text, int(token.start)), file_index, int(token.start), kind})
	} else if punct_is(text, second, '=') {
		index_add(index, Symbol{name, signature_from(text, int(token.start)), file_index, int(token.start), .Variable})
	}
}

index_collect_c :: proc(index: ^Project_Index, file_index: int, text: []u8, tokens: []Token, position: int, name: string) {
	token := tokens[position]
	if token.kind == .Directive && token_text(text, token) == "#define" && position + 1 < len(tokens) {
		target := tokens[position + 1]
		if target.kind == .Identifier || target.kind == .Function {
			index_add(index, Symbol{token_text(text, target), signature_from(text, int(token.start)), file_index, int(target.start), .Macro})
		}
		return
	}
	if token.kind == .Keyword {
		word := token_text(text, token)
		if (word == "struct" || word == "union" || word == "enum") &&
		   position + 2 < len(tokens) &&
		   tokens[position + 1].kind == .Identifier &&
		   punct_is(text, tokens[position + 2], '{') {
			target := tokens[position + 1]
			index_add(index, Symbol{token_text(text, target), signature_from(text, int(token.start)), file_index, int(target.start), .Type})
		}
		if word == "typedef" {
			last_identifier := -1
			for scan in position + 1 ..< len(tokens) {
				if punct_is(text, tokens[scan], ';') {
					break
				}
				if tokens[scan].kind == .Identifier {
					last_identifier = scan
				}
			}
			if last_identifier >= 0 {
				target := tokens[last_identifier]
				index_add(index, Symbol{token_text(text, target), signature_from(text, int(token.start)), file_index, int(target.start), .Type})
			}
		}
		return
	}
	if token.kind == .Identifier && position > 0 && position + 1 < len(tokens) {
		previous, next := tokens[position - 1], tokens[position + 1]
		declaring := previous.kind == .Type || previous.kind == .Identifier || punct_is(text, previous, '*')
		terminated := punct_is(text, next, ';') || punct_is(text, next, '=') || punct_is(text, next, '[')
		if declaring && terminated {
			index_add(index, Symbol{name, signature_from(text, int(token.start)), file_index, int(token.start), .Variable})
			return
		}
	}
	if token.kind == .Function && position + 1 < len(tokens) && punct_is(text, tokens[position + 1], '(') {
		nesting := 0
		closing := -1
		for scan in position + 1 ..< len(tokens) {
			if punct_is(text, tokens[scan], '(') {
				nesting += 1
			} else if punct_is(text, tokens[scan], ')') {
				nesting -= 1
				if nesting == 0 {
					closing = scan
					break
				}
			}
		}
		if closing >= 0 && closing + 1 < len(tokens) && punct_is(text, tokens[closing + 1], '{') {
			index_add(index, Symbol{name, signature_from(text, int(token.start)), file_index, int(token.start), .Function})
		}
	}
}

index_rename :: proc(index: ^Project_Index, old_name, new_name: string) -> int {
	locations := index_references(index, old_name)
	if len(locations) == 0 {
		return 0
	}
	per_file := make(map[int][dynamic]int, context.temp_allocator)
	for location in locations {
		list, exists := &per_file[location.file]
		if !exists {
			per_file[location.file] = make([dynamic]int, context.temp_allocator)
			list = &per_file[location.file]
		}
		append(list, location.offset)
	}
	changed := 0
	for file_index, offsets in per_file {
		file := index.files[file_index]
		builder := strings.builder_make(context.temp_allocator)
		cursor := 0
		sorted := offsets[:]
		for outer in 0 ..< len(sorted) {
			for inner in outer + 1 ..< len(sorted) {
				if sorted[inner] < sorted[outer] {
					sorted[outer], sorted[inner] = sorted[inner], sorted[outer]
				}
			}
		}
		for offset in sorted {
			if offset < cursor {
				continue
			}
			strings.write_string(&builder, string(file.text[cursor:offset]))
			strings.write_string(&builder, new_name)
			cursor = offset + len(old_name)
			changed += 1
		}
		strings.write_string(&builder, string(file.text[cursor:]))
		_ = os.write_entire_file(file.path, transmute([]u8)strings.to_string(builder))
	}
	return changed
}

