# Fretboard MIDI Controller (REAPER)

A JSFX plugin (`Fretboard.jsfx`) that draws a guitar fretboard in the FX window.
It **visualises** incoming MIDI (played notes light up on every position where
that pitch occurs) and lets you **input** MIDI by clicking positions on the
board.

## Install

Copy `Fretboard.jsfx` into your REAPER effects folder, e.g.
`%APPDATA%\REAPER\Effects\Guillaume\Fretboard.jsfx`
(already done on this machine), then in REAPER: add FX → JS → **Fretboard MIDI
Controller**.

## Use

Put it on a MIDI track. Route the track output to an instrument to hear your
clicks, or arm the track for recording to capture them. Incoming MIDI passes
through unchanged and is mirrored on the board.

**All controls are in the plugin's own GUI** — REAPER shows no native slider
panel. Click **settings** (top-right) to open the panel; **hide** to collapse
it back to just the fretboard. Everything persists with the FX state.

Panel controls: tuning preset, string count (3–9), fret count (5–30, default
22), inlays (none / standard / capsule), note-name display, MIDI-out channel,
click velocity.

**Tuning** is per-string. Drag a string's open-note label up or down to
retune it. Presets just fill the fields: "Standard" sets 6-string EADGBE and
locks the count to 6; the rule presets (4ths / 5ths / maj 3rds / min 3rds /
tritone) work at any count and tune from string 1 as the root. When a rule
preset is active a **ROOT** selector appears (E2 default, or C2) — or drag
string 1 to transpose to any root.

## For developers

`ARCHITECTURE.md` is the orientation doc — read it before the code. It covers
why JSFX, the section/threading model the code is bound to, the data flows,
the memory map, and the names worth tracking.

## Status

v0.3.0 — all settings moved into the plugin GUI (native params hidden),
drag-to-retune, greyscale UI, 22-fret default. Not yet play-tested in REAPER
after this rewrite. Known rough edges: mouse input is monophonic; GUI→MIDI
events are queued to the audio thread without locking; no hung-note safety;
panel layout is fixed-pixel (doesn't reflow on resize).

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
