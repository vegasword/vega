#+feature dynamic-literals
package vega

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

Command :: enum u8 {
	None,
	MoveLeft,
	MoveRight,
	MoveUp,
	MoveDown,
	WordNext,
	WordNextLong,
	WordEnd,
	WordEndLong,
	WordPrevious,
	WordPreviousLong,
	HalfPageDown,
	HalfPageUp,
	SelectLine,
	SelectAll,
	CollapseSelections,
	FlipSelections,
	KeepPrimary,
	ToggleSelectMode,
	AddCursorBelow,
	AddCursorAbove,
	SelectMatches,
	InsertBefore,
	InsertAfter,
	InsertLineStart,
	InsertLineEnd,
	OpenBelow,
	OpenAbove,
	Delete,
	Change,
	Yank,
	PasteAfter,
	PasteBefore,
	ReplaceWithYank,
	YankToClipboard,
	PasteFromClipboard,
	PasteFromClipboardBefore,
	ReplaceCharacter,
	SwitchCase,
	UpperCase,
	LowerCase,
	JoinLines,
	IndentIn,
	IndentOut,
	Undo,
	Redo,
	FindForward,
	TillForward,
	FindBackward,
	TillBackward,
	RepeatFind,
	MatchBracket,
	GotoFileStart,
	GotoFileEnd,
	GotoLineStart,
	GotoLineEnd,
	GotoDefinition,
	GotoReferences,
	NextBuffer,
	PreviousBuffer,
	ViewCenter,
	ViewTop,
	ViewBottom,
	SearchForward,
	SearchBackward,
	SearchNext,
	SearchPrevious,
	SearchWordUnderCursor,
	CommandMenu,
	PickFiles,
	PickBuffers,
	PickSymbols,
	GlobalSearch,
	RenameSymbol,
	WriteFile,
	OpenSettings,
	SplitVertical,
	SplitHorizontal,
	CloseSplit,
	OnlySplit,
	NextView,
	PreviousView,
	FocusLeft,
	FocusRight,
	FocusUp,
	FocusDown,
	GrowSplit,
	ShrinkSplit,
	ToggleCentered,
	ToggleFullscreen,
	ToggleSoftWrap,
	ToggleWhitespace,
	ToggleAudio,
	ToggleComment,
	ResetChange,
	NextChange,
	PreviousChange,
	NextFunction,
	PreviousFunction,
	HoverSymbol,
	NormalMode,
	RunBuild,
	RunProgram,
	RunClean,
	ZoomIn,
	ZoomOut,
	ZoomReset,
	PrefixGoto,
	PrefixMatch,
	PrefixView,
	PrefixSpace,
	PrefixWindow,
	CloseBuffer,
	OpenFileDialog,
	OpenWorkspaces,
	NewWorkspace,
	NextDiagnostic,
	PreviousDiagnostic,
	OpenDiagnostics,
	OpenProcesses,
	InsertTodo,
	InsertNote,
	JumpBackward,
	JumpForward,
}

command_help := #partial [Command]string {
	.MoveLeft              = "Move one character left",
	.MoveRight             = "Move one character right",
	.MoveUp                = "Move one line up",
	.MoveDown              = "Move one line down",
	.WordNext              = "Select to next word start",
	.WordNextLong          = "Select to next WORD start",
	.WordEnd               = "Select to word end",
	.WordEndLong           = "Select to WORD end",
	.WordPrevious          = "Select to previous word start",
	.WordPreviousLong      = "Select to previous WORD start",
	.HalfPageDown          = "Scroll half a page down",
	.HalfPageUp            = "Scroll half a page up",
	.SelectLine            = "Select the whole line",
	.SelectAll             = "Select the whole buffer",
	.CollapseSelections    = "Collapse selections to cursors",
	.FlipSelections        = "Swap anchor and head",
	.KeepPrimary           = "Keep only the primary selection",
	.ToggleSelectMode      = "Toggle select mode",
	.AddCursorBelow        = "Add a cursor on the line below",
	.AddCursorAbove        = "Add a cursor on the line above",
	.SelectMatches         = "Select every match inside the selections",
	.InsertBefore          = "Insert before the selection",
	.InsertAfter           = "Insert after the selection",
	.InsertLineStart       = "Insert at the first non blank",
	.InsertLineEnd         = "Insert at the end of the line",
	.OpenBelow             = "Open a line below",
	.OpenAbove             = "Open a line above",
	.Delete                = "Delete the selection",
	.Change                = "Delete the selection and insert",
	.Yank                  = "Yank the selection",
	.PasteAfter            = "Paste after the selection",
	.PasteBefore           = "Paste before the selection",
	.ReplaceWithYank       = "Replace the selection with the register",
	.YankToClipboard       = "Yank the selection to the system clipboard",
	.PasteFromClipboard    = "Paste the system clipboard after the selection",
	.PasteFromClipboardBefore = "Paste the system clipboard before the selection",
	.ReplaceCharacter      = "Replace every selected character",
	.SwitchCase            = "Switch the case of the selection",
	.UpperCase             = "Upper case the selection",
	.LowerCase             = "Lower case the selection",
	.JoinLines             = "Join the line below",
	.IndentIn              = "Indent the selected lines",
	.IndentOut             = "Unindent the selected lines",
	.Undo                  = "Undo",
	.Redo                  = "Redo",
	.FindForward           = "Find the next character",
	.TillForward           = "Find till the next character",
	.FindBackward          = "Find the previous character",
	.TillBackward          = "Find till the previous character",
	.RepeatFind            = "Repeat the last character search",
	.MatchBracket          = "Jump to the matching bracket",
	.GotoFileStart         = "Go to the first line",
	.GotoFileEnd           = "Go to the last line",
	.GotoLineStart         = "Go to the line start",
	.GotoLineEnd           = "Go to the line end",
	.GotoDefinition        = "Go to the definition under the cursor",
	.GotoReferences        = "List the references under the cursor",
	.NextBuffer            = "Next buffer",
	.PreviousBuffer        = "Previous buffer",
	.ViewCenter            = "Center the view on the cursor",
	.ViewTop               = "Put the cursor line on top",
	.ViewBottom            = "Put the cursor line at the bottom",
	.SearchForward         = "Search forward",
	.SearchBackward        = "Search backward",
	.SearchNext            = "Next match",
	.SearchPrevious        = "Previous match",
	.SearchWordUnderCursor = "Search the word under the cursor",
	.CommandMenu           = "Open the command menu",
	.PickFiles             = "Open the file picker",
	.PickBuffers           = "Open the buffer picker",
	.PickSymbols           = "Open the symbol picker",
	.GlobalSearch          = "Search the whole project",
	.RenameSymbol          = "Rename the symbol everywhere",
	.WriteFile             = "Write the buffer",
	.OpenSettings          = "Open the settings",
	.SplitVertical         = "Split the view vertically",
	.SplitHorizontal       = "Split the view horizontally",
	.CloseSplit            = "Close the current split",
	.NextView              = "Focus the next split",
	.PreviousView          = "Focus the previous split",
	.FocusLeft             = "Focus the pane on the left",
	.FocusRight            = "Focus the pane on the right",
	.FocusUp               = "Focus the pane above",
	.FocusDown             = "Focus the pane below",
	.OnlySplit             = "Close every other pane",
	.GrowSplit             = "Give this pane more room",
	.ShrinkSplit           = "Give this pane less room",
	.ToggleCentered        = "Hold the text in a centred square or fill the pane",
	.ToggleFullscreen      = "Toggle fullscreen",
	.ToggleSoftWrap        = "Wrap long lines or scroll sideways",
	.ToggleWhitespace      = "Show spaces and tabs",
	.ToggleAudio           = "Play a click as you type, or stay quiet",
	.ToggleComment         = "Comment or uncomment the selected lines",
	.ResetChange           = "Put the change under the cursor back to git HEAD",
	.NextChange            = "Jump to the next change against the file on disk",
	.PreviousChange        = "Jump to the previous change",
	.NextFunction          = "Jump to the next definition",
	.PreviousFunction      = "Jump to the previous definition",
	.HoverSymbol           = "Explain the symbol under the cursor",
	.NormalMode            = "Leave insert mode",
	.RunBuild              = "Run the build script",
	.RunProgram            = "Run the run script",
	.RunClean              = "Run the clean script",
	.ZoomIn                = "Increase the font size",
	.ZoomOut               = "Decrease the font size",
	.ZoomReset             = "Reset the font size",
	.PrefixGoto            = "Goto commands",
	.PrefixMatch           = "Match commands",
	.PrefixView            = "View commands",
	.PrefixSpace           = "Space menu",
	.PrefixWindow          = "Window commands",
	.CloseBuffer           = "Close this buffer",
	.OpenFileDialog        = "Open files with the system dialog",
	.OpenWorkspaces        = "Switch workspace",
	.NewWorkspace          = "Add a workspace from a folder",
	.NextDiagnostic        = "Go to the next build error",
	.PreviousDiagnostic    = "Go to the previous build error",
	.OpenDiagnostics       = "List the build errors and warnings",
	.OpenProcesses         = "List what is running in the background",
	.InsertTodo            = "Insert a todo comment",
	.InsertNote            = "Insert a note comment",
	.JumpBackward          = "Go back in the navigation history",
	.JumpForward           = "Go forward in the navigation history",
}

Key_Modifier :: enum u8 {
	Ctrl,
	Alt,
	Shift,
}

Key_Modifiers :: bit_set[Key_Modifier; u8]

Chord :: struct {
	prefix: u8,
	key:    u8,
	mods:   Key_Modifiers,
}

default_keymap := map[Chord]Command {
	{0, 'h', {}}       = .MoveLeft,
	{0, 'l', {}}       = .MoveRight,
	{0, 'k', {}}       = .MoveUp,
	{0, 'j', {}}       = .MoveDown,
	{0, 'w', {}}       = .WordNext,
	{0, 'W', {}}       = .WordNextLong,
	{0, 'e', {}}       = .WordEnd,
	{0, 'E', {}}       = .WordEndLong,
	{0, 'b', {}}       = .WordPrevious,
	{0, 'B', {}}       = .WordPreviousLong,
	{0, 'd', {.Ctrl}}        = .HalfPageDown,
	{0, 'u', {.Ctrl}}        = .HalfPageUp,
	{0, 'x', {}}       = .SelectLine,
	{0, '%', {}}       = .SelectAll,
	{0, ';', {}}       = .CollapseSelections,
	{0, ',', {}}       = .KeepPrimary,
	{0, 'v', {}}       = .ToggleSelectMode,
	{0, 'C', {}}       = .AddCursorBelow,
	{0, 's', {}}       = .SelectMatches,
	{0, 'i', {}}       = .InsertBefore,
	{0, 'a', {}}       = .InsertAfter,
	{0, 'I', {}}       = .InsertLineStart,
	{0, 'A', {}}       = .InsertLineEnd,
	{0, 'o', {}}       = .OpenBelow,
	{0, 'O', {}}       = .OpenAbove,
	{0, 'd', {}}       = .Delete,
	{0, 'c', {}}       = .Change,
	{0, 'y', {}}       = .Yank,
	{0, 'p', {}}       = .PasteAfter,
	{0, 'P', {}}       = .PasteBefore,
	{0, 'R', {}}       = .ReplaceWithYank,
	{0, 'r', {}}       = .ReplaceCharacter,
	{0, '~', {}}       = .SwitchCase,
	{' ', 'R', {}}     = .ResetChange,
	{' ', 'u', {}}     = .UpperCase,
	{' ', 'U', {}}     = .LowerCase,
	{0, 'J', {}}       = .JoinLines,
	{0, '>', {}}       = .IndentIn,
	{0, '<', {}}       = .IndentOut,
	{0, 'u', {}}       = .Undo,
	{0, 'U', {}}       = .Redo,
	{0, 'f', {}}       = .FindForward,
	{0, 't', {}}       = .TillForward,
	{0, 'F', {}}       = .FindBackward,
	{0, 'T', {}}       = .TillBackward,
	{0, '.', {}}       = .RepeatFind,
	{0, '/', {}}       = .SearchForward,
	{0, '?', {}}       = .SearchBackward,
	{0, 'n', {}}       = .SearchNext,
	{0, 'N', {}}       = .SearchPrevious,
	{0, '*', {}}       = .SearchWordUnderCursor,
	{0, ':', {}}       = .CommandMenu,
	{0, 'g', {}}       = .PrefixGoto,
	{0, 'm', {}}       = .PrefixMatch,
	{0, 'z', {}}       = .PrefixView,
	{0, ' ', {}}       = .PrefixSpace,
	{0, 's', {.Ctrl}}        = .WriteFile,
	{0, 'm', {.Ctrl}}        = .RunBuild,
	{0, 'r', {.Ctrl}}        = .RunProgram,
	{0, 'c', {.Ctrl}}        = .ToggleComment,
	{0, 'z', {.Ctrl}}        = .ToggleCentered,
	{0, 'C', {.Ctrl, .Shift}} = .RunClean,
	{0, 'c', {.Ctrl, .Shift}} = .RunClean,
	{0, 'h', {.Ctrl}}        = .PreviousBuffer,
	{0, 'l', {.Ctrl}}        = .NextBuffer,
	{0, 'j', {.Ctrl}}        = .NextChange,
	{0, 'k', {.Ctrl}}        = .PreviousChange,
	{0, 'f', {.Ctrl}}        = .ToggleFullscreen,
	{0, 'a', {.Ctrl}}        = .ToggleAudio,
	{0, 'w', {.Ctrl}}        = .PrefixWindow,
	{0, 'q', {.Ctrl}}        = .CloseSplit,
	{0, 'o', {.Ctrl}}        = .JumpBackward,
	{0, 'i', {.Ctrl}}        = .JumpForward,
	{'w', 'v', {}}     = .SplitVertical,
	{'w', 's', {}}     = .SplitHorizontal,
	{'w', 'q', {}}     = .CloseSplit,
	{'w', 'o', {}}     = .OnlySplit,
	{'w', 'w', {}}     = .NextView,
	{'w', 'W', {}}     = .PreviousView,
	{'w', 'h', {}}     = .FocusLeft,
	{'w', 'l', {}}     = .FocusRight,
	{'w', 'k', {}}     = .FocusUp,
	{'w', 'j', {}}     = .FocusDown,
	{'w', 'd', {}}     = .CloseBuffer,
	{'w', '=', {}}     = .GrowSplit,
	{'w', '-', {}}     = .ShrinkSplit,
	{0, '+', {.Ctrl}}        = .ZoomIn,
	{0, '=', {.Ctrl}}        = .ZoomIn,
	{0, '-', {.Ctrl}}        = .ZoomOut,
	{0, '_', {.Ctrl}}        = .ZoomOut,
	{0, '0', {.Ctrl}}        = .ZoomReset,
	{'g', 'g', {}}     = .GotoFileStart,
	{'g', 'e', {}}     = .GotoFileEnd,
	{'g', 'h', {}}     = .GotoLineStart,
	{'g', 'l', {}}     = .GotoLineEnd,
	{'g', 'd', {}}     = .GotoDefinition,
	{'g', 'r', {}}     = .GotoReferences,
	{'g', 'f', {}}     = .NextFunction,
	{'g', 'F', {}}     = .PreviousFunction,
	{'g', 'n', {}}     = .NextDiagnostic,
	{'g', 'p', {}}     = .PreviousDiagnostic,
	{'g', 'b', {}}     = .NextBuffer,
	{'g', 'B', {}}     = .PreviousBuffer,
	{'m', 'm', {}}     = .MatchBracket,
	{'z', 'z', {}}     = .ViewCenter,
	{'z', 't', {}}     = .ViewTop,
	{'z', 'b', {}}     = .ViewBottom,
	{' ', 'f', {}}     = .PickFiles,
	{' ', 'b', {}}     = .PickBuffers,
	{' ', 's', {}}     = .PickSymbols,
	{' ', '/', {}}     = .GlobalSearch,
	{' ', 'r', {}}     = .RenameSymbol,
	{' ', 'k', {}}     = .HoverSymbol,
	{' ', 'w', {}}     = .OpenWorkspaces,
	{' ', 'W', {}}     = .NewWorkspace,
	{' ', 'E', {}}     = .OpenDiagnostics,
	{0, 'p', {.Ctrl}}        = .OpenProcesses,
	{0, 't', {.Ctrl}}        = .InsertTodo,
	{0, 'n', {.Ctrl}}        = .InsertNote,
	{' ', 'c', {}}     = .OpenSettings,
	{' ', 'v', {}}     = .SplitVertical,
	{' ', 'x', {}}     = .SplitHorizontal,
	{' ', 'q', {}}     = .CloseSplit,
	{' ', 'o', {}}     = .OnlySplit,
	{' ', '=', {}}     = .GrowSplit,
	{' ', '-', {}}     = .ShrinkSplit,
	{' ', 'z', {}}     = .ToggleSoftWrap,
	{' ', 'i', {}}     = .ToggleWhitespace,
	{' ', 'n', {}}     = .NextChange,
	{' ', 'N', {}}     = .PreviousChange,
	{' ', 'a', {}}     = .AddCursorAbove,
	{' ', 'm', {}}     = .FlipSelections,
	{' ', 'e', {}}     = .OpenFileDialog,
	{' ', 'y', {}}     = .Yank,
	{' ', 'p', {}}     = .PasteAfter,
	{' ', 'Y', {}}     = .YankToClipboard,
	{' ', 'P', {}}     = .PasteFromClipboard,
}

keymap_reset :: proc(editor: ^Editor) {
	clear(&editor.keymap)
	for chord, command in default_keymap {
		editor.keymap[chord] = command
	}
	log.infof("keymap reset to %d default bindings", len(editor.keymap))
}

keymap_bind :: proc(editor: ^Editor, chord: Chord, command: Command) {
	for existing, bound in editor.keymap {
		if bound == command && existing != chord && existing.prefix == chord.prefix {
			delete_key(&editor.keymap, existing)
		}
	}
	editor.keymap[chord] = command
	log.infof("bound %v to %v", chord, command)
}

chord_label :: proc(chord: Chord) -> string {
	prefix := chord.prefix == 0 ? "" : (chord.prefix == ' ' ? "space " : fmt.tprintf("%c ", chord.prefix))
	modifiers := ""
	if .Ctrl in chord.mods {
		modifiers = fmt.tprintf("%sctrl-", modifiers)
	}
	if .Alt in chord.mods {
		modifiers = fmt.tprintf("%salt-", modifiers)
	}
	if .Shift in chord.mods {
		modifiers = fmt.tprintf("%sshift-", modifiers)
	}
	key := chord.key == ' ' ? "space" : fmt.tprintf("%c", chord.key)
	return fmt.tprintf("%s%s%s", prefix, modifiers, key)
}

modifiers_label :: proc(mods: Key_Modifiers) -> string {
	switch mods {
	case {}:
		return "plain"
	case {.Ctrl}:
		return "ctrl"
	case {.Alt}:
		return "alt"
	case {.Shift}:
		return "shift"
	case {.Ctrl, .Alt}:
		return "ctrl+alt"
	case {.Ctrl, .Shift}:
		return "ctrl+shift"
	case {.Alt, .Shift}:
		return "alt+shift"
	}
	return "ctrl+alt+shift"
}

modifiers_from_label :: proc(label: string) -> Key_Modifiers {
	mods: Key_Modifiers
	if strings.contains(label, "ctrl") {
		mods += {.Ctrl}
	}
	if strings.contains(label, "alt") {
		mods += {.Alt}
	}
	if strings.contains(label, "shift") {
		mods += {.Shift}
	}
	return mods
}

command_mutates :: proc(command: Command) -> bool {
	#partial switch command {
	case .InsertBefore, .InsertAfter, .InsertLineStart, .InsertLineEnd, .OpenBelow, .OpenAbove,
	     .Delete, .Change, .PasteAfter, .PasteBefore, .ReplaceWithYank, .ReplaceCharacter,
	     .SwitchCase, .UpperCase, .LowerCase, .ToggleComment, .ResetChange, .JoinLines, .IndentIn, .IndentOut, .Undo, .Redo:
		return true
	}
	return false
}

execute_command :: proc(editor: ^Editor, command: Command, count: int) {
	buffer := editor_buffer(editor)
	if (.ReadOnly in buffer.flags) && command_mutates(command) {
		notify("This buffer is read only", .Warning)
		return
	}
	if editor.output.open && (command == .HalfPageDown || command == .HalfPageUp) {
		output_scroll(editor, command == .HalfPageDown ? OUTPUT_LINES - 1 : -(OUTPUT_LINES - 1))
		return
	}
	view := editor_view(editor)
	extend := editor.mode == .Select
	repeat := max(1, count)
	log.debugf("command %v count %d mode %v", command, repeat, editor.mode)

	switch command {
	case .None:
	case .MoveLeft:
		move_horizontal(buffer, -repeat, extend)
	case .MoveRight:
		move_horizontal(buffer, repeat, extend)
	case .MoveUp:
		move_visual_vertical(editor, -repeat, extend)
	case .MoveDown:
		move_visual_vertical(editor, repeat, extend)
	case .WordNext:
		for _ in 0 ..< repeat {move_word(buffer, 1, false, false, extend)}
	case .WordNextLong:
		for _ in 0 ..< repeat {move_word(buffer, 1, false, true, extend)}
	case .WordEnd:
		for _ in 0 ..< repeat {move_word(buffer, 1, true, false, extend)}
	case .WordEndLong:
		for _ in 0 ..< repeat {move_word(buffer, 1, true, true, extend)}
	case .WordPrevious:
		for _ in 0 ..< repeat {move_word(buffer, -1, false, false, extend)}
	case .WordPreviousLong:
		for _ in 0 ..< repeat {move_word(buffer, -1, false, true, extend)}
	case .HalfPageDown:
		move_vertical(buffer, view_visible_lines(editor, view) / 2, extend)
		editor_center_view(editor)
	case .HalfPageUp:
		move_vertical(buffer, -view_visible_lines(editor, view) / 2, extend)
		editor_center_view(editor)
	case .SelectLine:
		for _ in 0 ..< repeat {select_lines(buffer, true)}
	case .SelectAll:
		buffer_collapse_to_primary(buffer)
		buffer_primary(buffer)^ = {0, max(0, len(buffer.text) - 1)}
	case .CollapseSelections:
		for &selection in buffer.selections {
			selection.anchor = selection.head
		}
	case .FlipSelections:
		for &selection in buffer.selections {
			selection.anchor, selection.head = selection.head, selection.anchor
		}
	case .KeepPrimary:
		buffer_collapse_to_primary(buffer)
	case .ToggleSelectMode:
		editor.mode = editor.mode == .Select ? .Normal : .Select
	case .AddCursorBelow:
		for _ in 0 ..< repeat {add_cursor(buffer, true)}
	case .AddCursorAbove:
		for _ in 0 ..< repeat {add_cursor(buffer, false)}
	case .SelectMatches:
		prompt_open(editor, .SelectMatches)
	case .InsertBefore:
		enter_insert(editor, buffer, false)
	case .InsertAfter:
		enter_insert(editor, buffer, true)
	case .InsertLineStart:
		goto_first_non_blank(buffer)
		enter_insert(editor, buffer, false)
	case .InsertLineEnd:
		goto_line_edge(buffer, .End, false)
		enter_insert(editor, buffer, true)
	case .OpenBelow:
		open_line(editor, buffer, true)
	case .OpenAbove:
		open_line(editor, buffer, false)
	case .Delete:
		delete_selections(editor, buffer, true)
		editor.mode = .Normal
		sfx_delete(editor)
	case .Change:
		delete_selections(editor, buffer, true)
		editor.mode = .Insert
	case .Yank:
		yank_selections(editor, buffer)
		editor.mode = .Normal
		log.debugf("yanked %d selection(s)", len(buffer.selections))
	case .PasteAfter:
		paste(editor, buffer, true)
	case .PasteBefore:
		paste(editor, buffer, false)
	case .ReplaceWithYank:
		replace_with_register(editor, buffer)
	case .YankToClipboard:
		yank_to_clipboard(editor, buffer)
		editor.mode = .Normal
	case .PasteFromClipboard:
		paste_from_clipboard(editor, buffer, true)
	case .PasteFromClipboardBefore:
		paste_from_clipboard(editor, buffer, false)
	case .ReplaceCharacter:
		editor.flags += {.PendingReplace}
	case .SwitchCase:
		case_selections(buffer, .Switch)
	case .UpperCase:
		case_selections(buffer, .Upper)
	case .LowerCase:
		case_selections(buffer, .Lower)
	case .JoinLines:
		join_lines(buffer)
	case .IndentIn:
		indent_selections(editor, buffer, true)
	case .IndentOut:
		indent_selections(editor, buffer, false)
	case .Undo:
		buffer_restore(buffer, &buffer.undo_stack, &buffer.redo_stack)
	case .Redo:
		buffer_restore(buffer, &buffer.redo_stack, &buffer.undo_stack)
	case .FindForward:
		editor.pending_find = .FindForward
	case .TillForward:
		editor.pending_find = .TillForward
	case .FindBackward:
		editor.pending_find = .FindBackward
	case .TillBackward:
		editor.pending_find = .TillBackward
	case .RepeatFind:
		if editor.last_find.character != 0 {
			find_character(buffer, editor.last_find.character, editor.last_find.forward, editor.last_find.till, extend)
		}
	case .MatchBracket:
		match_bracket(buffer)
	case .GotoFileStart:
		jump_push(editor)
		goto_offset(buffer, 0, extend)
		editor_center_view(editor)
	case .GotoFileEnd:
		jump_push(editor)
		goto_offset(buffer, len(buffer.text), extend)
		editor_center_view(editor)
	case .GotoLineStart:
		goto_line_edge(buffer, .Start, extend)
	case .GotoLineEnd:
		goto_line_edge(buffer, .End, extend)
	case .GotoDefinition:
		jump_push(editor)
		editor_goto_definition(editor)
	case .GotoReferences:
		jump_push(editor)
		editor_goto_references(editor)
	case .NextBuffer:
		view.buffer = (view.buffer + 1) % len(editor.buffers)
	case .PreviousBuffer:
		view.buffer = (view.buffer + len(editor.buffers) - 1) % len(editor.buffers)
	case .ViewCenter:
		editor_center_view(editor)
	case .ViewTop:
		view.scroll_line = buffer_line_of(buffer, buffer_primary(buffer).head)
	case .ViewBottom:
		view.scroll_line = max(0, buffer_line_of(buffer, buffer_primary(buffer).head) - view_visible_lines(editor, view) + 1)
	case .SearchForward:
		prompt_open(editor, .Search)
	case .SearchBackward:
		prompt_open(editor, .SearchBackward)
	case .SearchNext:
		if len(buffer.selections) > 1 {
			drop_selection(buffer, true)
		} else {
			search_in_buffer(buffer, editor.search_pattern, true)
		}
		editor_center_view(editor)
	case .SearchPrevious:
		if len(buffer.selections) > 1 {
			drop_selection(buffer, false)
		} else {
			search_in_buffer(buffer, editor.search_pattern, false)
		}
		editor_center_view(editor)
	case .SearchWordUnderCursor:
		word, _ := word_at(buffer.text[:], buffer_primary(buffer).head)
		if word != "" {
			delete(editor.search_pattern)
			editor.search_pattern = strings.clone(word)
			search_in_buffer(buffer, editor.search_pattern, true)
			editor_center_view(editor)
			log.debugf("search %s", word)
		}
	case .CommandMenu:
		picker_open(editor, .Commands, "Command")
	case .PickFiles:
		picker_open(editor, .Files, "Open file")
	case .PickBuffers:
		picker_open(editor, .Buffers, "Buffers")
	case .PickSymbols:
		picker_open(editor, .Symbols, "Symbols")
	case .GlobalSearch:
		picker_open(editor, .GlobalSearch, "Global search")
	case .RenameSymbol:
		editor_start_rename(editor)
	case .WriteFile:
		editor_write(editor, buffer)
	case .OpenSettings:
		settings_open(editor)
	case .SplitVertical:
		layout_split(editor, .Columns)
	case .SplitHorizontal:
		layout_split(editor, .Rows)
	case .CloseSplit:
		layout_close(editor)
	case .OnlySplit:
		layout_only(editor)
	case .NextView:
		layout_focus(editor, 1)
	case .PreviousView:
		layout_focus(editor, -1)
	case .FocusLeft:
		layout_focus_direction(editor, .Left)
	case .FocusRight:
		layout_focus_direction(editor, .Right)
	case .FocusUp:
		layout_focus_direction(editor, .Up)
	case .FocusDown:
		layout_focus_direction(editor, .Down)
	case .GrowSplit:
		layout_resize(editor, 0.05)
	case .ShrinkSplit:
		layout_resize(editor, -0.05)
	case .ToggleCentered:
		editor.config.options ~= {.Centered}
		editor.flags += {.ConfigDirty}
		log.debugf("centred %v", .Centered in editor.config.options)
	case .ToggleFullscreen:
		editor.config.options ~= {.Fullscreen}
		sdl.SetWindowFullscreen(editor.window, (.Fullscreen in editor.config.options))
		editor.flags += {.ConfigDirty}
	case .ToggleSoftWrap:
		editor.config.options ~= {.SoftWrap}
		editor.flags += {.ConfigDirty}
		log.debugf("soft wrap %v", .SoftWrap in editor.config.options)
	case .ResetChange:
		reset_change(editor)
	case .ToggleComment:
		comment_selections(buffer)
	case .ToggleAudio:
		editor.config.options ~= {.KeyClicks}
		editor.flags += {.ConfigDirty}
		notify((.KeyClicks in editor.config.options) ? "Key clicks on" : "Key clicks off")
	case .ToggleWhitespace:
		editor.config.options ~= {.RenderWhitespace}
		editor.flags += {.ConfigDirty}
	case .NextChange:
		goto_change(editor, true)
	case .PreviousChange:
		goto_change(editor, false)
	case .NextFunction:
		goto_function(editor, true)
	case .PreviousFunction:
		goto_function(editor, false)
	case .HoverSymbol:
		hover_open(editor)
	case .NormalMode:
		if editor.mode == .Insert {
			leave_insert(editor, buffer)
		}
	case .RunBuild:
		shell_run(editor, project_script("build"))
	case .RunProgram:
		shell_run(editor, project_script("run"))
	case .RunClean:
		shell_run(editor, project_script("clean"))
	case .ZoomIn:
		editor_zoom(editor, 1)
	case .ZoomOut:
		editor_zoom(editor, -1)
	case .ZoomReset:
		editor_zoom(editor, 0)
	case .PrefixGoto:
		editor_open_prefix(editor, 'g', "Goto")
	case .PrefixMatch:
		editor_open_prefix(editor, 'm', "Match")
	case .PrefixView:
		editor_open_prefix(editor, 'z', "View")
	case .PrefixSpace:
		editor_open_prefix(editor, ' ', "Space")
	case .PrefixWindow:
		editor_open_prefix(editor, 'w', "Window")
	case .CloseBuffer:
		editor_close_buffer(editor, false)
	case .OpenFileDialog:
		open_file_dialog(editor)
	case .NextDiagnostic:
		diagnostic_go(editor, 1)
	case .PreviousDiagnostic:
		diagnostic_go(editor, -1)
	case .OpenProcesses:
		if len(background_jobs(editor)) == 0 {
			notify("Nothing is running in the background")
			break
		}
		picker_open(editor, .Processes, "Background")
	case .OpenDiagnostics:
		if len(editor.diagnostics) == 0 {
			notify("Nothing was reported by the last build")
			break
		}
		picker_open(editor, .Diagnostics, "Problem")
	case .InsertTodo:
		insert_tagged_comment(editor, buffer, "TODO")
	case .InsertNote:
		insert_tagged_comment(editor, buffer, "NOTE")
	case .OpenWorkspaces:
		workspace_pick(editor)
	case .NewWorkspace:
		notify("Pick a folder to make it a workspace")
		open_folder_dialog(editor)
	case .JumpBackward:
		jump_to(editor, -1)
	case .JumpForward:
		if editor.mode == .Insert {
			leave_insert(editor, buffer)
		} else {
			jump_to(editor, 1)
		}
	}
	if command_mutates(command) && command != .Undo && command != .Redo && editor.mode != .Insert {
		buffer_commit(buffer)
	}
	view_focus_poll(editor)
	if command != .ViewTop && command != .ViewCenter && command != .ViewBottom {
		editor_ensure_visible(editor)
	}
}

Ex_Command :: struct {
	name: string,
	help: string,
}

ex_commands := []Ex_Command {
	{"w", "Write the buffer"},
	{"wa", "Write every modified buffer"},
	{"q", "Close the pane, or quit on the last one"},
	{"q!", "Quit, discard changes"},
	{"qa", "Quit all"},
	{"wqa", "Write everything and quit"},
	{"bc", "Close the buffer"},
	{"wq", "Write and close"},
	{"n", "New scratch buffer"},
	{"ws", "Switch workspace"},
	{"bn", "Next buffer"},
	{"bp", "Previous buffer"},
	{"bd", "Close the buffer"},
	{"vsplit", "Split the view vertically"},
	{"hsplit", "Split the view horizontally"},
	{"close", "Close the current split"},
	{"only", "Close every other pane"},
	{"centered", "Square the text and centre it in the pane"},
	{"audio", "Toggle the key clicks"},
	{"reset-diff-change", "Put the change under the cursor back to git HEAD"},
	{"cap", "Upper case the selection"},
	{"uncap", "Lower case the selection"},
	{"index", "Reindex the project"},
	{"reload", "Reload the buffer from disk"},
	{"settings", "Open the settings"},
	{"theme", "Set the theme, :theme ember"},
	{"font", "Set the font size, :font 22"},
	{"keys", "Open the keymap editor"},
	{"log", "Show the log path"},
	{"sh", "Run a shell command, :sh git status"},
	{"!", "Run a shell command, :! git status"},
	{"session", "Save the session now"},
	{"quit", "Quit vega"},
}

run_command :: proc(editor: ^Editor, line: string) {
	command_line := ""
	if strings.has_prefix(line, "!") {
		command_line = strings.trim_space(line[1:])
	} else if strings.has_prefix(line, "sh ") || line == "sh" {
		command_line = strings.trim_space(line[2:])
	}
	if command_line != "" {
		shell_run(editor, command_line)
		return
	}
	if strings.has_prefix(line, "!") || line == "sh" {
		notify("Give the command to run, :sh git status")
		return
	}
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) == 0 {
		return
	}
	buffer := editor_buffer(editor)
	argument := len(fields) > 1 ? fields[1] : ""
	log.infof("ex command %s", line)
	switch fields[0] {
	case "w", "write":
		editor_write(editor, buffer)
	case "wa", "write-all":
		editor_write_all(editor)
	case "q":
		if len(layout_ordered_leaves(editor)) > 1 {
			layout_close(editor)
		} else {
			editor_quit(editor, false)
		}
	case "q!":
		editor_quit(editor, true)
	case "qa", "quit-all":
		editor_quit(editor, false)
	case "qa!", "quit-all!":
		editor_quit(editor, true)
	case "wq", "x":
		if buffer.path == "" {
			save_file_dialog(editor, buffer)
			return
		}
		buffer_save(editor, buffer)
		if len(layout_ordered_leaves(editor)) > 1 {
			layout_close(editor)
		} else {
			editor_quit(editor, true)
		}
	case "wqa", "xa", "write-quit-all":
		editor_write_all(editor)
		editor_quit(editor, true)
	case "bc", "bc!":
		editor_close_buffer(editor, fields[0] == "bc!")
	case "n", "new":
		append(&editor.buffers, buffer_create(editor, ""))
		editor_view(editor).buffer = len(editor.buffers) - 1
		editor.flags += {.SessionDirty}
		notify("New scratch buffer")
	case "ws", "workspace":
		if len(fields) > 1 {
			workspace_open(editor, strings.join(fields[1:], " ", context.temp_allocator))
		} else {
			workspace_pick(editor)
		}
	case "bn":
		execute_command(editor, .NextBuffer, 1)
	case "bp":
		execute_command(editor, .PreviousBuffer, 1)
	case "bd":
		editor_close_buffer(editor, true)
	case "vsplit":
		layout_split(editor, .Columns)
	case "hsplit":
		layout_split(editor, .Rows)
	case "close":
		layout_close(editor)
	case "only":
		layout_only(editor)
	case "reset-diff-change", "reset":
		reset_change(editor)
	case "cap":
		execute_command(editor, .UpperCase, 1)
	case "uncap":
		execute_command(editor, .LowerCase, 1)
	case "audio":
		execute_command(editor, .ToggleAudio, 1)
	case "centered", "centred":
		execute_command(editor, .ToggleCentered, 1)
	case "index":
		index_start(&editor.index, editor.index.root)
		editor_status(editor, "Indexing in the background")
	case "reload":
		editor_reload(editor, buffer)
	case "settings", "config":
		settings_open(editor)
	case "theme":
		if argument == "" || !theme_set(editor, argument) {
			picker_open(editor, .Themes, "Theme")
		}
	case "font":
		editor.config.font_size = clamp(parse_number(argument), 8, 64)
		editor.flags += {.FontDirty, .ConfigDirty}
	case "keys":
		settings_open(editor)
		editor.settings.section = .Keys
	case "log":
		notify(fmt.tprintf("Logging to %s", log_path))
	case "session":
		session_save(editor)
		notify("Session saved")
	case "quit":
		editor.flags += {.Quit}
	case:
		suggestions := make([dynamic]string, 0, 4, context.temp_allocator)
		for entry in ex_commands {
			if len(suggestions) < 3 && strings.has_prefix(entry.name, fields[0][:1]) {
				append(&suggestions, entry.name)
			}
		}
		editor_status(editor, fmt.tprintf("Unknown command: %s\nDid you mean %s\nPress : for the full list", fields[0], strings.join(suggestions[:], ", ", context.temp_allocator)))
	}
}
