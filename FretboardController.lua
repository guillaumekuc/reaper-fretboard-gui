--[[
  Fretboard MIDI Controller  (ReaScript / Lua)
  version 0.4.0

  A guitar-fretboard window that inserts notes straight into the take open in
  the active MIDI editor (step-entry style: each click writes a note at a
  cursor and advances it), previews them audibly, and lights up the notes the
  take already contains.

  Run it as an action (Actions > Load ReaScript...). Open a MIDI item in the
  MIDI editor, place the edit cursor, then click the fretboard.

  See docs/REASCRIPT.md for the architecture.
]]--

local SECT = "GK_FretboardController"
local MAX_STRINGS = 9

-- ============================================================= model =====

local NAMES = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }

-- index 1 == "Custom"; rule is nil (custom), "standard", or a semitone interval
local TUNINGS = {
  { name = "Custom",   rule = nil     },
  { name = "Standard", rule = "std"   },
  { name = "4ths",     rule = 5       },
  { name = "5ths",     rule = 7       },
  { name = "Maj 3rds", rule = 4       },
  { name = "Min 3rds", rule = 3       },
  { name = "Tritone",  rule = 6       },
}

local STEP_LABELS = { "Grid", "1/4", "1/8", "1/16", "1/32" }
local STEP_QN     = {   nil,   1.0,  0.5,  0.25,   0.125  }   -- nil == follow editor grid

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
local function note_name(n) return NAMES[(n % 12) + 1] end
local function octave(n) return math.floor(n / 12) - 1 end

-- ============================================================= state =====

local S = {
  num_strings  = 6,
  num_frets    = 22,
  tuning       = 1,          -- 0..#TUNINGS-1  (0 == Custom)
  inlay        = 2,          -- 0 none / 1 standard / 2 capsule
  name_mode    = 1,          -- 0 off / 1 played / 2 all
  chan         = 1,          -- 1..16
  vel          = 100,
  step_mode    = 0,          -- index into STEP_LABELS (0-based)
  auto_advance = 1,
  panel_open   = 1,
  str_note     = { 40, 45, 50, 55, 59, 64, 35, 30, 25 },
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
    if type(v) == "number" then v = math.floor(v) end
    reaper.SetExtState(SECT, k, tostring(v), true)
  end
  set("num_strings", S.num_strings) set("num_frets", S.num_frets)
  set("tuning", S.tuning)           set("inlay", S.inlay)
  set("name_mode", S.name_mode)     set("chan", S.chan)
  set("vel", S.vel)                 set("step_mode", S.step_mode)
  set("auto_advance", S.auto_advance) set("panel_open", S.panel_open)
  set("str_note", table.concat(S.str_note, ","))
end

local function load_state()
  local function num(k, d)
    local v = reaper.GetExtState(SECT, k)
    return v ~= "" and tonumber(v) or d
  end
  S.num_strings  = num("num_strings", S.num_strings)
  S.num_frets    = num("num_frets", S.num_frets)
  S.tuning       = num("tuning", S.tuning)
  S.inlay        = num("inlay", S.inlay)
  S.name_mode    = num("name_mode", S.name_mode)
  S.chan         = num("chan", S.chan)
  S.vel          = num("vel", S.vel)
  S.step_mode    = num("step_mode", S.step_mode)
  S.auto_advance = num("auto_advance", S.auto_advance)
  S.panel_open   = num("panel_open", S.panel_open)
  local sn = reaper.GetExtState(SECT, "str_note")
  if sn ~= "" then
    local t = {}
    for x in sn:gmatch("[^,]+") do t[#t + 1] = tonumber(x) end
    if #t >= 3 then S.str_note = t end
  end
  for i = 1, MAX_STRINGS do S.str_note[i] = S.str_note[i] or (25 + i * 3) end
  S.num_strings = clamp(math.floor(S.num_strings), 3, MAX_STRINGS)
  S.num_frets   = clamp(math.floor(S.num_frets), 5, 30)
end

-- ========================================================= midi i/o ======

local cursor_qn        -- our step cursor, in project quarter-notes (nil = uninitialised)
local last_cursor_time -- edit-cursor time we last set, to detect the user moving it
local history = {}     -- stack of { take, sppq, pitch, chan, prev_qn } for backspace
local preview_pitch

local function get_take()
  local he = reaper.MIDIEditor_GetActive()
  if not he then return nil end
  local tk = reaper.MIDIEditor_GetTake(he)
  if tk and reaper.ValidatePtr2(0, tk, "MediaItem_Take*") then return tk, he end
  return nil
end

local function step_len_qn(take)
  local q = STEP_QN[S.step_mode + 1]
  if q then return q end
  local grid, _, notelen = reaper.MIDI_GetGrid(take)   -- QN
  if notelen and notelen > 0 then return notelen end
  return grid > 0 and grid or 0.25
end

local function sync_cursor_from_edit(take)
  local t = reaper.GetCursorPosition()
  if not last_cursor_time or math.abs(t - last_cursor_time) > 1e-6 then
    cursor_qn = reaper.TimeMap2_timeToQN(0, t)
    if cursor_qn and STEP_QN[S.step_mode + 1] == nil then
      -- snap to the editor grid when following it
      local g = step_len_qn(take)
      cursor_qn = math.floor(cursor_qn / g + 0.5) * g
    end
    last_cursor_time = reaper.TimeMap2_QNToTime(0, cursor_qn)
  end
end

local function preview_off()
  if preview_pitch then
    reaper.StuffMIDIMessage(0, 0x80 + (S.chan - 1), preview_pitch, 0)
    preview_pitch = nil
  end
end

local function preview_on(p)
  preview_off()
  reaper.StuffMIDIMessage(0, 0x90 + (S.chan - 1), p, S.vel)
  preview_pitch = p
end

local function insert_note(pitch, advance)
  local take = get_take()
  if not take then return false end
  if not cursor_qn then sync_cursor_from_edit(take) end
  local step  = step_len_qn(take)
  local prev  = cursor_qn
  local sppq  = reaper.MIDI_GetPPQPosFromProjQN(take, cursor_qn)
  local eppq  = reaper.MIDI_GetPPQPosFromProjQN(take, cursor_qn + step)
  reaper.Undo_BeginBlock()
  reaper.MIDI_InsertNote(take, false, false, sppq, eppq, S.chan - 1, pitch, S.vel, false)
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock("Fretboard: insert " .. note_name(pitch) .. octave(pitch), -1)
  history[#history + 1] = { take = take, sppq = sppq, pitch = pitch, chan = S.chan - 1, prev = prev }
  if advance then
    cursor_qn = cursor_qn + step
    last_cursor_time = reaper.TimeMap2_QNToTime(0, cursor_qn)
    reaper.SetEditCurPos(last_cursor_time, false, false)
  end
  return true
end

local function delete_last()
  local h = history[#history]
  if not h then return end
  history[#history] = nil
  if reaper.ValidatePtr2(0, h.take, "MediaItem_Take*") then
    local _, notes = reaper.MIDI_CountEvts(h.take)
    for i = notes - 1, 0, -1 do
      local ok, _, _, sppq, _, chan, pitch = reaper.MIDI_GetNote(h.take, i)
      if ok and pitch == h.pitch and chan == h.chan and math.abs(sppq - h.sppq) < 1 then
        reaper.Undo_BeginBlock()
        reaper.MIDI_DeleteNote(h.take, i)
        reaper.MIDI_Sort(h.take)
        reaper.Undo_EndBlock("Fretboard: remove note", -1)
        break
      end
    end
  end
  cursor_qn = h.prev
  last_cursor_time = reaper.TimeMap2_QNToTime(0, cursor_qn)
  reaper.SetEditCurPos(last_cursor_time, false, false)
end

-- pitch -> highlight state for the board:  1 = in take, 2 = sounding now
local function scan_take()
  local present, playing = {}, {}
  local take = get_take()
  if not take then return present, playing, nil end
  local _, notes = reaper.MIDI_CountEvts(take)
  local playing_ppq
  if (reaper.GetPlayState() & 1) == 1 then
    playing_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, reaper.GetPlayPosition())
  end
  for i = 0, notes - 1 do
    local ok, _, muted, sppq, eppq, _, pitch = reaper.MIDI_GetNote(take, i)
    if ok and not muted then
      present[pitch] = true
      if playing_ppq and sppq <= playing_ppq and eppq > playing_ppq then
        playing[pitch] = true
      end
    end
  end
  return present, playing, take
end

-- ============================================================ widgets ====

local mouse = { x = 0, y = 0, cap = 0, px = 0, py = 0, pcap = 0,
                down = false, up = false, held = false }
local consumed = false

local function update_mouse()
  mouse.px, mouse.py, mouse.pcap = mouse.x, mouse.y, mouse.cap
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
  gfx.line(x, y, x + w, y);         gfx.line(x, y + h, x + w, y + h)
  gfx.line(x, y, x, y + h);         gfx.line(x + w, y, x + w, y + h)
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

-- ============================================================ drawing ====

local L, R, T, B, boardw, boardh, fret_sp, str_sp, nr, ir, header_h
local PANEL_H = 132
local drag_s, drag_y0, drag_n0 = -1, 0, 0

local function str_y(s)  return gfx.h - B - (s - 1) * str_sp end
local function fret_x(f) return L + f * fret_sp end
local function note_x(f) if f <= 0 then return L - 24 end return L + (f - 0.5) * fret_sp end

local function layout()
  header_h = (S.panel_open == 1) and PANEL_H or 26
  L, R, T, B = 46, 16, header_h + 24, 18
  boardw  = gfx.w - L - R
  boardh  = gfx.h - T - B
  fret_sp = boardw / S.num_frets
  str_sp  = S.num_strings > 1 and boardh / (S.num_strings - 1) or boardh
  nr = clamp(math.min(fret_sp, str_sp) * 0.34, 4, 11)
  ir = math.max(3, nr * 0.55)
end

local function draw_board(present, playing)
  gfx.set(0.11, 0.11, 0.12); gfx.rect(0, 0, gfx.w, gfx.h)
  gfx.set(0.16, 0.16, 0.17); gfx.rect(L, T, boardw, boardh)

  -- inlays
  if S.inlay == 1 then
    local midy = (str_y(1) + str_y(S.num_strings)) * 0.5
    gfx.set(0.30, 0.30, 0.31)
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
    gfx.set(0.30, 0.30, 0.31)
    for f = 1, S.num_frets do
      local s = 1
      while s <= S.num_strings do
        local pc  = pitch_at(s, f) % 12
        local pcu = (s + 1 <= S.num_strings) and pitch_at(s + 1, f) % 12 or -1
        local tgt = pc == 0 or pc == 5
        local cap = tgt and ((pc == 0 and pcu == 5) or (pc == 5 and pcu == 0))
        if cap then
          local cx, y0, y1, rr = note_x(f), str_y(s), str_y(s + 1), ir + 1
          gfx.rect(cx - rr, math.min(y0, y1), rr * 2, math.abs(y1 - y0))
          gfx.circle(cx, y0, rr, 1, 1); gfx.circle(cx, y1, rr, 1, 1)
          s = s + 2
        else
          if tgt then gfx.circle(note_x(f), str_y(s), ir, 1, 1) end
          s = s + 1
        end
      end
    end
  end

  -- frets + numbers
  for f = 0, S.num_frets do
    gfx.set(f == 0 and 0.90 or 0.42, f == 0 and 0.90 or 0.42, f == 0 and 0.90 or 0.44)
    local x = fret_x(f)
    gfx.line(x, T, x, gfx.h - B)
    if f == 0 then gfx.line(x + 1, T, x + 1, gfx.h - B) end
    if f > 0 then
      gfx.set(0.45, 0.45, 0.47); gfx.x = note_x(f) - 6; gfx.y = T - 16
      gfx.drawstr(tostring(f))
    end
  end

  -- strings, open-note labels, markers
  for s = 1, S.num_strings do
    local y = str_y(s)
    gfx.set(0.55, 0.55, 0.56); gfx.line(L, y, gfx.w - R, y)

    local op = pitch_at(s, 0)
    if s == drag_s then gfx.set(0.98, 0.98, 1.0) else gfx.set(0.72, 0.72, 0.74) end
    gfx.x = 4; gfx.y = y - 7; gfx.drawstr(note_name(op) .. octave(op))

    for f = 0, S.num_frets do
      local p = pitch_at(s, f)
      local prev = (p == preview_pitch)
      local play = playing[p]
      local pres = present[p]
      if prev or play or pres then
        if prev then
          gfx.set(1, 1, 1);            gfx.circle(note_x(f), y, nr + 1, 1, 1)
          gfx.set(0.30, 0.30, 0.32);   gfx.circle(note_x(f), y, nr + 1, 0, 1)
        elseif play then
          gfx.set(0.88, 0.88, 0.90);   gfx.circle(note_x(f), y, nr, 1, 1)
          gfx.set(0.12, 0.12, 0.13);   gfx.circle(note_x(f), y, nr, 0, 1)
        else
          gfx.set(0.34, 0.34, 0.37);   gfx.circle(note_x(f), y, nr - 1, 1, 1)
        end
        if S.name_mode > 0 and (prev or play) then
          gfx.set(0.12, 0.12, 0.13)
          gfx.x = note_x(f) - 7; gfx.y = y - 6; gfx.drawstr(note_name(p))
        end
      elseif S.name_mode == 2 and f > 0 then
        gfx.set(0.40, 0.40, 0.42)
        gfx.x = note_x(f) - 6; gfx.y = y - 6; gfx.drawstr(note_name(p))
      end
    end
  end
end

local function draw_panel(take)
  gfx.set(0.13, 0.13, 0.15); gfx.rect(0, 0, gfx.w, PANEL_H)
  gfx.set(0.22, 0.22, 0.25); gfx.line(0, PANEL_H, gfx.w, PANEL_H)

  local bw, bh, gp, x0 = 60, 16, 3, 66
  caption(10, 11, "TUNING")
  for i = 0, #TUNINGS - 1 do
    if btn(x0 + i * (bw + gp), 8, bw, bh, TUNINGS[i + 1].name, S.tuning == i) then
      S.tuning = i; apply_preset(i)
    end
  end
  if S.tuning >= 2 then
    local rx = x0 + #TUNINGS * (bw + gp) + 12
    caption(rx, 11, "ROOT")
    if btn(rx + 38, 8, 38, bh, "E2", S.str_note[1] == 40) then S.str_note[1] = 40; apply_preset(S.tuning) end
    if btn(rx + 79, 8, 38, bh, "C2", S.str_note[1] == 36) then S.str_note[1] = 36; apply_preset(S.tuning) end
  end

  local ns = stepper(10, 34, 56, "STRINGS", S.num_strings, 3, MAX_STRINGS)
  if ns ~= S.num_strings then
    S.num_strings = ns
    if S.tuning >= 1 then apply_preset(S.tuning) end
  end
  S.num_frets = stepper(200, 34, 42, "FRETS", S.num_frets, 5, 30)

  caption(360, 38, "STEP")
  for i = 0, #STEP_LABELS - 1 do
    if btn(400 + i * 46, 34, 44, bh, STEP_LABELS[i + 1], S.step_mode == i) then S.step_mode = i end
  end

  caption(10, 63, "INLAYS")
  if btn(66,  60, 58, bh, "None",     S.inlay == 0) then S.inlay = 0 end
  if btn(127, 60, 58, bh, "Standard", S.inlay == 1) then S.inlay = 1 end
  if btn(188, 60, 58, bh, "Capsule",  S.inlay == 2) then S.inlay = 2 end
  caption(280, 63, "NAMES")
  if btn(330, 60, 50, bh, "Off",    S.name_mode == 0) then S.name_mode = 0 end
  if btn(383, 60, 50, bh, "Played", S.name_mode == 1) then S.name_mode = 1 end
  if btn(436, 60, 50, bh, "All",    S.name_mode == 2) then S.name_mode = 2 end

  S.chan = stepper(10, 86, 56, "MIDI CH", S.chan, 1, 16)
  S.vel  = stepper(200, 86, 60, "VELOCITY", S.vel, 1, 127)
  if btn(360, 86, 110, bh, S.auto_advance == 1 and "Auto-advance: on" or "Auto-advance: off",
         S.auto_advance == 1) then
    S.auto_advance = 1 - S.auto_advance
  end

  -- status line
  gfx.x = 10; gfx.y = PANEL_H - 20
  if take then
    gfx.set(0.55, 0.62, 0.55)
    local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    local where = ""
    if last_cursor_time then
      local beats, meas = reaper.TimeMap2_timeToBeats(0, last_cursor_time)
      where = string.format("   @ bar %d  beat %.2f", meas + 1, beats + 1)
    end
    local mode = (S.auto_advance == 1) and "step" or "chord"
    gfx.drawstr("Target: " .. (nm ~= "" and nm or "MIDI editor take")
      .. where .. "   (" .. mode .. ", " .. STEP_LABELS[S.step_mode + 1] .. ")")
  else
    gfx.set(0.60, 0.50, 0.45)
    gfx.drawstr("No MIDI editor open - clicks only preview. Open a MIDI item in the MIDI editor.")
  end
end

local function draw_header()
  gfx.set(0.40, 0.40, 0.43); gfx.x = 8; gfx.y = 6
  gfx.drawstr("Fretboard MIDI Controller  -  click a fret to insert at the edit cursor")
  gfx.set(0.22, 0.22, 0.25); gfx.line(0, header_h, gfx.w, header_h)
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
  -- nearest string
  local bs, bd = 1, 1e9
  for s = 1, S.num_strings do
    local d = math.abs(str_y(s) - mouse.y)
    if d < bd then bd, bs = d, s end
  end
  -- fret
  local f = mouse.x < L and 0 or clamp(math.ceil((mouse.x - L) / fret_sp), 1, S.num_frets)
  local p = pitch_at(bs, f)
  if p < 0 or p > 127 then return end
  preview_on(p)
  local advance = S.auto_advance == 1 and (mouse.cap & 8) == 0   -- shift = chord (no advance)
  insert_note(p, advance)
end

local function handle_keys(c)
  if c == 8 or c == 6579564 then delete_last()          -- backspace / delete
  elseif c == 32 then reaper.Main_OnCommand(40044, 0)   -- space: play/stop
  end
end

-- ============================================================= main ======

local frame = 0
local VIZ_present, VIZ_playing = {}, {}

local function loop()
  local c = gfx.getchar()
  if c < 0 or c == 27 then return end   -- window closed or Esc

  update_mouse()
  consumed = false
  handle_keys(c)

  local take = get_take()
  if take then sync_cursor_from_edit(take) else cursor_qn = nil end

  frame = frame + 1
  local playing = take and ((reaper.GetPlayState() & 1) == 1)
  if playing or frame % 8 == 1 then
    VIZ_present, VIZ_playing = scan_take()
  end

  layout()
  draw_board(VIZ_present, VIZ_playing)
  if S.panel_open == 1 then draw_panel(take) else draw_header() end
  draw_toggle()
  handle_string_drag()
  handle_board_click()

  if not mouse.held then preview_off() end

  gfx.update()
  reaper.defer(loop)
end

local function on_exit()
  preview_off()
  local d, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
  reaper.SetExtState(SECT, "wnd",
    string.format("%d,%d,%d,%d,%d", d or 0, x or 120, y or 120, w or 1040, h or 340), true)
  save_state()
end

load_state()
local d, x, y, w, h = 0, 120, 120, 1040, 340
local wnd = reaper.GetExtState(SECT, "wnd")
if wnd ~= "" then
  local t = {}
  for n in wnd:gmatch("[^,]+") do t[#t + 1] = tonumber(n) end
  if #t == 5 then d, x, y, w, h = t[1], t[2], t[3], t[4], t[5] end
end

gfx.init("Fretboard MIDI Controller", w, h, d, x, y)
gfx.setfont(1, "Arial", 14)
reaper.atexit(on_exit)
loop()
