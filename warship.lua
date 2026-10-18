-- Warship: Ship Pilot and Fire Control on one computer, one screen.
--
-- The Ship Pilot runs as usual (fly from the Linked Typewriter). Its menu's
-- A tile is "Auto cannons" here instead of "Go to": what every cannon is
-- doing. Hold F on the typewriter to fire. Fire Control (cc-fire-control) runs out of
-- sight the whole time, so the radar-aimed cannons work on every screen.
-- The title bar shows FIRING while the fire key is held.
--
-- Captain's display: a wide monitor with a DirectGPU on the network shows
-- flight (heading, speed, height, throttle, lift, fuel, autopilot), a
-- radar with the targets, the weapons, and a warning strip.
--
-- Settings for the two programs stay where they always were:
--   pilot: ship_settings.lua / its menus (saved in ship.cfg)
--   guns:  the UPPERCASE lines at the top of fire_control.lua, or /config.lua
--
-- On every boot it downloads the newest ship.lua and fire_control.lua.
-- Fire Control's own 15-minute updater still runs, but it only restarts
-- the guns, never the whole computer, so the ship keeps flying.

CAPTAIN_MONITOR = nil     -- monitor for the captain's display (needs a DirectGPU); nil = the widest one
CAPTAIN_FPS = 5           -- captain's display frames per second
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ setup

VERSION = "1.4.0"
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
local displayP = { name = "Captain's display", visible = false }
local order = { pilot, gunsP, displayP }
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
  if p.fn then p.co = coroutine.create(p.fn) return end
  p.co = coroutine.create(function()
    if not fs.exists(p.path) then error(p.path:sub(2) .. " isn't installed - check the internet and reboot", 0) end
    local fn, err = loadfile(p.path, nil, setmetatable(env, { __index = _G }))
    if not fn then error(err, 0) end
    return fn(table.unpack(p.args))
  end)
end

local function stopped(p, err)
  p.dead, p.err = true, err
  if p == displayP then return end
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

-- ============================================================ captain's display

-- A DirectGPU picture on a wide monitor: flight on the left, radar in the
-- middle, weapons on the right, warnings along the bottom.
local cap = { W = 0, H = 0, fails = 0 }
local FONT = "SansSerif"
local BG, PANEL, LINE = { 12, 14, 20 }, { 24, 28, 38 }, { 48, 54, 70 }
local WHITE, MUTED, DIM = { 235, 238, 245 }, { 150, 158, 175 }, { 90, 98, 115 }
local GREEN, RED, ORANGE, YELLOW, CYAN, BLUE = { 70, 200, 110 }, { 230, 70, 70 }, { 240, 150, 50 },
  { 245, 210, 80 }, { 80, 200, 230 }, { 70, 130, 230 }

local function I(v) return math.floor(v + 0.5) end
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

function cap.findMonitor()
  if CAPTAIN_MONITOR then return CAPTAIN_MONITOR end
  -- the widest monitor (not a Create Radar monitor, which is also a "monitor")
  local best, bestScore = nil, -1
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") and not peripheral.hasType(n, "create_radar:monitor") then
      local radarMon = false
      for _, m in ipairs(peripheral.getMethods(n) or {}) do if m == "getSelectedTrackId" then radarMon = true end end
      local ok, w, h = pcall(peripheral.call, n, "getSize")
      if not radarMon and ok and type(w) == "number" and h and h > 0 then
        local score = w / h * 10000 + w * h
        if score > bestScore then best, bestScore = n, score end
      end
    end
  end
  return best
end

function cap.setup()
  local gpu = peripheral.find("directgpu")
  local mon = cap.findMonitor()
  if not gpu or not mon then return false end
  local ok, id = pcall(gpu.autoDetectAndCreateDisplay, mon, 1)
  if not ok or not id then return false end
  local info = gpu.getDisplayInfo(id)
  -- Small monitors get a higher resolution so the text stays sharp.
  if info.pixelHeight < 300 then
    local res = math.min(4, math.ceil(300 / info.pixelHeight))
    local ok2, id2 = pcall(gpu.autoDetectAndCreateDisplay, mon, res)
    if ok2 and id2 then id, info = id2, gpu.getDisplayInfo(id2) end
  end
  pcall(gpu.setDisplayPersistent, id, true)
  cap.gpu, cap.id, cap.W, cap.H, cap.mon = gpu, id, info.pixelWidth, info.pixelHeight, mon
  cap.widths = {}
  return true
end

function cap.rect(x, y, w, h, c)
  if w <= 0 or h <= 0 then return end
  cap.gpu.fillRect(cap.id, I(x), I(y), I(w), I(h), c[1], c[2], c[3])
end
function cap.text(s, x, y, c, size, style)
  cap.gpu.drawText(cap.id, s, I(x), I(y), c[1], c[2], c[3], FONT, I(size), style or "plain")
end
function cap.tw(s, size, style)
  local key = s .. "|" .. I(size) .. "|" .. (style or "plain")
  local w = cap.widths[key]
  if not w then
    local ok, m = pcall(cap.gpu.measureText, s, FONT, I(size), style or "plain")
    w = (ok and m and m.width) or #s * size * 0.55
    cap.widths[key] = w
  end
  return w
end
function cap.textR(s, right, y, c, size, style) cap.text(s, right - cap.tw(s, size, style), y, c, size, style) end
function cap.textC(s, cx, y, c, size, style) cap.text(s, cx - cap.tw(s, size, style) / 2, y, c, size, style) end
function cap.fit(s, maxW, size, style)
  if cap.tw(s, size, style) <= maxW then return s end
  while #s > 1 and cap.tw(s .. "..", size, style) > maxW do s = s:sub(1, -2) end
  return s .. ".."
end
function cap.line(x1, y1, x2, y2, c) cap.gpu.drawLine(cap.id, I(x1), I(y1), I(x2), I(y2), c[1], c[2], c[3]) end
function cap.circle(x, y, r, c, filled) cap.gpu.drawCircle(cap.id, I(x), I(y), I(math.max(1, r)), c[1], c[2], c[3], filled) end

-- A rounded-looking label: colored box with text.
function cap.pill(s, right, y, c, size)
  local pad = size * 0.45
  local w = cap.tw(s, size, "bold") + pad * 2
  cap.rect(right - w, y, w, size + pad, c)
  cap.text(s, right - w + pad, y + pad / 2, BG, size, "bold")
  return right - w
end

-- A bar with a label on the left and the value on the right.
function cap.bar(x, y, w, label, value, frac, c, sz)
  cap.text(label, x, y, MUTED, sz)
  cap.textR(value, x + w, y, WHITE, sz, "bold")
  local by = y + sz * 1.25
  cap.rect(x, by, w, sz * 0.45, LINE)
  cap.rect(x, by, w * math.max(0, math.min(1, frac or 0)), sz * 0.45, c)
end

-- Compass heading (0 = north) from the pilot's angle (0 = east, radians).
local function compass(h) return (math.deg(h) + 90) % 360 end
local POINTS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function pointOf(d) return POINTS[math.floor((d + 22.5) % 360 / 45) + 1] end
local function timeText(s)
  if not s then return "" end
  if s >= 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  if s >= 60 then return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60)) end
  return string.format("%ds", math.floor(s))
end

function cap.flight(x, y, w, h, ps, sz)
  local pad = sz.pad
  cap.rect(x, y, w, h, PANEL)
  cap.text("FLIGHT", x + pad, y + pad, MUTED, sz.small, "bold")
  if not ps then
    cap.text("Pilot not running", x + pad, y + pad * 2 + sz.small, RED, sz.med, "bold")
    return
  end
  local bc = ({ HOVER = GREEN, CLIMB = CYAN, DESCEND = ORANGE, PARKED = DIM, LANDED = DIM })[ps.badge] or BLUE
  local lock = cap.lockState(ps)
  local pillText, pillC = ps.badge, bc
  if lock == "locked" then pillText, pillC = "LOCKED", CYAN elseif lock == "stopping" then pillText, pillC = "STOPPING", YELLOW end
  cap.pill(pillText, x + w - pad, y + pad * 0.6, pillC, sz.small)

  -- Heading tape: 120 degrees across, ticks every 10, labels every 30.
  local ty, th = y + pad * 2 + sz.small, sz.med * 1.9
  cap.rect(x + pad, ty, w - pad * 2, th, BG)
  local cx = x + w / 2
  if ps.heading then
    local hd = compass(ps.heading)
    local span = (w - pad * 2) / 120
    for d = math.floor((hd - 60) / 10) * 10, hd + 60, 10 do
      local px = cx + (d - hd) * span
      if px > x + pad + 2 and px < x + w - pad - 2 then
        local major = d % 30 == 0
        cap.line(px, ty + th - (major and th * 0.35 or th * 0.2), px, ty + th - 2, major and WHITE or DIM)
        if major then
          local dd = d % 360
          local lbl = dd % 90 == 0 and POINTS[math.floor(dd / 45) + 1] or tostring(dd)
          cap.textC(lbl, px, ty + th * 0.08, lbl == "N" and RED or MUTED, sz.tiny, "bold")
        end
      end
    end
    local v = string.format("%03d", I(hd) % 360)
    local bw = cap.tw(v, sz.med, "bold") + pad
    cap.rect(cx - bw / 2, ty + th * 0.08, bw, sz.med * 1.05, YELLOW)
    cap.textC(v, cx, ty + th * 0.08, BG, sz.med, "bold")
    cap.line(cx, ty + th * 0.6, cx, ty + th - 2, YELLOW)
  else
    cap.textC("no heading (needs CC: Sable)", cx, ty + th * 0.3, DIM, sz.small)
  end

  -- Speed, height, climb
  local ry = ty + th + pad
  local col = (w - pad * 2) / 3
  local speed = math.sqrt((ps.vx or 0) ^ 2 + (ps.vz or 0) ^ 2)
  local vals = {
    { "SPEED  b/s", string.format("%.1f", speed), WHITE },
    { "HEIGHT  y", ps.alt and string.format("%.0f", ps.alt) or "-", WHITE },
    { "CLIMB  b/s", string.format("%+.1f", ps.vy or 0), math.abs(ps.vy or 0) < 0.3 and MUTED or (ps.vy > 0 and CYAN or ORANGE) },
  }
  for i, v in ipairs(vals) do
    local vx = x + pad + (i - 1) * col
    cap.text(v[1], vx, ry, MUTED, sz.tiny)
    cap.text(cap.fit(v[2], col - pad, sz.big, "bold"), vx, ry + sz.tiny * 1.2, v[3], sz.big, "bold")
  end

  -- Bars
  local by = ry + sz.tiny * 1.4 + sz.big * 1.2
  local bw = (w - pad * 3) / 2
  local thr = ps.throttle or 0
  cap.bar(x + pad, by, bw, "THROTTLE", string.format("%d/15", I(thr)) .. (ps.boost and " BOOST" or ""), thr / 15,
    ps.boost and ORANGE or YELLOW, sz.small)
  cap.bar(x + pad * 2 + bw, by, bw, "LIFT", string.format("%d/256", I(ps.lift or 0)), (ps.lift or 0) / 256, CYAN, sz.small)
  by = by + sz.small * 2.2
  if ps.fuel then
    local f = ps.fuel
    local frac = f.cap and f.cap > 0 and f.amount / f.cap or nil
    local fc = f.low and RED or ((frac and frac < 0.2) and ORANGE or GREEN)
    local amt = f.amount >= 10000 and string.format("%.1fk mB", f.amount / 1000) or string.format("%d mB", f.amount)
    cap.bar(x + pad, by, w - pad * 2, "FUEL", amt .. (f.left and ("   " .. timeText(f.left) .. " left") or ""), frac or 1, fc, sz.small)
  else
    cap.text("FUEL", x + pad, by, MUTED, sz.small)
    cap.textR("no tanks connected", x + w - pad, by, DIM, sz.small)
  end

  -- What's flying the ship
  local my = y + h - pad - sz.small
  local mode, mc
  if lock then
    -- Stop & hold (B) or the autopilot holding a spot: a bar you can't miss.
    local title, tc, bgc = "LOCKED IN PLACE", CYAN, { 20, 70, 85 }
    if lock == "stopping" then title, tc, bgc = "STOPPING TO LOCK", YELLOW, { 75, 65, 20 }
    elseif lock == "nosetup" then title, tc, bgc = "CAN'T LOCK", ORANGE, { 80, 45, 15 } end
    cap.rect(x + pad * 0.5, my - pad * 0.3, w - pad, sz.small + pad * 0.6, bgc)
    cap.text(title, x + pad, my, tc, sz.small, "bold")
    local st = ps.nav.status or ""
    local off = st:match("%(([%d.]+) off%)")
    st = off and ("drift " .. off) or st:gsub("^stopping, ", ""):gsub("run Smart setup %(S%) first", "run Smart setup")
      :gsub("needs Smart setup first", "run Smart setup")
    local lw = cap.tw(title, sz.small, "bold") + pad * 2
    cap.textR(cap.fit(st, w - lw - pad * 2, sz.small), x + w - pad, my, WHITE, sz.small)
    return
  end
  if ps.nav then
    mode = ps.nav.mode == "brake" and "STOP & HOLD" or ("AUTOPILOT " .. (ps.nav.x and string.format("> %d %d", ps.nav.x, ps.nav.z) or ""))
    mc = GREEN
    if ps.nav.status then mode = mode .. "  " .. ps.nav.status end
  elseif ps.smart then
    mode, mc = ps.smartReady and "SMART  heading hold" or "SMART  needs Smart setup", ps.smartReady and GREEN or ORANGE
  else
    mode, mc = "MANUAL", MUTED
  end
  cap.text(cap.fit(mode, w - pad * 2, sz.small, "bold"), x + pad, my, mc, sz.small, "bold")
end

function cap.radar(x, y, w, h, ps, gs, sz)
  local pad = sz.pad
  cap.rect(x, y, w, h, PANEL)
  cap.text("RADAR", x + pad, y + pad, MUTED, sz.small, "bold")
  local up = ps and ps.heading
  cap.textR(up and "HEADING UP" or "NORTH UP", x + w - pad, y + pad, DIM, sz.tiny, "bold")
  local r = math.min(w - pad * 2, h - pad * 3 - sz.small) / 2
  local cx, cy = x + w / 2, y + pad * 2 + sz.small + r
  cap.circle(cx, cy, r, BG, true)
  cap.circle(cx, cy, r, LINE, false)
  cap.circle(cx, cy, r * 2 / 3, LINE, false)
  cap.circle(cx, cy, r / 3, LINE, false)
  cap.line(cx - r, cy, cx + r, cy, LINE)
  cap.line(cx, cy - r, cx, cy + r, LINE)
  local range = gs and gs.maxRange or 400
  cap.text(string.format("%d", range), cx + r * 0.72, cy + r * 0.72, DIM, sz.tiny)
  cap.text(string.format("%d", I(range / 3)), cx + r * 0.24 + 2, cy + r * 0.24, DIM, sz.tiny)

  -- world offset -> screen (heading up: the nose points up)
  local h0 = up and ps.heading or -math.pi / 2
  local fx, fz = math.cos(h0), math.sin(h0)
  local function toScreen(dx, dz)
    local f = dx * fx + dz * fz
    local rt = dx * -fz + dz * fx
    return rt, -f
  end
  -- north marker on the rim
  local nx, ny = toScreen(0, -1)
  cap.textC("N", cx + nx * (r - sz.tiny), cy + ny * (r - sz.tiny) - sz.tiny / 2, RED, sz.tiny, "bold")

  -- own ship: a triangle pointing at the nose
  local s = math.max(4, r * 0.07)
  cap.line(cx, cy - s * 1.6, cx - s, cy + s, CYAN)
  cap.line(cx, cy - s * 1.6, cx + s, cy + s, CYAN)
  cap.line(cx - s, cy + s, cx + s, cy + s, CYAN)
  if cap.locked(ps) then
    local b = s * 2.6
    cap.line(cx - b, cy - b, cx + b, cy - b, CYAN)
    cap.line(cx + b, cy - b, cx + b, cy + b, CYAN)
    cap.line(cx + b, cy + b, cx - b, cy + b, CYAN)
    cap.line(cx - b, cy + b, cx - b, cy - b, CYAN)
  end

  if not gs then
    cap.textC("guns offline", cx, cy + r * 0.35, DIM, sz.small)
    return
  end
  if not gs.radar then
    cap.textC("NO RADAR", cx, cy + r * 0.3, RED, sz.med, "bold")
  end
  for i = #gs.targets, 1, -1 do
    local t = gs.targets[i]
    if t.dx then
      local sx, sy = toScreen(t.dx, t.dz)
      local d = math.sqrt(sx * sx + sy * sy)
      local k = r / range
      if d * k > r - 4 then k = (r - 4) / d end
      local px, py = cx + sx * k, cy + sy * k
      local c = i == 1 and RED or ORANGE
      cap.circle(px, py, math.max(3, r * 0.045), c, true)
      if i == 1 then
        cap.circle(px, py, math.max(6, r * 0.09), RED, false)
        cap.text(string.format("%dm", I(t.d)), px + r * 0.1, py - sz.tiny / 2, WHITE, sz.tiny, "bold")
      end
    end
  end
end

-- Cannon states, short enough for a two-column tile.
local SHORT = { ["points at own ship"] = "own ship", ["own ship in line"] = "ship in line", ["not on target"] = "aiming",
  ["no target"] = "idle", ["not assembled"] = "unassembled", ["ship rocking"] = "rocking", ["ON TARGET"] = "ON TARGET" }

-- Stop & hold (B) or the autopilot holding a spot: "locked" only once it
-- really is holding; "stopping" on the way; "nosetup" when it can't hold.
function cap.lockState(ps)
  local n = ps and ps.nav
  if not n or (n.mode ~= "brake" and n.mode ~= "hold") then return nil end
  local st = n.status or ""
  if st:find("Smart setup") then return "nosetup" end
  if st:find("^holding") or st:find("holding here") then return "locked" end
  return "stopping"
end
function cap.locked(ps) return cap.lockState(ps) == "locked" end

-- The target's direction as a clock position (12 = dead ahead).
local function clockOf(ps, t)
  if not (ps and ps.heading and t.dx) then return nil end
  local rel = math.deg(atan2(t.dz, t.dx) - ps.heading) % 360
  local hr = math.floor(rel / 30 + 0.5) % 12
  return (hr == 0 and 12 or hr) .. " o'clock"
end

function cap.weapons(x, y, w, h, ps, gs, sz)
  local pad = sz.pad
  cap.rect(x, y, w, h, PANEL)
  cap.text("WEAPONS", x + pad, y + pad, MUTED, sz.small, "bold")
  if not gs then
    cap.pill("OFFLINE", x + w - pad, y + pad * 0.6, DIM, sz.small)
    local err = WARSHIP.gunsError
    cap.text(err and "Fire Control stopped" or "Fire Control starting...", x + pad, y + pad * 2 + sz.small, err and RED or MUTED, sz.med, "bold")
    if err then cap.text(cap.fit(err:match("^[^\n]*"), w - pad * 2, sz.tiny), x + pad, y + pad * 2.5 + sz.small + sz.med, MUTED, sz.tiny) end
    return
  end
  cap.pill(gs.firing and "FIRING" or "READY", x + w - pad, y + pad * 0.6, gs.firing and RED or GREEN, sz.small)

  -- Nearest target
  local ty = y + pad * 2 + sz.small
  local t = gs.targets[1]
  if t then
    local name = (t.cat == "SABLE" and "SHIP" or t.cat) .. "  " .. string.format("%d m", I(t.d))
    cap.text(name, x + pad, ty, RED, sz.big, "bold")
    local extra = string.format("%.0f m/s", t.speed)
    local ck = clockOf(ps, t)
    if ck then extra = ck .. "   " .. extra end
    if #gs.targets > 1 then extra = extra .. string.format("   +%d more", #gs.targets - 1) end
    cap.text(cap.fit(extra, w - pad * 2, sz.small), x + pad, ty + sz.big * 1.15, WHITE, sz.small)
  else
    cap.text("No targets", x + pad, ty, MUTED, sz.big, "bold")
    cap.text(string.format("in range %d-%d m", 20, gs.maxRange or 400), x + pad, ty + sz.big * 1.15, DIM, sz.small)
  end

  -- Cannons: a tile each, two columns
  local gy = ty + sz.big * 1.15 + sz.small * 1.6
  local n = #gs.mounts
  local footY = y + h - pad - sz.tiny
  if n == 0 then
    cap.text("No cannon mounts found", x + pad, gy, RED, sz.small, "bold")
  else
    local cols = n > 4 and 2 or 1
    local rows = math.ceil(n / cols)
    local cw = (w - pad * (cols + 1)) / cols
    local rh = math.min(sz.small * 1.7, (footY - pad - gy) / rows)
    for i, m in ipairs(gs.mounts) do
      local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
      local mx, my = x + pad + c * (cw + pad), gy + r * rh
      local st = m.state or ""
      local col = DIM
      local short = SHORT[st] or st:gsub("^fire error: ", "error: ")
      if st == "FIRE" or st == "FIRING" then col = RED
      elseif st == "ON TARGET" then col = GREEN
      elseif st == "points at own ship" or st == "own ship in line" then col = ORANGE
      elseif st == "not on target" or st == "no target" or st:find("^reload") then col = MUTED end
      cap.rect(mx, my, cw, rh - 3, BG)
      cap.rect(mx, my, math.max(4, rh * 0.18), rh - 3, col)
      local side = m.side == "left" and "L" or (m.side == "right" and "R" or "")
      local fs = math.min(sz.small, rh * 0.62)
      local label = m.name:gsub("^cannon_mount_", "#"):gsub("^cannon_", "") .. (side ~= "" and (" " .. side) or "")
      cap.text(label, mx + rh * 0.3, my + (rh - 3 - fs) / 2, WHITE, fs, "bold")
      local lw = cap.tw(label, fs, "bold") + rh * 0.3 + pad
      cap.textR(cap.fit(cols == 1 and st or short, cw - lw - pad * 0.5, fs), mx + cw - pad * 0.5, my + (rh - 3 - fs) / 2, col, fs)
    end
  end
  local rocking = gs.rock > gs.maxRock
  local foot = rocking and "Ship rocking - shots may miss" or "Ship steady"
  if gs.ignored > 0 then foot = foot .. string.format("   (%d ignored)", gs.ignored) end
  cap.text(cap.fit(foot, w - pad * 2, sz.tiny), x + pad, footY, rocking and ORANGE or DIM, sz.tiny, rocking and "bold" or "plain")
end

-- Problems, most important first.
function cap.alerts(ps, gs)
  local a = {}
  local function add(s, c) a[#a + 1] = { s, c } end
  if pilot.dead then add("PILOT STOPPED - press Enter on the computer", RED) end
  if WARSHIP.gunsError then add("GUNS STOPPED", RED) end
  if ps then
    if ps.fuelAlarm then add("FUEL ALARM", RED) end
    if ps.fuel and ps.fuel.low then add("LOW FUEL " .. timeText(ps.fuel.left), RED) end
    if ps.overstressed > 0 then add(ps.overstressed .. " OVERSTRESSED", RED) end
    if ps.relayError then add("RELAY ERROR", ORANGE) end
    if not ps.typewriter then add("NO TYPEWRITER", ORANGE) end
    if cap.lockState(ps) == "nosetup" then add("HOLD NEEDS SMART SETUP", ORANGE) end
  end
  if gs then
    if gs.fireControllers > 0 then add("FIRE CONTROLLER ON NETWORK", RED) end
    if not gs.radar then add("NO RADAR", ORANGE) end
    if #gs.mounts == 0 then add("NO CANNONS", ORANGE) end
  end
  return a
end

function cap.draw()
  local W, H = cap.W, cap.H
  local sz = { pad = math.max(5, I(H * 0.03)) }
  sz.tiny, sz.small, sz.med, sz.big = math.max(8, I(H * 0.045)), math.max(9, I(H * 0.058)),
    math.max(10, I(H * 0.075)), math.max(12, I(H * 0.12))
  local gsOk, gs = pcall(function() return WARSHIP.guns and WARSHIP.guns.state() end)
  gs = gsOk and gs or nil
  local psOk, ps = pcall(function() return WARSHIP.pilot and WARSHIP.pilot.state() end)
  ps = psOk and ps or nil
  local pad = sz.pad
  cap.gpu.clear(cap.id, BG[1], BG[2], BG[3])

  local stripH = sz.small + pad * 1.4
  local top, ph = pad, H - stripH - pad * 2.5
  local lw = W * 0.37
  local rw = math.min(ph + pad * 2, W * 0.28)
  local ww = W - lw - rw - pad * 4
  cap.flight(pad, top, lw, ph, ps, sz)
  cap.radar(pad * 2 + lw, top, rw, ph, ps, gs, sz)
  cap.weapons(pad * 3 + lw + rw, top, ww, ph, ps, gs, sz)

  -- Alert strip
  local sy = H - stripH - pad
  local alerts = cap.alerts(ps, gs)
  if #alerts == 0 then
    cap.rect(pad, sy, W - pad * 2, stripH, PANEL)
    cap.text("ALL SYSTEMS NORMAL", pad * 2, sy + (stripH - sz.small) / 2, GREEN, sz.small, "bold")
    if cap.locked(ps) then
      cap.text("LOCKED IN PLACE", pad * 4 + cap.tw("ALL SYSTEMS NORMAL", sz.small, "bold"), sy + (stripH - sz.small) / 2, CYAN, sz.small, "bold")
    end
  else
    -- blinks between bright and dark for red alerts
    local hot = alerts[1][2] == RED and math.floor(os.clock() * 2) % 2 == 0
    cap.rect(pad, sy, W - pad * 2, stripH, hot and { 120, 25, 25 } or { 60, 20, 20 })
    local tx = pad * 2
    for i, al in ipairs(alerts) do
      local s = al[1] .. (i < #alerts and "   |   " or "")
      if tx + cap.tw(al[1], sz.small, "bold") > W - pad * 2 then break end
      cap.text(s, tx, sy + (stripH - sz.small) / 2, al[2] == RED and { 255, 120, 120 } or ORANGE, sz.small, "bold")
      tx = tx + cap.tw(s, sz.small, "bold")
    end
  end
  local clock = textutils.formatTime(os.time(), true)
  cap.textR(clock, W - pad * 2, sy + (stripH - sz.small) / 2, MUTED, sz.small, "bold")
  cap.gpu.updateDisplay(cap.id)
end

-- Five frames a second; looks for the monitor and GPU again if they go away.
function cap.run()
  while true do
    if not cap.gpu then
      if not pcall(cap.setup) then cap.gpu = nil end
      if not cap.gpu then sleep(5) end
    end
    if cap.gpu then
      local ok, err = pcall(cap.draw)
      if ok then cap.fails = 0 else
        cap.fails = cap.fails + 1
        cap.err = err
        if cap.fails >= 3 then cap.gpu, cap.fails = nil, 0 end
      end
      sleep(1 / (CAPTAIN_FPS or 5))
    end
  end
end

displayP.fn = cap.run

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
resume(displayP, { n = 0 })

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

if cap.gpu then
  pcall(function()
    cap.gpu.clear(cap.id, BG[1], BG[2], BG[3])
    cap.text("Warship stopped", cap.H * 0.05, cap.H * 0.4, MUTED, cap.H * 0.12, "bold")
    cap.gpu.updateDisplay(cap.id)
  end)
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
