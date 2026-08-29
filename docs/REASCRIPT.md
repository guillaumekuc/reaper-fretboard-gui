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
  handle_keys(c)             -- digits, arrows(+ctrl=bar), Q chord, R/T/L, [ ]=note (alt=grid)
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
- **advanced** by `step_len_qn(take)` (the note length) after each inserted
  note — unless Shift is held or **chord mode** is on (stack, don't move).
- **nudged** by `step_cursor(±1, by)` — `by = "grid"` (default) on **← / →**,
  `by = "note"` on **R** (a rest of the current note length). And
  `step_bar(±1)` on **Ctrl+← / →** (to the previous / next barline; first
  Ctrl+← from mid-bar snaps to this bar's start). These exist because the
  window takes focus off the MIDI editor. Backspace (remove last note + step
  back) is separate. Ctrl/Alt come from `mouse.cap & 4 / & 16` (they track
  modifier keys even with no mouse button down).
- **re-synced** to the edit cursor whenever the user moves it: each frame,
  `sync_cursor_from_edit` compares `GetCursorPosition()` to
  `last_cursor_time` (the value the script itself last wrote) and, if they
  differ, adopts the user's position. So: click in the MIDI editor to
  reposition, then keep entering from there.

### Grid vs note length — REAPER owns both

Two independent lengths, both read live from REAPER, **never a local var**
(Dorico's model):

- **`grid_qn(take)`** = `MIDI_GetGrid`'s grid. Drives caret movement (←/→),
  and `sync_cursor_from_edit`'s snap.
- **`step_len_qn(take)`** = `MIDI_GetGrid`'s note-length, or the grid when
  that's "follow grid". Drives the length of inserted notes and how far an
  inserted note advances the caret (and `R`, `T`).

They're changed **in place** in REAPER:

| keys | function | REAPER call |
|---|---|---|
| `[` `]` (also `-` `=` `{` `}`) or **Ctrl+↑/↓** | `set_note_len(take, hwnd, ×2/0.5)` | `MIDIEditor_SetSetting_int(hwnd, "default_note_len", qn·tpqn)` |
| `Alt+[` `Alt+]` or **Alt+↑/↓** | `set_grid(take, ×0.5/2)` | `SetMIDIEditorGrid(0, qn)` |

The **arrow variants** exist because `[`/`]` don't survive every keyboard
layout (on AZERTY `[` is `AltGr`+key, which also sets the Alt bit → it'd hit
the grid branch). Ctrl/Alt+↑↓ deliver the arrow keycode plus a clean modifier
every time. `Ctrl`/`Alt` are read from `mouse.cap & 4 / & 16`.

`tpqn_of(take)` derives ticks-per-quarter from the take, usually 960. Both
clamp to `[1/64, 4]` QN. Dotted / triplet aren't reimplemented — use the MIDI
editor's grid menu; the status line shows `note 1/n  grid 1/n`.

The `default_note_len` write is a best guess at the encoding (ticks, positive
value = "don't follow grid"); if the note length doesn't move in REAPER,
that's the suspect. `SetMIDIEditorGrid` is solid. There's a **keycode
diagnostic** in the panel (`key: <n> <mods>`, top-right, 3 s) to check what a
key actually delivers.

### insert / delete / tie / rest

`insert_note(pitch, advance, string_idx)`:
1. start / end PPQ from `cursor_qn` and `cursor_qn + step`,
2. inside `Undo_BeginBlock` … `Undo_EndBlock("…", -1)` (skipped when
   `undo_suppress` is set): the let-ring trim, `MIDI_InsertNote`, `MIDI_Sort`,
   then **`mark_dirty(take)`** (`MarkTrackItemsDirty`) + `UpdateArrange()`.
   The `mark_dirty` call is load-bearing — without it `MIDI_InsertNote` in a
   deferred script makes **no undo point**, so one Ctrl+Z discards every note
   entered since the script started. `delete_last`, `tie_extend` and the
   two-digit amend do the same.
3. push `{take, sppq, pitch, chan, prev}` onto `history`,
4. if `S.let_ring`, stretch the end and trim the previous note on that string
   (§5),
5. if `advance`, `set_cursor(cursor_qn + step)`.

- `delete_last()` (Backspace) — pop `history`, `find_note` by
  `(pitch, chan, sppq≈)`, delete, restore `cursor_qn` to `prev`.
- `step_cursor(±1)` (←/→, `R` = +1) / `step_bar(±1)` (Ctrl+←/→) — move without
  inserting.
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

### Chord mode (`Q`)

Dorico-style. `chord_mode` (a plain local, not persisted) makes every insert —
typed or clicked — pass `advance = false`, so pitches stack at `cursor_qn`.
`Q` toggles it; toggling **off** while `chord_dirty` (a note was added) does one
`step_cursor(1)` so you land past the chord ready to continue. `→` still works
mid-chord to move between chord positions without leaving the mode. Preview in
chord mode is polyphonic (`preview_notes` is a set) and rings until you leave
the position (`step_cursor` / `step_bar` / `Q` / any non-note key call
`preview_off`); outside chord mode a preview self-clears 0.3 s after the last
note or mouse-release.

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
  4. **take notes in the context window** (`scan_context`) → dim grey. The
     window is `context_window(take)`: `S.ctx_mode` 0 = the current **beat**
     (`floor(beats)`…`+1` via `TimeMap2_timeToBeats`/`beatsToTime`), 1 = the
     whole **bar** (`meas`…`meas+1`). A note counts if it overlaps
     `[lo_ppq, hi_ppq)`. The `Grey: Beat / Bar` panel buttons set it. (v0.4
     drew *every* note in the take — that read as noise / fake inlays.)
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
  that matter (digits, arrows, Ctrl+arrows, `Q R T L [ ] - =`, Backspace,
  Ctrl+Z/Y, Space) against that take. Arrow keycodes are the ASCII-of-the-name
  magic constants in `K` (`LEFT = 1818584692` = `"left"`, `UP = 30064` =
  `"up"`, …), not plain codes. Ctrl for the Ctrl+arrow bar jumps comes from
  `mouse.cap & 4`, since `gfx.getchar` gives the same code for `←` and
  `Ctrl+←`.
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
- **`default_note_len` encoding is a guess** – `set_note_len` writes
  `MIDIEditor_SetSetting_int(hwnd, "default_note_len", qn·tpqn)` on the belief
  that the value is in ticks and any positive value un-follows the grid. If
  the note length doesn't move in REAPER, verify that (the panel keycode
  diagnostic first confirms the key even arrives). `SetMIDIEditorGrid` is
  reliable.
- **Undo needs `MarkTrackItemsDirty`** – see §4. A deferred script's
  `MIDI_InsertNote`/`DeleteNote`/`SetNote` inside `Undo_BeginBlock`/`EndBlock`
  still records nothing without `mark_dirty(take)` before `Undo_EndBlock`.
- **`history` desyncs on a manual undo** – a global Ctrl+Z can remove notes
  the `history` stack still lists; `delete_last`'s `find_note` then finds
  nothing and just pops (harmless).
- **`let ring` heuristic** – the ring tail length (`min(max(step×6,2),4)` QN)
  is a guess; a note that's never replayed on its string just rings that long.
- **`history` / `ring_prev` hold take refs** – `ValidatePtr2`-checked before
  use; a closed item orphans old entries (they no-op). A global Ctrl+Z can
  also desync `history` from the take — Backspace then finds nothing and
  harmlessly pops.
- **No polyphonic mouse** – one pointer. Chord entry is Shift+click.
- **`step_bar` measure indexing** – assumes `TimeMap2_timeToBeats`' measures
  out and `TimeMap2_beatsToTime`' `measuresIn` use the same base. If bar jumps
  land one bar off, that's the mismatch.
- **Keyboard layout** – on Windows `Alt+[` still yields `[`; on macOS `Opt+[`
  yields a different glyph, so the grid shortcut needs remapping there.
- **Runtime status** – loads and passes a stubbed-API frame harness (`gfx` /
  `reaper` mocked; simulated clicks + key sequences: typed frets & 2-digit
  amend, tie, let-ring trim, `[`/`]`→note-length + `Alt+[`/`]`→grid
  decoupled, `R` = note-length step vs arrows = grid step, Beat/Bar grey
  window, undo forwarding, `Q` chord stacking + commit, Ctrl+arrow bar jumps).
  Not yet run inside REAPER.

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
