-- Warship: Ship Pilot and Fire Control on one computer, one screen.
--
-- The Ship Pilot runs as usual (fly from the Linked Typewriter). Its menu's
-- A tile is "Auto cannons" here instead of "Go to": arm/safe, fire, ignore,
-- and what every cannon is doing. Fire Control (cc-fire-control) runs out of
-- sight the whole time, so the radar-aimed cannons work on every screen.
-- The title bar turns red (ARMED) while the cannons are armed.
--
-- Settings for the two programs stay where they always were:
--   pilot: ship_settings.lua / its menus (saved in ship.cfg)
--   guns:  the UPPERCASE lines at the top of fire_control.lua, or /config.lua
--
-- On every boot it downloads the newest ship.lua and fire_control.lua.
-- Fire Control's own 15-minute updater still runs, but it only restarts
-- the guns, never the whole computer, so the ship keeps flying.

AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ setup

VERSION = "1.1.0"
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

-- The pilot owns the screen, keyboard and monitor. Fire Control runs out of
-- sight and hands its status and controls to the pilot's Auto cannons screen
-- through WARSHIP.guns.
local native = term.current()
local W, H = native.getSize()
local WARSHIP = { version = VERSION }

local pilot = { name = "Pilot", path = PILOT_FILE, args = args, visible = true }
local gunsP = { name = "Fire Control", path = GUNS_FILE, args = {}, visible = false }
local order = { pilot, gunsP }
local quitting, restartGuns = false, false

local resume
local function start(p)
  p.win = p.win or window.create(native, 1, 1, W, H, p.visible)
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
    WARSHIP = WARSHIP,
    shell = setmetatable({ getRunningProgram = function() return p.path:sub(2) end }, { __index = shell }),
    os = setmetatable({ reboot = function()
      p.restart = true
      while true do coroutine.yield() end
    end }, { __index = os }),
  }
  if p == gunsP then
    WARSHIP.guns, WARSHIP.gunsError, WARSHIP.gunsNote = nil, nil, nil
    -- Its messages ("not on a Sable ship") show on the Auto cannons screen.
    env.printError = function(...)
      WARSHIP.gunsNote = table.concat({ ... }, " ")
      printError(...)
    end
  end
  p.co = coroutine.create(function()
    if not fs.exists(p.path) then error(p.path:sub(2) .. " isn't installed - check the internet and reboot", 0) end
    local fn, err = loadfile(p.path, nil, setmetatable(env, { __index = _G }))
    if not fn then error(err, 0) end
    return fn(table.unpack(p.args))
  end)
end

local function stopped(p, err)
  p.dead, p.err = true, err
  if p == gunsP then
    WARSHIP.guns = nil
    WARSHIP.gunsError = tostring(err or WARSHIP.gunsNote or "it stopped")
    return
  end
  local w = p.win
  w.setBackgroundColor(colors.black)
  w.setCursorPos(1, H - 2)
  w.clearLine()
  w.setTextColor(colors.red)
  w.write((p.name .. " stopped: " .. tostring(err or "finished")):match("^[^\n]*"):sub(1, W))
  w.setCursorPos(1, H - 1)
  w.clearLine()
  w.setTextColor(colors.yellow)
  w.write("Enter: restart " .. p.name .. " (the cannons keep running)")
  w.setTextColor(colors.white)
end

function resume(p, ev)
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

-- The pilot's R on the Auto cannons screen.
WARSHIP.restartGuns = function() restartGuns = true end

local INPUT = { key = true, key_up = true, char = true, paste = true, mouse_click = true, mouse_up = true,
  mouse_drag = true, mouse_scroll = true, monitor_touch = true }

local function route(ev)
  local name = ev[1]
  if INPUT[name] then
    if pilot.dead then
      if name == "key" and ev[2] == keys.enter then start(pilot) resume(pilot, { n = 0 }) end
      return
    end
    return resume(pilot, ev)
  end
  if name == "terminate" then quitting = true end
  for _, p in ipairs(order) do resume(p, ev) end
end

for _, p in ipairs(order) do start(p) end
-- Guns first, so the pilot's first menu already shows them.
resume(gunsP, { n = 0 })
resume(pilot, { n = 0 })

while true do
  local ev = table.pack(os.pullEventRaw())
  route(ev)
  if restartGuns then
    restartGuns = false
    start(gunsP)
    resume(gunsP, { n = 0 })
  end
  if quitting and pilot.dead and gunsP.dead then break end
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
