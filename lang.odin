package vega

import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

Language :: enum u8 {
	Plain,
	Odin,
	C,
	GLSL,
	Shell,
}

Token_Kind :: enum u8 {
	Identifier,
	Function,
	Keyword,
	Type,
	Number,
	String,
	Comment,
	Directive,
	Punct,
}

Token :: struct {
	kind:  Token_Kind,
	start: i32,
	end:   i32,
}

odin_keywords := []string {
	"package", "import", "foreign", "using", "proc", "struct", "enum", "union", "bit_set", "bit_field",
	"map", "matrix", "if", "else", "for", "switch", "case", "in", "not_in", "do", "return", "break",
	"continue", "fallthrough", "defer", "when", "where", "or_else", "or_return", "or_break",
	"or_continue", "cast", "transmute", "auto_cast", "distinct", "dynamic", "context", "nil", "true",
	"false", "size_of", "align_of", "offset_of", "type_of", "typeid", "any", "inline", "no_inline",
}

odin_types := []string {
	"int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
	"f16", "f32", "f64", "bool", "b8", "b16", "b32", "b64", "byte", "rune", "string", "cstring",
	"rawptr", "complex64", "complex128", "quaternion128", "quaternion256",
}

c_keywords := []string {
	"if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
	"goto", "sizeof", "typedef", "struct", "union", "enum", "static", "const", "volatile", "extern",
	"inline", "register", "restrict", "auto", "_Static_assert", "alignof", "defined", "NULL",
}

c_types := []string {
	"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "size_t",
	"ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
	"uint16_t", "uint32_t", "uint64_t", "bool", "_Bool", "va_list", "FILE",
}

glsl_keywords := []string {
	"attribute", "const", "uniform", "varying", "buffer", "shared", "layout", "centroid", "flat",
	"smooth", "noperspective", "patch", "sample", "break", "continue", "do", "for", "while", "switch",
	"case", "default", "if", "else", "subroutine", "in", "out", "inout", "true", "false", "invariant",
	"precise", "discard", "return", "struct", "precision", "highp", "mediump", "lowp",
}

glsl_types := []string {
	"void", "bool", "int", "uint", "float", "double", "vec2", "vec3", "vec4", "dvec2", "dvec3",
	"dvec4", "bvec2", "bvec3", "bvec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4",
	"mat2", "mat3", "mat4", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2",
	"mat4x3", "mat4x4", "sampler1D", "sampler2D", "sampler3D", "samplerCube", "sampler2DShadow",
	"sampler2DArray", "isampler2D", "usampler2D", "image2D", "iimage2D", "uimage2D", "atomic_uint",
}

shell_keywords := []string {
	"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
	"function", "return", "exit", "export", "local", "readonly", "source", "alias", "set", "unset",
	"echo", "printf", "cd", "shift", "trap", "param", "foreach", "switch", "try", "catch", "finally",
	"begin", "process", "end", "true", "false", "break", "continue",
}

shell_types := []string {
	"string", "int", "bool", "array", "hashtable", "object", "void", "double", "char", "byte",
}

language_words :: proc "contextless" (language: Language) -> (keywords, types: []string) {
	switch language {
	case .Shell:
		return shell_keywords, shell_types
	case .Odin:
		return odin_keywords, odin_types
	case .C:
		return c_keywords, c_types
	case .GLSL:
		return glsl_keywords, glsl_types
	case .Plain:
	}
	return nil, nil
}

language_of_path :: proc(path: string) -> Language {
	switch filepath.ext(path) {
	case ".odin":
		return .Odin
	case ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".inl":
		return .C
	case ".glsl", ".vert", ".frag", ".comp", ".geom", ".tesc", ".tese", ".vs", ".fs":
		return .GLSL
	case ".sh", ".bash", ".zsh", ".ps1", ".bat", ".cmd":
		return .Shell
	}
	return .Plain
}

is_word_byte :: proc(character: u8) -> bool {
	return character == '_' ||
		character >= 128 ||
		(character >= 'a' && character <= 'z') ||
		(character >= 'A' && character <= 'Z') ||
		(character >= '0' && character <= '9')
}

word_at :: proc(text: []u8, offset: int) -> (word: string, start: int) {
	if len(text) == 0 {
		return "", 0
	}
	position := clamp(offset, 0, len(text) - 1)
	if !is_word_byte(text[position]) {
		return "", position
	}
	start = position
	for start > 0 && is_word_byte(text[start - 1]) {
		start -= 1
	}
	end := position
	for end < len(text) && is_word_byte(text[end]) {
		end += 1
	}
	return string(text[start:end]), start
}

tokenize :: proc(text: []u8, language: Language, tokens: ^[dynamic]Token) {
	clear(tokens)
	keywords := &language_filters[language].keywords
	types := &language_filters[language].types
	line_comment_only := language == .Plain
	cursor := 0
	for cursor < len(text) {
		character := text[cursor]
		switch {
		case character == ' ' || character == '\t' || character == '\r' || character == '\n':
			cursor = scan_spaces(text, cursor)

		case !line_comment_only && character == '/' && cursor + 1 < len(text) && text[cursor + 1] == '/':
			start := cursor
			cursor = scan_byte(text, cursor, '\n')
			append(tokens, Token{.Comment, i32(start), i32(cursor)})

		case !line_comment_only && character == '/' && cursor + 1 < len(text) && text[cursor + 1] == '*':
			start := cursor
			cursor += 2
			nesting := 1
			for cursor + 1 < len(text) && nesting > 0 {
				if text[cursor] == '/' && text[cursor + 1] == '*' && language == .Odin {
					nesting += 1
					cursor += 2
				} else if text[cursor] == '*' && text[cursor + 1] == '/' {
					nesting -= 1
					cursor += 2
				} else {
					cursor += 1
				}
			}
			if nesting > 0 {
				cursor = len(text)
			}
			append(tokens, Token{.Comment, i32(start), i32(cursor)})

		case character == '"' || character == '\'' || (character == '`' && language == .Odin):
			start := cursor
			cursor += 1
			for cursor < len(text) && text[cursor] != character {
				if text[cursor] == '\\' && character != '`' {
					cursor += 1
				} else if text[cursor] == '\n' && character != '`' {
					break
				}
				cursor += 1
			}
			if cursor < len(text) {
				cursor += 1
			}
			append(tokens, Token{.String, i32(start), i32(cursor)})

		case character == '#':
			start := cursor
			cursor += 1
			if language == .Shell {
				cursor = scan_byte(text, cursor, '\n')
				append(tokens, Token{.Comment, i32(start), i32(cursor)})
				break
			}
			cursor = scan_words(text, cursor)
			append(tokens, Token{.Directive, i32(start), i32(cursor)})

		case character >= '0' && character <= '9':
			start := cursor
			for cursor < len(text) && (is_word_byte(text[cursor]) || text[cursor] == '.') {
				cursor += 1
			}
			append(tokens, Token{.Number, i32(start), i32(cursor)})

		case is_word_byte(character):
			start := cursor
			cursor = scan_words(text, cursor)
			word := string(text[start:cursor])
			kind := Token_Kind.Identifier
			if word_in_filter(keywords, word) {
				kind = .Keyword
			} else if word_in_filter(types, word) {
				kind = .Type
			} else {
				lookahead := cursor
				for lookahead < len(text) && (text[lookahead] == ' ' || text[lookahead] == '\t') {
					lookahead += 1
				}
				if lookahead < len(text) && text[lookahead] == '(' {
					kind = .Function
				}
			}
			append(tokens, Token{kind, i32(start), i32(cursor)})

		case:
			start := cursor
			cursor += 1
			append(tokens, Token{.Punct, i32(start), i32(cursor)})
		}
	}
}

Word_Filter :: struct {
	entries: []string,
	lengths: [256]u64,
}

language_filters: [Language]struct {
	keywords: Word_Filter,
	types:    Word_Filter,
}

@(init)
language_filters_prepare :: proc "contextless" () {
	for language in Language {
		keywords, types := language_words(language)
		language_filters[language] = {word_filter_of(keywords), word_filter_of(types)}
	}
}

word_filter_of :: proc "contextless" (entries: []string) -> (filter: Word_Filter) {
	filter.entries = entries
	for entry in entries {
		if len(entry) > 0 && len(entry) < 64 {
			filter.lengths[entry[0]] |= 1 << uint(len(entry))
		}
	}
	return
}

word_in_filter :: proc(filter: ^Word_Filter, word: string) -> bool {
	if len(word) == 0 || len(word) >= 64 {
		return false
	}
	if (filter.lengths[word[0]] >> uint(len(word))) & 1 == 0 {
		return false
	}
	for entry in filter.entries {
		if entry == word {
			return true
		}
	}
	return false
}

word_in_set :: proc(set: []string, word: string) -> bool {
	for entry in set {
		if entry == word {
			return true
		}
	}
	return false
}

token_text :: proc(text: []u8, token: Token) -> string {
	return string(text[token.start:token.end])
}

punct_is :: proc(text: []u8, token: Token, character: u8) -> bool {
	return token.kind == .Punct && text[token.start] == character
}

trimmed_line_around :: proc(text: []u8, offset: int) -> string {
	start := clamp(offset, 0, len(text))
	for start > 0 && text[start - 1] != '\n' {
		start -= 1
	}
	end := clamp(offset, 0, len(text))
	for end < len(text) && text[end] != '\n' {
		end += 1
	}
	return strings.trim_space(string(text[start:end]))
}

rune_size_at :: proc(text: []u8, offset: int) -> int {
	if offset < 0 || offset >= len(text) {
		return 1
	}
	_, size := utf8.decode_rune(text[offset:])
	return max(1, size)
}

rune_at :: proc(text: []u8, offset: int) -> rune {
	if offset < 0 || offset >= len(text) {
		return ' '
	}
	codepoint, _ := utf8.decode_rune(text[offset:])
	return codepoint
}

next_rune_offset :: proc(text: []u8, offset: int) -> int {
	return min(len(text), offset + rune_size_at(text, offset))
}

previous_rune_offset :: proc(text: []u8, offset: int) -> int {
	position := clamp(offset, 0, len(text)) - 1
	for position > 0 && text[position] & 0xc0 == 0x80 {
		position -= 1
	}
	return max(0, position)
}