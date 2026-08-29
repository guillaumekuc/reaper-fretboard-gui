# ReaScript architecture (`FretboardController.lua`)

This branch (`reascript-step-input`) reworks the plugin from a **JSFX effect**
into a **ReaScript** so it can insert notes directly into the take open in the
MIDI editor — the one thing the JSFX version structurally could not do
(FX-chain MIDI output is not a step-input source).

Read this before the code. The JSFX version and its `ARCHITECTURE.md` still
live on `master` for comparison.

---

## 1. Why the rewrite (and why it's cheap)

The JSFX ran in a track's FX chain: great for live MIDI thru, useless for
writing into an editor take. A ReaScript runs as an **action**, outside the
signal chain, and can call `reaper.MIDI_InsertNote` on any take.

The port is far less work than it sounds because **ReaScript's `gfx.*`
graphics API is the same immediate-mode API as JSFX's `@gfx`**. The drawing
code, the `ui_btn`/`stepper` widgets, the mouse-edge handling, the
drag-to-retune — all translate almost line-for-line. What changed is the
*shell* around them: a `defer` loop instead of `@gfx`, `reaper.*` calls
instead of `midisend`, `ExtState` instead of hidden sliders.

| Concern            | JSFX                         | ReaScript                          |
|--------------------|------------------------------|------------------------------------|
| Runs as            | FX in a track chain          | Action (toolbar / shortcut)        |
| Frame loop         | `@gfx` (host-driven)         | `reaper.defer(loop)` (~30 fps)      |
| MIDI out           | `midisend` (live thru)       | `MIDI_InsertNote` into editor take  |
| Preview sound      | pass-through                 | `StuffMIDIMessage` to VKB           |
| Visualise          | count live note-ons          | take notes at cursor + `MIDI_GetRecentInputEvent` |
| Note entry         | click only                   | Guitar-Pro-style: pick string, type fret |
| Step length        | n/a                          | the MIDI editor's own (`MIDI_GetGrid`); `[ ]` nudge its grid |
| State persistence  | hidden slider values         | `reaper.SetExtState(..., persist)`  |
| Threading          | `@gfx`/`@block` split        | single-threaded                     |

Single-threaded is a real simplification: **the `pend` ring buffer is gone**.
No lock-free queue, no cross-thread reasoning — `loop()` does input, MIDI, and
drawing in sequence every frame.

---

## 2. The `defer` loop

```
gfx.init(...) ; loop()

function loop()
  c = gfx.getchar()          -- -1 when the window is closed, 27 = Esc
  if c < 0 or c == 27 then return end   -- returning (not deferring) ends the script

  update_mouse()             -- edge detection: mouse.down / .up / .held
  consumed = false           -- click-routing flag for this frame
  handle_keys(c)             -- digits=frets, arrows=string/step, R/T/L, [ ]=grid, ctrl+Z/Y
  poll_live_input()          -- fold hardware MIDI into live_notes

  take = get_take()          -- the MIDI editor's active take, or nil
  -- on a new take: SetOnlyTrackSelected(its track) so VKB previews route there
  sync_cursor_from_edit(take) -- follow the user moving the edit cursor

  scan_context(take)         -- every 6th frame (or every frame while playing)
  layout() ; draw_board() ; draw_panel()/draw_header() ; draw_toggle()
  handle_string_drag()       -- retune by dragging open-note labels
  handle_board_click()       -- the main event: preview + insert

  gfx.update() ; reaper.defer(loop)
end
```

`reaper.atexit(on_exit)` saves state and the window rect, and sends any
held preview note-off, when the script stops for any reason.

---

## 3. Data model (unchanged from JSFX in spirit)

`S` is the single state table. Strings are **1-indexed** here (Lua), `S.str_note[1]`
is the lowest string; `pitch_at(s, f) = S.str_note[s] + f`.

- `TUNINGS` – list of `{name, rule}`. `rule` is `nil` (Custom), `"std"`
  (Standard: forces 6 strings, EADGBE), or a semitone interval (rule presets).
- `apply_preset(idx)` fills `S.str_note` from `TUNINGS[idx+1]`. Rule presets
  build from `S.str_note[1]` as the root; the **ROOT** buttons (E2 = 40,
  C2 = 36) and dragging string 1 both just set that and re-apply.
- `S` is loaded from / saved to `ExtState` section `GK_FretboardController`
  (a fixed key list; `str_note` comma-joined). `save_state` keeps integers
  integer and rounds fractions to 6 dp. `active_string` is *not* persisted.

---

## 4. The step cursor (the core of step-entry)

`cursor_qn` — our insertion point, in **project quarter-notes**. It is:

- **initialised** from the edit cursor (`GetCursorPosition` → `timeToQN`),
  snapped to the step length.
- **advanced** by `step_len_qn(take)` after each inserted note — unless Shift
  is held (chord entry: insert here, don't move).
- **nudged** by `step_cursor(±1)` on the **Left / Right arrow keys** — move
  one step with no note (Right = leave a rest, Left = back up). These keys
  exist because clicking the fretboard window pulls focus off the MIDI
  editor, so its own arrow-key cursor moves stop reaching it. Backspace
  (remove last note + step back) is separate.
- **re-synced** to the edit cursor whenever the user moves it: each frame,
  `sync_cursor_from_edit` compares `GetCursorPosition()` to
  `last_cursor_time` (the value the script itself last wrote) and, if they
  differ, adopts the user's position. So: click in the MIDI editor to
  reposition, then keep entering from there.

### Step length — one source of truth

`step_len_qn(take)` = **REAPER's own value, always**: `MIDI_GetGrid`'s note
length if set, otherwise its grid — exactly what keyboard step recording uses.
There is no local step state.

`[` / `]` (also `-` / `=`) call **`nudge_grid(0.5 / 2)`** →
`SetMIDIEditorGrid(0, grid × mult)`, clamped to `[1/64, 4]` QN. That changes
the MIDI editor grid itself, so the readout in the editor and keyboard step
input move in lockstep. Dotted / triplet: use the MIDI editor's own grid
dropdown (the script doesn't reimplement it). If the user has pinned a fixed
note length, `[` / `]` still nudge the grid (harmless) but the step follows the
pinned length — the panel's `STEP 1/n (note len | grid)` label says which.

### insert / delete / tie / rest

`insert_note(pitch, advance, string_idx)`:
1. start / end PPQ from `cursor_qn` and `cursor_qn + step`,
2. `MIDI_InsertNote(…, chan = S.chan-1, pitch, S.vel)` (+ `MIDI_Sort`), in an
   `Undo_BeginBlock`/`EndBlock` pair unless `undo_suppress` is set,
3. push `{take, sppq, pitch, chan, prev}` onto `history`,
4. if `S.let_ring`, stretch the end and trim the previous note on that string
   (§5),
5. if `advance`, `set_cursor(cursor_qn + step)`.

- `delete_last()` (Backspace) — pop `history`, `find_note` by
  `(pitch, chan, sppq≈)`, delete, restore `cursor_qn` to `prev`.
- `step_cursor(±1)` (arrows, and `R` for +1) — move a step, insert nothing.
- `tie_extend()` (`T`) — `find_note` the last note, `MIDI_SetNote` its end to
  `end + step`, advance the cursor. Repeatable.

### Typed fret entry (`type_fret`)

`0`–`9` insert `pitch_at(S.active_string, digit)` and advance; **↑/↓** pick
`S.active_string` (also set by a board click). Two-digit frets: if a digit
arrives within 0.8 s of the previous one and `prev*10 + d ≤ num_frets`, it
**amends** — `delete_last()` then re-inserts at the combined fret, the pair
wrapped in one undo block via `undo_suppress`. Otherwise the new digit starts
a fresh note. `digit_pending` is cleared by any non-digit key, a board click,
or the timeout.

---

## 5. Preview & visualisation

- **Preview**: on board press, `StuffMIDIMessage(0, 0x90|chan, pitch, vel)`
  (mode 0 = virtual-keyboard queue). It plays through whatever track the VKB
  targets, so when the editor's take changes the script does
  `SetOnlyTrackSelected` on that take's track. You still need the track
  **armed + input-monitoring** to hear it — same as keyboard step input — and
  the status line says so when it isn't. Note-off on release and whenever the
  mouse isn't held. Preview works with no MIDI editor open.
- **Visualisation** — the board lights, brightest first:
  1. **mouse preview** pitch → white.
  2. **live hardware MIDI** (`live_notes`) → bright. `poll_live_input()` reads
     `MIDI_GetRecentInputEvent` (REAPER 7+): each frame it walks events newer
     than `last_input_seq`, applying note-on/off to `live_notes`. This restores
     the JSFX version's "see what you play" — from any input device, no
     routing needed. (Piano-roll *mouse* preview isn't hardware input, so it
     doesn't show.)
  3. **playback** notes straddling the play cursor → bright.
  4. **take notes in the current step slot** (`scan_context`) → dim. This
     replaced v0.4's "every note in the take as a grey dot", which read as
     noise / fake inlays. Now the board only shows what's *at the cursor*, so
     arrowing through the take reveals each chord.
  `scan_context` is throttled to every 6th frame unless playing.

### Let ring (`L`)

MIDI has no "let ring", so it's modelled as **per-string voices**, like a real
guitar's 6 strings: `ring_prev[string]` holds the last note entered on each
string while let-ring is on. On the next insert on that string, the previous
note's end is pushed back (`MIDI_SetNote`) to the new note's start, and the
new note is given a long tail (`min(max(step×6, 2), 4)` QN, ~ up to a bar).
Notes on *different* strings overlap and ring together; a note on the *same*
string cuts its predecessor. Turning let-ring off just stops the trimming;
existing tails stay. `ring_prev` is cleared on every toggle.

---

## 6. Coordinate system & widgets

Identical approach to the JSFX version: `layout()` recomputes `L/R/T/B`,
`fret_sp`, `str_sp`, `nr`, `ir` each frame; `header_h` is `PANEL_H` (open) or
`26` (collapsed) and `T = header_h + 24` keeps the fret-number row clear.
`str_y` / `fret_x` / `note_x` are the same helpers.

Widgets are immediate-mode Lua functions — no `#lbl` global hack needed, they
take the label as a normal argument:

- `btn(x,y,w,h,label,active)` → true on the click edge; sets `consumed`.
- `stepper(x,y,caplen,label,val,lo,hi)` → new value.
- `caption(x,y,label)`.

`consumed` routes a single click to exactly one target (panel button →
string-label drag → fretboard).

**Left gutter** (`L = 54`): open-note name at `x = 5`; the active string gets a
full-width highlight band (drawn behind everything), a 2px line, and a filled
chip behind its name — no gutter glyph, so nothing overlaps the labels.
`note_x(0)` (open markers) sits at `L - 20`.

**Capsule bar** (`inlay == 2`): the rectangle joining the two dots is
integer-aligned — `cx = floor(note_x(f)+0.5)`, `rr = floor(ir+1)`, width
`2·rr + 1` — so its edges line up with the circles' edges (a half-pixel
mismatch used to shift the right edge inward).

---

## 7. Known limitations & gotchas

- **Focus steals editor keys** – clicking the fretboard window takes key
  focus, so the MIDI editor's own arrow / Backspace / letter shortcuts stop
  working while you're on the fretboard. `handle_keys` re-implements the ones
  that matter (digits, arrows, `R T L [ ] - =`, Backspace, Ctrl+Z/Y, Space)
  against that take. Arrow keycodes are the ASCII-of-the-name magic constants
  in `K` (`LEFT = 1818584692` = `"left"`, `UP = 30064` = `"up"`, …), not
  plain codes.
- **Keyboard layout** – digit and symbol keys come through as whatever
  character the OS produces. On layouts where the number row is shifted
  (AZERTY etc.) you hold Shift to type fret digits, and `[ ] - =` may be
  elsewhere or need AltGr. A numpad (NumLock on) always yields `0`–`9`.
- **Preview needs a monitored track** – `StuffMIDIMessage` mode 0 → the
  script `SetOnlyTrackSelected`s the take's track so the VKB routes there, but
  you hear nothing unless that track is armed + input-monitoring (same as
  REAPER's keyboard step input). The status line flags this. Selecting the
  track is a side effect worth knowing about.
- **`MIDI_GetRecentInputEvent` is REAPER 7+** – guarded by `HAS_INPUT_POLL`;
  older builds silently skip the live-input highlight. Hardware input only,
  not the piano roll's own mouse-preview.
- **`&` precedence in Lua** – `a & b == c` parses as `a & (b == c)`. Bit
  tests are parenthesised: `(GetPlayState() & 1) == 1`.
- **Lua 5.4** (REAPER 7) – `//`, `&`, integer/float. `ExtState` save keeps
  integers integer and rounds fractions (`step_base`) to 6 dp.
- **Two-digit fret amend = 2 undo points** – the first digit's insert is its
  own undo block; the amend (`delete` + re-`insert`) is a second. Ctrl+Z peels
  them one at a time.
- **`SetMIDIEditorGrid` only moves the grid** – there's no ReaScript setter
  for the MIDI editor's *note-length* dropdown, so `[` / `]` change the grid.
  With note length on "Grid" (the default) that's the whole step; with a pinned
  length it isn't, and the `STEP` label flags which.
- **`let ring` heuristic** – the ring tail length (`min(max(step×6,2),4)` QN)
  is a guess; a note that's never replayed on its string just rings that long.
- **`history` / `ring_prev` hold take refs** – `ValidatePtr2`-checked before
  use; a closed item orphans old entries (they no-op). A global Ctrl+Z can
  also desync `history` from the take — Backspace then finds nothing and
  harmlessly pops.
- **No polyphonic mouse** – one pointer. Chord entry is Shift+click.
- **Runtime status** – loads and passes a stubbed-API frame harness (`gfx` /
  `reaper` mocked; simulated clicks, key sequences incl. typed frets, the
  2-digit amend, tie, let-ring trim, `[`/`]` → `SetMIDIEditorGrid`, undo
  forwarding, rest). Not yet run inside REAPER.

---

## 8. Where to extend

| Want to… | Touch |
|----------|-------|
| Add a tuning preset | `TUNINGS` (rule presets are automatic) |
| Transpose the last note | `Shift`+↑/↓ in `handle_keys` → `find_note` + `MIDI_SetNote` pitch ±1 / ±12 |
| Palm-mute / dead-note modes | a flag that shortens `eppq` + drops `S.vel` in `insert_note` |
| Real chord entry from the keyboard | a modifier that makes digits not advance; `handle_board_click` already does it for Shift+click |
| Use the editor's active channel instead of `S.chan` | `MIDIEditor_GetSetting_int(hwnd, "default_note_chan")` in `insert_note` |
| Honour editor grid swing | `MIDI_GetGrid` returns swing; fold into `step_len_qn` |
| Toolbar toggle state (highlight while open) | `SetToggleCommandState` / `RefreshToolbar` around `loop`/`on_exit` |
| Also show live input from a specific track's record input | there's no direct API; `MIDI_GetRecentInputEvent` is all-devices |
