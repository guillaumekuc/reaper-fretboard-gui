--[[
  Fretboard MIDI Controller  (ReaScript / Lua)
  version 0.9.10-dbg

  A guitar-fretboard window that inserts notes into the take open in the active
  MIDI editor, Guitar-Pro-style: pick a string, type a fret, it writes the note
  and advances by the step length. It previews audibly and lights up notes at
  the cursor, live hardware-MIDI input, and notes under the play cursor.

  Run it as an action (Actions > Load ReaScript...). Open a MIDI item in the
  MIDI editor, place the edit cursor, then type or click.

  Keys (the window steals focus from the MIDI editor, so these are re-mapped):
    0-9            fret on the active string  (type 1 then 2 quickly = 12)
    up / down  (W / S)      choose the active string
    left / right  (A / D)   move the caret by one GRID step
    ctrl+left/right  (ctrl+A / ctrl+D)  jump to the previous / next bar
    Q              chord mode (Dorico-style): notes stack at the cursor without
                   advancing; press Q again to commit the chord and move on
    R              rest: advance by one NOTE LENGTH, insert nothing
    T              tie: lengthen the last note by one note length and advance
    [  ]           MIDI editor NOTE LENGTH shorter / longer   (or panel NOTE +/- )
    shift+[  shift+]   MIDI editor GRID finer / wider          (or panel GRID +/- )
    L              "let ring" on/off  (notes sustain until the string is replayed)
    backspace      remove the last inserted note and step back
    ctrl+Z / Y     undo / redo
    space          transport play/stop
    shift+click    insert without advancing (chord entry)

  Grid and note length are REAPER's own MIDI-editor settings. The [ ] and
  shift+[ shift+] keys (and the panel NOTE / GRID +/- buttons) step through
  REAPER's own "Set length for next inserted note: 1/N" and "Grid: set to 1/N"
  actions,
  which are discovered from the action list at startup (needs the SWS
  extension). Nothing is stored locally. Grid = caret movement & snap;
  note length = the length of inserted notes and how far a note advances the
  caret. Without SWS the NOTE control falls back to the grid.

  See docs/REASCRIPT.md for the architecture.
]]--

local SECT = "GK_FretboardController"
local MAX_STRINGS = 9
local HAS_INPUT_POLL = reaper.MIDI_GetRecentInputEvent ~= nil
local MIDI_SECTION  = 32060   -- MIDI editor action section

-- ============================================================= model =====

local NAME_SHARP = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }
local NAME_FLAT  = { "C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B" }

local TUNINGS = {
  { name = "Custom",   rule = nil   },
  { name = "Standard", rule = "std" },
  { name = "4ths",     rule = 5     },
  { name = "5ths",     rule = 7     },
  { name = "Maj 3rds", rule = 4     },
  { name = "Min 3rds", rule = 3     },
  { name = "Tritone",  rule = 6     },
}

local S   -- state; assigned below. note_name() reads S.accidental at call time.

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
local function note_name(n)
  return (S.accidental == 1 and NAME_FLAT or NAME_SHARP)[(n % 12) + 1]
end
local function octave(n) return math.floor(n / 12) - 1 end

-- ============================================================= state =====

S = {
  num_strings   = 6,
  num_frets     = 22,
  tuning        = 1,
  inlay         = 2,
  name_mode     = 1,
  chan          = 1,
  vel           = 100,
  panel_open    = 1,
  str_note      = { 40, 45, 50, 55, 59, 64, 35, 30, 25 },
  active_string = 3,      -- not persisted
  let_ring      = 0,
  ctx_mode      = 0,      -- grey context notes: 0 = beat, 1 = beat + next beat, 2 = whole bar
  accidental    = 0,      -- note spelling: 0 = sharps, 1 = flats
}

local function pitch_at(s, f) return S.str_note[s] + f end   -- s: 1 = lowest string

local function apply_preset(idx)
  local t = TUNINGS[idx + 1]
  if not t or not t.rule then return end
  if t.rule == "std" then
    S.num_strings = 6
    S.str_note = { 40, 45, 50, 55, 59, 64 }
  else
    local root = S.str_note[1] or 40
    for i = 1, MAX_STRINGS do S.str_note[i] = root + (i - 1) * t.rule end
  end
  for i = 1, MAX_STRINGS do S.str_note[i] = clamp(S.str_note[i] or 40, 12, 108) end
end

-- ======================================================= persistence =====

local function save_state()
  local function set(k, v)
    if type(v) == "number" then
      v = (v == math.floor(v)) and math.floor(v) or math.floor(v * 1e6 + 0.5) / 1e6
    end
    reaper.SetExtState(SECT, k, tostring(v), true)
  end
  for _, k in ipairs({ "num_strings","num_frets","tuning","inlay","name_mode",
                       "chan","vel","panel_open","let_ring","ctx_mode","accidental" }) do
    set(k, S[k])
  end
  set("str_note", table.concat(S.str_note, ","))
end

local function load_state()
  local function num(k, d)
    local v = reaper.GetExtState(SECT, k)
    return v ~= "" and tonumber(v) or d
  end
  for _, k in ipairs({ "num_strings","num_frets","tuning","inlay","name_mode",
                       "chan","vel","panel_open","let_ring","ctx_mode","accidental" }) do
    S[k] = num(k, S[k])
  end
  local sn = reaper.GetExtState(SECT, "str_note")
  if sn ~= "" then
    local t = {}
    for x in sn:gmatch("[^,]+") do t[#t + 1] = tonumber(x) end
    if #t >= 3 then S.str_note = t end
  end
  for i = 1, MAX_STRINGS do S.str_note[i] = S.str_note[i] or (25 + i * 3) end
  S.num_strings = clamp(math.floor(S.num_strings), 3, MAX_STRINGS)
  S.num_frets   = clamp(math.floor(S.num_frets), 5, 30)
  S.ctx_mode    = clamp(math.floor(S.ctx_mode), 0, 2)
  S.accidental  = clamp(math.floor(S.accidental), 0, 1)
  S.chan        = clamp(math.floor(S.chan), 1, 16)      -- 0 would break preview + insert
  S.vel         = clamp(math.floor(S.vel), 1, 127)      -- 0 = a silent note-off
  S.active_string = clamp(math.floor(S.num_strings / 2) + 1, 1, S.num_strings)
end

-- ========================================================= midi i/o ======

local cursor_qn
local last_cursor_time
local history = {}          -- { take, sppq, pitch, chan, prev } stack
local ring_prev = {}        -- [string] -> last let-ring note {take, sppq, pitch, chan}
local preview_notes = {}    -- pitch -> true, notes currently sounding as preview
local last_take
local undo_suppress = false
local digit_pending, digit_time = nil, 0
local chord_mode  = false   -- Dorico-style: pitches stack at the cursor, no advance (Q)
local chord_dirty = false   -- a note was added in the current chord
local last_key, last_key_time = "", 0   -- keycode diagnostic shown in the panel

local function get_take()
  local he = reaper.MIDIEditor_GetActive()
  if not he then return nil end
  local tk = reaper.MIDIEditor_GetTake(he)
  if tk and reaper.ValidatePtr2(0, tk, "MediaItem_Take*") then return tk, he end
  return nil
end

local function track_of(take)
  local item = reaper.GetMediaItemTake_Item(take)
  return item and reaper.GetMediaItem_Track(item) or nil
end

-- All lengths come from REAPER, never a private var:
--   grid_qn      = the MIDI editor grid  (caret / arrow movement, snap)
--   step_len_qn  = the length of inserted notes (MIDI editor note-length,
--                  which falls back to the grid when it "follows grid")
local function grid_qn(take)
  local g = reaper.MIDI_GetGrid(take)
  return (g and g > 0) and g or 1
end

local function step_len_qn(take)
  local grid, _, notelen = reaper.MIDI_GetGrid(take)
  if notelen and notelen > 0 then return notelen end
  return (grid and grid > 0) and grid or 1
end

-- ticks per quarter note for this take (usually 960)
local function tpqn_of(take)
  local d = reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
  return (d and d > 0) and d or 960
end

local DBG = ""

-- true when n is 1 or a power of two (musical note denominators)
local function pow2(n) return n == 1 or (n > 0 and (n & (n - 1)) == 0) end

-- MIDI-editor actions "Grid: set to X" and "Set length for next inserted note: X",
-- discovered from the action list at startup (needs the SWS extension).
-- Each list is sorted finest -> coarsest; .v is the value as a fraction of a
-- whole note (1/16 note -> 0.0625, whole note -> 1, two whole notes -> 2).
local grid_actions, notelen_actions = {}, {}

local function parse_note_value(s)
  local a, b = s:match("^(%d+)/(%d+)$")
  if a and pow2(tonumber(b)) then return tonumber(a) / tonumber(b) end
  local w = s:match("^(%d+)$")
  if w and pow2(tonumber(w)) then return tonumber(w) end
end

local function scan_actions()
  if not reaper.CF_GetCommandText then return end
  for cmd = 40000, 43200 do
    local txt = reaper.CF_GetCommandText(MIDI_SECTION, cmd)
    if txt and txt ~= "" then
      local gv = txt:match("^Grid: [Ss]et to (%S+)%s*$")
      local lv = txt:match("[Ll]ength for next inserted note:%s*(%S+)%s*$")
      if gv then local v = parse_note_value(gv); if v then grid_actions[#grid_actions+1] = {v=v, cmd=cmd} end end
      if lv then local v = parse_note_value(lv); if v then notelen_actions[#notelen_actions+1] = {v=v, cmd=cmd} end end
    end
  end
  local by_v = function(p, q) return p.v < q.v end
  table.sort(grid_actions, by_v); table.sort(notelen_actions, by_v)
end

-- step one entry finer / wider through an action list, starting from the entry
-- nearest the current value (`cur_wn` = current value as fraction of a whole note)
local function step_actions(list, hwnd, cur_wn, finer, label)
  if #list == 0 or not hwnd then DBG = label .. ": no actions (need SWS)"; return false end
  local idx, bd = 1, 1e9
  for i, a in ipairs(list) do
    local d = math.abs(a.v - cur_wn)
    if d < bd then bd, idx = d, i end
  end
  idx = clamp(idx + (finer and -1 or 1), 1, #list)
  reaper.MIDIEditor_OnCommand(hwnd, list[idx].cmd)
  DBG = string.format("%s %s -> 1/%g (cmd %d)", label, finer and "finer" or "wider",
    1 / list[idx].v, list[idx].cmd)
  return true
end

local NOTELEN_OK = nil
local function set_grid(take, hwnd, finer)
  if not take then return end
  if #grid_actions > 0 then
    step_actions(grid_actions, hwnd, grid_qn(take) / 4, finer, "grid")
  elseif reaper.SetMIDIEditorGrid then
    local g = grid_qn(take)
    reaper.SetMIDIEditorGrid(0, clamp(finer and g / 2 or g * 2, 1 / 32, 16))
    DBG = string.format("grid via SetMIDIEditorGrid (no actions): %.3f", grid_qn(take))
  end
end
local function set_note_len(take, hwnd, finer)
  if not take then return end
  NOTELEN_OK = step_actions(notelen_actions, hwnd, step_len_qn(take) / 4, finer, "notelen")
  if not NOTELEN_OK then set_grid(take, hwnd, finer) end
end

-- jump note length straight to a value (whole-note fraction: 1/4 note -> 0.25),
-- for the quick-length buttons. Uses the discovered "Set length..." actions;
-- without SWS it falls back to setting the grid, same as set_note_len.
local function set_note_len_to(take, hwnd, wn)
  if not take then return end
  if #notelen_actions > 0 and hwnd then
    local idx, bd = 1, 1e9
    for i, a in ipairs(notelen_actions) do
      local d = math.abs(a.v - wn)
      if d < bd then bd, idx = d, i end
    end
    reaper.MIDIEditor_OnCommand(hwnd, notelen_actions[idx].cmd)
    NOTELEN_OK = true
    DBG = string.format("notelen -> 1/%g (cmd %d)", 1 / notelen_actions[idx].v, notelen_actions[idx].cmd)
  elseif reaper.SetMIDIEditorGrid then
    reaper.SetMIDIEditorGrid(0, clamp(wn * 4, 1 / 32, 16))
    NOTELEN_OK = false
    DBG = "notelen: no SWS actions - set grid instead"
  end
end

local function as_frac(qn)
  if not qn or qn <= 0 then return "-" end
  if qn >= 3.9 then return tostring(math.floor(qn / 4 + 0.5)) end   -- whole notes: "1", "2", "4"
  return "1/" .. math.max(1, math.floor(4 / qn + 0.5))
end

local function step_label(take)
  local g, n = grid_qn(take), step_len_qn(take)
  return string.format("note %s   grid %s", as_frac(n), as_frac(g))
end

local function find_note(take, sppq, pitch, chan)
  local _, n = reaper.MIDI_CountEvts(take)
  for i = n - 1, 0, -1 do
    local ok, _, _, s, e, c, p = reaper.MIDI_GetNote(take, i)
    if ok and p == pitch and c == chan and math.abs(s - sppq) < 1 then return i, s, e end
  end
end

local function preview_off()
  for p in pairs(preview_notes) do
    reaper.StuffMIDIMessage(0, 0x80 + (S.chan - 1), p, 0)
  end
  preview_notes = {}
end

local preview_time = 0
local function preview_on(p)
  if not chord_mode then preview_off() end   -- chord mode: let them ring together
  reaper.StuffMIDIMessage(0, 0x90 + (S.chan - 1), p, S.vel)
  preview_notes[p] = true
  preview_time = reaper.time_precise()
end

local function set_cursor(qn)
  cursor_qn = math.max(0, qn)
  last_cursor_time = reaper.TimeMap2_QNToTime(0, cursor_qn)
  reaper.SetEditCurPos(last_cursor_time, false, false)
end

local function sync_cursor_from_edit(take)
  local t = reaper.GetCursorPosition()
  if not last_cursor_time or math.abs(t - last_cursor_time) > 1e-6 then
    local qn = reaper.TimeMap2_timeToQN(0, t)
    local g  = grid_qn(take)                       -- caret snaps to the grid
    cursor_qn = math.floor(qn / g + 0.5) * g
    last_cursor_time = reaper.TimeMap2_QNToTime(0, cursor_qn)
  end
end

-- MIDI_InsertNote & friends don't reliably make an undo point on their own
-- (worse in a deferred script); marking the item dirty inside the block fixes it
local function mark_dirty(take)
  local item = take and reaper.GetMediaItemTake_Item(take)
  if item then reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item) end
end

local function insert_note(pitch, advance, string_idx)
  local take = get_take()
  if not take then return false end
  if not cursor_qn then sync_cursor_from_edit(take) end
  local step = step_len_qn(take)
  local prev = cursor_qn
  local sppq = reaper.MIDI_GetPPQPosFromProjQN(take, cursor_qn)
  local eppq = reaper.MIDI_GetPPQPosFromProjQN(take, cursor_qn + step)

  if not undo_suppress then reaper.Undo_BeginBlock() end

  if S.let_ring == 1 and string_idx then
    local tail = math.min(math.max(step * 6, 2), 4)          -- ring up to a bar
    eppq = reaper.MIDI_GetPPQPosFromProjQN(take, cursor_qn + tail)
    local pr = ring_prev[string_idx]
    if pr and reaper.ValidatePtr2(0, pr.take, "MediaItem_Take*") then
      local i2 = find_note(pr.take, pr.sppq, pr.pitch, pr.chan)
      if i2 then reaper.MIDI_SetNote(pr.take, i2, nil, nil, nil, sppq, nil, nil, nil, false) end
    end
  end

  reaper.MIDI_InsertNote(take, false, false, sppq, eppq, S.chan - 1, pitch, S.vel, false)
  reaper.MIDI_Sort(take)
  if not undo_suppress then
    mark_dirty(take)
    reaper.Undo_EndBlock("Fretboard: insert " .. note_name(pitch) .. octave(pitch), -1)
    reaper.UpdateArrange()
  end

  history[#history + 1] = { take = take, sppq = sppq, pitch = pitch, chan = S.chan - 1, prev = prev }
  if S.let_ring == 1 and string_idx then
    ring_prev[string_idx] = { take = take, sppq = sppq, pitch = pitch, chan = S.chan - 1 }
  end
  if advance then set_cursor(cursor_qn + step) end
  return true
end

local function delete_last()
  local h = history[#history]
  if not h then return end
  history[#history] = nil
  if reaper.ValidatePtr2(0, h.take, "MediaItem_Take*") then
    local idx = find_note(h.take, h.sppq, h.pitch, h.chan)
    if idx then
      if not undo_suppress then reaper.Undo_BeginBlock() end
      reaper.MIDI_DeleteNote(h.take, idx)
      reaper.MIDI_Sort(h.take)
      if not undo_suppress then
        mark_dirty(h.take)
        reaper.Undo_EndBlock("Fretboard: remove note", -1)
        reaper.UpdateArrange()
      end
    end
  end
  set_cursor(h.prev)
end

-- move the caret by `by` ("grid" for arrows, "note" for a rest of the current length)
local function step_cursor(dir, by)
  local take = get_take()
  if not take then return end
  if not cursor_qn then sync_cursor_from_edit(take) end
  preview_off()
  chord_dirty = false
  local amt = (by == "note") and step_len_qn(take) or grid_qn(take)
  set_cursor(cursor_qn + dir * amt)
end

-- jump the cursor to the start of the next/previous bar (Ctrl + left/right)
local function step_bar(dir)
  local take = get_take()
  if not take then return end
  if not cursor_qn then sync_cursor_from_edit(take) end
  preview_off()
  chord_dirty = false
  local t = reaper.TimeMap2_QNToTime(0, cursor_qn)
  local beats, meas = reaper.TimeMap2_timeToBeats(0, t)
  local target = meas + dir
  if dir < 0 and beats > 1e-4 then target = meas end   -- first Ctrl+Left snaps to this bar's start
  target = math.max(0, target)
  set_cursor(reaper.TimeMap2_timeToQN(0, reaper.TimeMap2_beatsToTime(0, 0, target)))
end

local function tie_extend()
  local take = get_take()
  local h = history[#history]
  if not take or not h then return end
  local idx, _, e = find_note(take, h.sppq, h.pitch, h.chan)
  if not idx then return end
  local step  = step_len_qn(take)
  local e_qn  = reaper.MIDI_GetProjQNFromPPQPos(take, e)
  local new_e = reaper.MIDI_GetPPQPosFromProjQN(take, e_qn + step)
  reaper.Undo_BeginBlock()
  reaper.MIDI_SetNote(take, idx, nil, nil, nil, new_e, nil, nil, nil, false)
  reaper.MIDI_Sort(take)
  mark_dirty(take)
  reaper.Undo_EndBlock("Fretboard: tie", -1)
  reaper.UpdateArrange()
  set_cursor((cursor_qn or 0) + step)
end

local TWODIGIT_WINDOW = 0.4   -- seconds: a 2nd digit within this = a 2-digit fret

local function type_fret(d)
  if d > S.num_frets then return end
  local now = reaper.time_precise()
  if digit_pending and (now - digit_time) < TWODIGIT_WINDOW then
    local combined = digit_pending * 10 + d
    if combined <= S.num_frets then
      reaper.Undo_BeginBlock()
      undo_suppress = true
      delete_last()
      insert_note(pitch_at(S.active_string, combined), not chord_mode, S.active_string)
      undo_suppress = false
      mark_dirty(get_take())
      reaper.Undo_EndBlock("Fretboard: fret " .. combined, -1)
      reaper.UpdateArrange()
      preview_on(pitch_at(S.active_string, combined))
      digit_pending, digit_time = nil, now
      return
    end
  end
  local p = pitch_at(S.active_string, d)
  preview_on(p)
  insert_note(p, not chord_mode, S.active_string)
  if chord_mode then chord_dirty = true end
  digit_pending = (d >= 1 and d <= math.floor(S.num_frets / 10)) and d or nil
  digit_time = now
end

-- PPQ window shown as grey "context" notes: the current beat, or the whole bar
local function context_window(take)
  if not cursor_qn then return nil end
  local t = reaper.TimeMap2_QNToTime(0, cursor_qn)
  local beats, meas = reaper.TimeMap2_timeToBeats(0, t)
  local lo_t, hi_t
  if S.ctx_mode == 2 then                                   -- whole Bar
    lo_t = reaper.TimeMap2_beatsToTime(0, 0, meas)
    hi_t = reaper.TimeMap2_beatsToTime(0, 0, meas + 1)
  else                                                       -- Beat, or Beat + next beat
    local b = math.floor(beats)
    lo_t = reaper.TimeMap2_beatsToTime(0, b, meas)
    hi_t = reaper.TimeMap2_beatsToTime(0, b + (S.ctx_mode == 1 and 2 or 1), meas)
  end
  return reaper.MIDI_GetPPQPosFromProjQN(take, reaper.TimeMap2_timeToQN(0, lo_t)),
         reaper.MIDI_GetPPQPosFromProjQN(take, reaper.TimeMap2_timeToQN(0, hi_t))
end

-- notes in the take in the context window / under the play cursor
local function scan_context(take)
  local at_cursor, playing = {}, {}
  if not take then return at_cursor, playing end
  local _, notes = reaper.MIDI_CountEvts(take)
  local lo_ppq, hi_ppq = context_window(take)
  local play_ppq
  if (reaper.GetPlayState() & 1) == 1 then
    play_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, reaper.GetPlayPosition())
  end
  for i = 0, notes - 1 do
    local ok, _, muted, sppq, eppq, _, pitch = reaper.MIDI_GetNote(take, i)
    if ok and not muted then
      if lo_ppq and sppq < hi_ppq and eppq > lo_ppq then at_cursor[pitch] = true end
      if play_ppq and sppq <= play_ppq and eppq > play_ppq then playing[pitch] = true end
    end
  end
  return at_cursor, playing
end

-- live MIDI from any hardware input (REAPER 7+)
local live_notes = {}
local last_input_seq = 0

local function poll_live_input()
  if not HAS_INPUT_POLL then return end
  local seq0 = reaper.MIDI_GetRecentInputEvent(0)
  if not seq0 or seq0 == 0 then return end
  if seq0 < last_input_seq then last_input_seq = 0 end
  if seq0 == last_input_seq then return end
  local fresh, i = {}, 0
  while i < 64 do
    local seq, buf = reaper.MIDI_GetRecentInputEvent(i)
    if not seq or seq == 0 or seq <= last_input_seq then break end
    fresh[#fresh + 1] = buf
    i = i + 1
  end
  last_input_seq = seq0
  for j = #fresh, 1, -1 do
    local b = fresh[j]
    if b and #b >= 3 then
      local st, d1, d2 = b:byte(1), b:byte(2), b:byte(3)
      local hi = st & 0xF0
      if hi == 0x90 and d2 > 0 then live_notes[d1] = true
      elseif hi == 0x80 or (hi == 0x90 and d2 == 0) then live_notes[d1] = nil
      elseif hi == 0xB0 and d1 == 123 then live_notes = {} end
    end
  end
end

-- ============================================================ widgets ====

local mouse = { x = 0, y = 0, cap = 0, pcap = 0, down = false, up = false, held = false }
local consumed = false

local function update_mouse()
  mouse.pcap = mouse.cap
  mouse.x, mouse.y, mouse.cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  local l, pl = mouse.cap & 1, mouse.pcap & 1
  mouse.down = l ~= 0 and pl == 0
  mouse.up   = l == 0 and pl ~= 0
  mouse.held = l ~= 0
end

local function in_rect(x, y, w, h)
  return mouse.x >= x and mouse.x <= x + w and mouse.y >= y and mouse.y <= y + h
end

local function box(x, y, w, h)
  gfx.line(x, y, x + w, y);   gfx.line(x, y + h, x + w, y + h)
  gfx.line(x, y, x, y + h);   gfx.line(x + w, y, x + w, y + h)
end

local function btn(x, y, w, h, label, active)
  local hot = in_rect(x, y, w, h)
  if active then gfx.set(0.30, 0.30, 0.34)
  elseif hot then gfx.set(0.24, 0.24, 0.27)
  else gfx.set(0.16, 0.16, 0.18) end
  gfx.rect(x, y, w, h)
  gfx.set(0.38, 0.38, 0.42); box(x, y, w, h)
  if active then gfx.set(0.95, 0.95, 0.97) else gfx.set(0.70, 0.70, 0.74) end
  gfx.x = x + 6; gfx.y = y + math.floor((h - 8) / 2)
  gfx.drawstr(label)
  if hot and mouse.down then consumed = true; return true end
  return false
end

local function caption(x, y, label)
  gfx.set(0.52, 0.52, 0.55); gfx.x = x; gfx.y = y; gfx.drawstr(label)
end

local function stepper(x, y, caplen, label, val, lo, hi)
  caption(x, y + 4, label)
  local bx, nv = x + caplen, val
  if btn(bx, y, 17, 16, "-", false) then nv = math.max(lo, val - 1) end
  gfx.set(0.86, 0.86, 0.89); gfx.x = bx + 24; gfx.y = y + 4; gfx.drawstr(tostring(val))
  if btn(bx + 46, y, 17, 16, "+", false) then nv = math.min(hi, val + 1) end
  return nv
end

-- a musical-note glyph for the quick note-length buttons; den = 1,2,4,8,16,32
-- (whole -> hollow head, half -> hollow + stem, quarter+ -> filled, eighth+ -> flags)
local function note_icon(cx, cy, den)
  local filled = den >= 4
  local r = 3
  gfx.circle(cx - 1, cy + 3, r, filled and 1 or 0, 1)
  gfx.circle(cx + 1, cy + 3, r, filled and 1 or 0, 1)
  if den >= 2 then
    gfx.line(cx + r + 1, cy + 3, cx + r + 1, cy - 6)                 -- stem
    local flags = (den == 8) and 1 or (den == 16) and 2 or (den == 32) and 3 or 0
    for i = 0, flags - 1 do
      local fy = cy - 6 + i * 3
      gfx.line(cx + r + 1, fy, cx + r + 5, fy + 4)                   -- flag
    end
  end
end

-- quick note-length button: sets the MIDI editor note length to 1/den,
-- lit when that is the current length. cur_wn = current length / whole note.
local function len_btn(x, y, den, cur_wn)
  local active = math.abs((1 / den) - cur_wn) < 1e-4
  local clicked = btn(x, y, 24, 16, "", active)
  gfx.set(active and 0.96 or 0.74, active and 0.96 or 0.74, active and 0.98 or 0.77)
  note_icon(x + 9, y + 8, den)
  return clicked
end

-- ============================================================ drawing ====

local L, R, T, B, boardw, boardh, fret_sp, str_sp, nr, ir, header_h
local PANEL_H = 146
local HDR_H   = 30          -- always-visible top strip (title + quick controls)
local drag_s, drag_y0, drag_n0 = -1, 0, 0

local function str_y(s)  return gfx.h - B - (s - 1) * str_sp end
local function fret_x(f) return L + f * fret_sp end
local function note_x(f) if f <= 0 then return L - 20 end return L + (f - 0.5) * fret_sp end

local function layout()
  header_h = HDR_H + ((S.panel_open == 1) and PANEL_H or 0)
  L, R, T, B = 54, 16, header_h + 32, 18
  boardw  = gfx.w - L - R
  boardh  = gfx.h - T - B
  fret_sp = boardw / S.num_frets
  str_sp  = S.num_strings > 1 and boardh / (S.num_strings - 1) or boardh
  nr = clamp(math.min(fret_sp, str_sp) * 0.34, 4, 11)
  ir = math.max(3, nr * 0.55)
end

local function draw_board(at_cursor, playing)
  gfx.set(0.11, 0.11, 0.12); gfx.rect(0, 0, gfx.w, gfx.h)
  gfx.set(0.16, 0.16, 0.17); gfx.rect(L, T, boardw, boardh)

  -- active-string highlight band (full width, behind everything)
  local ay = str_y(S.active_string)
  gfx.set(0.205, 0.205, 0.225)
  gfx.rect(0, ay - str_sp * 0.42, gfx.w, str_sp * 0.84)

  if S.inlay == 1 then
    local midy = (str_y(1) + str_y(S.num_strings)) * 0.5
    gfx.set(0.29, 0.29, 0.30)
    for f = 1, S.num_frets do
      local m = f % 12
      if m == 3 or m == 5 or m == 7 or m == 9 then
        gfx.circle(note_x(f), midy, ir, 1, 1)
      elseif m == 0 then
        gfx.circle(note_x(f), midy - str_sp * 0.6, ir, 1, 1)
        gfx.circle(note_x(f), midy + str_sp * 0.6, ir, 1, 1)
      end
    end
  elseif S.inlay == 2 then
    gfx.set(0.29, 0.29, 0.30)
    for f = 1, S.num_frets do
      local s = 1
      while s <= S.num_strings do
        local pc  = pitch_at(s, f) % 12
        local pcu = (s + 1 <= S.num_strings) and pitch_at(s + 1, f) % 12 or -1
        local tgt = pc == 0 or pc == 5
        local cap = tgt and ((pc == 0 and pcu == 5) or (pc == 5 and pcu == 0))
        if cap then
          -- integer-aligned so the joining bar and the two dots share edges
          local cx = math.floor(note_x(f) + 0.5)
          local rr = math.floor(ir + 1)
          local y0, y1 = str_y(s), str_y(s + 1)
          gfx.rect(cx - rr, math.floor(math.min(y0, y1) + 0.5),
                   rr * 2 + 1, math.floor(math.abs(y1 - y0) + 0.5))
          gfx.circle(cx, y0, rr, 1, 1); gfx.circle(cx, y1, rr, 1, 1)
          s = s + 2
        else
          if tgt then gfx.circle(note_x(f), str_y(s), ir, 1, 1) end
          s = s + 1
        end
      end
    end
  end

  for f = 0, S.num_frets do
    local g = (f == 0) and 0.90 or 0.42
    gfx.set(g, g, f == 0 and 0.90 or 0.44)
    local x = fret_x(f)
    gfx.line(x, T, x, gfx.h - B)
    if f == 0 then gfx.line(x + 1, T, x + 1, gfx.h - B) end
    if f > 0 then
      local m = f % 12
      local marker = m == 3 or m == 5 or m == 7 or m == 9 or m == 0
      local dx  = math.floor(note_x(f) + 0.5)
      local lbl = tostring(f)
      gfx.setfont(marker and 2 or 1)                 -- bold at a fretmarker
      local tw = gfx.measurestr(lbl)
      if marker then
        gfx.set(0.74, 0.74, 0.77)                    -- fretmarker dot(s), centred on the number
        if m == 0 then gfx.circle(dx - 3, T - 25, 1.5, 1, 1); gfx.circle(dx + 3, T - 25, 1.5, 1, 1)
        else gfx.circle(dx, T - 25, 1.5, 1, 1) end
        gfx.set(0.66, 0.66, 0.69)
      else
        gfx.set(0.45, 0.45, 0.47)
      end
      gfx.x = dx - math.floor(tw / 2 + 0.5); gfx.y = T - 16
      gfx.drawstr(lbl)
    end
  end
  gfx.setfont(1)

  for s = 1, S.num_strings do
    local y = str_y(s)
    local act = (s == S.active_string)
    gfx.set(act and 0.82 or 0.55, act and 0.82 or 0.55, act and 0.84 or 0.56)
    gfx.line(L, y, gfx.w - R, y)
    if act then gfx.line(L, y + 1, gfx.w - R, y + 1) end

    local op = pitch_at(s, 0)
    if act then
      gfx.set(0.32, 0.32, 0.36); gfx.rect(1, y - 8, L - 24, 16)
      gfx.set(0.42, 0.42, 0.46); box(1, y - 8, L - 24, 16)
    end
    if s == drag_s then gfx.set(0.98, 0.98, 1.0)
    elseif act then gfx.set(0.96, 0.96, 0.98)
    else gfx.set(0.72, 0.72, 0.74) end
    gfx.x = 5; gfx.y = y - 7; gfx.drawstr(note_name(op) .. octave(op))

    for f = 0, S.num_frets do
      local p = pitch_at(s, f)
      local prev = preview_notes[p]
      local live = live_notes[p]
      local play = playing[p]
      local here = at_cursor[p]
      if prev or live or play then
        gfx.set(1, 1, 1);           gfx.circle(note_x(f), y, nr + (prev and 1 or 0), 1, 1)
        gfx.set(0.28, 0.28, 0.30);  gfx.circle(note_x(f), y, nr + (prev and 1 or 0), 0, 1)
        if S.name_mode > 0 then
          gfx.set(0.10, 0.10, 0.11)
          gfx.x = note_x(f) - 7; gfx.y = y - 6; gfx.drawstr(note_name(p))
        end
      elseif here then
        gfx.set(0.42, 0.42, 0.46);  gfx.circle(note_x(f), y, nr - 1, 1, 1)
      elseif S.name_mode == 2 and f > 0 then
        gfx.set(0.40, 0.40, 0.42)
        gfx.x = note_x(f) - 6; gfx.y = y - 6; gfx.drawstr(note_name(p))
      end
    end
  end

  if chord_mode then                          -- always-visible chord-mode badge
    local w = 58
    local bx, by = math.floor((gfx.w - w) / 2), T + 3
    gfx.set(0.86, 0.55, 0.22); gfx.rect(bx, by, w, 15)
    gfx.set(0.40, 0.22, 0.06); box(bx, by, w, 15)
    gfx.set(0.10, 0.10, 0.11); gfx.x = bx + 9; gfx.y = by + 3; gfx.drawstr("CHORD")
  end
end

local function monitor_hint(take)
  local tr = take and track_of(take)
  if not tr then return "" end
  local arm = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
  local mon = reaper.GetMediaTrackInfo_Value(tr, "I_RECMON")
  if arm and mon > 0 then return "" end
  return "   (arm + monitor the track to hear previews)"
end

local HINTS = "0-9 fret   up/down (W/S) string   left/right (A/D) grid-step   ctrl+A/D bar   Q chord   R rest   T tie   "
           .. "[ ] note len   shift+[ ] grid   L let-ring   ctrl+Z/Y undo    (or the strip LEN + panel GRID / NOTE buttons)"

local function draw_panel(take)
  local py = HDR_H                              -- panel sits below the permanent strip
  gfx.set(0.13, 0.13, 0.15); gfx.rect(0, py, gfx.w, PANEL_H)
  gfx.set(0.22, 0.22, 0.25); gfx.line(0, py + PANEL_H, gfx.w, py + PANEL_H)
  local _, hwnd = get_take()

  local bw, bh, gp, x0 = 60, 16, 3, 66
  caption(10, py + 11, "TUNING")
  for i = 0, #TUNINGS - 1 do
    if btn(x0 + i * (bw + gp), py + 8, bw, bh, TUNINGS[i + 1].name, S.tuning == i) then
      S.tuning = i; apply_preset(i)
    end
  end
  if S.tuning >= 2 then
    local rx = x0 + #TUNINGS * (bw + gp) + 12
    caption(rx, py + 11, "ROOT")
    if btn(rx + 38, py + 8, 38, bh, "E2", S.str_note[1] == 40) then S.str_note[1] = 40; apply_preset(S.tuning) end
    if btn(rx + 79, py + 8, 38, bh, "C2", S.str_note[1] == 36) then S.str_note[1] = 36; apply_preset(S.tuning) end
  end

  local ns = stepper(10, py + 34, 56, "STRINGS", S.num_strings, 3, MAX_STRINGS)
  if ns ~= S.num_strings then
    S.num_strings = ns
    if S.tuning >= 1 then apply_preset(S.tuning) end
  end
  S.num_frets = stepper(200, py + 34, 42, "FRETS", S.num_frets, 5, 30)
  S.vel  = stepper(360, py + 34, 60, "VEL", S.vel, 1, 127)

  -- GRID and NOTE LENGTH steppers (- shorter / + longer); quick sizes live in the strip
  caption(500, py + 38, "GRID")
  if btn(532, py + 34, 17, 16, "-", false) then set_grid(take, hwnd, true)  end
  gfx.set(0.86, 0.86, 0.89); gfx.x = 554; gfx.y = py + 38
  gfx.drawstr(take and as_frac(grid_qn(take)) or "-")
  if btn(594, py + 34, 17, 16, "+", false) then set_grid(take, hwnd, false) end

  caption(626, py + 38, "NOTE")
  if btn(660, py + 34, 17, 16, "-", false) then set_note_len(take, hwnd, true)  end
  gfx.set(0.86, 0.86, 0.89); gfx.x = 682; gfx.y = py + 38
  gfx.drawstr(take and as_frac(step_len_qn(take)) or "-")
  if btn(722, py + 34, 17, 16, "+", false) then set_note_len(take, hwnd, false) end
  if NOTELEN_OK == false then
    gfx.set(0.58, 0.50, 0.40); gfx.x = 754; gfx.y = py + 38; gfx.drawstr("(NL not settable - using grid)")
  end

  caption(10, py + 63, "INLAYS")
  if btn(66,  py + 60, 58, bh, "None",     S.inlay == 0) then S.inlay = 0 end
  if btn(127, py + 60, 58, bh, "Standard", S.inlay == 1) then S.inlay = 1 end
  if btn(188, py + 60, 58, bh, "Capsule",  S.inlay == 2) then S.inlay = 2 end
  caption(280, py + 63, "NAMES")
  if btn(330, py + 60, 46, bh, "Off",    S.name_mode == 0) then S.name_mode = 0 end
  if btn(379, py + 60, 52, bh, "Played", S.name_mode == 1) then S.name_mode = 1 end
  if btn(434, py + 60, 42, bh, "All",    S.name_mode == 2) then S.name_mode = 2 end

  caption(490, py + 63, "SPELL")                     -- sharps or flats, everywhere
  if btn(534, py + 60, 34, bh, "C#", S.accidental == 0) then S.accidental = 0 end
  if btn(571, py + 60, 34, bh, "Db", S.accidental == 1) then S.accidental = 1 end

  if btn(628, py + 60, 74, bh, "Let ring", S.let_ring == 1) then S.let_ring = 1 - S.let_ring; ring_prev = {} end

  gfx.set(0.44, 0.44, 0.47); gfx.x = 10; gfx.y = py + 82; gfx.drawstr(HINTS)
  if reaper.time_precise() - last_key_time < 3 then      -- key diagnostic (last press)
    gfx.set(0.62, 0.58, 0.35); gfx.x = gfx.w - 180; gfx.y = py + 82
    gfx.drawstr("key: " .. last_key)
  end
  gfx.set(0.50, 0.50, 0.42); gfx.x = 10; gfx.y = py + 100  -- grid / note-length diagnostic
  gfx.drawstr(string.format("dbg: gridQN=%.3f noteQN=%.3f  actions g=%d n=%d  %s",
    take and grid_qn(take) or 0,
    take and (select(3, reaper.MIDI_GetGrid(take)) or 0) or 0,
    #grid_actions, #notelen_actions, DBG))

  gfx.x = 10; gfx.y = py + PANEL_H - 20
  if take then
    gfx.set(0.55, 0.62, 0.55)
    local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    local where = ""
    if last_cursor_time then
      local beats, meas = reaper.TimeMap2_timeToBeats(0, last_cursor_time)
      where = string.format("  @ bar %d beat %.2f", meas + 1, beats + 1)
    end
    local ap = pitch_at(S.active_string, 0)
    gfx.drawstr(string.format("%s%s   string %d (%s%d)   %s%s",
      nm ~= "" and nm or "MIDI editor take", where,
      S.active_string, note_name(ap), octave(ap), step_label(take), monitor_hint(take)))
  else
    gfx.set(0.60, 0.50, 0.45)
    gfx.drawstr("No MIDI editor open - clicks/keys only preview. Open a MIDI item in the MIDI editor.")
  end
end

-- the permanent top strip: always drawn, never hidden by the settings panel,
-- and never duplicated inside it
local function draw_strip(take)
  local _, hwnd = get_take()
  gfx.set(0.12, 0.12, 0.14); gfx.rect(0, 0, gfx.w, HDR_H)

  gfx.set(0.42, 0.42, 0.45); gfx.x = 8; gfx.y = 9
  gfx.drawstr("Fretboard")

  local x = 78
  if btn(x, 5, 50, 18, "Chord", chord_mode) then
    if chord_mode and chord_dirty then step_cursor(1) end
    chord_mode = not chord_mode; chord_dirty = false; preview_off()
  end
  x = x + 58

  caption(x, 9, "SHOW"); x = x + 34
  if btn(x, 5, 36, 18, "Beat",  S.ctx_mode == 0) then S.ctx_mode = 0 end
  x = x + 38
  if btn(x, 5, 42, 18, "Beat+", S.ctx_mode == 1) then S.ctx_mode = 1 end   -- beat + next beat
  x = x + 44
  if btn(x, 5, 32, 18, "Bar",   S.ctx_mode == 2) then S.ctx_mode = 2 end
  x = x + 40

  S.chan = stepper(x, 6, 20, "CH", S.chan, 1, 16)
  x = x + 95

  caption(x, 9, "LEN"); x = x + 26                 -- quick note length: fastest -> slowest
  local cur_wn = take and (step_len_qn(take) / 4) or -1
  for _, den in ipairs({ 32, 16, 8, 4, 2, 1 }) do
    if len_btn(x, 6, den, cur_wn) then set_note_len_to(take, hwnd, 1 / den) end
    x = x + 26
  end

  if not take then
    gfx.set(0.60, 0.50, 0.45); gfx.x = x + 12; gfx.y = 9
    gfx.drawstr("- no MIDI editor")
  end
  gfx.set(0.22, 0.22, 0.25); gfx.line(0, HDR_H, gfx.w, HDR_H)
end

local function draw_toggle()
  local w, h = 68, 17
  local x, y = gfx.w - w - 6, 4
  if btn(x, y, w, h, S.panel_open == 1 and "hide" or "settings", S.panel_open == 1) then
    S.panel_open = 1 - S.panel_open
  end
end

-- ============================================================ input =====

local function handle_string_drag()
  for s = 1, S.num_strings do
    local y = str_y(s)
    if mouse.down and not consumed
       and mouse.x >= 2 and mouse.x <= L - 6
       and math.abs(mouse.y - y) <= math.max(6, str_sp * 0.4) then
      drag_s, drag_y0, drag_n0 = s, mouse.y, S.str_note[s]
      consumed = true
    end
  end
  if drag_s >= 1 and mouse.held then
    S.str_note[drag_s] = clamp(drag_n0 + math.floor((drag_y0 - mouse.y) / 7 + 0.5), 12, 108)
  elseif drag_s >= 1 and not mouse.held then
    if drag_s == 1 and S.tuning >= 2 then apply_preset(S.tuning)
    elseif S.tuning ~= 0 then S.tuning = 0 end
    drag_s = -1
  end
end

local function handle_board_click()
  if not (mouse.down and not consumed) then return end
  if mouse.y <= T - 4 or mouse.y >= gfx.h - B + 6 or mouse.x <= L - 30 then return end
  local bs, bd = 1, 1e9
  for s = 1, S.num_strings do
    local d = math.abs(str_y(s) - mouse.y)
    if d < bd then bd, bs = d, s end
  end
  local f = mouse.x < L and 0 or clamp(math.ceil((mouse.x - L) / fret_sp), 1, S.num_frets)
  local p = pitch_at(bs, f)
  if p < 0 or p > 127 then return end
  S.active_string = bs
  digit_pending = nil
  local advance = not chord_mode and (mouse.cap & 8) == 0   -- shift or chord mode: stack
  preview_on(p)
  insert_note(p, advance, bs)
  if not advance then chord_dirty = true end
end

local K = { LEFT = 1818584692, RIGHT = 1919379572, UP = 30064, DOWN = 1685026670,
            BKSP = 8, DEL = 6579564, SPACE = 32, CZ = 26, CY = 25 }

local function handle_keys(c)
  if c >= 48 and c <= 57 then type_fret(c - 48); return end
  if c ~= 0 then digit_pending = nil end   -- clear on a real non-digit key, NOT every idle frame

  -- left-hand cluster (mouse in the right hand): W/A/S/D double the arrows.
  -- Remapped before everything else, so Ctrl+A / Ctrl+D still jump by the bar.
  -- No conflict with the letter commands (Q chord, R rest, T tie, L let-ring).
  if     c == string.byte("a") or c == string.byte("A") then c = K.LEFT
  elseif c == string.byte("d") or c == string.byte("D") then c = K.RIGHT
  elseif c == string.byte("w") or c == string.byte("W") then c = K.UP
  elseif c == string.byte("s") or c == string.byte("S") then c = K.DOWN
  end

  if c == string.byte("q") or c == string.byte("Q") then      -- Dorico-style chord mode
    if chord_mode and chord_dirty then step_cursor(1) end     -- commit the chord, move on
    chord_mode = not chord_mode
    chord_dirty = false
    preview_off()
    return
  end

  if c ~= 0 then preview_off() end   -- a real non-note key ends any ringing preview
  local ctrl = (mouse.cap & 4) ~= 0
  if ctrl and (mouse.cap & 16) ~= 0 then ctrl = false end   -- AltGr = Ctrl+Alt -> plain Alt
  local take, hwnd = get_take()
  if c == K.BKSP or c == K.DEL then delete_last()
  elseif c == K.RIGHT then if ctrl then step_bar(1)  else step_cursor(1)  end
  elseif c == K.LEFT  then if ctrl then step_bar(-1) else step_cursor(-1) end
  elseif c == K.UP   then S.active_string = clamp(S.active_string + 1, 1, S.num_strings)
  elseif c == K.DOWN then S.active_string = clamp(S.active_string - 1, 1, S.num_strings)
  elseif c == string.byte("r") or c == string.byte("R") then step_cursor(1, "note")
  elseif c == string.byte("t") or c == string.byte("T") then tie_extend()
  elseif c == string.byte("l") or c == string.byte("L") then S.let_ring = 1 - S.let_ring; ring_prev = {}
  elseif c == string.byte("[") then set_note_len(take, hwnd, true)    -- note length shorter
  elseif c == string.byte("]") then set_note_len(take, hwnd, false)   -- note length longer
  elseif c == string.byte("{") then set_grid(take, hwnd, true)        -- shift+[  grid finer
  elseif c == string.byte("}") then set_grid(take, hwnd, false)       -- shift+]  grid wider
  elseif c == K.CZ then reaper.Main_OnCommand(40029, 0)
  elseif c == K.CY then reaper.Main_OnCommand(40030, 0)
  elseif c == K.SPACE then reaper.Main_OnCommand(40044, 0)
  end
end

-- ============================================================= main ======

local frame = 0
local CTX_at_cursor, CTX_playing = {}, {}

local function loop()
  local c = gfx.getchar()
  if c < 0 then return end   -- window closed (Esc/ctrl+[ = 27 no longer closes it)

  update_mouse()
  consumed = false
  if c ~= 0 and (c < 48 or c > 57) then
    last_key = string.format("%d%s%s%s", c,
      (mouse.cap & 4) ~= 0 and " ctrl" or "", (mouse.cap & 8) ~= 0 and " shift" or "",
      (mouse.cap & 16) ~= 0 and " alt" or "")
    last_key_time = reaper.time_precise()
  end
  if digit_pending and (reaper.time_precise() - digit_time) > TWODIGIT_WINDOW then digit_pending = nil end
  handle_keys(c)
  poll_live_input()

  local take = get_take()
  if take then
    if take ~= last_take then
      last_take = take
      local tr = track_of(take)
      if tr then reaper.SetOnlyTrackSelected(tr) end
    end
    sync_cursor_from_edit(take)
  else
    cursor_qn, last_take = nil, nil
  end
  S.active_string = clamp(S.active_string, 1, S.num_strings)

  frame = frame + 1
  local playing = take and ((reaper.GetPlayState() & 1) == 1)
  if take and (playing or frame % 6 == 1) then
    CTX_at_cursor, CTX_playing = scan_context(take)
  elseif not take then
    CTX_at_cursor, CTX_playing = {}, {}
  end

  layout()
  draw_board(CTX_at_cursor, CTX_playing)
  if S.panel_open == 1 then draw_panel(take) end
  draw_strip(take)
  draw_toggle()
  handle_string_drag()
  handle_board_click()

  if not chord_mode and not mouse.held
     and next(preview_notes) and reaper.time_precise() - preview_time > 0.3 then
    preview_off()
  end

  gfx.update()
  reaper.defer(loop)
end

local function on_exit()
  preview_off()
  local d, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
  reaper.SetExtState(SECT, "wnd",
    string.format("%d,%d,%d,%d,%d", d or 0, x or 120, y or 120, w or 1040, h or 320), true)
  save_state()
end

load_state()
scan_actions()
local d, x, y, w, h = 0, 120, 120, 1040, 320
local wnd = reaper.GetExtState(SECT, "wnd")
if wnd ~= "" then
  local t = {}
  for n in wnd:gmatch("[^,]+") do t[#t + 1] = tonumber(n) end
  if #t == 5 then d, x, y, w, h = t[1], t[2], t[3], t[4], t[5] end
end

gfx.init("Fretboard MIDI Controller", w, h, d, x, y)
gfx.setfont(2, "Arial", 14, string.byte("b"))   -- bold: the fretmarker fret numbers
gfx.setfont(1, "Arial", 14)                      -- regular (current)
reaper.atexit(on_exit)
loop()
