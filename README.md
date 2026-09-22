# vega

I vibe-cooked this at work because I was too bored of Helix and my own job.

>[!WARNING]
> This project was entirely made by Claude Opus 5 in low effort.
> Do not take this project seriously and expect dumb features and bugs.
> The garbage below is the Claude's dev journal, which is pointless because this fucker keep losing its memory when it's context compacting and breaking random well established features.
> Do not reproduce this stunt at home because it could cost you hover 500$ in the Anthropic economy.

A Helix-flavoured modal editor in Odin. GPU rendered through SDL3's renderer: every
glyph, selection, panel, keyboard key, colour swatch and connector line of a frame goes
out as one batched `RenderGeometry` call against a single glyph atlas that fills in as
new codepoints appear. The
window has no title bar and opens maximized. The logo sits at the left of the top bar,
tinted with the theme's accent, then the buffer tabs; drag the bar to move the window,
drag any edge or corner to resize it, and the three buttons on the right minimise,
maximise and close. F11 or alt-enter makes it fullscreen. The same `icons/logo.png` is
compiled in three ways: drawn in the top bar, handed to SDL as the window icon, and built
into `icons/vega.ico` for the executable.

```
build.bat / build.sh          builds, with the icon resource on Windows
run.bat   / run.sh            builds, then launches it
clean.bat / clean.sh          removes the executable, the log and the screenshots
vega.exe path/to/file.odin
```

`build.sh` ends by running `vega --install-desktop`, which writes a 256×256 PNG into
`~/.local/share/icons/hicolor` and a `vega.desktop` entry beside it, so Linux launchers
and docks show the same mark. `build.bat` regenerates `icons/vega.ico` from `icons/logo.png` when the logo is newer,
and passes it to the linker, so the executable carries the mark in Explorer and on the
taskbar. It notices when vega itself is running, which locks its own file, and builds
`vega.new.exe` instead of failing. Those scripts are what `ctrl-m`, `ctrl-r` and
`ctrl-shift-c` run from inside the editor, in their `.bat` or `.sh` form depending on the
platform vega was compiled for. Spawning a child process is the one piece that is written
twice: `process_windows.odin` uses `CreateProcessW` with `CREATE_NO_WINDOW` so nothing
flashes a console, `process_posix.odin` uses `core:os`'s `process_exec`.

One file, no dependencies. SDL3 is linked statically, text is rasterised with
stb_truetype rather than SDL_ttf, and Victor Mono Medium is compiled into the binary, so the
executable runs on its own; only the `themes` directory is read from disk, and its
absence just falls back to the built-in themes. It builds as a windowed program, so
double clicking it never leaves a console behind, and the child processes it runs (git,
the build scripts) are started hidden.

Launch it with no argument and it reopens the files, cursors and scroll of the last
session, VS Code style. Everything is autosaved: any setting, colour, binding or cursor
move marks the config and the session dirty and both files are written a tenth of a
second later, so there is nothing to save by hand and a crash costs one keystroke. The
files — `vega.conf`, `vega.log` and one session per workspace under `sessions` — live in
the folder SDL calls the preference path (`%APPDATA%\vega\vega` on Windows,
`~/.local/share/vega/vega` elsewhere), never in the project you are editing; `:log`
prints where. The working directory is the project root: it is walked and indexed at
startup, and every root keeps its own files, cursors and scroll. `space w` and `:ws` list
the workspaces you have chosen and switch to the one you pick — new root, new index, its
own session — and `:ws some/path` goes straight there. Nothing is ever added behind your
back from where the executable happens to sit: launched with no file, vega reopens the
workspace you used last wherever it sits, and with no workspace cached yet it asks
for one with the system folder dialog as it starts, and the folder you choose becomes the
first one, remembered from then on. `space W` asks for a folder whenever you want to add
one, and `space w` asks the same way when the list is still empty.
A file on the command line wins over both: vega stays where you launched it.

## Model

Selections come first, like Helix. Every cursor is a range with an anchor and an
inclusive head, motions extend or replace it, and commands act on all ranges at once.
Offsets are byte positions into one contiguous buffer, so search, syntax highlighting,
the diff against disk and the symbol index all read the same bytes. A buffer holds the
text, its content kind, its selections and its baseline; a view holds a buffer
reference, its animated scroll and its cursor.

## Panes, not layout modes

There is one layout: a split tree you build with keys. `ctrl-w` is the window prefix, as
in Helix: `ctrl-w v` splits into columns, `ctrl-w s` into rows, `ctrl-w q` closes the
pane, `ctrl-w o` keeps only this one, `ctrl-w h j k l` move the focus, `ctrl-w d` closes
the buffer, `ctrl-w =` and `ctrl-w -` resize. `ctrl-q` closes a pane directly, `ctrl-w w`
cycles them, and the same commands live under the space menu. A single pane
fills the window, so "full screen editing" is just the state you start in.

Centring is separate from splitting, because it is about reading shape rather than
arrangement: `ctrl-z`, `space l` or `:centered` holds the text in a **square** centred in
the pane, unless the pane is taller than it is wide, where centring would only waste the
screen and is skipped. The side is the smaller of the pane's width and its height times the square
ratio (1.2 by default, 1 to 2 in the View settings), snapped down to a whole number of
lines so the last row is never half drawn; the height is clamped to the pane so no line
ever hides behind a bar, and the leftover space is split evenly on both axes. Soft wrap, the visible row count and the cursor all read the same
rectangle, so the square really is the buffer, not a frame drawn around it.

## Keys

Every binding is a chord of an optional prefix plus a key, looked up in a table you can
rewrite at runtime. Space and `:` open a menu listing what is bound under them, and the
right of the top bar always spells out the keys for whatever you are doing.

Movement `h j k l`, `w W e E b B`, `f t F T` plus `.` to repeat, `gg` top, `ge` bottom,
`gh gl` line start and end, `mm` matching bracket, `x` select line,
`%` select all, counts with digits, `ctrl-d` / `ctrl-u` half page, `zz zt zb` to
reposition. The arrow keys do nothing by default, to keep you on the home row; the
setting is in View if you want them back.

Selections `v` select mode, `;` collapse, `,` keep primary, `space m` flip, `C` cursor
below, `space a` cursor above, `s` select every occurrence inside the selections, which
re-selects from your original ranges on every keystroke, so the matches light up as you
type and Escape puts the selection back exactly as it was.

Changes `i a I A o O`, `d c y p P R`, `r` replace characters, `~` switch case, `J` join,
`> <` indent, `u` undo, `U` redo. Brackets and quotes close themselves as you type.

`w`, `e` and `b` select the word they land on rather than dragging a selection behind
them, which is the one Helix habit vega does not keep: a motion leaves you holding a
word, ready for `d`, `c` or `space U`. Going backwards puts the cursor on the head of the
word, so `b` and `B` keep walking back rather than sitting on the same word.

Delete `Delete` removes the selection in normal mode and the character ahead in insert
mode, `ctrl-backspace` and `ctrl-delete` eat a word at a time in either. `space U` upper
cases the selection, `space u` lower cases it, `~` switches it, and `:cap` / `:uncap` do
the same from the command line. `ctrl-c` comments or uncomments the selected lines with
the language's own marker, deciding by whether every non-blank line is already commented.

With several selections in hand, `n` drops the first one and `N` the last, so a `s`
search can be peeled down to the occurrences you actually want; with a single selection
they are the usual next and previous match.

Copy and paste follows Helix's split between the editor's registers and the machine's
clipboard: `y` and `p` stay on the register, `space y` and `space p` are the same thing
from the menu, and `space Y` and `space P` go through the system clipboard, so `space Y`
puts every selection (joined by newlines) where the rest of the desktop can read it and
`space P` pastes whatever is there.

Jumping `g` followed by digits and Enter goes to that line, so `g120⏎` lands on line 120,
and the old `gs` first-non-blank motion is gone (`I` still inserts there).

Navigation `ctrl-o` steps back through the jump list and `ctrl-i`, or Tab, steps
forward, as in Helix; Shift-Tab is another way back. A jump is recorded when you leave a
place rather than when you move: goto definition, goto references, `gg` and `ge`, and
opening anything from a picker each push where you were, with the file and the offset, so
back comes home across files. `ctrl-i` in insert mode still leaves insert mode.

`ctrl-h` and `ctrl-l` step through buffers, `gb` and `gB` do the same from
the goto prefix, `gn` and `gp` jump to the next and previous definition in the file,
`ctrl-j` and `ctrl-k` (or `space n` and `space p`) jump between changes against git
HEAD, which the gutter marks as you edit.

A build that fails comes back into the buffer rather than into a wall of text. The
compiler output is parsed for `file(line:column) Error:` and for the `file:line:col:
error:` shape the C compilers use, and every problem it names is drawn on its own line:
a bar in the gutter, the line tinted, the offending column underlined, and the message
itself right aligned on that line, over the tail of the code so it stays readable. The
cursor lands on the first one immediately, `g N` and `g P` walk the rest, each one
opening the file it belongs to, and the next build clears them.

Running `ctrl-s` writes, `ctrl-m` builds, `ctrl-r` runs, `ctrl-shift-c` cleans, and
`:sh any command`, or `:! any command`, runs anything else. Which scripts those keys
reach is decided at compile time: `build.bat` / `run.bat` / `clean.bat` on Windows,
`./build.sh` / `./run.sh` / `./clean.sh` everywhere else, through `cmd.exe /c` or
`/bin/sh -c` respectively. They run hidden and report through a toast with the exit code
and the last line of output; the full output goes to the log rather than into a buffer.

`ctrl-z` is the centred square toggle and `ctrl-a` mutes or unmutes the key clicks.

Output from a script or from `:sh` no longer flies past in a toast: it opens a panel
under the cursor, over the buffer, the way Helix shows command output. The command runs
on its own thread, so the editor stays live while it works and the panel fills in when it
finishes. It does not take the keyboard hostage: every key still edits and moves as
usual, only `ctrl-d` and `ctrl-u` are borrowed to page through the output (the wheel
works too), and escape is what closes it, so it stays put while you keep working. Its
border is green or red depending on the exit code. Toasts themselves now wrap and keep their newlines, so a
message with three lines shows three lines.

Files and buffers `space f` lists every file in the project that git does not ignore,
not just the indexed sources, and previews the highlighted one live in the buffer behind
the picker. The panel sits in the bottom right with its search field along the bottom
edge and the matches listed above it top down, best first. Previewing never stacks buffers: one reusable read-only slot is reloaded as
you move, it stays out of the tab bar, the buffer list and the session, and Escape or
Enter releases it and puts back what you were reading. Typing puts the selection back on
the best match rather than leaving it where you had scrolled to.

Searching is meant to stay ahead of your fingers. The project listing is taken once at
startup and cached, labels are lowercased when the list is built rather than on every
keystroke, and a query that extends the previous one is filtered over the previous
matches instead of the whole list, which holds for the global search too since a longer
needle can only occur where the shorter one did. Files around the selection are read
ahead into a cache, a few per frame out to twelve items either side, so a cached file
previews the instant you land on it and holding Tab flips through files rather than
showing nothing; only an uncached one waits the 90 ms debounce, and a preview buffer
skips the git baseline entirely. Opening a file no longer waits on git either: the
baseline is fetched a frame later, off the interactive path.

Writing a scratch buffer, which has no path yet, opens the system save dialog, and the
name you give it becomes the buffer's path, language and syntax before the bytes are
written. `space e` opens the system file dialog, which shows every file rather than a
list of extensions and takes a multiple selection, and `space f` is the fuzzy file
picker, where a query with a slash is read as a folder, so `src/` lists what is inside
`src` and nothing else, the way Helix completes a path. `:n` makes a new scratch buffer.
`:bc` closes a buffer, the scratch one included, and
vega keeps an empty scratch around rather than exiting. `:wa` writes every modified
buffer, `:qa` and `:wqa` end the session, `:q` closes the pane and only quits on the last
one.

`--bench` prints the numbers on the current project and exits. On this one: file listing
107 ms cold and free warm, picker open 0.5 ms for 257 items, a keystroke 0.01 to 0.03 ms,
a preview load 0.5 ms and a reload 0.07 ms, a cached preview 0.1 to 0.3 ms, buffer open
0.15 ms with its 82 ms git baseline deferred, global search 2.1 ms cold and 0.03 ms once
narrowing.

Modes `ctrl-i` leaves insert mode like escape. The cursor is a block in normal, a bar in
insert and an underline in select, each configurable.

Space menu `space f` files, `space b` buffers, `space s` symbols, `space /` global
search, `space r` rename, `space k` hover, `space w` workspaces, `space c` settings, plus
the
pane and toggle keys above (`space z` soft wrap, `space i` whitespace).

A chord is resolved against the character your layout really produces, not just the
keycode SDL reports: on an AZERTY keyboard SDL calls the minus key `6`, so a chord that
misses is retried with the unmodified and shifted characters of its scancode, which is
what makes `ctrl--` zoom out there.

Zoom `ctrl-+` and `ctrl--` resize the font and rebuild the atlas, `ctrl-0` resets. On an
image buffer the same keys zoom the picture.

## Hover

`space k` opens a popup under the cursor with the doc comment above the definition, the
signature, where it lives, and how many times the name occurs in this buffer. Every
visible occurrence gets a translucent line drawn from the popup to it and a highlight on
the word itself, so you see at a glance where the symbol is used on screen. Any key
closes it.

## Content kinds

A byte order mark at the head of a file is dropped on open and not written back, so no
buffer starts with an invisible `﻿` before its first word.

A buffer knows what it holds. **Text** is syntax highlighted for Odin, C, GLSL and
shell, with optional soft wrap and whitespace marks. **Markdown** colours headings,
bullets, quotes, fenced code and rules while you still edit the raw source. **Images**
(png, jpg, bmp, tga, gif, psd) decode through stb_image and draw fitted and zoomable.
**PDF** files are inflated and their text streams extracted into a read-only buffer,
which is text extraction, not page rendering.

Soft wrap is a real editing mode, not just a display one: `j` and `k` step visual rows
inside a wrapped line and the cursor sits where the text does, so a long paragraph edits
the way it looks. A wrapped line keeps its own indentation on every row it spills onto,
marked with a faint `↪`, so an indented statement never slides back to the left margin —
the wrap arithmetic, the row count and the visual motions all read that same indent.

## The index instead of a language server

`index.odin` walks the project, tokenizes every `.odin`, C and GLSL file once, and keeps
two maps: name to definitions and name to every identifier occurrence. That is enough
for goto definition, references, hover and rename, and it costs a few milliseconds
instead of a JSON-RPC handshake.

Indexing never blocks the editor. Startup hands the root to a background build and
returns in three microseconds; the window is up and typable while the tree is read, and
the finished index is swapped in whole on a later frame, so nothing is ever half built
under a query. Until it lands, goto definition and references say so rather than lying.
A scripted run (`--keys`, `--screenshot`) waits for it, so tests stay deterministic.

The build itself is child stealing with no lock at all. One directory is one task on a
lock-free stack: a worker claims the top with a compare and swap, lists it, pushes every
subdirectory it finds back for any idle worker to claim, then reads, tokenizes and
collects that directory's own files into a private index of its own. Tasks are never
freed during a build, so the stack cannot see the same node twice and needs no tag
against ABA. The only other shared word is an atomic count of tasks in flight, which is
how a worker knows the difference between empty for now and done. Nothing else is
shared, the tree balances itself however lopsided it is, and twice as many workers as
cores keeps the disk queue deep.

Nothing is merged at the end either. Each task's private index becomes a shard of the
project index, carrying the offset its symbols and files were placed at, and a lookup
walks the shards and rebases what it finds. Files and symbols are still concatenated in
tree order, so the picker order and every number stay identical to the single threaded
build, and the merge that used to cost 100 ms costs about 5 ms.

Three more things keep it off the disk and off the heap. Every worker allocates from a
growing arena of its own, so a million small allocations never touch the process heap
lock, and the whole index is freed by dropping its arenas. Directories are enumerated
with `FindFirstFileExW` at the basic info level with a large fetch, which brings back
each entry's size and write time with no `stat` behind it, and files are read with
`FILE_FLAG_SEQUENTIAL_SCAN`.

Those write times feed a cache that holds the work, not just the bytes. Beside each
workspace session sits a blob, written to two slots in turn so the live one is never
overwritten under its own mapping, holding for every file its path, write time, text,
symbols, and every name in it with that name's definitions and occurrences, grouped and
sorted. The next build memory maps that blob and a file whose write time and size still
match is never read, never tokenized and never collected again: its symbols are pointed
straight at the mapping and its name table becomes a shard the lookups binary search in
place. The blob also carries every directory and its write time, so a directory that has
not changed is not even enumerated, only asked for its own timestamp. That last shortcut
cannot see a file edited in place by another program, so it is never the last word:
the fast index is published, a full scan runs behind it, and if a single path or write
time disagrees the corrected index is swapped in a few milliseconds later.

The tokenizer got the same treatment. Keyword and type lookups no longer walk the word
list: each set carries a 256 by 64 bit table of which first byte and length pairs exist
in it, so one shift and one and reject almost every identifier before a single string
compare, which alone doubled the tokenizer. Runs of identifier bytes, of blanks and the
hunt for the end of a line comment are scanned 32 bytes at a time with `#simd[32]u8`,
classifying a whole vector with comparisons and taking the first lane that breaks the
run out of the sign bit mask, worth another fifth. Newlines are counted the same way,
and global search now counts them forward from the previous hit instead of from the top
of the file for every one.

On the Odin core library, 981 files and 98170 symbols went from 640 ms to 8 ms, with the
verifying scan behind it at 14 ms and a cold build, cache and all, at about 180 ms. The
tokenizer itself runs at 250 MB/s against 123 before. On this project, 41 files, it is
3 ms. What the editor itself pays is 0.005 ms.

Odin definitions come from `name ::` at depth zero, classified by what follows, plus
`name :=` globals. C and GLSL contribute `#define`s, tagged structs, typedefs, function
definitions with a body, and file-scope declarations, which is what makes `gd` work on a
GLSL uniform. Rename rewrites every occurrence across the project on disk, then
reindexes and reloads open buffers, so comments and strings are never touched.

## Diff against git

`space R`, or `:reset-diff-change`, puts the hunk under the cursor back to what git HEAD
holds — the diff records both sides of every hunk, so a change can be undone line for
line without touching the rest of the buffer.

vega watches `.git/index` and `.git/HEAD` once a second and refetches every baseline when
either moves, so committing, switching branch or staging from another window updates the
gutter instead of leaving a stale state behind.

The baseline for a buffer is `git show HEAD:./name`, so the gutter marks what you have
changed since the last commit, not since you opened the file, and saving does not clear
it. Files outside a repository fall back to their contents on disk. The diff itself is a
patience diff: common prefix and suffix trimmed, then split on lines unique to both
sides. `ctrl-j` and `ctrl-k` walk the hunks. Undo is honest about it: restoring from the
history marks the hunks stale so the gutter is recomputed, and a buffer wound back to the
depth it was last saved at drops its modified mark rather than staying dirty forever.

## Themes

All 218 Helix theme files are compiled into the executable with `#load_directory`, so the
`themes` folder is optional: drop a `.toml` in it and that copy wins, delete the folder
and every theme still works. vega reads them
directly: the palette, the `inherits` chain and the scopes it needs, mapped onto its own
palette. A theme is parsed once and kept, so stepping through the picker repaints from
memory instead of re-reading TOML. It starts on `earl_grey`. `:theme` or the picker in the settings lists them and
previews each as you move; Escape restores, Enter keeps.

A theme is taken literally. Nothing falls back to vega's own colours: a root theme paints
every syntax slot with its `ui.text` first, and only what the file actually styles is
overridden, which is what Helix does, so a minimal theme like `earl_grey` — which styles
only `keyword`, `type` and the ui scopes — comes out with strings, numbers and functions
in plain silver rather than in colours it never asked for. A scope carrying only
`modifiers = ["dim"]`, as its comments do, is rendered as the text colour at sixty
percent. Only a theme that inherits keeps its parent's colours for what it leaves
unstyled.

## Settings

`space c` opens them. Six sections: Editor, View, Cursor, Audio, Appearance and Keys.
View carries the centred square and its ratio, soft wrap, whitespace, the diff gutter,
arrow keys, fullscreen, smooth scroll and line spacing. Editor carries the indent, the
gutter, the menu hints and auto pairs with a checkbox per pair — `( )`, `[ ]`, `{ }`,
quotes, single quotes, backticks. Audio carries the key
clicks, their volume, which keyboard they are sampled from and which modes click at all,
insert only by default. Cursor carries the animation, its
speed and the three cursor shapes. Appearance carries the font size, the theme preset
picker, bold, ligatures and true black, and **edit this theme** turns the same section
into the palette: every colour with its hex value and a swatch, Enter opening the colour
picker, and *done editing* at the top to come back.

Appearance shrinks the panel to six tenths of the window and render a sample
buffer beside it rather than your own file, a short Odin listing with keywords, types,
strings, escapes, numbers, comments and ligatures, so every colour of the theme has
something to land on. It is a hidden buffer: no tab, no buffer list entry, nothing in the
session, and it is destroyed when you leave those sections. Every change is
written to `vega.conf`, and the session alongside it, a tenth of a second after you make
it.

The font is Victor Mono Medium and Bold, compiled into the binary, so there is nothing to
pick and nothing to install; size is a setting, bold is not, because bold is reserved for
one thing: function names, in the buffer, so a call stands out without a colour of its
own. System faces fill in for codepoints Victor Mono lacks.

Ligatures are the font's own, not drawings of them. Victor Mono carries no `liga` table:
its ligatures live in `calt` as chained contextual substitutions, the trick Fira Code
uses, where each character of `->` is swapped for a piece of the arrow. So vega reads
GSUB out of the embedded file and runs that small part of a shaper itself — coverage
tables, chain rules and the single substitutions they nest, applied recursively — which
is why `:=`, `->`, `=>`, `<-`, `==`, `!=`, `<=`, `>=`, `<->`, `<=>`, `...`, `//` and the
rest come out exactly as the typeface designer drew them. Each substitution is one glyph
for one character, so the grid never moves. Runs of joining characters are shaped with
four characters of context either side and cached by their text, and a table of which
ASCII characters can join at all keeps the common case to an array lookup. True black
forces the background of a dark theme to pure black and dims the panels to match, for
OLED screens.

Enter on a colour opens the colour picker: a saturation and value square you drag, a hue
strip, and a hex field you type into. That popup is the only place vega uses the mouse.

## The keymap editor

Two views of the same table. The keyboard scheme draws your physical keyboard: each box
is a scancode, and its label comes from `GetKeyFromScancode` under the layout you are
actually typing on, so an AZERTY machine shows a z e r t y and the header names the
layout it detected. A command appears on the key that produces its character, which is
where your fingers will look for it.

Ten layers, cycled with page up and page down: plain, shift, ctrl, alt, ctrl shift, then
the prefix layers `g`, `m`, `z`, space and the `ctrl-w` window layer. Enter on a key
opens a searchable command list, Delete unbinds. The list underneath is the same
bindings as text, and Enter there captures the next chord you press, modifiers included,
so binding ctrl-alt-e is a matter of pressing it. A chord is a prefix, a key and a
modifier set, and only your changes are written to `vega.conf` as `bind` lines such as
`bind none e ctrl PrefixSpace`.

## Footprint

The settings are a `bit_set` of options rather than a wall of booleans, and buffers and
the editor carry their own small flag sets, so a config is four bytes of state instead
of twenty. Rendering is event driven: when nothing is animating, vega blocks in
`WaitEventTimeout` instead of spinning at the refresh rate, and wakes for input, for a
cursor or scroll still in flight or for a live toast. Switching a pane to another buffer
cancels the cursor and scroll animations rather than gliding across an unrelated file,
and the switch
is detected on the buffer itself rather than its slot, so reloading the preview slot onto
another file counts as a switch too. A buffer keeps its own scroll line next to its
selections, so leaving a file and coming back puts you where you were, and the session
stores it. The frame clock is reset when that wait returns, so time spent idle is
not charged to the animation and a keypress after a pause still glides instead of
snapping.

## Key sounds

The `sfx` folder is compiled in the same way as the themes: sixteen samples from two
keyboards (`akko_lavender` and `nk_creams`) become one SDL audio device with a pool of
eight streams. Every keystroke picks a random sample of the chosen family and a random
frequency ratio between 0.88 and 1.12, so no two presses sound alike and a fast burst
overlaps instead of queueing. Clicks are tied to the mode: insert only out of the box,
with a checkbox for normal and select. `ctrl-a` or `:audio` mutes the lot, and the Audio
settings carry the volume and the keyboard.

## Logging and toasts

Every run truncates `vega.log` and writes to it through `core:log`: startup and indexing,
each command with its count and mode, every setting change, picker activity, splits,
theme and font changes, shell runs, hunk counts, writes and failures. The same logger
raises a toast in the bottom right for anything at warning level or above, and for the
few messages worth confirming: a write, a rename, a clipboard copy, a reason something
did not happen. State you can already see on screen — a toggle, a selection count, a
jump, the startup index — only goes to the log. `:log` prints the path.

## Testing hooks

`--index [dir]` prints the symbol table and exits. `--keys "<sequence>"` feeds one key
per frame (`\e` escape, `\n` return, `\t` tab, `\b` backspace, `\d \u \r \L` arrows, `\f`
F11, `\X` delete, `\B` ctrl-backspace, `\Y` ctrl-delete), `--delay N` waits N frames
after the last key, `--size WxH` unmaximizes the window
to that size, which is how the status bar is checked at narrow widths, `--bench [dir]`
times indexing,
listing, filtering, previewing and searching, and `--screenshot out.bmp` captures
that frame and exits. A short delay catches the cursor glide mid-flight, a long one
catches the settled view.

## Unicode

Text is UTF-8 throughout. The glyph atlas caches codepoints on demand rather than a
fixed ASCII block: a glyph missing from the atlas is rasterised, packed and uploaded to
the texture region it occupies, so the first frame that shows a character pays for it
and no other does. Segoe UI Symbol, Malgun Gothic and MS Gothic are attached as fallback
faces, which covers Greek, Cyrillic, CJK, box drawing, arrows and most maths; anything
none of them has draws as a faint box. CJK and other wide codepoints take two cells, and
a fallback glyph wider than its cells is scaled down so the grid never breaks.

Editing is rune-wise: motions step whole codepoints, backspace removes one, and a
selection covers a codepoint rather than a byte, while offsets stay byte positions
underneath.

## Known limits

Panes of the same buffer share its selections, combining marks and emoji sequences are
drawn as separate codepoints, PDF is text extraction rather than page rendering, and
undo keeps whole-buffer snapshots, though a step that changed nothing is dropped rather
than left on the stack.

The `themes` directory is copied from the Helix distribution and carries its licence.
