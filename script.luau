--!nonstrict

local SERVER_IP = "89.125.169.199"
local SERVER_PORT = 443
local PARSE_INTERVAL = 1
local START_DELAY = 3
local RECONNECT_DELAY = 5

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local Settings = {
	ParsingEnabled = true,
	AntiAFKEnabled = true,
	soundAlerts = true,
	weatherAlerts = true,
	opacity = 0,
	compact = false,
	watchlist = {},
	_win = nil,
}

local Stats = {
	startTime = os.time(),
	sentPackets = 0,
	itemsFound = 0,
	lastServerMs = nil,
	weatherSeen = 0,
	moonsSeen = 0,
	watchHits = 0,
}

local LatestParse = nil


local CONFIG_FILE = "GardenParser_config.json"
local _hasFileIO = (typeof(writefile) == "function"
	and typeof(readfile) == "function"
	and typeof(isfile) == "function")

local function saveConfig()
	if not _hasFileIO then return end
	pcall(function()
		writefile(CONFIG_FILE, game:GetService("HttpService"):JSONEncode({
			ParsingEnabled = Settings.ParsingEnabled,
			AntiAFKEnabled = Settings.AntiAFKEnabled,
			soundAlerts = Settings.soundAlerts,
			weatherAlerts = Settings.weatherAlerts,
			opacity = Settings.opacity,
			compact = Settings.compact,
			watchlist = Settings.watchlist,
			win = Settings._win,
		}))
	end)
end

local function loadConfig()
	if not _hasFileIO then return end
	pcall(function()
		if not isfile(CONFIG_FILE) then return end
		local obj = game:GetService("HttpService"):JSONDecode(readfile(CONFIG_FILE))
		if type(obj) ~= "table" then return end
		if type(obj.ParsingEnabled) == "boolean" then Settings.ParsingEnabled = obj.ParsingEnabled end
		if type(obj.AntiAFKEnabled) == "boolean" then Settings.AntiAFKEnabled = obj.AntiAFKEnabled end
		if type(obj.soundAlerts) == "boolean" then Settings.soundAlerts = obj.soundAlerts end
		if type(obj.weatherAlerts) == "boolean" then Settings.weatherAlerts = obj.weatherAlerts end
		if type(obj.opacity) == "number" then Settings.opacity = math.clamp(obj.opacity, 0, 0.85) end
		if type(obj.compact) == "boolean" then Settings.compact = obj.compact end
		if type(obj.watchlist) == "table" then Settings.watchlist = obj.watchlist end
		if type(obj.win) == "table" then Settings._win = obj.win end
	end)
end


local function isWatched(name)
	if not name then return false end
	local lname = string.lower(name)
	for _, w in ipairs(Settings.watchlist) do
		if string.lower(w) == lname then return true end
	end
	return false
end

local function setWatched(name, on)
	if not name then return end
	local lname = string.lower(name)
	for i = #Settings.watchlist, 1, -1 do
		if string.lower(Settings.watchlist[i]) == lname then
			table.remove(Settings.watchlist, i)
		end
	end
	if on then table.insert(Settings.watchlist, name) end
	saveConfig()
end

local function stockCount(stockStr)
	if not stockStr then return 0 end
	local n = string.match(tostring(stockStr), "%d+")
	return n and tonumber(n) or 0
end


local function parseDuration(text)
	if text == nil then return nil end
	local s = tostring(text)
	if not string.match(s, "%d") then return nil end


	if string.find(s, ":") then
		local nums = {}
		for n in string.gmatch(s, "%d+") do
			nums[#nums + 1] = tonumber(n)
		end
		if #nums == 0 then return nil end
		local h, m, sec = 0, 0, 0
		if #nums >= 3 then
			h, m, sec = nums[#nums - 2], nums[#nums - 1], nums[#nums]
		elseif #nums == 2 then
			m, sec = nums[1], nums[2]
		else
			sec = nums[1]
		end
		return h * 3600 + m * 60 + sec
	end


	local h = tonumber(string.match(s, "(%d+)%s*[hH]")) or 0
	local m = tonumber(string.match(s, "(%d+)%s*[mM]")) or 0
	local sec = tonumber(string.match(s, "(%d+)%s*[sS]")) or 0
	if h ~= 0 or m ~= 0 or sec ~= 0 then
		return h * 3600 + m * 60 + sec
	end


	local bare = tonumber(string.match(s, "%d+"))
	return bare
end


loadConfig()


local CONSOLE_INFO = false

local Logger = {}
Logger.lines = {}
Logger.seq = 0


local function nowStr()
	return os.date("%H:%M:%S")
end

function Logger.push(level, message)
	local line = string.format("[%s][%s] %s", nowStr(), level, tostring(message))
	table.insert(Logger.lines, line)
	if #Logger.lines > 500 then
		table.remove(Logger.lines, 1)
	end
	Logger.seq += 1
	if level == "ERR" or level == "WARN" then
		warn(line)
	elseif CONSOLE_INFO then
		print(line)
	end
	return line
end

local function info(msg) return Logger.push("INFO", msg) end
local function warnl(msg) return Logger.push("WARN", msg) end
local function errl(msg) return Logger.push("ERR", msg) end


local SELF_FILE = "GardenParser.luau"


local BOOT_PAYLOAD = string.format(
	[[task.wait(4)
	local ok, src = pcall(function() return readfile(%q) end)
	if ok and type(src) == "string" and #src > 0 then
		local fn = loadstring(src)
		if fn then pcall(fn) end
	end]],
	SELF_FILE
)

local function resolveTeleportQueue()
	local candidates = {
		function() return syn and syn.queue_on_teleport end,
		function() return queue_on_teleport end,
		function() return queueonteleport end,
		function() return fluxus and fluxus.queue_on_teleport end,
	}
	for _, getter in ipairs(candidates) do
		local ok, fn = pcall(getter)
		if ok and typeof(fn) == "function" then
			return fn
		end
	end
	return nil
end

local function armTeleportRestore()
	local hasReadFile = (typeof(readfile) == "function" and typeof(isfile) == "function")
	if not hasReadFile then
		warnl("Auto-restore off: executor has no readfile()")
		return false
	end
	local ok, present = pcall(isfile, SELF_FILE)
	if not ok or not present then
		warnl("Auto-restore off: save this script as '" .. SELF_FILE
			.. "' in the executor workspace folder")
		return false
	end
	local q = resolveTeleportQueue()
	if not q then
		warnl("Auto-restore off: executor has no queue_on_teleport")
		return false
	end
	local armed = pcall(q, BOOT_PAYLOAD)
	if armed then
		info("Auto-restore armed (will survive next rejoin)")
	else
		warnl("Auto-restore: queue_on_teleport call failed")
	end
	return armed
end

local function resolveWS()
	local candidates = {
		function() return syn and syn.websocket and syn.websocket.connect end,
		function() return WebSocket and WebSocket.connect end,
		function() return Websocket and Websocket.connect end,
		function() return websocket and websocket.connect end,
	}
	for _, getter in ipairs(candidates) do
		local ok, fn = pcall(getter)
		if ok and typeof(fn) == "function" then
			return fn
		end
	end
	return nil
end

local wsConnect = resolveWS()

local Net = {}
Net.socket = nil
Net.connected = false

local function safeConnectSignal(signal, handler)
	if typeof(signal) == "RBXScriptSignal" or (typeof(signal) == "table" and signal.Connect) then
		local ok = pcall(function()
			signal:Connect(handler)
		end)
		return ok
	end
	return false
end

function Net.close()
	if Net.socket then
		pcall(function() Net.socket:Close() end)
	end
	Net.socket = nil
	Net.connected = false
end

function Net.connect()
	if not wsConnect then
		errl("This executor has no WebSocket support")
		return false
	end
	if Net.connected and Net.socket then
		return true
	end

	local url = string.format("ws://%s:%d", SERVER_IP, SERVER_PORT)
	info("Connecting to " .. url)

	local sock
	local ok, err = pcall(function()
		sock = wsConnect(url)
	end)

	if not ok then
		errl("connect() threw: " .. tostring(err))
		Net.socket = nil
		Net.connected = false
		return false
	end
	if typeof(sock) ~= "table" and typeof(sock) ~= "userdata" then
		errl("connect() returned no socket")
		Net.socket = nil
		Net.connected = false
		return false
	end

	Net.socket = sock
	Net.connected = true
	info("Connected")

	pcall(function()
		if sock.OnMessage then
			safeConnectSignal(sock.OnMessage, function(data)
				Stats.lastServerMs = os.time()
				info("Server: " .. tostring(data))
			end)
		end
	end)
	pcall(function()
		if sock.OnClose then
			safeConnectSignal(sock.OnClose, function()
				warnl("Socket closed by server")
				Net.connected = false
				Net.socket = nil
			end)
		end
	end)

	return true
end

function Net.send(payload)
	if not Net.connected or not Net.socket then
		return false
	end
	local okEncode, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not okEncode then
		errl("encode failed: " .. tostring(encoded))
		return false
	end
	local okSend, sendErr = pcall(function()
		Net.socket:Send(encoded)
	end)
	if not okSend then
		warnl("send failed: " .. tostring(sendErr))
		Net.connected = false
		Net.socket = nil
		return false
	end
	return true
end

local function getPlayerGui()
	local ok, pg = pcall(function()
		return LocalPlayer:FindFirstChildOfClass("PlayerGui")
	end)
	if ok then
		return pg
	end
	return nil
end

local function readText(inst)
	if not inst then return nil end
	local ok, value = pcall(function()
		return inst.Text
	end)
	if ok and typeof(value) == "string" then
		return value
	end
	return nil
end

local function field(parent, name)
	if not parent then return nil end
	local child = parent:FindFirstChild(name)
	return readText(child)
end

local function nested(parent, childName, fieldName)
	if not parent then return nil end
	local child = parent:FindFirstChild(childName)
	if not child then return nil end
	return readText(child:FindFirstChild(fieldName))
end

local SKIP_NAMES = {
	ItemTemplate = true,
	Sheckles_Shelf = true,
	Robux_Shelf = true,
}

local function parseShopContainer(container)
	local items = {}
	if not container then return items end
	local ok, children = pcall(function()
		return container:GetChildren()
	end)
	if not ok then return items end
	for _, child in ipairs(children) do
		if not SKIP_NAMES[child.Name] and not child:IsA("UIComponent")
			and not child:IsA("UILayout") and not child:IsA("UIBase") then
			local main = child:FindFirstChild("Main_Frame")
			if main then
				local name = field(main, "Seed_Text")
				local stock = field(main, "Stock_Text")
				if name or stock then
					table.insert(items, {
						item = name or child.Name,
						stock = stock,
						cost = field(main, "Cost_Text"),
						rarity = nested(main, "Rarity", "Rarity_Text"),
						stockNum = stockCount(stock),
						inStock = stockCount(stock) > 0,
					})
				end
			end
		end
	end
	return items
end

local function timerOf(frame, headerName)
	if not frame then return nil end
	local header = frame:FindFirstChild(headerName or "Header")
	if not header then return nil end
	local refresh = header:FindFirstChild("RefreshIn")
	if not refresh then return nil end
	return field(refresh, "Timer")
end

local function parseSeedShop(pg)
	local shop = pg:FindFirstChild("SeedShop")
	if not shop then return nil end
	local frame = shop:FindFirstChild("Frame")
	if not frame then return nil end
	local restock = timerOf(frame, "Header")
	return {
		restock = restock,
		restockSeconds = parseDuration(restock),
		items = parseShopContainer(frame:FindFirstChild("NormalShop")),
	}
end

local function parseGearShop(pg)
	local shop = pg:FindFirstChild("GearShop")
	if not shop then return nil end
	local frame = shop:FindFirstChild("Frame")
	if not frame then return nil end
	local restock = timerOf(frame, "Header")
	return {
		restock = restock,
		restockSeconds = parseDuration(restock),
		items = parseShopContainer(frame:FindFirstChild("ScrollingFrame")),
	}
end

local function parseCrateShop(pg)
	local shop = pg:FindFirstChild("CrateShop")
	if not shop then return nil end
	local frame = shop:FindFirstChild("Frame")
	if not frame then return nil end
	local restock = timerOf(frame, "Header")
	return {
		restock = restock,
		restockSeconds = parseDuration(restock),
		items = parseShopContainer(frame:FindFirstChild("ScrollingFrame")),
	}
end


local function formatDuration(secs)
	if type(secs) ~= "number" or secs < 0 then return nil end
	secs = math.floor(secs)
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if h > 0 then
		return string.format("%dh %dm %ds", h, m, s)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", s)
end


local function isDayPhaseName(name)
	local low = string.lower(tostring(name or "")):gsub("[%s_%-]+", "")
	return low == "day" or low == "night" or low == "daytime" or low == "nighttime"
end


local function parseWeather(pg)
	local wv = ReplicatedStorage:FindFirstChild("WeatherValues")
	if not wv then return nil end

	local now = os.time()
	local byName = {}

	local function record(name, playing, endTime)
		if not name or name == "" then return end
		if isDayPhaseName(name) then return end
		local e = byName[name]
		if not e then
			e = { playing = false, endTime = nil }
			byName[name] = e
		end
		if playing ~= nil then e.playing = e.playing or playing end
		if type(endTime) == "number" and endTime > 0 then e.endTime = endTime end
	end


	local okA, attrs = pcall(function() return wv:GetAttributes() end)
	if okA and attrs then
		for key, value in pairs(attrs) do
			local base = string.match(key, "^(.+)_Playing$")
			if base then record(base, value == true, nil) end
			local baseEnd = string.match(key, "^(.+)_EndTime$")
			if baseEnd then record(baseEnd, nil, tonumber(value)) end
		end
	end


	local okC, children = pcall(function() return wv:GetChildren() end)
	if okC and children then
		for _, child in ipairs(children) do
			local playingObj = child:FindFirstChild("Playing")
			local endObj = child:FindFirstChild("EndTime")
			if playingObj or endObj then
				local playing = playingObj ~= nil and playingObj.Value == true or nil
				local endTime = endObj ~= nil and tonumber(endObj.Value) or nil
				record(child.Name, playing, endTime)
			end
		end
	end

	local out = {}
	for name, e in pairs(byName) do
		local active = e.playing == true
		local secondsLeft = nil
		if e.endTime and e.endTime > 0 then
			secondsLeft = math.max(0, e.endTime - now)
		end
		table.insert(out, {
			name = name,
			active = active,
			endTime = e.endTime,
			secondsLeft = secondsLeft,
			time = active and formatDuration(secondsLeft) or nil,
		})
	end
	return out
end

local function parseGardenLevel(pg)
	local gl = pg:FindFirstChild("GardenLevel")
	if not gl then return nil end
	local mf = gl:FindFirstChild("MainFrame")
	if not mf then return nil end
	return field(mf, "TextLabel")
end


local MOON_STRIKE_TTL = 90
local MOON_BLOOD_TTL  = 20 * 60
local MOON_DEBUG = false
local MOON_DEBUG_MAX = 60
local _moonDebugSeen = 0

local DEFAULT_MOON_PACKET_IDS = {
	BloodmoonStart = 208,
	BloodmoonEnd = 209,
	BloodmoonBeam = 210,
	NightStart = 214,
	NightEnd = 215,
	GoldMoonStrike = 217,
	RainbowMoonStrike = 218,
}


local moonState = {
	Bloodmoon        = { startedAt = nil, endedAt = nil },
	Night            = { startedAt = nil, endedAt = nil },
	["Gold Moon"]    = { startedAt = nil, lastStrikeAt = nil },
	["Rainbow Moon"] = { startedAt = nil, lastStrikeAt = nil },
}

local function moonStrike(entry, now)

	if entry.lastStrikeAt == nil or (now - entry.lastStrikeAt) >= MOON_STRIKE_TTL then
		entry.startedAt = now
	end
	entry.lastStrikeAt = now
end


local MOON_OPCODES = {
	BloodmoonStart = function(now)
		moonState.Bloodmoon.startedAt = now
		moonState.Bloodmoon.endedAt = nil
	end,
	BloodmoonEnd = function(now)
		moonState.Bloodmoon.endedAt = now
	end,
	BloodmoonBeam = function(now)
		local b = moonState.Bloodmoon
		if b.startedAt == nil or b.endedAt ~= nil then
			b.startedAt = now
		end
		b.endedAt = nil
	end,
	NightStart = function(now)
		moonState.Night.startedAt = now
		moonState.Night.endedAt = nil
	end,
	NightEnd = function(now)
		moonState.Night.endedAt = now
	end,
	GoldMoonStrike = function(now) moonStrike(moonState["Gold Moon"], now) end,
	RainbowMoonStrike = function(now) moonStrike(moonState["Rainbow Moon"], now) end,
}

local function readMoonPacket(buf, idToName, watched)
	local len = buffer.len(buf)
	if len < 1 then return nil, nil end

	-- Packet.RemoteEvent stores the packet id at the start of the buffer. Do not
	-- scan later bytes: weather payloads can contain 217/218 and fake moon strikes.
	local candidates = {}
	if len >= 2 then
		local a = buffer.readu8(buf, 0)
		local b = buffer.readu8(buf, 1)
		candidates[#candidates + 1] = buffer.readu16(buf, 0)
		candidates[#candidates + 1] = a * 256 + b
		candidates[#candidates + 1] = a
	else
		candidates[#candidates + 1] = buffer.readu8(buf, 0)
	end

	for _, id in ipairs(candidates) do
		local op = idToName[id]
		if op then
			return id, watched[op] and op or nil
		end
	end
	return candidates[1], nil
end


local function parseMoons(now)
	now = now or os.time()
	local out = {}

	local b = moonState.Bloodmoon
	local bActive = b.startedAt ~= nil and b.endedAt == nil
		and (now - b.startedAt) < MOON_BLOOD_TTL
	out[#out + 1] = { name = "Bloodmoon", active = bActive, since = bActive and b.startedAt or nil }

	local n = moonState.Night
	local nightActive = false
	local nightObj = ReplicatedStorage:FindFirstChild("Night")
	if nightObj then
		nightActive = nightObj.Value == true
		if nightActive and n.startedAt == nil then
			n.startedAt = now
			n.endedAt = nil
		elseif not nightActive and n.startedAt ~= nil and n.endedAt == nil then
			n.endedAt = now
		end
	end
	for _, name in ipairs({ "Gold Moon", "Rainbow Moon" }) do
		local e = moonState[name]
		local active = e.lastStrikeAt ~= nil and (now - e.lastStrikeAt) < MOON_STRIKE_TTL
		out[#out + 1] = { name = name, active = active, since = active and e.startedAt or nil }
	end

	return out
end


local function setupMoonListener()
	local ok, err = pcall(function()
		local sm = ReplicatedStorage:FindFirstChild("SharedModules")
		local packet = sm and sm:FindFirstChild("Packet")
		local remote = packet and packet:FindFirstChild("RemoteEvent")
		if not remote then
			warnl("Moon listener: Packet.RemoteEvent not found — moons disabled")
			return
		end


		local idToName = {}
		local attrs = remote:GetAttributes()
		for attrName, value in pairs(attrs or {}) do
			if type(value) == "number" then idToName[value] = attrName end
		end
		for attrName, value in pairs(DEFAULT_MOON_PACKET_IDS) do
			if not idToName[value] then idToName[value] = attrName end
		end

		local watched = {
			BloodmoonStart = true, BloodmoonEnd = true, BloodmoonBeam = true,
			NightStart = true, NightEnd = true,
			GoldMoonStrike = true, RainbowMoonStrike = true,
		}

		local connected = safeConnectSignal(remote.OnClientEvent, function(buf, ...)
			if typeof(buf) ~= "buffer" or buffer.len(buf) < 1 then return end
			local id, opName = readMoonPacket(buf, idToName, watched)

			if MOON_DEBUG and _moonDebugSeen < MOON_DEBUG_MAX then
				_moonDebugSeen += 1
				local n = math.min(buffer.len(buf), 12)
				local bytes = table.create(n)
				for i = 0, n - 1 do bytes[i + 1] = string.format("%02X", buffer.readu8(buf, i)) end
				info(string.format("[MOON-RAW] id=%d name=%s bytes=%s",
					id, tostring(opName), table.concat(bytes, " ")))
			end

			if opName and watched[opName] then
				local handler = MOON_OPCODES[opName]
				if handler then
					handler(os.time())
					info("Moon event: " .. opName)
				end
			end
		end)

		if connected then
			info("Moon listener armed on Packet.RemoteEvent")
		else
			warnl("Moon listener: failed to connect OnClientEvent")
		end
	end)
	if not ok then
		warnl("Moon listener setup error: " .. tostring(err))
	end
end

local function buildPayload()
	local pg = getPlayerGui()
	if not pg then
		return nil
	end
	local payload
	local ok = pcall(function()
		local weather = parseWeather(pg)
		local seedShop = parseSeedShop(pg)
		local gearShop = parseGearShop(pg)
		local crateShop = parseCrateShop(pg)
		local moons = parseMoons()


		local weatherActive = 0
		local activeNames = {}
		for _, w in ipairs(weather or {}) do
			if w.active then
				weatherActive += 1
				activeNames[#activeNames + 1] = w.name
			end
		end

		local moonsActive = 0
		local activeMoonNames = {}
		for _, m in ipairs(moons or {}) do
			if m.active then
				moonsActive += 1
				activeMoonNames[#activeMoonNames + 1] = m.name
			end
		end


		local isNight = false
		local nightObj = ReplicatedStorage:FindFirstChild("Night")
		if nightObj then
			isNight = nightObj.Value == true
		end

		payload = {
			type = "data",
			ts = os.time(),
			player = LocalPlayer.Name,
			userId = LocalPlayer.UserId,
			weather = weather,
			moons = moons,
			seedShop = seedShop,
			gearShop = gearShop,
			crateShop = crateShop,
			gardenLevel = parseGardenLevel(pg),
			isNight = isNight,
			dayPhase = isNight and "Night" or "Day",
			counts = {
				weatherActive = weatherActive,
				activeNames = activeNames,
				moonsActive = moonsActive,
				activeMoonNames = activeMoonNames,
				seeds = seedShop and #seedShop.items or 0,
				gear = gearShop and #gearShop.items or 0,
				crates = crateShop and #crateShop.items or 0,
			},
		}
	end)
	if not ok then
		return nil
	end
	return payload
end

local function sendLog(line)
	Net.send({
		type = "log",
		ts = os.time(),
		player = LocalPlayer.Name,
		line = line,
	})
end

local Running = true

safeConnectSignal(LocalPlayer.AncestryChanged, function(_, parent)
	if parent == nil then
		Running = false
		Net.close()
	end
end)

task.spawn(function()
	task.wait(START_DELAY)
	info("GardenParser started")


	pcall(armTeleportRestore)


	pcall(setupMoonListener)

	if not wsConnect then
		errl("Aborting: no WebSocket API")
		return
	end

	while Running do
		if not Net.connected then
			local ok = Net.connect()
			if not ok then
				task.wait(RECONNECT_DELAY)
			end
		elseif Settings.ParsingEnabled then
			local okLoop, loopErr = pcall(function()
				local payload = buildPayload()
				if payload then
					LatestParse = payload
					if Net.send(payload) then
						local seeds = (payload.seedShop and #payload.seedShop.items) or 0
						local gears = (payload.gearShop and #payload.gearShop.items) or 0
						local weathers = (payload.weather and #payload.weather) or 0
						local moonsActive = (payload.counts and payload.counts.moonsActive) or 0
						Stats.sentPackets += 1
						Stats.itemsFound = seeds + gears
						sendLog(info(string.format("Sent: %d seeds, %d gear, %d weather, %d moon", seeds, gears, weathers, moonsActive)))
					end
				else
					warnl("PlayerGui not ready / parse skipped")
				end
			end)
			if not okLoop then
				errl("loop error: " .. tostring(loopErr))
			end
			task.wait(PARSE_INTERVAL)
		else
			task.wait(PARSE_INTERVAL)
		end
	end

	info("Parser stopped")
	Net.close()
end)


local AntiAFK = {}
AntiAFK.running = false

local function doAntiAFK()
	pcall(function()
		local keys = {Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D}
		local key = keys[math.random(#keys)]
		VirtualInputManager:SendKeyEvent(true, key, false, nil)
		task.wait(0.05)
		VirtualInputManager:SendKeyEvent(false, key, false, nil)

		local pos = UserInputService:GetMouseLocation()
		VirtualInputManager:SendMouseMoveEvent(pos.X + math.random(-3, 3), pos.Y + math.random(-3, 3), nil)

		local cam = workspace.CurrentCamera
		if cam then
			cam.CFrame = cam.CFrame * CFrame.Angles(0, math.rad(math.random(-2, 2)), 0)
		end
	end)
end

function AntiAFK.start()
	if AntiAFK.running then return end
	AntiAFK.running = true
	task.spawn(function()
		while AntiAFK.running and Running do
			doAntiAFK()
			task.wait(25 + math.random(0, 10))
		end
		AntiAFK.running = false
	end)
end

function AntiAFK.stop()
	AntiAFK.running = false
end


if Settings.AntiAFKEnabled then
	AntiAFK.start()
end


local function getTeleportDestinations()
	local out = {}
	local folder = workspace:FindFirstChild("Teleports")
	if folder then
		for _, c in ipairs(folder:GetChildren()) do
			local cf
			if c:IsA("BasePart") then
				cf = c.CFrame
			elseif c:IsA("Model") then
				local ok, pivot = pcall(function() return c:GetPivot() end)
				if ok then
					cf = pivot
				elseif c.PrimaryPart then
					cf = c.PrimaryPart.CFrame
				end
			end
			if cf then

				table.insert(out, { Name = c.Name, CFrame = cf + Vector3.new(0, 4, 0) })
			end
		end
	end
	table.sort(out, function(a, b) return a.Name < b.Name end)
	return out
end

local function teleportTo(cf)
	local char = LocalPlayer.Character
	if not char then return false end
	local root = char:FindFirstChild("HumanoidRootPart")
		or char:FindFirstChild("Torso")
		or char:FindFirstChild("UpperTorso")
	if not root then return false end
	local ok = pcall(function()
		root.CFrame = cf
	end)
	return ok
end


local TweenService = game:GetService("TweenService")

local C = {
	BG      = Color3.fromRGB(15, 16, 18),
	BG2     = Color3.fromRGB(11, 12, 14),
	PANEL   = Color3.fromRGB(23, 25, 28),
	PANEL2  = Color3.fromRGB(33, 36, 41),
	PANEL3  = Color3.fromRGB(46, 50, 57),
	STROKE  = Color3.fromRGB(48, 52, 60),
	ACCENT  = Color3.fromRGB(225, 228, 235),
	TEXT    = Color3.fromRGB(236, 238, 243),
	SUBTLE  = Color3.fromRGB(150, 155, 165),
	DIM     = Color3.fromRGB(98, 103, 113),
	GREEN   = Color3.fromRGB(72, 200, 130),
	RED     = Color3.fromRGB(228, 90, 96),
	YELLOW  = Color3.fromRGB(240, 200, 105),
}

local function tween(obj, t, props, style, dir)
	local ti = TweenInfo.new(t, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out)
	local tw = TweenService:Create(obj, ti, props)
	tw:Play()
	return tw
end

local function cr(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = p
	return c
end

local function stroke(p, col, th)
	local s = Instance.new("UIStroke")
	s.Color = col or C.STROKE
	s.Thickness = th or 1
	s.Parent = p
	return s
end

local function pad(p, l, t, r, b)
	local u = Instance.new("UIPadding")
	u.PaddingLeft = UDim.new(0, l)
	u.PaddingTop = UDim.new(0, t or l)
	u.PaddingRight = UDim.new(0, r or l)
	u.PaddingBottom = UDim.new(0, b or t or l)
	u.Parent = p
	return u
end


local function iconLine(parent, px, x1, y1, x2, y2, thick, color)
	local s = px / 24
	local dx, dy = (x2 - x1) * s, (y2 - y1) * s
	local len = math.sqrt(dx * dx + dy * dy)
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = UDim2.fromOffset((x1 + x2) / 2 * s, (y1 + y2) / 2 * s)
	line.Size = UDim2.fromOffset(math.max(len, thick), thick)
	line.Rotation = math.deg(math.atan2(dy, dx))
	line.BackgroundColor3 = color
	line.BorderSizePixel = 0
	line.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, thick / 2)
	c.Parent = line
	return line
end

local function iconCircle(parent, px, cx, cy, r, color, filled, thick)
	local s = px / 24
	local d = 2 * r * s
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(d, d)
	f.BorderSizePixel = 0
	if filled then
		f.BackgroundColor3 = color
	else
		f.BackgroundTransparency = 1
		local st = Instance.new("UIStroke")
		st.Color = color
		st.Thickness = thick or 1.6
		st.Parent = f
	end
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = f
	f.Parent = parent
	return f
end


local function makeIcon(parent, name, color, px)
	px = px or 18
	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(px, px)
	box.BackgroundTransparency = 1
	box.Parent = parent
	local th = math.max(1.5, px * 0.085)
	local function L(x1, y1, x2, y2) iconLine(box, px, x1, y1, x2, y2, th, color) end
	local function ring(cx, cy, r) iconCircle(box, px, cx, cy, r, color, false, th) end
	local function disc(cx, cy, r) iconCircle(box, px, cx, cy, r, color, true) end

	if name == "minus" then
		L(5, 12, 19, 12)
	elseif name == "close" then
		L(6, 6, 18, 18); L(18, 6, 6, 18)
	elseif name == "expand" then
		L(5, 10, 5, 5); L(5, 5, 10, 5); L(19, 14, 19, 19); L(19, 19, 14, 19)
	elseif name == "status" then
		L(4, 13, 7, 10); L(7, 10, 10, 13); L(10, 13, 14, 8); L(14, 8, 17, 12); L(17, 12, 21, 6)
	elseif name == "sun" then
		ring(12, 12, 3.6)
		for i = 0, 7 do
			local a = i * math.pi / 4
			L(12 + math.cos(a) * 6, 12 + math.sin(a) * 6, 12 + math.cos(a) * 8, 12 + math.sin(a) * 8)
		end
	elseif name == "shop" then
		L(6, 8, 18, 8); L(18, 8, 17, 19); L(17, 19, 7, 19); L(7, 19, 6, 8)
		L(9.5, 8, 9.5, 5.5); L(9.5, 5.5, 14.5, 5.5); L(14.5, 5.5, 14.5, 8)
	elseif name == "sliders" then
		L(4, 8, 19, 8); L(4, 16, 19, 16); ring(9, 8, 2.4); ring(15, 16, 2.4)
	elseif name == "pin" then
		ring(12, 9, 3.6); L(8.7, 11.5, 12, 20); L(15.3, 11.5, 12, 20); disc(12, 9, 1.4)
	elseif name == "loglines" then
		L(5, 6, 19, 6); L(5, 10, 19, 10); L(5, 14, 14, 14); L(5, 18, 11, 18)
	elseif name == "search" then
		ring(10, 10, 5); L(14, 14, 20, 20)
	elseif name == "copy" then
		L(8.5, 8.5, 19, 8.5); L(19, 8.5, 19, 19); L(19, 19, 8.5, 19); L(8.5, 19, 8.5, 8.5)
		L(5, 15, 5, 5); L(5, 5, 15, 5)
	elseif name == "refresh" then
		ring(12, 12, 6); L(15, 3.5, 18.5, 6); L(18.5, 6, 15, 8.5)
	elseif name == "chevron" then
		L(9, 7, 13, 12); L(13, 12, 9, 17)
	elseif name == "disc" then
		disc(12, 12, 7)
	end
	return box
end

local function fmtUptime(sec)
	sec = math.max(0, math.floor(sec))
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = sec % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function fmtSecs(sec)
	if sec == nil then return "—" end
	sec = math.floor(sec)
	if sec < 0 then sec = 0 end
	if sec >= 3600 then
		return string.format("%dч %02dм", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
	elseif sec >= 60 then
		return string.format("%dм %02dс", math.floor(sec / 60), sec % 60)
	end
	return sec .. "с"
end


local WX_DEFS = {
	{ pat = "blood",   emoji = "🌑", ru = "Кровавая луна", color = Color3.fromRGB(228, 90, 96),  moon = true,  fx = { "Кровавая мутация ×60" } },
	{ pat = "gold",    emoji = "🌕", ru = "Золотая луна",  color = Color3.fromRGB(240, 200, 105), moon = true,  fx = { "Золотая мутация ×10", "Касание Мидаса" } },
	{ pat = "rainbow moon", emoji = "🌈", ru = "Радужная луна", color = Color3.fromRGB(170, 140, 235), moon = true, fx = { "Радужная мутация ×30", "Звёздная сила" } },
	{ pat = "rainbowmoon",  emoji = "🌈", ru = "Радужная луна", color = Color3.fromRGB(170, 140, 235), moon = true, fx = { "Радужная мутация ×30", "Звёздная сила" } },
	{ pat = "rainbow", emoji = "🌈", ru = "Радуга",        color = Color3.fromRGB(180, 150, 240), moon = false, fx = { "Радужная мутация" } },
	{ pat = "thunder", emoji = "⛈️", ru = "Гроза",         color = Color3.fromRGB(167, 139, 250), moon = false, fx = { "Молнии", "Электро-мутация" } },
	{ pat = "light",   emoji = "⚡",  ru = "Молния",        color = Color3.fromRGB(167, 139, 250), moon = false, fx = { "Электро-мутация" } },
	{ pat = "blizz",   emoji = "🌨️", ru = "Метель",        color = Color3.fromRGB(147, 197, 253), moon = false, fx = { "Заморозка" } },
	{ pat = "snow",    emoji = "❄️", ru = "Снегопад",      color = Color3.fromRGB(186, 230, 253), moon = false, fx = { "Заморозка" } },
	{ pat = "frost",   emoji = "🧊", ru = "Мороз",          color = Color3.fromRGB(125, 211, 252), moon = false, fx = { "Заморозка" } },
	{ pat = "rain",    emoji = "🌧️", ru = "Дождь",         color = Color3.fromRGB(96, 165, 250),  moon = false, fx = { "Ускорение роста ×2", "Бесплатный полив" } },
	{ pat = "star",    emoji = "⭐", ru = "Звездопад",      color = Color3.fromRGB(253, 224, 71),  moon = false, fx = { "Звёздная мутация" } },
	{ pat = "night",   emoji = "🌙", ru = "Ночь",           color = Color3.fromRGB(129, 140, 248), moon = false, fx = {} },
}

local function weatherMeta(name)
	local low = string.lower(tostring(name or ""))
	for _, d in ipairs(WX_DEFS) do
		if string.find(low, d.pat, 1, true) then return d end
	end
	return { emoji = "🌤️", ru = name or "Погода", color = Color3.fromRGB(120, 200, 150), moon = false, fx = {} }
end

local function copyToClipboard(text)
	local fn = (typeof(setclipboard) == "function" and setclipboard)
		or (typeof(toclipboard) == "function" and toclipboard)
		or (typeof(set_clipboard) == "function" and set_clipboard)
	if fn then
		local ok = pcall(fn, text)
		return ok
	end
	return false
end

local function createGUI()
	local hidden
	pcall(function()
		if typeof(gethui) == "function" then
			local ok, h = pcall(gethui)
			if ok and h then hidden = h end
		end
	end)
	if not hidden then
		hidden = LocalPlayer:FindFirstChildOfClass("PlayerGui") or game:GetService("CoreGui")
	end

	local old = hidden:FindFirstChild("GardenParserGUI")
	if old then old:Destroy() end

	local sg = Instance.new("ScreenGui")
	sg.Name = "GardenParserGUI"
	sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 999998
	sg.Parent = hidden
	pcall(function() if syn and syn.protect_gui then syn.protect_gui(sg) end end)
	pcall(function() if protect_gui then protect_gui(sg) end end)

	local MIN_W, MIN_H = 560, 300
	local MAX_W, MAX_H = 900, 520
	local W, H = 720, 360


	local win
	do
		local ok, cg = pcall(function() return Instance.new("CanvasGroup") end)
		win = (ok and cg) or Instance.new("Frame")
	end
	win.Name = "Window"
	win.Size = UDim2.fromOffset(W, H)
	win.Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2)
	win.BackgroundColor3 = C.BG
	win.BorderSizePixel = 0
	win.Active = true
	win.ClipsDescendants = true
	win.Parent = sg
	cr(win, 12)
	stroke(win, C.STROKE, 1)

	local winScale = Instance.new("UIScale")
	winScale.Scale = 0.72
	winScale.Parent = win


	if type(Settings._win) == "table" then
		local g = Settings._win
		if g.w and g.h then
			win.Size = UDim2.fromOffset(
				math.clamp(g.w, MIN_W, MAX_W),
				math.clamp(g.h, MIN_H, MAX_H)
			)
		end
		if g.x and g.y then
			win.Position = UDim2.fromOffset(g.x, g.y)
		end
	end

	local function persistGeometry()
		Settings._win = {
			x = math.floor(win.AbsolutePosition.X),
			y = math.floor(win.AbsolutePosition.Y),
			w = math.floor(win.AbsoluteSize.X),
			h = math.floor(win.AbsoluteSize.Y),
		}
		saveConfig()
	end


	local supportsGroupT = (win.ClassName == "CanvasGroup")
	local baseOpacity = math.clamp(Settings.opacity or 0, 0, 0.85)
	local hovering = true
	local function applyWinTransparency(animate)
		if not supportsGroupT then return end
		local target = hovering and baseOpacity or math.max(baseOpacity, 0.5)
		if animate then
			tween(win, hovering and 0.18 or 0.45, { GroupTransparency = target })
		else
			win.GroupTransparency = target
		end
	end
	local function setOpacity(t)
		baseOpacity = math.clamp(t, 0, 0.85)
		Settings.opacity = baseOpacity
		applyWinTransparency(true)
		saveConfig()
	end
	if supportsGroupT then
		win.MouseEnter:Connect(function() hovering = true; applyWinTransparency(true) end)
		win.MouseLeave:Connect(function() hovering = false; applyWinTransparency(true) end)
		applyWinTransparency(false)
	end

	local preCompactSize = nil
	local function applyCompact(on)
		if on then
			if not preCompactSize then preCompactSize = win.Size end
			tween(win, 0.2, { Size = UDim2.fromOffset(560, 300) }, Enum.EasingStyle.Quad)
		elseif preCompactSize then
			tween(win, 0.2, { Size = preCompactSize }, Enum.EasingStyle.Quad)
			preCompactSize = nil
		end
	end
	if Settings.compact then applyCompact(true) end


	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.Size = UDim2.new(0, 168, 1, 0)
	rail.BackgroundColor3 = C.BG2
	rail.BorderSizePixel = 0
	rail.Parent = win
	pad(rail, 10, 12, 10, 10)


	do
		local div = Instance.new("Frame")
		div.Size = UDim2.new(0, 1, 1, 0)
		div.Position = UDim2.fromOffset(167, 0)
		div.BackgroundColor3 = C.STROKE
		div.BorderSizePixel = 0
		div.ZIndex = 2
		div.Parent = win
	end

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.Size = UDim2.new(1, -168, 1, 0)
	stage.Position = UDim2.fromOffset(168, 0)
	stage.BackgroundTransparency = 1
	stage.Parent = win


	local brand = Instance.new("Frame")
	brand.Size = UDim2.new(1, 0, 0, 36)
	brand.BackgroundTransparency = 1
	brand.Parent = rail
	local blogo = Instance.new("Frame")
	blogo.Size = UDim2.fromOffset(26, 26)
	blogo.Position = UDim2.fromOffset(2, 4)
	blogo.BackgroundColor3 = C.GREEN
	blogo.Parent = brand
	cr(blogo, 8)
	local bname = Instance.new("TextLabel")
	bname.Size = UDim2.new(1, -38, 0, 16)
	bname.Position = UDim2.fromOffset(38, 3)
	bname.BackgroundTransparency = 1
	bname.Font = Enum.Font.GothamBold
	bname.TextSize = 14
	bname.TextColor3 = C.TEXT
	bname.TextXAlignment = Enum.TextXAlignment.Left
	bname.Text = "Garden Parser"
	bname.Parent = brand
	local bsub = Instance.new("TextLabel")
	bsub.Size = UDim2.new(1, -38, 0, 12)
	bsub.Position = UDim2.fromOffset(38, 20)
	bsub.BackgroundTransparency = 1
	bsub.Font = Enum.Font.Gotham
	bsub.TextSize = 10
	bsub.TextColor3 = C.DIM
	bsub.TextXAlignment = Enum.TextXAlignment.Left
	bsub.Text = "v2 · live"
	bsub.Parent = brand


	local navHolder = Instance.new("Frame")
	navHolder.Size = UDim2.new(1, 0, 1, -84)
	navHolder.Position = UDim2.fromOffset(0, 44)
	navHolder.BackgroundTransparency = 1
	navHolder.Parent = rail
	local navLayout = Instance.new("UIListLayout")
	navLayout.Padding = UDim.new(0, 3)
	navLayout.SortOrder = Enum.SortOrder.LayoutOrder
	navLayout.Parent = navHolder


	local foot = Instance.new("Frame")
	foot.Size = UDim2.new(1, 0, 0, 24)
	foot.Position = UDim2.new(0, 0, 1, -24)
	foot.BackgroundTransparency = 1
	foot.Parent = rail
	do
		local topdiv = Instance.new("Frame")
		topdiv.Size = UDim2.new(1, 0, 0, 1)
		topdiv.BackgroundColor3 = C.STROKE
		topdiv.BorderSizePixel = 0
		topdiv.Parent = foot
	end
	local railDot = Instance.new("Frame")
	railDot.Size = UDim2.fromOffset(7, 7)
	railDot.Position = UDim2.fromOffset(2, 9)
	railDot.BackgroundColor3 = C.RED
	railDot.Parent = foot
	cr(railDot, 4)
	local footLbl = Instance.new("TextLabel")
	footLbl.Size = UDim2.new(1, -16, 0, 14)
	footLbl.Position = UDim2.fromOffset(14, 5)
	footLbl.BackgroundTransparency = 1
	footLbl.Font = Enum.Font.Gotham
	footLbl.TextSize = 10
	footLbl.TextColor3 = C.DIM
	footLbl.TextXAlignment = Enum.TextXAlignment.Left
	footLbl.TextTruncate = Enum.TextTruncate.AtEnd
	footLbl.Text = "Подключение… · " .. SERVER_IP
	footLbl.Parent = foot


	local topbar = Instance.new("Frame")
	topbar.Name = "TopBar"
	topbar.Size = UDim2.new(1, 0, 0, 46)
	topbar.BackgroundTransparency = 1
	topbar.Active = true
	topbar.Parent = stage
	do
		local topdiv = Instance.new("Frame")
		topdiv.Size = UDim2.new(1, 0, 0, 1)
		topdiv.Position = UDim2.new(0, 0, 1, -1)
		topdiv.BackgroundColor3 = C.STROKE
		topdiv.BorderSizePixel = 0
		topdiv.Parent = topbar
	end
	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromOffset(96, 16)
	title.Position = UDim2.fromOffset(16, 15)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = C.TEXT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Garden Parser"
	title.Parent = topbar
	local crumb = Instance.new("TextLabel")
	crumb.Size = UDim2.new(1, -240, 0, 16)
	crumb.Position = UDim2.fromOffset(118, 15)
	crumb.BackgroundTransparency = 1
	crumb.Font = Enum.Font.Gotham
	crumb.TextSize = 11
	crumb.TextColor3 = C.DIM
	crumb.TextXAlignment = Enum.TextXAlignment.Left
	crumb.TextTruncate = Enum.TextTruncate.AtEnd
	crumb.Text = "Главная"
	crumb.Parent = topbar


	local function segment(parent, defs)
		local seg = Instance.new("Frame")
		seg.Size = UDim2.fromOffset(#defs * 30 + (#defs - 1), 26)
		seg.BackgroundColor3 = C.STROKE
		seg.BorderSizePixel = 0
		seg.ClipsDescendants = true
		seg.Parent = parent
		cr(seg, 7)
		local out = {}
		for i, d in ipairs(defs) do
			local b = Instance.new("TextButton")
			b.Size = UDim2.fromOffset(30, 26)
			b.Position = UDim2.fromOffset((i - 1) * 31, 0)
			b.BackgroundColor3 = C.PANEL2
			b.AutoButtonColor = false
			b.Text = ""
			b.Parent = seg
			local ic = makeIcon(b, d.icon, C.SUBTLE, 15)
			ic.AnchorPoint = Vector2.new(0.5, 0.5)
			ic.Position = UDim2.fromScale(0.5, 0.5)
			local isClose = d.close
			b.MouseEnter:Connect(function() tween(b, 0.14, {BackgroundColor3 = isClose and C.RED or C.PANEL3}) end)
			b.MouseLeave:Connect(function() tween(b, 0.14, {BackgroundColor3 = C.PANEL2}) end)
			out[d.key] = b
		end
		return seg, out
	end
	local topSeg, topBtns = segment(topbar, {
		{ key = "hide", icon = "minus" },
		{ key = "close", icon = "close", close = true },
	})
	topSeg.AnchorPoint = Vector2.new(1, 0.5)
	topSeg.Position = UDim2.new(1, -10, 0.5, 0)
	local hideBtn = topBtns.hide
	local closeBtn = topBtns.close


	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, -46)
	content.Position = UDim2.fromOffset(0, 46)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = true
	content.Parent = stage

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, -28, 1, -24)
	body.Position = UDim2.fromOffset(16, 12)
	body.BackgroundTransparency = 1
	body.Parent = content


	local placeholder = Instance.new("Frame")
	placeholder.Name = "Placeholder"
	placeholder.Size = UDim2.fromScale(1, 1)
	placeholder.BackgroundTransparency = 1
	placeholder.Parent = content
	do
		local ring = Instance.new("Frame")
		ring.Size = UDim2.fromOffset(60, 60)
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.new(0.5, 0, 0.5, -36)
		ring.BackgroundColor3 = C.PANEL
		ring.Parent = placeholder
		cr(ring, 16)
		stroke(ring, C.STROKE, 1)
		local pi = makeIcon(ring, "loglines", C.SUBTLE, 28)
		pi.AnchorPoint = Vector2.new(0.5, 0.5)
		pi.Position = UDim2.fromScale(0.5, 0.5)
		local ph = Instance.new("TextLabel")
		ph.Size = UDim2.new(1, -40, 0, 20)
		ph.AnchorPoint = Vector2.new(0.5, 0.5)
		ph.Position = UDim2.new(0.5, 0, 0.5, 12)
		ph.BackgroundTransparency = 1
		ph.Font = Enum.Font.GothamBold
		ph.TextSize = 15
		ph.TextColor3 = C.TEXT
		ph.Text = "Выберите функцию слева"
		ph.Parent = placeholder
		local ph2 = Instance.new("TextLabel")
		ph2.Size = UDim2.new(1, -120, 0, 32)
		ph2.AnchorPoint = Vector2.new(0.5, 0.5)
		ph2.Position = UDim2.new(0.5, 0, 0.5, 40)
		ph2.BackgroundTransparency = 1
		ph2.Font = Enum.Font.Gotham
		ph2.TextSize = 12
		ph2.TextColor3 = C.DIM
		ph2.TextWrapped = true
		ph2.Text = "Панель слева — навигация. Нажмите раздел, чтобы открыть его здесь."
		ph2.Parent = placeholder
	end

	local pages = {}
	local navButtons = {}
	local currentTab = nil
	local showToast
	local refreshShop
	local updateSky
	local tickRestocks
	local exportStock

	local function makePage(name)
		local pg = Instance.new("Frame")
		pg.Name = name
		pg.Size = UDim2.fromScale(1, 1)
		pg.BackgroundTransparency = 1
		pg.Visible = false
		pg.Parent = body
		pages[name] = pg
		return pg
	end

	local TAB_DEFS = {
		{ key = "Status",   ru = "Статус",    icon = "status" },
		{ key = "Sky",      ru = "Небо",      icon = "sun" },
		{ key = "Shop",     ru = "Магазины",  icon = "shop" },
		{ key = "Controls", ru = "Настройки", icon = "sliders" },
		{ key = "Teleport", ru = "Телепорт",  icon = "pin" },
		{ key = "Log",      ru = "Лог",       icon = "loglines" },
	}
	local RU_BY_KEY = {}
	for _, d in ipairs(TAB_DEFS) do RU_BY_KEY[d.key] = d.ru end

	local function selectTab(name)
		if currentTab == name then return end
		currentTab = name
		placeholder.Visible = false
		for n, refs in pairs(navButtons) do
			local active = (n == name)
			tween(refs.bg, 0.16, {BackgroundColor3 = active and C.PANEL3 or C.BG2})
			tween(refs.lbl, 0.16, {TextColor3 = active and C.TEXT or C.SUBTLE})
			refs.accent.Visible = active
		end
		for n, pg in pairs(pages) do
			pg.Visible = (n == name)
		end
		crumb.Text = RU_BY_KEY[name] or "Главная"
		local cur = pages[name]
		if cur then
			cur.Position = UDim2.fromOffset(0, 10)
			tween(cur, 0.22, {Position = UDim2.fromOffset(0, 0)}, Enum.EasingStyle.Back)
		end
	end

	local function makeNav(def, order)
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, 0, 0, 38)
		btn.BackgroundColor3 = C.BG2
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = order
		btn.Parent = navHolder
		cr(btn, 9)
		local accent = Instance.new("Frame")
		accent.Size = UDim2.fromOffset(3, 18)
		accent.Position = UDim2.fromOffset(0, 10)
		accent.BackgroundColor3 = C.GREEN
		accent.Visible = false
		accent.Parent = btn
		cr(accent, 2)
		local ico = makeIcon(btn, def.icon, C.SUBTLE, 18)
		ico.Position = UDim2.fromOffset(11, 10)
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, -42, 1, 0)
		lbl.Position = UDim2.fromOffset(40, 0)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamMedium
		lbl.TextSize = 13
		lbl.TextColor3 = C.SUBTLE
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Text = def.ru
		lbl.Parent = btn
		navButtons[def.key] = { bg = btn, lbl = lbl, accent = accent, ico = ico }
		btn.MouseEnter:Connect(function()
			if currentTab ~= def.key then tween(btn, 0.14, {BackgroundColor3 = C.PANEL}) end
		end)
		btn.MouseLeave:Connect(function()
			if currentTab ~= def.key then tween(btn, 0.14, {BackgroundColor3 = C.BG2}) end
		end)
		btn.MouseButton1Click:Connect(function() selectTab(def.key) end)
		makePage(def.key)
	end
	for i, d in ipairs(TAB_DEFS) do makeNav(d, i) end


	local connDot, connLbl, parseDot, parseLbl
	local vUptime, vPackets, vItems, vPing
	local vRate, vWeatherSeen, vMoonsSeen, sparkBars
	do
		local p = pages["Status"]
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = p

		local function card(h, order)
			local f = Instance.new("Frame")
			f.Size = UDim2.new(1, 0, 0, h)
			f.BackgroundColor3 = C.PANEL
			f.BorderSizePixel = 0
			f.LayoutOrder = order
			f.Parent = p
			cr(f, 8)
			return f
		end

		local function cardHeader(parent, text)
			local h = Instance.new("TextLabel")
			h.Size = UDim2.new(1, -24, 0, 14)
			h.Position = UDim2.fromOffset(12, 8)
			h.BackgroundTransparency = 1
			h.Font = Enum.Font.GothamBold
			h.TextSize = 10
			h.TextColor3 = C.DIM
			h.TextXAlignment = Enum.TextXAlignment.Left
			h.Text = string.upper(text)
			h.Parent = parent
		end

		local function dotRow(parent, y, label)
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(8, 8)
			dot.Position = UDim2.fromOffset(12, y + 3)
			dot.BackgroundColor3 = C.RED
			dot.Parent = parent
			cr(dot, 4)
			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(1, -32, 0, 16)
			lbl.Position = UDim2.fromOffset(28, y - 1)
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.Gotham
			lbl.TextSize = 13
			lbl.TextColor3 = C.TEXT
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.Text = label
			lbl.Parent = parent
			return dot, lbl
		end

		local function kvRow(parent, y, key)
			local k = Instance.new("TextLabel")
			k.Size = UDim2.new(0.55, -12, 0, 16)
			k.Position = UDim2.fromOffset(12, y)
			k.BackgroundTransparency = 1
			k.Font = Enum.Font.Gotham
			k.TextSize = 13
			k.TextColor3 = C.SUBTLE
			k.TextXAlignment = Enum.TextXAlignment.Left
			k.Text = key
			k.Parent = parent
			local v = Instance.new("TextLabel")
			v.Size = UDim2.new(0.45, -12, 0, 16)
			v.Position = UDim2.new(0.55, 0, 0, y)
			v.BackgroundTransparency = 1
			v.Font = Enum.Font.GothamMedium
			v.TextSize = 13
			v.TextColor3 = C.TEXT
			v.TextXAlignment = Enum.TextXAlignment.Right
			v.Text = "—"
			v.Parent = parent
			return v
		end

		local connCard = card(78, 1)
		cardHeader(connCard, "Connection")
		connDot, connLbl = dotRow(connCard, 32, "Disconnected")
		parseDot, parseLbl = dotRow(connCard, 54, "Parser stopped")

		local statCard = card(122, 2)
		cardHeader(statCard, "Statistics")
		vUptime = kvRow(statCard, 30, "Uptime")
		vPackets = kvRow(statCard, 52, "Packets sent")
		vItems = kvRow(statCard, 74, "Items found")
		vPing = kvRow(statCard, 96, "Last server msg")


		local sessCard = card(120, 3)
		cardHeader(sessCard, "Session")
		vRate = kvRow(sessCard, 30, "Packets / min")
		vWeatherSeen = kvRow(sessCard, 52, "Weather seen")
		vMoonsSeen = kvRow(sessCard, 74, "Moons seen")

		local spark = Instance.new("Frame")
		spark.Size = UDim2.new(1, -24, 0, 22)
		spark.Position = UDim2.fromOffset(12, 92)
		spark.BackgroundColor3 = C.BG2
		spark.BorderSizePixel = 0
		spark.Parent = sessCard
		cr(spark, 4)
		local sparkLayout = Instance.new("UIListLayout")
		sparkLayout.FillDirection = Enum.FillDirection.Horizontal
		sparkLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		sparkLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		sparkLayout.Padding = UDim.new(0, 1)
		sparkLayout.Parent = spark
		pad(spark, 3, 3, 3, 3)
		sparkBars = {}
		for i = 1, 32 do
			local b = Instance.new("Frame")
			b.Size = UDim2.new(0, 3, 0, 1)
			b.BackgroundColor3 = C.GREEN
			b.BorderSizePixel = 0
			b.LayoutOrder = i
			b.Parent = spark
			cr(b, 1)
			sparkBars[i] = b
		end
	end


	do
		local p = pages["Sky"]
		local scroll = Instance.new("ScrollingFrame")
		scroll.Size = UDim2.fromScale(1, 1)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.ScrollBarImageColor3 = C.PANEL3
		scroll.ScrollingDirection = Enum.ScrollingDirection.Y
		pcall(function() scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y end)
		scroll.CanvasSize = UDim2.new()
		scroll.Parent = p
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = scroll


		local phaseBanner = Instance.new("TextLabel")
		phaseBanner.Size = UDim2.new(1, -4, 0, 30)
		phaseBanner.BackgroundColor3 = C.PANEL
		phaseBanner.Font = Enum.Font.GothamMedium
		phaseBanner.TextSize = 13
		phaseBanner.TextColor3 = C.TEXT
		phaseBanner.Text = "—"
		phaseBanner.LayoutOrder = 0
		phaseBanner.Parent = scroll
		cr(phaseBanner, 8)

		local emptyNote = Instance.new("TextLabel")
		emptyNote.Size = UDim2.new(1, -4, 0, 40)
		emptyNote.BackgroundTransparency = 1
		emptyNote.Font = Enum.Font.Gotham
		emptyNote.TextSize = 12
		emptyNote.TextColor3 = C.DIM
		emptyNote.TextWrapped = true
		emptyNote.Text = "Сейчас ясно — активной погоды и лун нет."
		emptyNote.LayoutOrder = 1
		emptyNote.Parent = scroll


		local cards = {}
		local lastKeySig = nil

		local function makeCard(meta)
			local cardF = Instance.new("Frame")
			cardF.Size = UDim2.new(1, -4, 0, 64)
			cardF.BackgroundColor3 = C.PANEL
			cardF.BorderSizePixel = 0
			cardF.Parent = scroll
			cr(cardF, 8)
			local accent = Instance.new("Frame")
			accent.Size = UDim2.fromOffset(4, 48)
			accent.Position = UDim2.fromOffset(8, 8)
			accent.BackgroundColor3 = meta.color
			accent.Parent = cardF
			cr(accent, 2)


			local em = makeIcon(cardF, "disc", meta.color, 22)
			em.Position = UDim2.fromOffset(21, 13)
			local nameLbl = Instance.new("TextLabel")
			nameLbl.Size = UDim2.new(1, -110, 0, 18)
			nameLbl.Position = UDim2.fromOffset(52, 9)
			nameLbl.BackgroundTransparency = 1
			nameLbl.Font = Enum.Font.GothamBold
			nameLbl.TextSize = 14
			nameLbl.TextColor3 = C.TEXT
			nameLbl.TextXAlignment = Enum.TextXAlignment.Left
			nameLbl.Text = meta.ru
			nameLbl.Parent = cardF
			local fxLbl = Instance.new("TextLabel")
			fxLbl.Size = UDim2.new(1, -64, 0, 14)
			fxLbl.Position = UDim2.fromOffset(52, 30)
			fxLbl.BackgroundTransparency = 1
			fxLbl.Font = Enum.Font.Gotham
			fxLbl.TextSize = 11
			fxLbl.TextColor3 = C.SUBTLE
			fxLbl.TextXAlignment = Enum.TextXAlignment.Left
			fxLbl.TextTruncate = Enum.TextTruncate.AtEnd
			fxLbl.Text = (#meta.fx > 0) and table.concat(meta.fx, " · ") or "—"
			fxLbl.Parent = cardF
			local badge = Instance.new("TextLabel")
			badge.Size = UDim2.new(0, 90, 0, 16)
			badge.Position = UDim2.new(1, -98, 0, 44)
			badge.BackgroundTransparency = 1
			badge.Font = Enum.Font.GothamMedium
			badge.TextSize = 11
			badge.TextColor3 = meta.color
			badge.TextXAlignment = Enum.TextXAlignment.Right
			badge.Text = "идёт"
			badge.Parent = cardF
			return cardF, badge
		end

		updateSky = function()
			local pl = LatestParse
			local now = os.time()
			local active = {}
			if pl then
				for _, w in ipairs(pl.weather or {}) do
					if w.active then
						active[#active + 1] = { name = w.name, endTime = w.endTime, since = nil, moon = false }
					end
				end
				for _, m in ipairs(pl.moons or {}) do
					if m.active then
						active[#active + 1] = { name = m.name, endTime = nil, since = m.since, moon = true }
					end
				end
			end


			if pl then
				local night = pl.isNight == true or pl.dayPhase == "Night"
				phaseBanner.Text = (night and "Ночь" or "День")
					.. (("   ·   %d актив."):format(#active))
				phaseBanner.TextColor3 = night and C.SUBTLE or C.TEXT
			end
			emptyNote.Visible = (#active == 0)

			local keySig = ""
			for _, a in ipairs(active) do keySig = keySig .. "|" .. tostring(a.name) end
			if keySig ~= lastKeySig then
				lastKeySig = keySig
				for _, c in ipairs(cards) do c.frame:Destroy() end
				cards = {}
				for i, a in ipairs(active) do
					local meta = weatherMeta(a.name)
					local frame, badge = makeCard(meta)
					frame.LayoutOrder = i + 1
					cards[#cards + 1] = { frame = frame, badge = badge, endTime = a.endTime, since = a.since }
				end
			end


			for _, c in ipairs(cards) do
				if c.endTime then
					c.badge.Text = "осталось " .. fmtSecs(c.endTime - now)
				elseif c.since then
					c.badge.Text = "идёт " .. fmtSecs(now - c.since)
				else
					c.badge.Text = "идёт"
				end
			end
		end
	end


	do
		local p = pages["Shop"]


		local searchText = ""
		local searchBox = Instance.new("TextBox")
		searchBox.Size = UDim2.new(1, -86, 0, 26)
		searchBox.Position = UDim2.fromOffset(0, 0)
		searchBox.BackgroundColor3 = C.PANEL
		searchBox.BorderSizePixel = 0
		searchBox.Font = Enum.Font.Gotham
		searchBox.TextSize = 12
		searchBox.TextColor3 = C.TEXT
		searchBox.PlaceholderText = "Поиск по названию…"
		searchBox.PlaceholderColor3 = C.DIM
		searchBox.Text = ""
		searchBox.ClearTextOnFocus = false
		searchBox.TextXAlignment = Enum.TextXAlignment.Left
		searchBox.Parent = p
		cr(searchBox, 6)
		pad(searchBox, 28, 0, 8, 0)
		do
			local sIco = makeIcon(searchBox, "search", C.DIM, 14)
			sIco.AnchorPoint = Vector2.new(0, 0.5)
			sIco.Position = UDim2.new(0, 8, 0.5, 0)
		end

		local exportBtn = Instance.new("TextButton")
		exportBtn.Size = UDim2.fromOffset(80, 26)
		exportBtn.Position = UDim2.new(1, -80, 0, 0)
		exportBtn.BackgroundColor3 = C.PANEL2
		exportBtn.AutoButtonColor = false
		exportBtn.Font = Enum.Font.GothamMedium
		exportBtn.TextSize = 12
		exportBtn.TextColor3 = C.TEXT
		exportBtn.Text = "Копир."
		exportBtn.Parent = p
		cr(exportBtn, 6)
		pad(exportBtn, 24, 0, 6, 0)
		do
			local eIco = makeIcon(exportBtn, "copy", C.TEXT, 14)
			eIco.AnchorPoint = Vector2.new(0, 0.5)
			eIco.Position = UDim2.new(0, 8, 0.5, 0)
		end
		exportBtn.MouseEnter:Connect(function() tween(exportBtn, 0.15, {BackgroundColor3 = C.PANEL3}) end)
		exportBtn.MouseLeave:Connect(function() tween(exportBtn, 0.15, {BackgroundColor3 = C.PANEL2}) end)

		local restockBanner = Instance.new("TextLabel")
		restockBanner.Size = UDim2.new(1, -20, 0, 20)
		restockBanner.Position = UDim2.fromOffset(20, 32)
		restockBanner.BackgroundTransparency = 1
		restockBanner.Font = Enum.Font.GothamMedium
		restockBanner.TextSize = 12
		restockBanner.TextColor3 = C.SUBTLE
		restockBanner.TextXAlignment = Enum.TextXAlignment.Left
		restockBanner.Text = "Ресток: —"
		restockBanner.Parent = p
		do
			local rIco = makeIcon(p, "refresh", C.SUBTLE, 13)
			rIco.AnchorPoint = Vector2.new(0, 0.5)
			rIco.Position = UDim2.fromOffset(2, 42)
		end

		local scroll = Instance.new("ScrollingFrame")
		scroll.Size = UDim2.new(1, 0, 1, -58)
		scroll.Position = UDim2.fromOffset(0, 56)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.ScrollBarImageColor3 = C.PANEL3
		scroll.ScrollingDirection = Enum.ScrollingDirection.Y
		pcall(function() scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y end)
		scroll.CanvasSize = UDim2.new()
		scroll.Parent = p
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = scroll

		local order = 0
		local function nextOrder() order += 1; return order end

		local rows = {}
		local restockBars = {}

		local function applyFilter()
			for _, r in ipairs(rows) do
				r.frame.Visible = (searchText == "")
					or (string.find(string.lower(r.name), searchText, 1, true) ~= nil)
			end
		end

		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			searchText = string.lower(searchBox.Text)
			applyFilter()
		end)

		local function itemRow(it)
			local watched = isWatched(it.item)
			local inStock = stockCount(it.stock) > 0
			local hot = watched and inStock
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -4, 0, 30)
			row.BackgroundColor3 = hot and Color3.fromRGB(30, 46, 37) or C.PANEL
			row.BorderSizePixel = 0
			row.LayoutOrder = nextOrder()
			row.Parent = scroll
			cr(row, 6)
			if hot then
				stroke(row, C.GREEN, 1)
				local accent = Instance.new("Frame")
				accent.Size = UDim2.fromOffset(3, 20)
				accent.Position = UDim2.fromOffset(0, 5)
				accent.BackgroundColor3 = C.GREEN
				accent.Parent = row
				cr(accent, 2)
			end

			local star = Instance.new("TextButton")
			star.Size = UDim2.fromOffset(24, 24)
			star.Position = UDim2.fromOffset(4, 3)
			star.BackgroundTransparency = 1
			star.Font = Enum.Font.GothamBold
			star.TextSize = 16
			star.Text = watched and "★" or "☆"
			star.TextColor3 = watched and C.YELLOW or C.DIM
			star.AutoButtonColor = false
			star.Parent = row

			local nameLbl = Instance.new("TextLabel")
			nameLbl.Size = UDim2.new(0.55, -32, 1, 0)
			nameLbl.Position = UDim2.fromOffset(30, 0)
			nameLbl.BackgroundTransparency = 1
			nameLbl.Font = Enum.Font.GothamMedium
			nameLbl.TextSize = 12
			nameLbl.TextColor3 = C.TEXT
			nameLbl.TextXAlignment = Enum.TextXAlignment.Left
			nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
			nameLbl.Text = it.item or "?"
			nameLbl.Parent = row

			local infoLbl = Instance.new("TextLabel")
			infoLbl.Size = UDim2.new(0.45, -8, 1, 0)
			infoLbl.Position = UDim2.new(0.55, 0, 0, 0)
			infoLbl.BackgroundTransparency = 1
			infoLbl.Font = Enum.Font.Gotham
			infoLbl.TextSize = 11
			infoLbl.TextColor3 = inStock and C.GREEN or C.SUBTLE
			infoLbl.TextXAlignment = Enum.TextXAlignment.Right
			local parts = {}
			if it.stock then table.insert(parts, "x" .. tostring(stockCount(it.stock))) end
			if it.cost then table.insert(parts, tostring(it.cost)) end
			infoLbl.Text = (#parts > 0) and table.concat(parts, "  ·  ") or "-"
			infoLbl.Parent = row

			star.MouseButton1Click:Connect(function()
				local now = not isWatched(it.item)
				setWatched(it.item, now)
				star.Text = now and "★" or "☆"
				star.TextColor3 = now and C.YELLOW or C.DIM
			end)

			rows[#rows + 1] = { frame = row, name = it.item or "" }
		end


		local function shopSig(payload)
			local t = {}
			local function add(shop, tag)
				if shop then
					for _, it in ipairs(shop.items or {}) do
						t[#t + 1] = tag .. (it.item or "") .. "=" .. tostring(it.stock or "")
					end
				end
			end
			add(payload.seedShop, "S")
			add(payload.gearShop, "G")
			add(payload.crateShop, "C")
			return table.concat(t, "|")
		end

		local function clearRows()
			for _, c in ipairs(scroll:GetChildren()) do
				if not c:IsA("UIListLayout") then c:Destroy() end
			end
			order = 0
			rows = {}
			restockBars = {}
		end

		local lastSig = nil
		refreshShop = function(payload)
			payload = payload or LatestParse
			if not payload then
				if lastSig == "__none__" then return end
				lastSig = "__none__"
				clearRows()
				local note = Instance.new("TextLabel")
				note.Size = UDim2.new(1, -4, 0, 40)
				note.BackgroundTransparency = 1
				note.Font = Enum.Font.Gotham
				note.TextSize = 12
				note.TextColor3 = C.DIM
				note.TextWrapped = true
				note.Text = "Waiting for shop data…\nOpen the Seed/Gear shop in-game."
				note.LayoutOrder = nextOrder()
				note.Parent = scroll
				return
			end
			local sig = shopSig(payload)
			if sig == lastSig then return end
			lastSig = sig
			clearRows()

			local function section(title, shop)
				if not shop then return end


				local h = Instance.new("Frame")
				h.Size = UDim2.new(1, -4, 0, 20)
				h.BackgroundTransparency = 1
				h.LayoutOrder = nextOrder()
				h.Parent = scroll
				local hLbl = Instance.new("TextLabel")
				hLbl.Size = UDim2.new(0.5, 0, 1, 0)
				hLbl.BackgroundTransparency = 1
				hLbl.Font = Enum.Font.GothamBold
				hLbl.TextSize = 11
				hLbl.TextColor3 = C.DIM
				hLbl.TextXAlignment = Enum.TextXAlignment.Left
				hLbl.Text = string.upper(title)
				hLbl.Parent = h
				local tLbl = Instance.new("TextLabel")
				tLbl.Size = UDim2.new(0.5, 0, 1, 0)
				tLbl.Position = UDim2.fromScale(0.5, 0)
				tLbl.BackgroundTransparency = 1
				tLbl.Font = Enum.Font.GothamMedium
				tLbl.TextSize = 11
				tLbl.TextColor3 = C.SUBTLE
				tLbl.TextXAlignment = Enum.TextXAlignment.Right
				tLbl.Text = shop.restock and ("ресток " .. tostring(shop.restock)) or ""
				tLbl.Parent = h


				if type(shop.restockSeconds) == "number" and shop.restockSeconds > 0 then
					local track = Instance.new("Frame")
					track.Size = UDim2.new(1, -4, 0, 3)
					track.BackgroundColor3 = C.PANEL2
					track.BorderSizePixel = 0
					track.LayoutOrder = nextOrder()
					track.Parent = scroll
					cr(track, 2)
					local fill = Instance.new("Frame")
					fill.Size = UDim2.fromScale(1, 1)
					fill.BackgroundColor3 = C.GREEN
					fill.BorderSizePixel = 0
					fill.Parent = track
					cr(fill, 2)
					restockBars[#restockBars + 1] = {
						fill = fill, total = shop.restockSeconds,
						expiry = os.clock() + shop.restockSeconds, timeLbl = tLbl,
					}
				end

				local items = shop.items or {}
				if #items == 0 then
					local empty = Instance.new("TextLabel")
					empty.Size = UDim2.new(1, -4, 0, 22)
					empty.BackgroundTransparency = 1
					empty.Font = Enum.Font.Gotham
					empty.TextSize = 11
					empty.TextColor3 = C.DIM
					empty.TextXAlignment = Enum.TextXAlignment.Left
					empty.Text = "  (пусто)"
					empty.LayoutOrder = nextOrder()
					empty.Parent = scroll
				else

					local sorted = table.clone(items)
					table.sort(sorted, function(a, b)
						local ha = isWatched(a.item) and stockCount(a.stock) > 0
						local hb = isWatched(b.item) and stockCount(b.stock) > 0
						if ha ~= hb then return ha end
						return tostring(a.item) < tostring(b.item)
					end)
					for _, it in ipairs(sorted) do itemRow(it) end
				end
			end

			section("Seeds", payload.seedShop)
			section("Gear", payload.gearShop)
			section("Crates", payload.crateShop)
			applyFilter()
		end

		tickRestocks = function()
			local soonest = nil
			for _, rb in ipairs(restockBars) do
				local remaining = rb.expiry - os.clock()
				if remaining < 0 then remaining = 0 end
				if rb.timeLbl and rb.timeLbl.Parent then
					rb.timeLbl.Text = "ресток " .. fmtSecs(remaining)
				end
				if rb.fill and rb.fill.Parent then
					local frac = math.clamp(remaining / rb.total, 0, 1)
					rb.fill.Size = UDim2.fromScale(frac, 1)
					rb.fill.BackgroundColor3 = (remaining <= 15) and C.YELLOW or C.GREEN
				end
				if not soonest or remaining < soonest then soonest = remaining end
			end
			restockBanner.Text = soonest and ("Следующий ресток: " .. fmtSecs(soonest)) or "Ресток: —"
		end

		exportStock = function()
			local pl = LatestParse
			if not pl then
				if showToast then showToast("Экспорт", "Нет данных стока", C.RED) end
				return
			end
			local out = { "🌱 Garden Parser — сток" }
			local function addShop(title, shop)
				if not shop then return end
				out[#out + 1] = ""
				out[#out + 1] = title .. (shop.restock and ("  (ресток " .. tostring(shop.restock) .. ")") or "")
				for _, it in ipairs(shop.items or {}) do
					out[#out + 1] = string.format("  • %s — x%d%s",
						it.item or "?", stockCount(it.stock),
						it.cost and ("  " .. tostring(it.cost)) or "")
				end
			end
			addShop("Seeds", pl.seedShop)
			addShop("Gear", pl.gearShop)
			addShop("Crates", pl.crateShop)
			local active = {}
			for _, w in ipairs(pl.weather or {}) do if w.active then active[#active + 1] = w.name end end
			for _, m in ipairs(pl.moons or {}) do if m.active then active[#active + 1] = m.name end end
			if #active > 0 then
				out[#out + 1] = ""
				out[#out + 1] = "Погода/луны: " .. table.concat(active, ", ")
			end
			local text = table.concat(out, "\n")
			if copyToClipboard(text) then
				if showToast then showToast("Скопировано", "Сток в буфере обмена", C.GREEN) end
			else
				if showToast then showToast("Экспорт", "Буфер недоступен в этом executor", C.RED) end
			end
		end
		exportBtn.MouseButton1Click:Connect(function() exportStock() end)

		refreshShop(LatestParse)
	end


	do
		local p = pages["Controls"]
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = p

		local function toggleCard(order, label, desc, getter, setter)
			local f = Instance.new("Frame")
			f.Size = UDim2.new(1, 0, 0, 52)
			f.BackgroundColor3 = C.PANEL
			f.BorderSizePixel = 0
			f.LayoutOrder = order
			f.Parent = p
			cr(f, 8)

			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(1, -80, 0, 18)
			lbl.Position = UDim2.fromOffset(12, 9)
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.GothamMedium
			lbl.TextSize = 14
			lbl.TextColor3 = C.TEXT
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.Text = label
			lbl.Parent = f

			local sub = Instance.new("TextLabel")
			sub.Size = UDim2.new(1, -80, 0, 14)
			sub.Position = UDim2.fromOffset(12, 29)
			sub.BackgroundTransparency = 1
			sub.Font = Enum.Font.Gotham
			sub.TextSize = 11
			sub.TextColor3 = C.DIM
			sub.TextXAlignment = Enum.TextXAlignment.Left
			sub.Text = desc
			sub.Parent = f

			local track = Instance.new("Frame")
			track.Size = UDim2.fromOffset(44, 24)
			track.Position = UDim2.new(1, -56, 0.5, -12)
			track.BackgroundColor3 = C.PANEL3
			track.Parent = f
			cr(track, 12)

			local knob = Instance.new("Frame")
			knob.Size = UDim2.fromOffset(18, 18)
			knob.Position = UDim2.fromOffset(3, 3)
			knob.BackgroundColor3 = Color3.fromRGB(220, 222, 228)
			knob.Parent = track
			cr(knob, 9)

			local btn = Instance.new("TextButton")
			btn.Size = UDim2.fromScale(1, 1)
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.Parent = f

			local function refresh(animate)
				local on = getter()
				local kpos = on and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3)
				local tcol = on and C.GREEN or C.PANEL3
				if animate then
					tween(knob, 0.18, {Position = kpos}, Enum.EasingStyle.Back)
					tween(track, 0.18, {BackgroundColor3 = tcol})
				else
					knob.Position = kpos
					track.BackgroundColor3 = tcol
				end
			end

			btn.MouseButton1Click:Connect(function()
				setter(not getter())
				refresh(true)
			end)
			refresh(false)
		end

		toggleCard(1, "Send to Server", "Parse UI and stream data",
			function() return Settings.ParsingEnabled end,
			function(v) Settings.ParsingEnabled = v; saveConfig() end)

		toggleCard(2, "Anti-AFK", "Simulate input to avoid kick",
			function() return Settings.AntiAFKEnabled end,
			function(v)
				Settings.AntiAFKEnabled = v
				if v then AntiAFK.start() else AntiAFK.stop() end
				saveConfig()
			end)

		toggleCard(3, "Sound alerts", "Play a sound on watchlist hits",
			function() return Settings.soundAlerts end,
			function(v) Settings.soundAlerts = v; saveConfig() end)

		toggleCard(4, "Weather & moon alerts", "Toast + sound when one starts",
			function() return Settings.weatherAlerts end,
			function(v) Settings.weatherAlerts = v; saveConfig() end)

		toggleCard(5, "Compact mode", "Shrink the window",
			function() return Settings.compact end,
			function(v) Settings.compact = v; applyCompact(v); saveConfig() end)


		local function sliderCard(order, label, desc, get01, set01)
			local f = Instance.new("Frame")
			f.Size = UDim2.new(1, 0, 0, 62)
			f.BackgroundColor3 = C.PANEL
			f.BorderSizePixel = 0
			f.LayoutOrder = order
			f.Parent = p
			cr(f, 8)

			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(1, -24, 0, 18)
			lbl.Position = UDim2.fromOffset(12, 8)
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.GothamMedium
			lbl.TextSize = 14
			lbl.TextColor3 = C.TEXT
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.Text = label
			lbl.Parent = f

			local sub = Instance.new("TextLabel")
			sub.Size = UDim2.new(1, -24, 0, 14)
			sub.Position = UDim2.fromOffset(12, 28)
			sub.BackgroundTransparency = 1
			sub.Font = Enum.Font.Gotham
			sub.TextSize = 11
			sub.TextColor3 = C.DIM
			sub.TextXAlignment = Enum.TextXAlignment.Left
			sub.Text = desc
			sub.Parent = f

			local track = Instance.new("Frame")
			track.Size = UDim2.new(1, -24, 0, 6)
			track.Position = UDim2.fromOffset(12, 48)
			track.BackgroundColor3 = C.PANEL3
			track.Active = true
			track.Parent = f
			cr(track, 3)
			local fill = Instance.new("Frame")
			fill.Size = UDim2.fromScale(math.clamp(get01(), 0, 1), 1)
			fill.BackgroundColor3 = C.GREEN
			fill.BorderSizePixel = 0
			fill.Parent = track
			cr(fill, 3)
			local knob = Instance.new("Frame")
			knob.Size = UDim2.fromOffset(14, 14)
			knob.AnchorPoint = Vector2.new(0.5, 0.5)
			knob.Position = UDim2.new(math.clamp(get01(), 0, 1), 0, 0.5, 0)
			knob.BackgroundColor3 = Color3.fromRGB(230, 232, 238)
			knob.Active = true
			knob.Parent = track
			cr(knob, 7)

			local dragging = false
			local function setFrac(frac, fire)
				frac = math.clamp(frac, 0, 1)
				fill.Size = UDim2.fromScale(frac, 1)
				knob.Position = UDim2.new(frac, 0, 0.5, 0)
				if fire then set01(frac) end
			end
			local function fromX(px)
				setFrac((px - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), true)
			end
			local function beginDrag(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					fromX(input.Position.X)
				end
			end
			track.InputBegan:Connect(beginDrag)
			knob.InputBegan:Connect(beginDrag)
			UserInputService.InputChanged:Connect(function(input)
				if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch) then
					fromX(input.Position.X)
				end
			end)
			UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					dragging = false
				end
			end)
		end

		sliderCard(6, "Window opacity", "Higher = more transparent (fades when idle)",
			function() return baseOpacity / 0.85 end,
			function(frac) setOpacity(frac * 0.85) end)
	end


	do
		local p = pages["Teleport"]

		local listScroll = Instance.new("ScrollingFrame")
		listScroll.Size = UDim2.fromScale(1, 1)
		listScroll.BackgroundTransparency = 1
		listScroll.BorderSizePixel = 0
		listScroll.ScrollBarThickness = 4
		listScroll.ScrollBarImageColor3 = C.PANEL3
		listScroll.ScrollingDirection = Enum.ScrollingDirection.Y
		pcall(function() listScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y end)
		listScroll.CanvasSize = UDim2.new()
		listScroll.Parent = p
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = listScroll

		local function spotButton(order, name, getCF)
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(1, -4, 0, 40)
			btn.BackgroundColor3 = C.PANEL
			btn.AutoButtonColor = false
			btn.Text = ""
			btn.LayoutOrder = order
			btn.Parent = listScroll
			cr(btn, 8)
			local pinIco = makeIcon(btn, "pin", C.GREEN, 16)
			pinIco.AnchorPoint = Vector2.new(0, 0.5)
			pinIco.Position = UDim2.new(0, 12, 0.5, 0)
			local nameLbl = Instance.new("TextLabel")
			nameLbl.Size = UDim2.new(1, -64, 1, 0)
			nameLbl.Position = UDim2.fromOffset(36, 0)
			nameLbl.BackgroundTransparency = 1
			nameLbl.Font = Enum.Font.GothamMedium
			nameLbl.TextSize = 14
			nameLbl.TextColor3 = C.TEXT
			nameLbl.TextXAlignment = Enum.TextXAlignment.Left
			nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
			nameLbl.Text = name
			nameLbl.Parent = btn
			local chev = makeIcon(btn, "chevron", C.DIM, 14)
			chev.AnchorPoint = Vector2.new(1, 0.5)
			chev.Position = UDim2.new(1, -12, 0.5, 0)
			btn.MouseEnter:Connect(function() tween(btn, 0.15, {BackgroundColor3 = C.PANEL3}) end)
			btn.MouseLeave:Connect(function() tween(btn, 0.15, {BackgroundColor3 = C.PANEL}) end)
			btn.MouseButton1Click:Connect(function()
				local cf = getCF()
				if cf and teleportTo(cf) then
					info("Teleported to " .. name)
				else
					warnl("Teleport failed: " .. name)
				end
			end)
		end

		local function rebuild()
			for _, c in ipairs(listScroll:GetChildren()) do
				if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
			end

			local rescan = Instance.new("TextButton")
			rescan.Size = UDim2.new(1, -4, 0, 30)
			rescan.BackgroundColor3 = C.PANEL2
			rescan.AutoButtonColor = false
			rescan.Font = Enum.Font.GothamMedium
			rescan.TextSize = 12
			rescan.TextColor3 = C.SUBTLE
			rescan.Text = "Пересканировать"
			rescan.LayoutOrder = 0
			rescan.Parent = listScroll
			cr(rescan, 8)
			pad(rescan, 26, 0, 6, 0)
			do
				local rIco = makeIcon(rescan, "refresh", C.SUBTLE, 14)
				rIco.AnchorPoint = Vector2.new(0, 0.5)
				rIco.Position = UDim2.new(0, 9, 0.5, 0)
			end

			local dests = getTeleportDestinations()
			if #dests == 0 then
				local note = Instance.new("TextLabel")
				note.Size = UDim2.new(1, -4, 0, 40)
				note.BackgroundTransparency = 1
				note.Font = Enum.Font.Gotham
				note.TextSize = 12
				note.TextColor3 = C.DIM
				note.TextWrapped = true
				note.Text = "No teleport pads found.\nOpen the teleport menu in-game, then Rescan."
				note.LayoutOrder = 1
				note.Parent = listScroll
			else
				for i, spot in ipairs(dests) do
					spotButton(i, spot.Name, function() return spot.CFrame end)
				end
			end

			rescan.MouseButton1Click:Connect(rebuild)
			rescan.MouseEnter:Connect(function() tween(rescan, 0.15, {BackgroundColor3 = C.PANEL3}) end)
			rescan.MouseLeave:Connect(function() tween(rescan, 0.15, {BackgroundColor3 = C.PANEL2}) end)
		end

		rebuild()
	end


	local logScroll
	local logFilter = ""
	local lastLogSeq = -1
	do
		local p = pages["Log"]

		local searchBox = Instance.new("TextBox")
		searchBox.Size = UDim2.new(1, 0, 0, 26)
		searchBox.Position = UDim2.fromOffset(0, 0)
		searchBox.BackgroundColor3 = C.PANEL
		searchBox.BorderSizePixel = 0
		searchBox.Font = Enum.Font.Gotham
		searchBox.TextSize = 12
		searchBox.TextColor3 = C.TEXT
		searchBox.PlaceholderText = "Фильтр логов…"
		searchBox.PlaceholderColor3 = C.DIM
		searchBox.Text = ""
		searchBox.ClearTextOnFocus = false
		searchBox.TextXAlignment = Enum.TextXAlignment.Left
		searchBox.Parent = p
		cr(searchBox, 6)
		pad(searchBox, 28, 0, 8, 0)
		do
			local sIco = makeIcon(searchBox, "search", C.DIM, 14)
			sIco.AnchorPoint = Vector2.new(0, 0.5)
			sIco.Position = UDim2.new(0, 8, 0.5, 0)
		end

		logScroll = Instance.new("ScrollingFrame")
		logScroll.Size = UDim2.new(1, 0, 1, -32)
		logScroll.Position = UDim2.fromOffset(0, 32)
		logScroll.BackgroundColor3 = C.BG2
		logScroll.BorderSizePixel = 0
		logScroll.ScrollBarThickness = 4
		logScroll.ScrollBarImageColor3 = C.PANEL3
		logScroll.ScrollingDirection = Enum.ScrollingDirection.Y
		pcall(function() logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y end)
		logScroll.CanvasSize = UDim2.new()
		logScroll.Parent = p
		cr(logScroll, 8)
		pad(logScroll, 8, 8, 8, 8)
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 2)
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Parent = logScroll

		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			logFilter = string.lower(searchBox.Text)
			lastLogSeq = -1
		end)
	end

	local function updateLog()
		local lines = Logger.lines


		if Logger.seq == lastLogSeq then return end
		lastLogSeq = Logger.seq
		for _, c in ipairs(logScroll:GetChildren()) do
			if not (c:IsA("UIListLayout") or c:IsA("UIPadding")) then c:Destroy() end
		end

		local matched = {}
		for i = #lines, 1, -1 do
			local txt = lines[i]
			if txt and (logFilter == "" or string.find(string.lower(txt), logFilter, 1, true)) then
				matched[#matched + 1] = txt
				if #matched >= 60 then break end
			end
		end
		for idx = #matched, 1, -1 do
			local txt = matched[idx]
			local col = C.SUBTLE
			if string.find(txt, "%[ERR%]") then
				col = C.RED
			elseif string.find(txt, "%[WARN%]") then
				col = C.YELLOW
			end
			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(1, 0, 0, 14)
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.Code
			lbl.TextSize = 11
			lbl.TextColor3 = col
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextTruncate = Enum.TextTruncate.AtEnd
			lbl.Text = txt
			lbl.LayoutOrder = (#matched - idx)
			lbl.Parent = logScroll
		end
		task.wait()
		pcall(function()
			logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
		end)
	end


	local toastHolder = Instance.new("Frame")
	toastHolder.Size = UDim2.fromOffset(260, 320)
	toastHolder.AnchorPoint = Vector2.new(1, 1)
	toastHolder.Position = UDim2.new(1, -16, 1, -16)
	toastHolder.BackgroundTransparency = 1
	toastHolder.Parent = sg
	do
		local tl = Instance.new("UIListLayout")
		tl.VerticalAlignment = Enum.VerticalAlignment.Bottom
		tl.HorizontalAlignment = Enum.HorizontalAlignment.Right
		tl.Padding = UDim.new(0, 6)
		tl.SortOrder = Enum.SortOrder.LayoutOrder
		tl.Parent = toastHolder
	end

	local SoundService = game:GetService("SoundService")
	local alertSound = Instance.new("Sound")
	alertSound.SoundId = "rbxassetid://4590662766"
	alertSound.Volume = 0.6
	alertSound.Parent = sg

	local function playAlertSound()
		if not Settings.soundAlerts then return end
		pcall(function()
			alertSound.TimePosition = 0
			SoundService:PlayLocalSound(alertSound)
		end)
	end

	showToast = function(titleText, bodyText, accent)
		accent = accent or C.GREEN
		local card = Instance.new("Frame")
		card.Size = UDim2.new(1, 0, 0, 52)
		card.BackgroundColor3 = C.PANEL2
		card.BorderSizePixel = 0
		card.Parent = toastHolder
		cr(card, 8)
		stroke(card, accent, 1)

		local bar2 = Instance.new("Frame")
		bar2.Size = UDim2.fromOffset(3, 40)
		bar2.Position = UDim2.fromOffset(8, 6)
		bar2.BackgroundColor3 = accent
		bar2.Parent = card
		cr(bar2, 2)

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -26, 0, 18)
		t.Position = UDim2.fromOffset(18, 8)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.TextSize = 13
		t.TextColor3 = C.TEXT
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Text = titleText
		t.Parent = card

		local b = Instance.new("TextLabel")
		b.Size = UDim2.new(1, -26, 0, 16)
		b.Position = UDim2.fromOffset(18, 27)
		b.BackgroundTransparency = 1
		b.Font = Enum.Font.Gotham
		b.TextSize = 12
		b.TextColor3 = C.SUBTLE
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextTruncate = Enum.TextTruncate.AtEnd
		b.Text = bodyText or ""
		b.Parent = card

		local sc = Instance.new("UIScale")
		sc.Scale = 0.6
		sc.Parent = card
		tween(sc, 0.2, {Scale = 1}, Enum.EasingStyle.Back)

		task.delay(4.5, function()
			tween(sc, 0.2, {Scale = 0}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.wait(0.22)
			card:Destroy()
		end)
	end


	local grip = Instance.new("TextButton")
	grip.Size = UDim2.fromOffset(20, 20)
	grip.Position = UDim2.new(1, -22, 1, -22)
	grip.BackgroundTransparency = 1
	grip.Text = "◢"
	grip.Font = Enum.Font.GothamBold
	grip.TextSize = 14
	grip.TextColor3 = C.DIM
	grip.AutoButtonColor = false
	grip.Parent = win


	local minibar = Instance.new("Frame")
	minibar.Name = "Minibar"
	minibar.Size = UDim2.fromScale(1, 1)
	minibar.BackgroundTransparency = 1
	minibar.Visible = false
	minibar.Active = true
	minibar.Parent = win
	local mbLogo = Instance.new("Frame")
	mbLogo.Size = UDim2.fromOffset(20, 20)
	mbLogo.Position = UDim2.fromOffset(11, 11)
	mbLogo.BackgroundColor3 = C.GREEN
	mbLogo.Parent = minibar
	cr(mbLogo, 6)
	local mbName = Instance.new("TextLabel")
	mbName.Size = UDim2.new(1, -116, 1, 0)
	mbName.Position = UDim2.fromOffset(38, 0)
	mbName.BackgroundTransparency = 1
	mbName.Font = Enum.Font.GothamBold
	mbName.TextSize = 12
	mbName.TextColor3 = C.TEXT
	mbName.TextXAlignment = Enum.TextXAlignment.Left
	mbName.Text = "Garden Parser"
	mbName.Parent = minibar

	local mbGrip = Instance.new("TextButton")
	mbGrip.Size = UDim2.new(1, -74, 1, 0)
	mbGrip.BackgroundTransparency = 1
	mbGrip.Text = ""
	mbGrip.Active = true
	mbGrip.Parent = minibar

	local mbSeg, mbBtns = segment(minibar, {
		{ key = "expand", icon = "expand" },
		{ key = "close", icon = "close", close = true },
	})
	mbSeg.AnchorPoint = Vector2.new(1, 0.5)
	mbSeg.Position = UDim2.new(1, -8, 0.5, 0)
	local expandBtn = mbBtns.expand
	local closeBtn2 = mbBtns.close


	local collapsed = false
	local fullSize = win.Size
	local function destroyGUI()
		tween(winScale, 0.16, {Scale = 0}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.18, function() sg:Destroy() end)
	end
	local function setCollapsed(state)
		if collapsed == state then return end
		collapsed = state
		if state then
			fullSize = win.Size
			rail.Visible = false
			stage.Visible = false
			grip.Visible = false
			minibar.Visible = true
			tween(win, 0.26, {Size = UDim2.fromOffset(184, 42)}, Enum.EasingStyle.Quart)
		else
			minibar.Visible = false
			tween(win, 0.26, {Size = fullSize}, Enum.EasingStyle.Quart)
			task.delay(0.26, function()
				if not collapsed then
					rail.Visible = true
					stage.Visible = true
					grip.Visible = true
				end
			end)
		end
	end

	hideBtn.MouseButton1Click:Connect(function() setCollapsed(true) end)
	expandBtn.MouseButton1Click:Connect(function() setCollapsed(false) end)
	closeBtn.MouseButton1Click:Connect(destroyGUI)
	closeBtn2.MouseButton1Click:Connect(destroyGUI)


	local function makeDraggable(handle)
		local dragging, dragStart, startPos
		handle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = win.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						dragging = false
						if not collapsed then persistGeometry() end
					end
				end)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				win.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + d.X,
					startPos.Y.Scale, startPos.Y.Offset + d.Y
				)
			end
		end)
	end
	makeDraggable(topbar)
	makeDraggable(mbGrip)


	do
		local resizing, startInput, startSize
		grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				resizing = true
				startInput = input.Position
				startSize = win.AbsoluteSize
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						resizing = false
						persistGeometry()
					end
				end)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - startInput
				local nw = math.clamp(startSize.X + d.X, MIN_W, MAX_W)
				local nh = math.clamp(startSize.Y + d.Y, MIN_H, MAX_H)
				win.Size = UDim2.fromOffset(nw, nh)
			end
		end)
	end


	task.spawn(function()
		local lastPackets = Stats.sentPackets
		local packHist = {}
		for i = 1, 32 do packHist[i] = 0 end
		while Running and sg.Parent do
			pcall(function()
				local conn = Net.connected
				connDot.BackgroundColor3 = conn and C.GREEN or C.RED
				connLbl.Text = conn and "Connected" or "Disconnected"
				connLbl.TextColor3 = conn and C.TEXT or C.SUBTLE

				local parsing = Settings.ParsingEnabled
				parseDot.BackgroundColor3 = parsing and C.GREEN or C.RED
				parseLbl.Text = parsing and "Parser active" or "Parser stopped"

				railDot.BackgroundColor3 = conn and C.GREEN or C.RED
				footLbl.Text = (conn and "Подключено · " or "Нет связи · ") .. SERVER_IP

				local uptime = os.time() - Stats.startTime
				vUptime.Text = fmtUptime(uptime)
				vPackets.Text = tostring(Stats.sentPackets)
				vItems.Text = tostring(Stats.itemsFound)
				if Stats.lastServerMs then
					local ago = os.time() - Stats.lastServerMs
					vPing.Text = (ago <= 1) and "just now" or (tostring(ago) .. "s ago")
				else
					vPing.Text = "—"
				end


				local rate = Stats.sentPackets / math.max(1, uptime / 60)
				if vRate then vRate.Text = string.format("%.1f", rate) end
				if vWeatherSeen then vWeatherSeen.Text = tostring(Stats.weatherSeen) end
				if vMoonsSeen then vMoonsSeen.Text = tostring(Stats.moonsSeen) end


				if sparkBars then
					local delta = Stats.sentPackets - lastPackets
					lastPackets = Stats.sentPackets
					table.remove(packHist, 1)
					packHist[#packHist + 1] = delta
					local maxV = 1
					for _, v in ipairs(packHist) do if v > maxV then maxV = v end end
					for i, barFrame in ipairs(sparkBars) do
						local v = packHist[i] or 0
						local hpx = math.max(1, math.floor((v / maxV) * 16))
						barFrame.Size = UDim2.new(0, 3, 0, hpx)
						barFrame.BackgroundColor3 = (v > 0) and C.GREEN or C.PANEL3
					end
				end
			end)
			if updateSky then pcall(updateSky) end
			if tickRestocks then pcall(tickRestocks) end
			pcall(updateLog)
			task.wait(0.5)
		end
	end)


	task.spawn(function()
		local watchState = {}
		local condState = {}
		while Running and sg.Parent do


			local pl = LatestParse
			local ok, built = pcall(buildPayload)
			if ok and built then
				pl = built
				LatestParse = built
			end
			if pl then
				pcall(function() refreshShop(pl) end)
				local function scan(shop)
					if not shop or not shop.items then return end
					for _, it in ipairs(shop.items) do
						if it.item and isWatched(it.item) then
							local key = string.lower(it.item)
							local avail = stockCount(it.stock) > 0
							if avail and not watchState[key] then
								watchState[key] = true
								if showToast then
									local body = "x" .. stockCount(it.stock)
									if it.cost then body = body .. "  ·  " .. tostring(it.cost) end
									showToast("In stock: " .. it.item, body, C.GREEN)
								end
								playAlertSound()
								Stats.watchHits += 1
								info("Watchlist hit: " .. it.item)
							elseif not avail then
								watchState[key] = nil
							end
						end
					end
				end
				pcall(function()
					scan(pl.seedShop)
					scan(pl.gearShop)
					scan(pl.crateShop)
				end)


				pcall(function()
					local function condScan(list, isMoon)
						for _, c in ipairs(list or {}) do
							if c.name then
								local key = (isMoon and "moon:" or "wx:") .. string.lower(c.name)
								if c.active and not condState[key] then
									condState[key] = true
									if isMoon then Stats.moonsSeen += 1 else Stats.weatherSeen += 1 end
									local meta = weatherMeta(c.name)
									if Settings.weatherAlerts and showToast then
										showToast((isMoon and "Луна: " or "Погода: ") .. meta.ru,
											(#meta.fx > 0) and table.concat(meta.fx, " · ") or "началось",
											meta.color)
										playAlertSound()
									end
									info((isMoon and "Moon started: " or "Weather started: ") .. tostring(c.name))
								elseif not c.active and condState[key] then
									condState[key] = nil
								end
							end
						end
					end
					condScan(pl.weather, false)
					condScan(pl.moons, true)
				end)
			end
			task.wait(2)
		end
	end)


	tween(winScale, 0.42, {Scale = 1}, Enum.EasingStyle.Quart)
end

task.spawn(function()
	task.wait(START_DELAY + 0.5)
	createGUI()
end)
