package vega

import "base:intrinsics"
import "core:math/bits"
import "core:simd"

BYTE_LANES :: 32

Byte_Vector :: #simd[BYTE_LANES]u8

byte_load :: #force_inline proc(text: []u8, from: int) -> Byte_Vector {
	return intrinsics.unaligned_load((^Byte_Vector)(raw_data(text[from:])))
}

byte_splat :: #force_inline proc(value: u8) -> Byte_Vector {
	return Byte_Vector(value)
}

byte_word_mask :: #force_inline proc(chunk: Byte_Vector) -> u32 {
	lower := simd.lanes_ge(chunk, byte_splat('a')) & simd.lanes_le(chunk, byte_splat('z'))
	upper := simd.lanes_ge(chunk, byte_splat('A')) & simd.lanes_le(chunk, byte_splat('Z'))
	digits := simd.lanes_ge(chunk, byte_splat('0')) & simd.lanes_le(chunk, byte_splat('9'))
	other := simd.lanes_eq(chunk, byte_splat('_')) | simd.lanes_ge(chunk, byte_splat(128))
	return transmute(u32)simd.extract_msbs(lower | upper | digits | other)
}

byte_space_mask :: #force_inline proc(chunk: Byte_Vector) -> u32 {
	blanks := simd.lanes_eq(chunk, byte_splat(' ')) | simd.lanes_eq(chunk, byte_splat('\t'))
	breaks := simd.lanes_eq(chunk, byte_splat('\n')) | simd.lanes_eq(chunk, byte_splat('\r'))
	return transmute(u32)simd.extract_msbs(blanks | breaks)
}

scan_words :: proc(text: []u8, from: int) -> int {
	cursor := from
	for cursor + BYTE_LANES <= len(text) {
		mask := byte_word_mask(byte_load(text, cursor))
		if mask != max(u32) {
			return cursor + int(bits.count_trailing_zeros(~mask))
		}
		cursor += BYTE_LANES
	}
	for cursor < len(text) && is_word_byte(text[cursor]) {
		cursor += 1
	}
	return cursor
}

scan_spaces :: proc(text: []u8, from: int) -> int {
	cursor := from
	for cursor + BYTE_LANES <= len(text) {
		mask := byte_space_mask(byte_load(text, cursor))
		if mask != max(u32) {
			return cursor + int(bits.count_trailing_zeros(~mask))
		}
		cursor += BYTE_LANES
	}
	for cursor < len(text) && (text[cursor] == ' ' || text[cursor] == '\t' || text[cursor] == '\r' || text[cursor] == '\n') {
		cursor += 1
	}
	return cursor
}

scan_byte :: proc(text: []u8, from: int, needle: u8) -> int {
	cursor := from
	wanted := byte_splat(needle)
	for cursor + BYTE_LANES <= len(text) {
		mask := transmute(u32)simd.extract_msbs(simd.lanes_eq(byte_load(text, cursor), wanted))
		if mask != 0 {
			return cursor + int(bits.count_trailing_zeros(mask))
		}
		cursor += BYTE_LANES
	}
	for cursor < len(text) && text[cursor] != needle {
		cursor += 1
	}
	return cursor
}

count_byte :: proc(text: []u8, upto: int, needle: u8) -> int {
	end := min(upto, len(text))
	cursor := 0
	total := 0
	wanted := byte_splat(needle)
	for cursor + BYTE_LANES <= end {
		mask := transmute(u32)simd.extract_msbs(simd.lanes_eq(byte_load(text, cursor), wanted))
		total += int(bits.count_ones(mask))
		cursor += BYTE_LANES
	}
	for cursor < end {
		if text[cursor] == needle {
			total += 1
		}
		cursor += 1
	}
	return total
}
