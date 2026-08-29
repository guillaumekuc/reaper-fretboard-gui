# Architecture & orientation

Read this before diving into `Fretboard.jsfx`. It explains the platform, the
execution model the code is bound to, the data flows, and the names worth
holding in your head.

---

## 1. What this is

A single-file **JSFX** plugin for REAPER. It renders a guitar fretboard in the
FX window and does two jobs:

- **Visualise** – MIDI arriving at the plugin lights up every fretboard
  position whose pitch matches a currently-held note.
- **Input** – clicking a position on the board emits a MIDI note-on; releasing
  the mouse emits the matching note-off.

Everything else (tuning, string/fret counts, inlay style) is configuration
layered on top of those two flows, and **all of it is edited inside the
`@gfx` canvas** – there is no native REAPER slider UI (see §3 and §4.6).

---

## 2. Why JSFX

The requirement is "a plugin for REAPER that has a GUI and passes MIDI both
ways". The realistic options are a native VST/CLAP, a ReaScript with a
ReaImGui window, or a JSFX effect.

JSFX wins here because it is the only one that is *all* of: in the signal
chain (so MIDI in/out is native and sample-accurate), GUI-capable with mouse
input, single self-contained text file, no build step, no external
dependency. The cost is the language (EEL2 – see §3) and a deliberately small
API.

If the project ever needs polyphonic mouse input, resizable high-DPI vector
UI, or preset management beyond slider values, that is the point to
reconsider a native plugin. Nothing in the current design leaks REAPER
specifics outside this one file, so a port would be a rewrite of the render
and I/O layers, not the model.

---

## 3. The JSFX execution model (the part that constrains everything)

A JSFX file is divided into **named sections**. REAPER calls them on
different schedules and, critically, **on different threads**:

| Section   | Runs when                                  | Thread        | Used here for |
|-----------|--------------------------------------------|---------------|---------------|
| `@init`   | on load, and on samplerate/config change   | –             | allocate buffers, define **all** functions, define the widget helpers |
| `@slider` | once after `@init`, then on any param change (automation, preset recall) | audio/UI | clamp values, `read_sliders()`, re-apply a recalled preset |
| `@block`  | once per audio block (~every few ms)       | **audio**     | read incoming MIDI, flush queued outgoing MIDI |
| `@gfx`    | once per UI frame (~30 fps), only when the FX window is open | **UI** | draw the board, read the mouse, queue outgoing MIDI |
| `@sample` | per sample – **not used**                  | audio         | – |

Consequences you must respect when editing:

- **`@gfx` and `@block` run on different threads.** They communicate through
  the `pend` ring buffer (§5). `@gfx` only ever *writes* the write index,
  `@block` only ever *reads* and advances the read index. There is no lock;
  this is a standard lock-free single-producer/single-consumer queue and it
  relies on word-sized reads/writes being atomic. Don't add a second producer
  or consumer without rethinking this.
- **MIDI can only be sent from `@block` (or `@sample`).** `@gfx` cannot call
  `midisend` meaningfully. That is the entire reason the queue exists.
- **The language is EEL2.** Everything is a double. `x[y]` means
  `memory[x + y]` – arrays are just base offsets into one flat instance
  memory space. `#name` is a string variable. Functions are declared with
  `function f(args) local(...)  ( ... )` and the last expression is the
  return value. `a ? ( ... ) : b ? ( ... ) : ( ... )` is the normal control
  structure. `loop(n, ...)` and `while ( ... )` exist; there is no `for`.
  `#name` strings are global and **cannot be function parameters** in this
  REAPER build – a function that needs to return a string writes into a fixed
  global one (that's what `note_name` does with `#nm`).
- **`@gfx` has no persistent local scope.** Variables set in `@gfx` (like
  `L`, `str_sp`, `board_w`) are globals that happen to be recomputed every
  frame. The layout-helper functions in `@init` read those globals, so they
  only give correct answers *during* a `@gfx` frame.
- **Every parameter is declared hidden** (`slider1:...>-Label`). REAPER then
  shows only the `@gfx` canvas. The parameters still exist – they hold and
  persist state and remain automatable – but the user only ever touches them
  through the immediate-mode widgets drawn in `@gfx`. `slider_show()` (the
  runtime show/hide call) was tried in v0.2 and did nothing useful here, hence
  the static `-` prefix instead.
- **Changing a parameter from `@gfx`** means assigning the slider variable
  (`num_frets = 22`) and calling `sliderchange(mask)` once per frame if
  anything changed, so REAPER records/persists it. `@gfx` sets a `dirty` flag;
  the flush block at the end of `@gfx` does the `write_sliders()` +
  `sliderchange(allmask)`.

---

## 4. Data model

### 4.1 Strings and frets

- String index `s`: **0 is the lowest-pitched string**, increasing upward.
  This matches how the board is drawn (low string at the bottom).
- Fret index `f`: **0 is the open string / nut**, increasing toward the body.
- The pitch of any position is `pitch_at(s, f)` = `str_note[s] + f`.

### 4.2 Tuning model

The tuning is **fully custom**: every string has its own MIDI-note parameter
(`slider11`..`slider19`). `str_note[]` (base offset `500`) is the working copy
everything reads; `read_sliders()` (in `@slider`, on load) and
`write_sliders()` (in the `@gfx` flush) move values between the parameters and
that array.

You retune a string by **dragging its open-note label** up/down on the canvas
(§4.6). Presets **just fill the fields** – `apply_preset()`:

- **Standard** (preset 1) – hard-codes 6-string EADGBE and **forces
  `num_strings = 6`**.
- **Rule presets** (2–6: 4ths / 5ths / Maj 3rds / Min 3rds / Tritone) –
  `str_note[i] = root + i * interval`, where `root = str_note[0]` (string 1's
  current value). Any string count. When a rule preset is active the panel
  shows a **ROOT** selector (E2 = 40, C2 = 36); it just sets `str_note[0]` and
  re-applies. Dragging string 1 sets an off-menu root the same way.
- **Custom** (0) – `apply_preset()` is a no-op; the fields stand as set.

`apply_preset()` is called from the preset buttons and the string-count
stepper in `@gfx`, and from `@slider` when a project/FX-preset recall changes
`tuning_preset` (compared against `last_preset`). Because every preset is a
deterministic function of `root` + count, re-applying on recall is idempotent.

Dragging string 1 under a rule preset re-runs `apply_preset()` (transpose from
the new root, preset kept); dragging any other string, or any string under
Standard, sets `tuning_preset = 0` (Custom) and keeps the edit. This
reconciliation lives at the end of the drag handler in `@gfx`.

### 4.3 Incoming-note state

`notestate[]` (base offset `0`, 128 slots) is a **counter per MIDI pitch**,
not a boolean. `@block` does `+= 1` on note-on and `-= 1` on note-off. A
counter rather than a flag so that overlapping note-ons for the same pitch
(common with multiple sources or fast retriggers) don't switch the light off
early. `@gfx` treats `notestate[p] > 0` as "lit".

Channel is currently ignored on input – any channel lights the board.

### 4.4 Outgoing-event queue

`pend[]` (base offset `300`) is a ring buffer of `(m1, m2, m3)` MIDI triplets,
`PEND_MAX` (64) entries. `pend_w` is the write cursor (owned by `@gfx`),
`pend_r` the read cursor (owned by `@block`). `push_event()` appends;
`@block` drains everything up to `pend_w` each block and sends it with
timestamp 0 (start of block).

### 4.5 Mouse-held note

`gui_note` is the single pitch currently held down by the mouse, or `-1`.
Because it is a single value, **mouse input is monophonic** – pressing a new
position sends a note-off for the old one first. `last_cap` stores the
previous frame's `mouse_cap` so `@gfx` can detect button *edges* (press,
release) rather than level.

### 4.6 The on-canvas UI

All configuration is drawn by `@gfx` as **immediate-mode widgets** – there is
no retained widget tree, each frame re-draws every control and re-tests the
mouse against its rectangle.

- **`ui_btn(x,y,w,h,active)`** – draws a button (label taken from the global
  string `#lbl`, set right before the call), returns 1 on the click *edge*
  this frame, and sets the `consumed` flag so the same click can't also hit
  the fretboard.
- **`ui_stepper(x,y,caplen,val,lo,hi)`** – a `caption [-] value [+]` row (two
  `ui_btn`s), returns the new value.
- **`ui_caption(x,y)`** – dim label text from `#lbl`.

`ui_click` (mouse-press edge) and `consumed` are frame globals set at the top
of `@gfx`; widgets read them.

**Panel toggle.** `settings_panel` (slider1) is mirrored to the `panel_open`
global. The top-right *settings / hide* button flips it. When open, the panel
occupies the top `panel_h` px and `T` (board top margin) is pushed down below
it; when closed the canvas is just the fretboard plus that button.
`settings_panel` persists with the FX state, so an instance reopens the way
you left it.

**Drag-to-retune.** A separate pass after the panel checks the mouse against
each string's open-label zone (`x < L`, within ~`str_sp*0.4` of `str_y(s)`).
Press captures `drag_s`, `drag_y0`, `drag_n0`; motion sets
`str_note[drag_s] = drag_n0 + round((drag_y0 - mouse_y)/7)`; release runs the
preset reconciliation from §4.2.

---

## 5. The three data flows

### Visualise (MIDI in → screen)

```
incoming MIDI ──▶ @block: parse status, notestate[note] ++/--    (also pass-through via midisend)
                                    │
                                    ▼
                 @gfx: for every (s,f), if notestate[pitch_at(s,f)] > 0 → draw lit dot
```

### Input (click → MIDI out)

```
@gfx: mouse press edge ──▶ nearest_string(mouse_y) + fret_from_x(mouse_x)
                           ──▶ pitch_at(...) ──▶ push_event(note-on) ; gui_note = pitch
      mouse release edge ─▶ push_event(note-off) ; gui_note = -1
                                    │  (pend ring buffer)
                                    ▼
@block: drain pend ──▶ midisend(...)
```

Everything is greyscale. Incoming notes are a light-grey filled dot with a
dark outline; the mouse-held note is a slightly larger **white** dot, so your
own input still reads as distinct without adding colour.

### Configure (canvas → parameters)

```
@gfx widget click / label drag
   ──▶ mutate the param global (tuning_preset, num_strings, str_note[], …)
       + apply_preset() where relevant, set dirty = 1
   ──▶ end-of-@gfx flush (if dirty): clamp, write_sliders(), sliderchange(allmask)

@slider (only fires on automation / preset recall, not on canvas edits)
   ──▶ clamp, read_sliders(), re-apply a recalled preset
```

`@gfx` reads the param globals directly every frame (`inlay_mode`,
`name_mode`, `out_channel`, `out_velocity`) and `str_note[]` for tuning.

Pass-through: `@block` re-sends every MIDI event it receives, so inserting
this plugin in a chain is transparent to downstream MIDI.

---

## 6. Coordinate system (`@gfx`)

Set once per frame at the top of `@gfx`:

- `L, R, T, B` – pixel margins (left is wide for open-string labels).
- `board_w`, `board_h` – the playable rectangle.
- `header_h` – top strip: `panel_h` when `panel_open`, else `26` (title +
  toggle button). `T` (board top margin) `= header_h + 24`, the `+24` leaving
  the fret-number row clear of the header.
- `fret_sp` = `board_w / num_frets` – horizontal pixels per fret.
- `str_sp` = `board_h / (num_strings - 1)` – vertical pixels per string gap.
- `nr` / `ir` – note-marker and inlay-dot radii, scaled from the smaller of
  `fret_sp` / `str_sp` and clamped, so the board stays legible at any size.

Helper functions (defined in `@init`, valid only mid-frame):

| Function            | Returns |
|---------------------|---------|
| `str_y(s)`          | y pixel of string `s` (low string at bottom) |
| `fret_x(f)`         | x pixel of fret line `f` (`f=0` is the nut) |
| `note_x(f)`         | x pixel where a dot for fret `f` is drawn – centred in the fret space; open notes sit left of the nut |
| `nearest_string(my)`| string index closest to mouse y |
| `fret_from_x(mx)`   | fret index for mouse x (`0` if left of the nut) |
| `ui_btn` / `ui_stepper` / `ui_caption` | immediate-mode widgets (§4.6) |

---

## 7. Inlays

`inlay_mode`: 0 none, 1 standard, 2 capsule.

- **Standard** – decorative only. Single dots on the centre line at frets
  3/5/7/9 (mod 12), doubled dots at fret 12 (mod 12 == 0).
- **Capsule** – *semantic*, from the ruleset in `README.md`. For each cell it
  computes the pitch class, flags C (0) and F (5), and looks at the string
  above at the same fret. A C directly below an F (a perfect fourth, i.e.
  adjacent strings in all-fourths tuning) is drawn as one **capsule** – a
  rounded rectangle joining the two string positions. An isolated C or F is a
  single dot. The loop advances by 2 strings when it draws a capsule so the
  upper note isn't re-processed.

The capsule scan is O(strings × frets) redone every frame. Fine at these
sizes; if the board grows, cache it and rebuild on `@slider`.

---

## 8. Names worth tracking

| Name | Where | Meaning |
|------|-------|---------|
| `pitch_at(s, f)` | `@init` | **the** model function – `str_note[s] + f` |
| `str_note[]` @ 500 | memory | working per-string MIDI notes (index 0 = lowest) |
| `apply_preset()` | `@init`; called from `@gfx` + `@slider` | fills `str_note[]` from `tuning_preset` |
| `read_sliders()` / `write_sliders()` | `@init` | move values between `slider11..19` and `str_note[]` |
| `dirty` | `@gfx` frame global | "a param changed this frame" → triggers the flush |
| `allmask` | `@init` global | bitfield of every param, passed to `sliderchange` |
| `last_preset` | global | last-seen `tuning_preset`, to catch external recalls |
| `panel_open` | global | mirrors `settings_panel`; drives `T` and the panel draw |
| `consumed`, `ui_click` | `@gfx` frame globals | click routing between widgets / drag / board |
| `drag_s`, `drag_y0`, `drag_n0` | globals | in-progress string-label retune drag |
| `notestate[]` @ 0 | memory | incoming note-on counter per pitch (viz source) |
| `pend[]` @ 300, `pend_r`, `pend_w` | memory | lock-free outgoing MIDI queue |
| `push_event(m1,m2,m3)` | `@init` | enqueue an outgoing MIDI message from `@gfx` |
| `gui_note` | global | the one pitch the mouse is holding (`-1` = none) |
| `last_cap` | global | previous-frame `mouse_cap`, for edge detection |
| `settings_panel` | slider1 | panel open/closed, persisted |
| `tuning_preset` | slider4 | Custom / Standard / 5 rule presets |
| `num_strings`, `num_frets` | slider2/3 | board dimensions |
| `MAX_STRINGS` | `@init` | 9 – array sizes and the upper string clamp |
| `note_name(n)` | `@init` | writes pitch `n`'s note name into the global string `#nm` |
| `#lbl` | global string | button/caption text, set before each widget call |
| `L / R / T / B`, `fret_sp`, `str_sp`, `nr`, `ir` | `@gfx` globals | layout, recomputed per frame |

---

## 9. Known limitations & gotchas

- **Monophonic mouse input** – `gui_note` is a scalar. Polyphony needs an
  array of held notes keyed by something (cell, or pitch).
- **Lock-free queue, no memory barriers** – EEL2 gives no atomics; this
  works in practice because slots are doubles and there is exactly one
  producer and one consumer. Keep it that way.
- **Input channel ignored** – all incoming MIDI lights the board regardless
  of channel; output channel is configurable.
- **No hung-note protection** – if the FX window closes mid-click, the
  release edge may never fire. A safety all-notes-off in `@block` (or on
  `@gfx` losing focus) would be worth adding.
- **Standard is 6-string only, by design** – selecting it forces
  `num_strings = 6`. Use a rule preset or Custom for extended range.
- **Rule-preset root is string 1** – no separate "root" control; transpose by
  dragging string 1's label while the rule preset is selected.
- **Immediate-mode UI, no scroll / no keyboard entry** – values change only
  by button clicks and label drags. Fine for the current control count; a
  denser panel would want a real widget lib (e.g. geraintluff's `ui-lib`).
- **`sliderchange(allmask)` assumption** – the flush relies on `sliderchange`
  accepting a bitmask. If canvas edits don't persist across
  save/reload or automation, that call is the first suspect (fall back to
  per-slider `sliderchange(sliderN)`).
- **Persistence of `@gfx`-written params** – state lives entirely in the
  (hidden) slider values; there is no `@serialize`. If REAPER ever stops
  round-tripping a canvas-set value, add `@serialize`.
- **Runtime status (v0.3.0)** – full UI rewrite (all controls moved into
  `@gfx`, params hidden with `-`); not yet load/play-tested in REAPER. Earlier
  versions surfaced EEL2 parser quirks: no `#`-string function params, no
  `1e9` literals.

---

## 10. Where to extend

| Want to… | Touch |
|----------|-------|
| Add a tuning preset | bump `slider4` max + `allmask` is unaffected; add a branch in `apply_preset()` (and the `iv` line) + a `ui_btn` in the panel's preset row |
| Add a setting | declare a hidden `sliderN`, add its bit to `allmask`, draw a widget in the panel, set `dirty` on change |
| Change the capsule "target notes" | the `is_target` / `cap` conditions in the `inlay_mode == 2` block |
| Make mouse input polyphonic | replace `gui_note` scalar with a held-notes array; update the press/release blocks and the "held" test in the draw loop |
| Show scales/chords | add a highlight source alongside `notestate` and draw it in the note-marker loop |
| Persist non-param state | add a JSFX `@serialize` section |
| Resize behaviour | everything derives from `gfx_w/gfx_h`; the panel layout uses fixed pixel coords and would need reflowing |
