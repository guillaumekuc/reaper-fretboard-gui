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
| Visualise          | count live note-ons          | read notes from the take            |
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
  handle_keys(c)             -- backspace = undo last, space = transport

  take = get_take()          -- the MIDI editor's active take, or nil
  sync_cursor_from_edit(take) -- follow the user moving the edit cursor

  scan_take()                -- every 8th frame (or every frame while playing)
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
  (`str_note` is stored comma-joined). Numbers are floored on save so the
  steppers never show `6.0`.

---

## 4. The step cursor (the core of step-entry)

`cursor_qn` — our insertion point, in **project quarter-notes**. It is:

- **initialised** from the edit cursor (`GetCursorPosition` → `timeToQN`),
  snapped to the editor grid when STEP = "Grid".
- **advanced** by `step_len_qn(take)` after each inserted note (unless
  auto-advance is off, or Shift is held → chord entry).
- **re-synced** to the edit cursor whenever the user moves it: each frame,
  `sync_cursor_from_edit` compares `GetCursorPosition()` to
  `last_cursor_time` (the value the script itself last wrote) and, if they
  differ, adopts the user's position. So: click in the MIDI editor to
  reposition, then keep entering from there.

`step_len_qn` returns the fixed value for STEP = 1/4…1/32, or the editor's
own grid / note-length (`MIDI_GetGrid`) for STEP = "Grid".

`insert_note(pitch, advance)`:
1. `MIDI_GetPPQPosFromProjQN` for start and start+step,
2. `MIDI_InsertNote(take, sel=false, mut=false, …, chan = S.chan-1, pitch, S.vel)`,
   wrapped in `Undo_BeginBlock`/`EndBlock` so Ctrl+Z removes one note,
3. push `{take, sppq, pitch, chan, prev}` onto `history`,
4. if advancing, bump `cursor_qn` and `SetEditCurPos`.

`delete_last()` (Backspace) pops `history`, finds the matching note in the
take by `(pitch, chan, sppq≈)`, deletes it, and restores `cursor_qn` to the
entry's `prev`.

---

## 5. Preview & visualisation

- **Preview**: on board press, `StuffMIDIMessage(0, 0x90|chan, pitch, vel)`
  (mode 0 = virtual-keyboard queue → plays through the record-armed track).
  Note-off on release, and unconditionally whenever the mouse isn't held.
  Preview is independent of insertion — with no MIDI editor open, clicks
  still preview.
- **Visualisation**: `scan_take()` walks the take's notes (`MIDI_CountEvts` /
  `MIDI_GetNote`) into two sets — `present` (dim dot) and, during playback,
  `playing` (bright dot, notes straddling the play cursor). The mouse-preview
  pitch draws brightest (white). Throttled to every 8th frame unless playing.

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

---

## 7. Known limitations & gotchas

- **`&` precedence in Lua** – `a & b == c` parses as `a & (b == c)`. All
  bit tests are parenthesised: `(GetPlayState() & 1) == 1`. Watch this when
  editing.
- **Lua 5.4** (REAPER 7) – `//`, `&`, `~`, integer/float distinction. The
  code floors on `ExtState` save so no `%d`-format surprises.
- **Preview routing** – `StuffMIDIMessage` mode 0 goes to whatever the
  virtual keyboard targets (usually the last-touched / armed track), not
  necessarily the MIDI editor's track. Good enough for feedback; not a
  guarantee.
- **Editor refresh** – after `MIDI_InsertNote` + `MIDI_Sort` the editor
  redraws on its own next paint. If a note ever seems to lag a frame, add an
  explicit `MIDIEditor_OnCommand` refresh.
- **One undo point per note** – deliberate (Ctrl+Z peels notes one at a
  time), but it fills the undo history fast during long entry.
- **`history` holds take references** – validated with `ValidatePtr2` before
  use, but closing the item mid-session orphans older entries (they no-op).
- **No polyphonic mouse** – still one pointer. Chord entry is
  Shift+click (insert without advancing), not simultaneous notes.
- **Runtime status** – loads and passes a stubbed-API frame harness
  (`gfx`/`reaper` mocked, simulated clicks/keys). Not yet run inside REAPER.

---

## 8. Where to extend

| Want to… | Touch |
|----------|-------|
| Add a tuning preset | `TUNINGS` + (rule presets are automatic) |
| Add a step length | `STEP_LABELS` + `STEP_QN` (parallel arrays) |
| Insert chords from one click | collect pitches, insert all at `cursor_qn`, advance once |
| Read the editor's active channel / note length | `MIDIEditor_GetSetting_int(hwnd, ...)` in `insert_note` |
| Show the step cursor on the board | it's a time position, not a fret — draw a marker column, or a bar:beat readout (already in the status line) |
| Honour editor grid triplet/swing | `MIDI_GetGrid` returns swing; fold into `step_len_qn` |
| Toolbar toggle state (highlight while open) | add the `SetToggleCommandState` / `RefreshToolbar` pair around `loop`/`on_exit` |
