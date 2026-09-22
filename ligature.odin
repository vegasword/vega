package vega

import "core:log"
import "core:strings"
import stbtt "vendor:stb/truetype"

LIGATURE_CONTEXT :: 4

Chain_Rule :: struct {
	backtrack: []map[int]bool,
	input:     []map[int]bool,
	lookahead: []map[int]bool,
	records:   [][2]int,
}

Lookup :: struct {
	kind:    int,
	singles: map[int]int,
	chains:  []Chain_Rule,
	parsed:  bool,
}

Shaper :: struct {
	data:       []u8,
	lookup_list: int,
	lookups:    []Lookup,
	order:      [dynamic]int,
	candidates: map[int]bool,
	joining:    [128]bool,
	shaped:     map[string][]int,
}

read_u16 :: proc(data: []u8, at: int) -> int {
	if at < 0 || at + 1 >= len(data) {
		return 0
	}
	return int(data[at]) << 8 | int(data[at + 1])
}

read_u32 :: proc(data: []u8, at: int) -> int {
	return read_u16(data, at) << 16 | read_u16(data, at + 2)
}

font_table :: proc(data: []u8, tag: string) -> int {
	base := int(stbtt.GetFontOffsetForIndex(raw_data(data), 0))
	for index in 0 ..< read_u16(data, base + 4) {
		record := base + 12 + index * 16
		if record + 16 > len(data) {
			break
		}
		if string(data[record:record + 4]) == tag {
			return read_u32(data, record + 8)
		}
	}
	return 0
}

coverage_list :: proc(data: []u8, at: int, allocator := context.allocator) -> []int {
	glyphs := make([dynamic]int, 0, 32, allocator)
	place :: proc(glyphs: ^[dynamic]int, index, glyph: int) {
		for len(glyphs) <= index {
			append(glyphs, -1)
		}
		glyphs[index] = glyph
	}
	switch read_u16(data, at) {
	case 1:
		for index in 0 ..< read_u16(data, at + 2) {
			place(&glyphs, index, read_u16(data, at + 4 + index * 2))
		}
	case 2:
		for index in 0 ..< read_u16(data, at + 2) {
			record := at + 4 + index * 6
			start := read_u16(data, record)
			for glyph in start ..= read_u16(data, record + 2) {
				place(&glyphs, read_u16(data, record + 4) + glyph - start, glyph)
			}
		}
	}
	return glyphs[:]
}

coverage_set :: proc(data: []u8, at: int) -> map[int]bool {
	glyphs := make(map[int]bool)
	for glyph in coverage_list(data, at, context.temp_allocator) {
		if glyph >= 0 {
			glyphs[glyph] = true
		}
	}
	return glyphs
}

lookup_parse :: proc(shaper: ^Shaper, index: int) -> ^Lookup {
	if index < 0 || index >= len(shaper.lookups) {
		return nil
	}
	entry := &shaper.lookups[index]
	if entry.parsed {
		return entry
	}
	entry.parsed = true
	data := shaper.data
	lookup := shaper.lookup_list + read_u16(data, shaper.lookup_list + 2 + index * 2)
	entry.kind = read_u16(data, lookup)

	switch entry.kind {
	case 1:
		entry.singles = make(map[int]int)
		for slot in 0 ..< read_u16(data, lookup + 4) {
			subtable := lookup + read_u16(data, lookup + 6 + slot * 2)
			covered := coverage_list(data, subtable + read_u16(data, subtable + 2), context.temp_allocator)
			for glyph, position in covered {
				if glyph < 0 {
					continue
				}
				switch read_u16(data, subtable) {
				case 1:
					entry.singles[glyph] = (glyph + read_u16(data, subtable + 4)) & 0xffff
				case 2:
					if position < read_u16(data, subtable + 4) {
						entry.singles[glyph] = read_u16(data, subtable + 6 + position * 2)
					}
				}
			}
		}
	case 6:
		rules := make([dynamic]Chain_Rule, 0, 4)
		for slot in 0 ..< read_u16(data, lookup + 4) {
			subtable := lookup + read_u16(data, lookup + 6 + slot * 2)
			if read_u16(data, subtable) != 3 {
				log.warnf("chain subtable format %d is not handled", read_u16(data, subtable))
				continue
			}
			read_run :: proc(data: []u8, cursor: ^int, subtable: int) -> []map[int]bool {
				count := read_u16(data, cursor^)
				sets := make([]map[int]bool, count)
				for position in 0 ..< count {
					sets[position] = coverage_set(data, subtable + read_u16(data, cursor^ + 2 + position * 2))
				}
				cursor^ += 2 + count * 2
				return sets
			}
			rule: Chain_Rule
			cursor := subtable + 2
			rule.backtrack = read_run(data, &cursor, subtable)
			rule.input = read_run(data, &cursor, subtable)
			rule.lookahead = read_run(data, &cursor, subtable)
			count := read_u16(data, cursor)
			rule.records = make([][2]int, count)
			for position in 0 ..< count {
				record := cursor + 2 + position * 4
				rule.records[position] = {read_u16(data, record), read_u16(data, record + 2)}
			}
			if len(rule.input) == 0 || count == 0 {
				continue
			}
			for record in rule.records {
				lookup_parse(shaper, record[1])
			}
			append(&rules, rule)
		}
		entry.chains = rules[:]
	}
	return entry
}

shaper_build :: proc(shaper: ^Shaper, face: ^Face) {
	data := face.data
	gsub := font_table(data, "GSUB")
	if gsub == 0 {
		log.warn("the font carries no GSUB table, no ligatures")
		return
	}
	shaper.data = data
	shaper.lookup_list = gsub + read_u16(data, gsub + 8)
	shaper.lookups = make([]Lookup, read_u16(data, shaper.lookup_list))

	feature_list := gsub + read_u16(data, gsub + 6)
	seen := make(map[int]bool, 128, context.temp_allocator)
	for index in 0 ..< read_u16(data, feature_list) {
		record := feature_list + 2 + index * 6
		if string(data[record:record + 4]) != "calt" {
			continue
		}
		feature := feature_list + read_u16(data, record + 4)
		for slot in 0 ..< read_u16(data, feature + 2) {
			which := read_u16(data, feature + 4 + slot * 2)
			if seen[which] {
				continue
			}
			seen[which] = true
			append(&shaper.order, which)
			entry := lookup_parse(shaper, which)
			for rule in entry.chains {
				for glyph in rule.input[0] {
					shaper.candidates[glyph] = true
				}
			}
		}
	}
	joining := 0
	for character in 33 ..< 127 {
		shaper.joining[character] = shaper.candidates[int(stbtt.FindGlyphIndex(&face.info, rune(character)))]
		joining += shaper.joining[character] ? 1 : 0
	}
	log.infof("%d contextual lookups read from the font, %d glyphs and %d characters can join", len(shaper.order), len(shaper.candidates), joining)
}

rule_matches :: proc(rule: Chain_Rule, glyphs: []int, position: int) -> bool {
	if position < len(rule.backtrack) || position + len(rule.input) + len(rule.lookahead) > len(glyphs) {
		return false
	}
	for set, step in rule.input {
		if !set[glyphs[position + step]] {
			return false
		}
	}
	for set, step in rule.backtrack {
		if !set[glyphs[position - 1 - step]] {
			return false
		}
	}
	for set, step in rule.lookahead {
		if !set[glyphs[position + len(rule.input) + step]] {
			return false
		}
	}
	return true
}

apply_lookup :: proc(shaper: ^Shaper, index: int, glyphs: []int, position: int, depth := 0) -> bool {
	if depth > 6 || position < 0 || position >= len(glyphs) {
		return false
	}
	entry := lookup_parse(shaper, index)
	if entry == nil {
		return false
	}
	switch entry.kind {
	case 1:
		if replacement, found := entry.singles[glyphs[position]]; found {
			glyphs[position] = replacement
			return true
		}
	case 6:
		for rule in entry.chains {
			if !rule_matches(rule, glyphs, position) {
				continue
			}
			for record in rule.records {
				apply_lookup(shaper, record[1], glyphs, position + record[0], depth + 1)
			}
			return true
		}
	}
	return false
}

shaper_shape :: proc(painter: ^Painter, text: string) -> []int {
	shaper := &painter.shaper
	if cached, found := shaper.shaped[text]; found {
		return cached
	}
	glyphs := make([]int, len(text))
	for index in 0 ..< len(text) {
		glyphs[index] = int(stbtt.FindGlyphIndex(&painter.faces[0].info, rune(text[index])))
	}
	for index in shaper.order {
		for position in 0 ..< len(glyphs) {
			apply_lookup(shaper, index, glyphs, position)
		}
	}
	shaper.shaped[strings.clone(text)] = glyphs
	return glyphs
}

ligature_candidate :: proc(painter: ^Painter, character: u8) -> bool {
	return character < 128 && painter.shaper.joining[character]
}
