# Fretboard MIDI Controller (REAPER)

A guitar fretboard for REAPER that **visualises** MIDI and lets you **input**
MIDI by clicking the board.

Two implementations:

| | `Fretboard.jsfx` | `FretboardController.lua` |
|---|---|---|
| Kind | JSFX effect, in a track's FX chain | ReaScript action |
| Input target | live MIDI thru (record it) | **inserts notes into the MIDI editor take** (step-entry) |
| Visualises | incoming live MIDI | notes already in the take |
| Docs | `ARCHITECTURE.md` | `docs/REASCRIPT.md` |

The ReaScript exists so clicking a fret can write a
note straight into the piano roll — see `docs/REASCRIPT.md` for why the JSFX
version can't and how the port works.

## Install (ReaScript)

Copy `FretboardController.lua` into `%APPDATA%\REAPER\Scripts\` (already done
on this machine at `Scripts\Guillaume\`), then in REAPER: **Actions → Load
ReaScript…**, pick the file, and run it (assign a shortcut / toolbar button
if you like).

## Use (ReaScript)

Open a MIDI item in the MIDI editor, place the edit cursor, run the script.
Type a fret (or click one) → the note is inserted at the cursor, previewed
audibly, and the cursor advances by one step.

**Keyboard** (the window takes focus off the MIDI editor, so these are
re-mapped):

| key | action |
|---|---|
| `0`–`9` | fret on the **active string** (type `1` then `2` fast = fret 12) |
| `↑` / `↓` (or `W` / `S`) | choose the active string |
| `←` / `→` (or `A` / `D`) | move the caret one **grid** step |
| `Ctrl+←` / `Ctrl+→` (or `Ctrl+A` / `Ctrl+D`) | jump to the previous / next bar |
| `Q` | chord mode (Dorico-style): notes stack at the cursor; `Q` again commits and moves on |
| `R` | rest — advance one **note length** |
| `T` | tie: lengthen the last note by one note length and advance |
| `[` `]` (or `-` `=`, or `Ctrl+↑`/`Ctrl+↓`) | halve / double the MIDI editor **note length** |
| `Alt+[` `Alt+]` (or `Alt+↑`/`Alt+↓`) | halve / double the MIDI editor **grid** |
| `L` | "let ring" — notes sustain until that string is replayed |
| `Backspace` | remove the last note and step back |
| `Ctrl+Z` / `Ctrl+Y` | undo / redo |
| `Space` | transport play/stop |
| `Shift`+click | insert without advancing (chord entry) |

- **Grid and note length are REAPER's own MIDI-editor settings** — the keys
  change them in place (visible in the editor, shared with keyboard step
  input). Grid = how far the caret moves; note length = how long inserted
  notes are. For dotted/triplet use the editor's own grid menu.
- **Grey notes** (what's already in the take) show for the current **beat**,
  the beat plus the next one, or the whole **bar** — pick with **SHOW** in the
  strip.
- Every inserted / removed / tied note is its **own undo point** (`Ctrl+Z`
  peels them one at a time), same as editing in the piano roll.
- The panel shows a **keycode diagnostic** (top-right) when a key doesn't seem
  to register — tell me what `[` / `Alt+[` report if they still don't work.
- Move the edit cursor in the MIDI editor to reposition; the script follows.
- The board lights up: notes at the cursor (dim), notes you play on a MIDI
  keyboard (bright), notes under the play cursor during playback (bright).
- Previews play straight through the take's track FX (needs **SWS**; no
  arming needed). Without SWS they go via the Virtual MIDI Keyboard, which
  only sounds when the track is **armed + monitoring**; the panel says so.

## Install / use (JSFX version)

Copy `Fretboard.jsfx` into `%APPDATA%\REAPER\Effects\`, add FX → JS →
**Fretboard MIDI Controller** on a MIDI track. Incoming MIDI passes through
unchanged and is mirrored on the board; clicking sends live MIDI (record the
track's MIDI output to capture it).

## Top strip & settings panel (ReaScript)

A permanent top **strip** always shows the controls you reach for while
entering: the **Chord** toggle, the **SHOW** grey-notes selector (**Beat** /
**Beat+** the next beat / whole **Bar**), the **MIDI channel**, and a **LEN**
row of note-icon buttons (1/32 → whole, fastest first) that jump the
MIDI-editor note length straight to that value. A `CHORD` badge sits over the
board whenever chord mode is on.

Notes already in the take at the caret are drawn **white**; click one to
remove it from the MIDI. The SHOW window around it stays grey.

Click **settings** (top-right) to open the control panel below the strip;
**hide** to collapse it. The panel holds everything else — tuning preset,
string count (3–9), fret count (5–30, default 22), velocity, **GRID / NOTE**
steppers, inlays (none / standard / capsule), note-name display, **SPELL**
(sharps `C#` or flats `Db` — applies to every note name shown), let-ring —
and never duplicates the strip's controls. Settings persist (`ExtState`).

Fret numbers at the traditional fretmarker positions (3, 5, 7, 9, 12, 15, …)
are **bold** and carry a small dot above them (two at the octave).

(The JSFX version keeps its single in-canvas panel; see `ARCHITECTURE.md`.)

**Tuning** is per-string. Drag a string's open-note label up or down to
retune it. Presets just fill the fields: "Standard" sets 6-string EADGBE and
locks the count to 6; the rule presets (4ths / 5ths / maj 3rds / min 3rds /
tritone) work at any count and tune from string 1 as the root. When a rule
preset is active a **ROOT** selector appears (E2 default, or C2) — or drag
string 1 to transpose to any root.

## For developers

- `docs/REASCRIPT.md` — orientation for `FretboardController.lua`: the `defer` loop, the step cursor, MIDI-editor insertion, and what
  the port shares with / changes from the JSFX version.
- `ARCHITECTURE.md` — orientation for the JSFX version.

## Status

**ReaScript `v0.9.2`** — fretboard window with Guitar-Pro-style
typed entry (pick string, type fret) into the active MIDI editor take:
Dorico-style chord mode (`Q`), rest, tie, let-ring, per-note undo/redo, bar
navigation, and Dorico-style **decoupled grid vs note length** — both are
REAPER's own MIDI-editor settings, changed in place. Grey "what's here" notes
show per beat or per bar. Previews audibly; lights up cursor + live keyboard +
playback. Passes a stubbed-API frame harness; not yet fully verified inside
REAPER (the note-length setter API is unconfirmed — see `docs/REASCRIPT.md §7`).

**JSFX `v0.3.0`** — all settings in the plugin GUI, drag-to-retune,
greyscale UI. Live MIDI thru + click-to-send only (no editor insertion).

---

# Requirements

Goal = a plugin for Reaper that offers a guitar fretboard GUI to both visualise & input midi.
The fretboard should be customizable :
- Custom tunings (offer standard, all fourths, all fifths, all thirds, minor third, tirtone tuning)
- Strings count
- Fret count

Inlays : either none, or standard, or an custom pattern we will name "capsule" (see further section)

# Capsule inlays ruleset

The capsule inlay system is meant for all-fourths tuning but the rules should apply regardless of tuning.

* Target Notes: Default tracks C and F pitches exclusively.
* Mapping: Note-centric (string + fret coordinates), not linear fret positions.

* Isolated Notes: Single circular dot centered directly under the string (not between strings).
* Adjacent Pairs: C and F on the same fret across adjacent strings merge into a vertical rounded rectangle (capsule).
* Capsule Geometry: Two per-string circle components seamlessly joined together.

* Step 1: Calculate pitch matrix (string, fret) across the neck.
* Step 2: Flag all cells matching C or F.
* Step 3: Check vertical neighbors (string ± 1) at the same fret.
* Step 4: Render Capsule if neighbor matches paired fourth; render Single Dot if isolated.
