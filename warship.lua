-- Warship: Ship Pilot and Fire Control on one computer.
--
-- Both programs run at the same time, each on its own screen:
--   Pilot  flies the ship (cc-ship-pilot, keys on the Linked Typewriter)
--   Guns   fires the radar-aimed cannons (cc-fire-control)
-- Press ` (the key under Esc) on the computer to switch screens.
--
-- Typewriter keys always go to the pilot, never to the guns, so turning
-- left with A can't arm the cannons. Keys typed on the computer go to the
-- screen you're looking at.
--
-- Settings for the two programs stay where they always were:
--   pilot: ship_settings.lua / its menus (saved in ship.cfg)
--   guns:  the UPPERCASE lines at the top of fire_control.lua, or /config.lua
--
-- On every boot it downloads the newest ship.lua and fire_control.lua.
-- Fire Control's own 15-minute updater still runs, but it only restarts
-- the guns, never the whole computer, so the ship keeps flying.

SWITCH_KEY = "grave"      -- key on the computer that swaps Pilot / Guns screens
START_ON = "pilot"        -- screen shown first: "pilot" or "guns"
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ setup

VERSION = "1.0.0"
local args = { ... }
local PILOT_REPO, PILOT_FILE = "levisnakes/cc-ship-pilot", "/ship.lua"
local GUNS_REPO, GUNS_FILE = "levisnakes/cc-fire-control", "/fire_control.lua"

local function fetch(url, headers)
  if not http then return nil end
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

-- Room for a file of `need` bytes: old logs go first if the disk is full.
local function makeRoom(need)
  for _, f in ipairs({ "ship.log.old", "controller.log.old", "ship.log", "controller.log" }) do
    if fs.getFreeSpace("/") >= need + 20000 then return end
    if fs.exists(f) then fs.delete(f) print("Low on disk space - deleted " .. f) end
  end
end

-- Written next to the old file first, so a full disk can't leave half a program.
local function writeText(path, text)
  makeRoom(#text)
  local f = fs.open(path .. ".new", "w")
  f.write(text)
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".new", path)
end

local function latestSha(repo)
  local sha = fetch("https://api.github.com/repos/" .. repo .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  sha = sha and sha:match("^%s*(%x+)%s*$")
  if sha and #sha >= 40 then return sha end
end

local function raw(repo, sha, file)
  return fetch("https://raw.githubusercontent.com/" .. repo .. "/" .. (sha or "main") .. "/" .. file)
end

-- ============================================================ auto-update

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

-- This launcher: newest version with your settings, then a reboot into it.
-- Only at boot, so an update never stops the ship mid-flight.
local SELF_REPO, SELF_FILE = "levisnakes/cc-warship", "warship.lua"
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SELF_SHA_FILE = "/.version_" .. SELF_FILE
local function updateSelf()
  local sha = latestSha(SELF_REPO)
  if not sha or readText(SELF_SHA_FILE) == sha then return end
  local newSrc = raw(SELF_REPO, sha, SELF_FILE)
  if not newSrc or not load(newSrc, SELF_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, SELF_FILE) then return end
  writeText(SELF_SHA_FILE, sha)
  if merged == oldSrc then return end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  print("Warship updated to " .. sha:sub(1, 7) .. ", restarting...")
  os.reboot()
end

-- ship.lua: same check as the Ship Pilot launcher (version.txt).
local function updatePilot()
  local have = readText(PILOT_FILE)
  have = have and have:match('VERSION = "([^"]+)"')
  local sha = latestSha(PILOT_REPO)
  local latest = raw(PILOT_REPO, sha, "version.txt")
  latest = latest and latest:match("%S+")
  if not latest then
    print("Pilot: couldn't reach GitHub" .. (have and ", using v" .. have or ""))
  elseif latest == have then
    print("Pilot v" .. have .. " up to date.")
  else
    print("Pilot: downloading v" .. latest .. "...")
    local new = raw(PILOT_REPO, sha, "ship.lua")
    if new and new:match('VERSION = "([^"]+)"') == latest then
      writeText(PILOT_FILE, new)
      print("Pilot updated to v" .. latest .. ".")
    else
      print("Pilot download failed" .. (have and ", using v" .. have or ""))
    end
  end
end

-- fire_control.lua updates itself (keeping your settings); this only installs it.
local function installGuns()
  if fs.exists(GUNS_FILE) then return end
  print("Guns: downloading fire_control.lua...")
  local src = raw(GUNS_REPO, latestSha(GUNS_REPO), "fire_control.lua")
  if src and load(src, "fire_control.lua") then
    writeText(GUNS_FILE, src)
  else
    print("Guns download failed.")
  end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Warship v" .. VERSION)
if AUTO_UPDATE ~= false and http then
  pcall(updateSelf)
  pcall(updatePilot)
end
pcall(installGuns)

-- ============================================================ two programs

local native = term.current()
local W, H = native.getSize()
local TYPING = { key = true, key_up = true, char = true, paste = true }
local MOUSE = { mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true }

local progs = {
  pilot = { name = "Pilot", path = PILOT_FILE, args = args },
  guns = { name = "Guns", path = GUNS_FILE, args = {} },
}
local order = { progs.pilot, progs.guns }
local focus = progs[START_ON] or progs.pilot
local quitting = false

local function start(p)
  p.win = p.win or window.create(native, 1, 1, W, H, p == focus)
  p.win.setBackgroundColor(colors.black)
  p.win.setTextColor(colors.white)
  p.win.clear()
  p.win.setCursorPos(1, 1)
  p.term, p.filter, p.dead, p.err, p.restart = p.win, nil, false, nil, false
  -- Each program sees its own file as the running program (Fire Control
  -- updates whatever file that is), and its os.reboot() restarts just it:
  -- it parks the program (a pcall around it can't catch that) and the
  -- loop below starts it again.
  local env = {
    shell = setmetatable({ getRunningProgram = function() return p.path:sub(2) end }, { __index = shell }),
    os = setmetatable({ reboot = function()
      p.restart = true
      while true do coroutine.yield() end
    end }, { __index = os }),
  }
  p.co = coroutine.create(function()
    if not fs.exists(p.path) then error(p.path:sub(2) .. " isn't installed - check the internet and reboot", 0) end
    local fn, err = loadfile(p.path, nil, setmetatable(env, { __index = _G }))
    if not fn then error(err, 0) end
    return fn(table.unpack(p.args))
  end)
end

local function show(p)
  if focus == p then return end
  focus.win.setVisible(false)
  focus = p
  p.win.setVisible(true)
  p.win.redraw()
  p.win.restoreCursor()
end

local function stopped(p, err)
  p.dead, p.err = true, err
  local w = p.win
  w.setBackgroundColor(colors.black)
  w.setCursorPos(1, H - 2)
  w.clearLine()
  w.setTextColor(colors.red)
  w.write((p.name .. " stopped: " .. tostring(err or "finished")):match("^[^\n]*"):sub(1, W))
  w.setCursorPos(1, H - 1)
  w.clearLine()
  w.setTextColor(colors.yellow)
  w.write("Enter: restart " .. p.name)
  w.setTextColor(colors.white)
end

local function resume(p, ev)
  if p.dead then return end
  if p.filter and p.filter ~= ev[1] and ev[1] ~= "terminate" then return end
  term.redirect(p.term)
  local ok, res = coroutine.resume(p.co, table.unpack(ev, 1, ev.n))
  p.term = term.redirect(native)
  if p.restart then
    start(p)
    return resume(p, { n = 0 })
  end
  if not ok then
    stopped(p, res)
  elseif coroutine.status(p.co) == "dead" then
    stopped(p, nil)
  else
    p.filter = res
  end
end

-- Little bar in the bottom-right corner for a few seconds after a switch.
local toastUntil, toastTimer = 0, nil
local function toast()
  toastUntil = os.clock() + 3
  toastTimer = os.startTimer(3)
end
local function drawToast()
  if os.clock() >= toastUntil then return end
  local key = (keys.getName(keys[SWITCH_KEY] or 0) or SWITCH_KEY):gsub("^grave$", "`")
  local text = " " .. focus.name .. " screen - " .. key .. " switches "
  native.setCursorPos(math.max(1, W - #text + 1), H)
  native.setBackgroundColor(colors.blue)
  native.setTextColor(colors.white)
  native.write(text)
  focus.win.restoreCursor()
end

-- Typewriter keys: the computer gets the same key events from the
-- typewriter as from its own keyboard; the typewriter's held keys tell
-- them apart (seen in the last half second, for quick taps).
-- Polled every tick too, so even a quick tap is never taken for the keyboard.
local typewriter = peripheral.find("linked_typewriter")
local twSeen = {}
local pollTimer = nil
local function pollTypewriter()
  if not typewriter then return end
  local ok, codes = pcall(typewriter.getPressedKeyCodes)
  if ok and type(codes) == "table" then
    local t = os.clock()
    for _, c in ipairs(codes) do twSeen[c] = t end
  end
end
local function fromTypewriter(code)
  pollTypewriter()
  return twSeen[code] ~= nil and os.clock() - twSeen[code] < 0.5
end

local keyTo = {}        -- key code -> program that got its key press
local charTo = nil      -- program for the char event right after a key press
local eatChar = false   -- the switch key's own char

local function switchScreens()
  local old = focus
  -- Keys still held on the computer are let go on the old screen.
  for code, p in pairs(keyTo) do
    if p == old then
      keyTo[code] = nil
      resume(p, { n = 2, "key_up", code })
    end
  end
  show(old == progs.pilot and progs.guns or progs.pilot)
  toast()
end

local function route(ev)
  local name = ev[1]
  if name == "key" then
    local code = ev[2]
    if fromTypewriter(code) then
      keyTo[code], charTo = progs.pilot, progs.pilot
      return resume(progs.pilot, ev)
    end
    if code == keys[SWITCH_KEY] and not ev[3] then
      eatChar = true
      return switchScreens()
    end
    if focus.dead then
      if code == keys.enter then start(focus) resume(focus, { n = 0 }) end
      return
    end
    keyTo[code], charTo, eatChar = focus, focus, false
    return resume(focus, ev)
  elseif name == "key_up" then
    local p = keyTo[ev[2]]
    keyTo[ev[2]] = nil
    if p then return resume(p, ev) end
    if ev[2] ~= keys[SWITCH_KEY] then return resume(progs.pilot, ev) end
  elseif name == "char" then
    if eatChar then eatChar = false return end
    return resume(charTo or focus, ev)
  elseif name == "paste" or MOUSE[name] then
    return resume(focus, ev)
  elseif name == "monitor_touch" then
    -- the monitor shows the pilot's screens
    return resume(progs.pilot, ev)
  elseif name == "timer" and ev[2] == pollTimer then
    pollTypewriter()
    pollTimer = os.startTimer(0.05)
  elseif name == "timer" and ev[2] == toastTimer then
    toastTimer = nil
    focus.win.redraw()
    focus.win.restoreCursor()
  else
    if name == "terminate" then quitting = true end
    for _, p in ipairs(order) do resume(p, ev) end
  end
end

for _, p in ipairs(order) do start(p) end
focus.win.setVisible(true)
for _, p in ipairs(order) do resume(p, { n = 0 }) end
toast()
drawToast()
if typewriter then pollTimer = os.startTimer(0.05) end

while true do
  local ev = table.pack(os.pullEventRaw())
  route(ev)
  if quitting and progs.pilot.dead and progs.guns.dead then break end
  drawToast()
end

term.redirect(native)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
for _, p in ipairs(order) do
  if p.err and not tostring(p.err):find("Terminated") then print(p.name .. ": " .. tostring(p.err):match("^[^\n]*")) end
end
print("Warship stopped. Pilot: thrusters off, lift held. Guns: triggers released.")
