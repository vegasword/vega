package vega

import "base:intrinsics"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

INDEX_CACHE_MAGIC :: i64(0x76656761_63616368)
INDEX_CACHE_VERSION :: i64(3)

Cached_Symbol :: struct {
	name_offset:    u32,
	name_length:    u32,
	signature_off:  u32,
	signature_len:  u32,
	offset:         u32,
	kind:           u32,
}

Cached_Entry :: struct {
	name_offset:      u32,
	name_length:      u32,
	definition_start: u32,
	definition_count: u32,
	reference_start:  u32,
	reference_count:  u32,
}

Index_Unit :: struct {
	text:        []u8,
	entries:     []Cached_Entry,
	definitions: []u32,
	references:  []u32,
	base_symbol: int,
	base_file:   int,
}

Cached_File :: struct {
	modified: i64,
	text:     []u8,
	symbols:  []Cached_Symbol,
	unit:     Index_Unit,
	record:   []u8,
}

parent_of :: proc(path: string) -> string {
	cut := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return cut <= 0 ? "" : path[:cut]
}

cache_remember :: proc(listing: ^map[string][dynamic]string, folder, child: string) {
	list, found := &listing[folder]
	if !found {
		listing[folder] = make([dynamic]string, 0, 8)
		list = &listing[folder]
	}
	append(list, child)
}

unit_find :: proc(unit: Index_Unit, name: string) -> (Cached_Entry, bool) {
	low, high := 0, len(unit.entries)
	for low < high {
		middle := (low + high) / 2
		entry := unit.entries[middle]
		found := string(unit.text[entry.name_offset:][:entry.name_length])
		if found == name {
			return entry, true
		}
		if found < name {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return {}, false
}

cache_align :: proc(value: int) -> int {
	return (value + 7) / 8 * 8
}

cache_put :: proc(blob: []u8, cursor: ^int, value: $T) {
	intrinsics.unaligned_store((^T)(raw_data(blob[cursor^:])), value)
	cursor^ += size_of(T)
}

cache_take :: proc(blob: []u8, cursor: ^int, count: int) -> []u8 {
	if count < 0 || cursor^ + count > len(blob) {
		cursor^ = len(blob) + 1
		return nil
	}
	taken := blob[cursor^:cursor^ + count]
	cursor^ += count
	return taken
}

cache_number :: proc(blob: []u8, cursor: ^int, $T: typeid) -> T {
	bytes := cache_take(blob, cursor, size_of(T))
	return len(bytes) == size_of(T) ? intrinsics.unaligned_load((^T)(raw_data(bytes))) : 0
}

Cache_Reference :: struct {
	name:   string,
	offset: u32,
}

Cache_Definition :: struct {
	name:  string,
	index: u32,
}

cache_record :: proc(
	path: string,
	text: []u8,
	modified: i64,
	language: Language,
	symbols: []Symbol,
	tokens: []Token,
	allocator := context.allocator,
) -> []u8 {
	offset_in :: proc(text: []u8, part: string) -> u32 {
		return u32(uintptr(raw_data(part)) - uintptr(raw_data(text)))
	}

	references := make([dynamic]Cache_Reference, 0, len(tokens), context.temp_allocator)
	for token in tokens {
		if token.kind == .Identifier || token.kind == .Function {
			append(&references, Cache_Reference{string(text[token.start:token.end]), u32(token.start)})
		}
	}
	definitions := make([dynamic]Cache_Definition, 0, len(symbols), context.temp_allocator)
	for symbol, position in symbols {
		append(&definitions, Cache_Definition{symbol.name, u32(position)})
	}
	slice.sort_by(references[:], proc(a, b: Cache_Reference) -> bool {
		return a.name != b.name ? a.name < b.name : a.offset < b.offset
	})
	slice.sort_by(definitions[:], proc(a, b: Cache_Definition) -> bool {
		return a.name != b.name ? a.name < b.name : a.index < b.index
	})

	names := make([dynamic]Cached_Entry, 0, 256, context.temp_allocator)
	reference_cursor := 0
	definition_cursor := 0
	for reference_cursor < len(references) || definition_cursor < len(definitions) {
		name := ""
		if reference_cursor < len(references) && definition_cursor < len(definitions) {
			name = min(references[reference_cursor].name, definitions[definition_cursor].name)
		} else if reference_cursor < len(references) {
			name = references[reference_cursor].name
		} else {
			name = definitions[definition_cursor].name
		}
		entry := Cached_Entry {
			name_offset      = offset_in(text, name),
			name_length      = u32(len(name)),
			definition_start = u32(definition_cursor),
			reference_start  = u32(reference_cursor),
		}
		for definition_cursor < len(definitions) && definitions[definition_cursor].name == name {
			entry.definition_count += 1
			definition_cursor += 1
		}
		for reference_cursor < len(references) && references[reference_cursor].name == name {
			entry.reference_count += 1
			reference_cursor += 1
		}
		append(&names, entry)
	}

	total := cache_align(48 + len(path)) + cache_align(len(text))
	total += len(symbols) * size_of(Cached_Symbol) + len(names) * size_of(Cached_Entry)
	total += (len(definitions) + len(references)) * 4
	record := make([]u8, cache_align(total), allocator)
	cursor := 0
	cache_put(record, &cursor, modified)
	cache_put(record, &cursor, u32(len(path)))
	cache_put(record, &cursor, u32(len(text)))
	cache_put(record, &cursor, u32(len(symbols)))
	cache_put(record, &cursor, u32(len(names)))
	cache_put(record, &cursor, u32(len(definitions)))
	cache_put(record, &cursor, u32(len(references)))
	cache_put(record, &cursor, u32(language))
	cache_put(record, &cursor, u64(len(record)))
	copy(record[cursor:], transmute([]u8)path)
	cursor = cache_align(cursor + len(path))
	copy(record[cursor:], text)
	cursor = cache_align(cursor + len(text))
	for symbol in symbols {
		cache_put(record, &cursor, Cached_Symbol {
			name_offset   = offset_in(text, symbol.name),
			name_length   = u32(len(symbol.name)),
			signature_off = offset_in(text, symbol.signature),
			signature_len = u32(len(symbol.signature)),
			offset        = u32(symbol.offset),
			kind          = u32(symbol.kind),
		})
	}
	for entry in names {
		cache_put(record, &cursor, entry)
	}
	for definition in definitions {
		cache_put(record, &cursor, definition.index)
	}
	for reference in references {
		cache_put(record, &cursor, reference.offset)
	}
	return record
}

cache_parse :: proc(blob: []u8, cursor: ^int) -> (path: string, file: Cached_File, language: Language, ok: bool) {
	start := cursor^
	file.modified = cache_number(blob, cursor, i64)
	path_length := int(cache_number(blob, cursor, u32))
	text_length := int(cache_number(blob, cursor, u32))
	symbol_count := int(cache_number(blob, cursor, u32))
	name_count := int(cache_number(blob, cursor, u32))
	definition_count := int(cache_number(blob, cursor, u32))
	reference_count := int(cache_number(blob, cursor, u32))
	language = Language(cache_number(blob, cursor, u32))
	record_length := int(cache_number(blob, cursor, u64))
	if start + record_length > len(blob) || record_length <= 0 {
		return "", {}, .Plain, false
	}
	path_bytes := cache_take(blob, cursor, path_length)
	cursor^ = start + cache_align(cursor^ - start)
	file.text = cache_take(blob, cursor, text_length)
	cursor^ = start + cache_align(cursor^ - start)
	symbols := cache_take(blob, cursor, symbol_count * size_of(Cached_Symbol))
	entries := cache_take(blob, cursor, name_count * size_of(Cached_Entry))
	definitions := cache_take(blob, cursor, definition_count * 4)
	references := cache_take(blob, cursor, reference_count * 4)
	if cursor^ > len(blob) {
		return "", {}, .Plain, false
	}
	file.symbols = slice.reinterpret([]Cached_Symbol, symbols)
	file.unit = Index_Unit {
		text        = file.text,
		entries     = slice.reinterpret([]Cached_Entry, entries),
		definitions = slice.reinterpret([]u32, definitions),
		references  = slice.reinterpret([]u32, references),
	}
	file.record = blob[start:start + record_length]
	cursor^ = start + record_length
	return string(path_bytes), file, language, true
}

index_cache_path :: proc(root: string, slot: int, allocator := context.temp_allocator) -> string {
	session := workspace_session_path(root, context.temp_allocator)
	stem := session[:len(session) - len(".session")]
	return strings.concatenate({stem, slot == 0 ? ".cache0" : ".cache1"}, allocator)
}

index_cache_load :: proc(root: string) -> (blob: []u8, slot: int) {
	newest := i64(-1)
	slot = 0
	for candidate in 0 ..< 2 {
		mapped, ok := scan_map(index_cache_path(root, candidate))
		if !ok {
			continue
		}
		cursor := 0
		if cache_number(mapped, &cursor, i64) != INDEX_CACHE_MAGIC || cache_number(mapped, &cursor, i64) != INDEX_CACHE_VERSION {
			scan_unmap(mapped)
			continue
		}
		generation := cache_number(mapped, &cursor, i64)
		if generation <= newest {
			scan_unmap(mapped)
			continue
		}
		if blob != nil {
			scan_unmap(blob)
		}
		newest = generation
		blob = mapped
		slot = candidate
	}
	if blob == nil {
		return nil, 0
	}
	index_cache_generation = newest
	header := 24
	folders_offset := int(cache_number(blob, &header, i64))
	cursor := 32
	for cursor < folders_offset && cursor < len(blob) {
		path, file, language, ok := cache_parse(blob, &cursor)
		if !ok {
			break
		}
		index_cache[path] = file
		index_cache_languages[path] = language
		cache_remember(&index_cache_children, parent_of(path), path)
	}
	cursor = folders_offset
	count := int(cache_number(blob, &cursor, i64))
	for _ in 0 ..< count {
		start := cursor
		modified := cache_number(blob, &cursor, i64)
		length := int(cache_number(blob, &cursor, u32))
		_ = cache_number(blob, &cursor, u32)
		path := cache_take(blob, &cursor, length)
		if path == nil {
			break
		}
		cursor = start + cache_align(16 + length)
		index_cache_folders[string(path)] = modified
		if string(path) != root {
			cache_remember(&index_cache_folder_children, parent_of(string(path)), string(path))
		}
	}
	log.debugf("index cache generation %d holds %d files in %d folders", newest, len(index_cache), len(index_cache_folders))
	return blob, slot
}

index_cache_save :: proc(index: ^Project_Index, root: string, slot: int) {
	records := index.records
	folders := 8
	for path, modified in index.folders {
		_ = modified
		folders += cache_align(16 + len(path))
	}
	total := 32 + folders
	for file in index.files {
		record, found := records[file.path]
		if !found {
			continue
		}
		total += len(record)
	}
	blob := make([]u8, total, context.temp_allocator)
	cursor := 0
	cache_put(blob, &cursor, INDEX_CACHE_MAGIC)
	cache_put(blob, &cursor, INDEX_CACHE_VERSION)
	cache_put(blob, &cursor, index_cache_generation + 1)
	folders_header := cursor
	cache_put(blob, &cursor, i64(0))
	for file in index.files {
		record, found := records[file.path]
		if !found {
			continue
		}
		copy(blob[cursor:], record)
		cursor += len(record)
	}
	intrinsics.unaligned_store((^i64)(raw_data(blob[folders_header:])), i64(cursor))
	cache_put(blob, &cursor, i64(len(index.folders)))
	for path, modified in index.folders {
		start := cursor
		cache_put(blob, &cursor, modified)
		cache_put(blob, &cursor, u32(len(path)))
		cache_put(blob, &cursor, u32(0))
		copy(blob[cursor:], transmute([]u8)path)
		cursor = start + cache_align(16 + len(path))
	}
	if os.write_entire_file(index_cache_path(root, 1 - slot), blob[:cursor]) != nil {
		log.debug("the index cache could not be written")
		return
	}
	log.debugf("index cache written with %d files, %.1f MB", len(records), f64(cursor) / (1 << 20))
}
