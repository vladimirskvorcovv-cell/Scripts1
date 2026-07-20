--!nonstrict

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = select(2, pcall(function()
	return game:GetService("VirtualInputManager")
end))

local LocalPlayer = Players.LocalPlayer

local Config = {
	FlySpeed = 50,
	FastSpeed = 120,
	MinSpeed = 1,
	MaxSpeed = 300,
	FlySmooth = 10,
	Hotkey = Enum.KeyCode.F,
	AntiAFKHotkey = Enum.KeyCode.G,
	NoClipHotkey = Enum.KeyCode.N,
	ClickerHotkey = Enum.KeyCode.C,
	ESPHotkey = Enum.KeyCode.V,
	GuiHotkey = Enum.KeyCode.RightShift,
	AntiAFKInterval = 120,
	MinAntiAFKInterval = 10,
	MaxAntiAFKInterval = 3600,
	KeyTapTime = 0.08,
	ClickInterval = 0.1,
	MinClickInterval = 0.03,
	MaxClickInterval = 10,
	MinFastSpeed = 1,
	MaxFastSpeed = 600,
	ClickButton = "Left",
	ClickTargetEnabled = false,
	ClickTargetX = nil,
	ClickTargetY = nil,
}

local Theme = {
	Window = Color3.fromRGB(24, 25, 31),
	Panel = Color3.fromRGB(33, 35, 44),
	PanelSoft = Color3.fromRGB(40, 43, 54),
	Stroke = Color3.fromRGB(61, 65, 78),
	Text = Color3.fromRGB(241, 243, 248),
	Muted = Color3.fromRGB(159, 166, 181),
	Accent = Color3.fromRGB(55, 153, 117),
	AccentDark = Color3.fromRGB(37, 108, 84),
	Off = Color3.fromRGB(69, 73, 86),
	Button = Color3.fromRGB(48, 51, 63),
	Danger = Color3.fromRGB(176, 74, 74),
}

local function getCharacter()
	return LocalPlayer.Character
end

local function getRootAndHumanoid()
	local character = getCharacter()
	if not character then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart"), character:FindFirstChildOfClass("Humanoid")
end

local function clampNumber(value, minValue, maxValue)
	value = tonumber(value)
	if not value then
		return nil
	end
	return math.clamp(value, minValue, maxValue)
end

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function destroy(instance)
	if instance then
		instance:Destroy()
	end
end

local random = Random.new()
local antiAfkKeys = {
	Enum.KeyCode.W,
	Enum.KeyCode.A,
	Enum.KeyCode.S,
	Enum.KeyCode.D,
}

local function hasVirtualInput()
	return typeof(VirtualInputManager) == "Instance"
end

local function tapKey(keyCode, holdTime)
	if not hasVirtualInput() then
		return false, "VirtualInputManager is unavailable"
	end
	local ok, err = pcall(function()
		VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
		task.wait(holdTime or Config.KeyTapTime)
		VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
	end)
	if not ok then
		return false, err
	end
	return true
end

local function clickMouse()
	if not hasVirtualInput() then
		return false, "VirtualInputManager is unavailable"
	end

	local ok, err = pcall(function()
		local position = UserInputService:GetMouseLocation()
		if Config.ClickTargetEnabled and type(Config.ClickTargetX) == "number" and type(Config.ClickTargetY) == "number" then
			position = Vector2.new(Config.ClickTargetX, Config.ClickTargetY)
		end
		local buttonIndex = Config.ClickButton == "Right" and 1 or 0
		VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, buttonIndex, true, game, 0)
		task.wait(0.015)
		VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, buttonIndex, false, game, 0)
	end)
	if not ok then
		return false, err
	end
	return true
end

local Fly = {
	Enabled = false,
	_render = nil,
	_inputBegan = nil,
	_inputEnded = nil,
	_root = nil,
	_keys = {},
	_vel = Vector3.zero,
	_attach = nil,
	_lv = nil,
	_ao = nil,
	_humanoid = nil,
	_prevPlatformStand = nil,
	_prevAutoRotate = nil,
}

local FLY_KEYS = {
	[Enum.KeyCode.W] = true,
	[Enum.KeyCode.A] = true,
	[Enum.KeyCode.S] = true,
	[Enum.KeyCode.D] = true,
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.LeftShift] = true,
}

local function getCameraVectors()
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.zero, Vector3.zero
	end
	local cframe = camera.CFrame
	return cframe.LookVector, cframe.RightVector
end

function Fly.start()
	if Fly.Enabled then
		return true
	end

	local root, humanoid = getRootAndHumanoid()
	if not root or not humanoid or humanoid.Health <= 0 then
		return false, "Character is not ready"
	end

	Fly.Enabled = true
	Fly._keys = {}
	Fly._root = root
	Fly._humanoid = humanoid
	Fly._vel = Vector3.zero
	Fly._prevPlatformStand = humanoid.PlatformStand
	Fly._prevAutoRotate = humanoid.AutoRotate

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false

	local attach = Instance.new("Attachment")
	attach.Name = "FlyAttach"
	attach.Parent = root

	local lv = Instance.new("LinearVelocity")
	lv.Name = "FlyVelocity"
	lv.Attachment0 = attach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root

	local ao = Instance.new("AlignOrientation")
	ao.Name = "FlyOrientation"
	ao.Attachment0 = attach
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.RigidityEnabled = false
	ao.Responsiveness = 50
	ao.MaxTorque = math.huge
	ao.Parent = root

	Fly._attach = attach
	Fly._lv = lv
	Fly._ao = ao

	Fly._inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if FLY_KEYS[input.KeyCode] then
			Fly._keys[input.KeyCode] = true
		end
	end)

	Fly._inputEnded = UserInputService.InputEnded:Connect(function(input)
		if FLY_KEYS[input.KeyCode] then
			Fly._keys[input.KeyCode] = nil
		end
	end)

	Fly._render = RunService.RenderStepped:Connect(function(dt)
		if not Fly.Enabled or not root.Parent or not humanoid.Parent or humanoid.Health <= 0 then
			Fly.stop()
			return
		end

		local look, right = getCameraVectors()
		local move = Vector3.zero
		local keys = Fly._keys

		if keys[Enum.KeyCode.W] then move += look end
		if keys[Enum.KeyCode.S] then move -= look end
		if keys[Enum.KeyCode.D] then move += right end
		if keys[Enum.KeyCode.A] then move -= right end
		if keys[Enum.KeyCode.Space] then move += Vector3.yAxis end
		if keys[Enum.KeyCode.LeftControl] then move -= Vector3.yAxis end

		local speed = keys[Enum.KeyCode.LeftShift] and Config.FastSpeed or Config.FlySpeed
		local targetVel = Vector3.zero

		if move.Magnitude > 0 then
			targetVel = move.Unit * speed
		end

		Fly._vel = Fly._vel:Lerp(targetVel, math.clamp(Config.FlySmooth * dt, 0, 1))

		if lv.Parent then
			lv.VectorVelocity = Fly._vel
		end

		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude < 0.001 then
			flatLook = Vector3.new(0, 0, -1)
		end

		if ao.Parent then
			ao.CFrame = CFrame.lookAt(Vector3.zero, flatLook.Unit)
		end
	end)

	return true
end

function Fly.stop()
	if not Fly.Enabled and not Fly._lv and not Fly._ao and not Fly._attach then
		return true
	end

	Fly.Enabled = false
	Fly._keys = {}

	disconnect(Fly._render)
	disconnect(Fly._inputBegan)
	disconnect(Fly._inputEnded)

	Fly._render = nil
	Fly._inputBegan = nil
	Fly._inputEnded = nil

	destroy(Fly._lv)
	destroy(Fly._ao)
	destroy(Fly._attach)

	Fly._lv = nil
	Fly._ao = nil
	Fly._attach = nil
	Fly._root = nil
	Fly._vel = Vector3.zero

	local humanoid = Fly._humanoid
	if humanoid and humanoid.Parent then
		humanoid.PlatformStand = if Fly._prevPlatformStand == nil then false else Fly._prevPlatformStand
		humanoid.AutoRotate = if Fly._prevAutoRotate == nil then true else Fly._prevAutoRotate
	end

	Fly._humanoid = nil
	Fly._prevPlatformStand = nil
	Fly._prevAutoRotate = nil

	return true
end

function Fly.toggle(state)
	if state then
		return Fly.start()
	end
	return Fly.stop()
end

local AntiAFK = {
	Enabled = false,
	_token = 0,
}

function AntiAFK.pressRandomKey()
	local keyCode = antiAfkKeys[random:NextInteger(1, #antiAfkKeys)]
	return tapKey(keyCode, Config.KeyTapTime)
end

function AntiAFK.start()
	if AntiAFK.Enabled then
		return true
	end
	if not hasVirtualInput() then
		return false, "VirtualInputManager is unavailable"
	end

	AntiAFK.Enabled = true
	AntiAFK._token += 1
	local token = AntiAFK._token

	task.spawn(function()
		while AntiAFK.Enabled and AntiAFK._token == token do
			local ok = AntiAFK.pressRandomKey()
			if not ok then
				AntiAFK.stop()
				break
			end
			local elapsed = 0
			while elapsed < Config.AntiAFKInterval and AntiAFK.Enabled and AntiAFK._token == token do
				elapsed += task.wait(1)
			end
		end
	end)

	return true
end

function AntiAFK.stop()
	if not AntiAFK.Enabled then
		return true
	end
	AntiAFK.Enabled = false
	AntiAFK._token += 1
	return true
end

function AntiAFK.toggle(state)
	if state then
		return AntiAFK.start()
	end
	return AntiAFK.stop()
end

local Clicker = {
	Enabled = false,
	_token = 0,
}

function Clicker.start()
	if Clicker.Enabled then
		return true
	end
	if not hasVirtualInput() then
		return false, "VirtualInputManager is unavailable"
	end

	Clicker.Enabled = true
	Clicker._token += 1
	local token = Clicker._token

	task.spawn(function()
		while Clicker.Enabled and Clicker._token == token do
			local ok = clickMouse()
			if not ok then
				Clicker.stop()
				break
			end
			task.wait(Config.ClickInterval)
		end
	end)

	return true
end

function Clicker.stop()
	if not Clicker.Enabled then
		return true
	end
	Clicker.Enabled = false
	Clicker._token += 1
	return true
end

function Clicker.toggle(state)
	if state then
		return Clicker.start()
	end
	return Clicker.stop()
end

local NoClip = {
	Enabled = false,
	_conn = nil,
	_descendantAdded = nil,
	_parts = {},
	_original = setmetatable({}, { __mode = "k" }),
}

local function registerNoClipPart(part)
	if not part:IsA("BasePart") then
		return
	end
	if NoClip._original[part] == nil then
		NoClip._original[part] = part.CanCollide
		table.insert(NoClip._parts, part)
	end
	part.CanCollide = false
end

local function scanNoClipCharacter()
	local character = getCharacter()
	if not character then
		return false
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		registerNoClipPart(descendant)
	end
	disconnect(NoClip._descendantAdded)
	NoClip._descendantAdded = character.DescendantAdded:Connect(registerNoClipPart)
	return true
end

function NoClip.start()
	if NoClip.Enabled then
		return true
	end

	if not scanNoClipCharacter() then
		return false, "Character is not ready"
	end

	NoClip.Enabled = true
	NoClip._conn = RunService.Stepped:Connect(function()
		if not NoClip.Enabled then
			return
		end

		for index = #NoClip._parts, 1, -1 do
			local part = NoClip._parts[index]
			if part.Parent then
				if part.CanCollide then
					part.CanCollide = false
				end
			else
				table.remove(NoClip._parts, index)
				NoClip._original[part] = nil
			end
		end
	end)

	return true
end

function NoClip.stop()
	if not NoClip.Enabled and not NoClip._conn and not NoClip._descendantAdded then
		return true
	end

	NoClip.Enabled = false

	disconnect(NoClip._conn)
	disconnect(NoClip._descendantAdded)

	NoClip._conn = nil
	NoClip._descendantAdded = nil

	for _, part in ipairs(NoClip._parts) do
		if part.Parent then
			local original = NoClip._original[part]
			if original ~= nil then
				part.CanCollide = original
			end
		end
		NoClip._original[part] = nil
	end

	table.clear(NoClip._parts)

	return true
end

function NoClip.toggle(state)
	if state then
		return NoClip.start()
	end
	return NoClip.stop()
end

local Invisibility = {
	Enabled = false,
	_remote = nil,
	_checked = false,
}

local invisibilityKeywords = {
	"invis",
	"invisible",
	"invisibility",
	"cloak",
	"stealth",
	"vanish",
	"ghost",
}

local function findInvisibilityRemote()
	if Invisibility._checked and Invisibility._remote and Invisibility._remote.Parent then
		return Invisibility._remote
	end

	Invisibility._checked = true
	Invisibility._remote = nil

	local roots = { ReplicatedStorage, Workspace }
	for _, root in ipairs(roots) do
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
				local name = string.lower(descendant.Name)
				for _, keyword in ipairs(invisibilityKeywords) do
					if string.find(name, keyword, 1, true) then
						Invisibility._remote = descendant
						return descendant
					end
				end
			end
		end
	end

	return nil
end

function Invisibility.isSupported()
	return findInvisibilityRemote() ~= nil
end

function Invisibility.apply(state)
	local remote = findInvisibilityRemote()
	if not remote then
		return false, "No server invisibility remote found"
	end

	local ok, err = pcall(function()
		if remote:IsA("RemoteEvent") then
			remote:FireServer(state)
		else
			remote:InvokeServer(state)
		end
	end)

	if not ok then
		return false, err
	end

	Invisibility.Enabled = state == true
	return true
end

function Invisibility.toggle(state)
	return Invisibility.apply(state)
end

local storage = (getgenv and getgenv()) or _G
storage.FlyAntiAFK_State = storage.FlyAntiAFK_State or {}
local sessionState = storage.FlyAntiAFK_State
local settingsFile = "FlyAntiAFK_Settings.json"

local function canReadSettings()
	return type(readfile) == "function" and type(isfile) == "function"
end

local function canWriteSettings()
	return type(writefile) == "function"
end

local function loadSettings()
	if not canReadSettings() or not isfile(settingsFile) then
		return nil
	end
	local ok, raw = pcall(readfile, settingsFile)
	if not ok or type(raw) ~= "string" or raw == "" then
		return nil
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if decodedOk and type(decoded) == "table" then
		return decoded
	end
	return nil
end

local function mergeSettings(saved)
	if type(saved) ~= "table" then
		return
	end
	if type(saved.Hotkeys) == "table" then
		sessionState.Hotkeys = saved.Hotkeys
	end
	if type(saved.Settings) == "table" then
		sessionState.Settings = saved.Settings
	end
	if type(saved.ExpandedPosition) == "table" then
		sessionState.ExpandedPosition = saved.ExpandedPosition
	end
	if type(saved.CollapsedPosition) == "table" then
		sessionState.CollapsedPosition = saved.CollapsedPosition
	end
	if type(saved.Collapsed) == "boolean" then
		sessionState.Collapsed = saved.Collapsed
	end
	if type(saved.TeleportPoints) == "table" then
		sessionState.TeleportPoints = saved.TeleportPoints
	end
end

mergeSettings(loadSettings())
sessionState.Hotkeys = sessionState.Hotkeys or {}
sessionState.Settings = sessionState.Settings or {}
sessionState.TeleportPoints = sessionState.TeleportPoints or {}

local saveQueued = false

local function saveSettingsNow()
	if not canWriteSettings() then
		return
	end
	local payload = {
		Hotkeys = sessionState.Hotkeys,
		Settings = sessionState.Settings,
		ExpandedPosition = sessionState.ExpandedPosition,
		CollapsedPosition = sessionState.CollapsedPosition,
		Collapsed = sessionState.Collapsed,
		TeleportPoints = sessionState.TeleportPoints,
	}
	pcall(function()
		writefile(settingsFile, HttpService:JSONEncode(payload))
	end)
end

local function queueSaveSettings()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(0.5, function()
		saveQueued = false
		saveSettingsNow()
	end)
end

for _, configKey in ipairs({ "Hotkey", "AntiAFKHotkey", "NoClipHotkey", "ClickerHotkey", "ESPHotkey", "GuiHotkey" }) do
	local keyName = sessionState.Hotkeys[configKey]
	if type(keyName) == "string" and Enum.KeyCode[keyName] then
		Config[configKey] = Enum.KeyCode[keyName]
	end
end

local function applySavedNumber(configKey, minValue, maxValue)
	local value = clampNumber(sessionState.Settings[configKey], minValue, maxValue)
	if value then
		Config[configKey] = value
	end
end

applySavedNumber("FlySpeed", Config.MinSpeed, Config.MaxSpeed)
applySavedNumber("FastSpeed", Config.MinFastSpeed, Config.MaxFastSpeed)
applySavedNumber("AntiAFKInterval", Config.MinAntiAFKInterval, Config.MaxAntiAFKInterval)
applySavedNumber("ClickInterval", Config.MinClickInterval, Config.MaxClickInterval)

if sessionState.Settings.ClickButton == "Right" then
	Config.ClickButton = "Right"
else
	Config.ClickButton = "Left"
end

if type(sessionState.Settings.ClickTargetEnabled) == "boolean" then
	Config.ClickTargetEnabled = sessionState.Settings.ClickTargetEnabled
end

if type(sessionState.Settings.ClickTarget) == "table" then
	local x = tonumber(sessionState.Settings.ClickTarget.X)
	local y = tonumber(sessionState.Settings.ClickTarget.Y)
	if x and y then
		Config.ClickTargetX = x
		Config.ClickTargetY = y
	end
end

local function saveConfigValue(configKey)
	sessionState.Settings[configKey] = Config[configKey]
	queueSaveSettings()
end

local guiParent = (gethui and gethui()) or LocalPlayer:WaitForChild("PlayerGui")
local existing = guiParent:FindFirstChild("FlyAntiAFK_GUI")
if existing then
	existing:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "FlyAntiAFK_GUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset = true
screenGui.Parent = guiParent

local uiConnections = {}
local destroyed = false

local function track(connection)
	table.insert(uiConnections, connection)
	return connection
end

local function addCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function addStroke(parent, color, transparency)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = transparency or 0
	stroke.Thickness = 1
	stroke.Parent = parent
	return stroke
end

local function tween(instance, duration, props)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	local activeTween = TweenService:Create(instance, info, props)
	activeTween:Play()
	return activeTween
end

local isTouchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local screenPadding = isTouchOnly and 10 or 8
local rowHeight = isTouchOnly and 50 or 44

local function getViewportSize()
	local camera = Workspace.CurrentCamera
	if camera then
		return camera.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function getExpandedSize()
	local viewport = getViewportSize()
	local widthLimit = math.max(160, viewport.X - screenPadding * 2)
	local heightLimit = math.max(180, viewport.Y - screenPadding * 2)
	local preferredWidth = isTouchOnly and 330 or 306
	local preferredHeight = isTouchOnly and math.max(320, math.floor(viewport.Y * 0.64)) or 360
	return UDim2.fromOffset(math.min(preferredWidth, widthLimit), math.min(preferredHeight, heightLimit))
end

local function getCollapsedSize()
	return isTouchOnly and UDim2.fromOffset(62, 50) or UDim2.fromOffset(52, 42)
end

local function clampOffsetPosition(position, size)
	local viewport = getViewportSize()
	local maxX = math.max(screenPadding, viewport.X - size.X.Offset - screenPadding)
	local maxY = math.max(screenPadding, viewport.Y - size.Y.Offset - screenPadding)
	local x = math.clamp(position.X.Offset, screenPadding, maxX)
	local y = math.clamp(position.Y.Offset, screenPadding, maxY)
	return UDim2.fromOffset(x, y)
end

local function savePosition(key, position)
	sessionState[key] = {
		X = math.floor(position.X.Offset),
		Y = math.floor(position.Y.Offset),
	}
	queueSaveSettings()
end

local function loadPosition(key, fallback)
	local saved = sessionState[key]
	if typeof(saved) == "table" and type(saved.X) == "number" and type(saved.Y) == "number" then
		return UDim2.fromOffset(saved.X, saved.Y)
	end
	return fallback
end

local function defaultExpandedPosition()
	local size = getExpandedSize()
	return UDim2.fromOffset(screenPadding + 12, math.max(screenPadding, math.floor(getViewportSize().Y * 0.5 - size.Y.Offset * 0.5)))
end

local expandedSize = getExpandedSize()
local collapsedSize = getCollapsedSize()
local expandedPosition = loadPosition("ExpandedPosition", defaultExpandedPosition())
local collapsedPosition = loadPosition("CollapsedPosition", expandedPosition)
local collapsed = sessionState.Collapsed == true
local animatingCollapse = false

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = expandedSize
frame.Position = clampOffsetPosition(expandedPosition, expandedSize)
frame.Visible = not collapsed
frame.BackgroundColor3 = Theme.Window
frame.BorderSizePixel = 0
frame.Active = true
frame.ClipsDescendants = true
frame.Parent = screenGui
addCorner(frame, 8)
addStroke(frame, Theme.Stroke, 0.15)

local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 42)
topBar.BackgroundTransparency = 1
topBar.Active = true
topBar.Parent = frame

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -92, 1, 0)
title.Position = UDim2.fromOffset(12, 0)
title.BackgroundTransparency = 1
title.Text = "by @Kryv1x"
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextColor3 = Theme.Text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = topBar

local function createIconButton(name, text, xOffset)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.fromOffset(30, 28)
	button.Position = UDim2.new(1, xOffset, 0, 7)
	button.BackgroundColor3 = Theme.Button
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = text
	button.Font = Enum.Font.GothamBold
	button.TextSize = 15
	button.TextColor3 = Theme.Text
	button.Parent = topBar
	addCorner(button, 6)
	return button
end

local minimizeButton = createIconButton("Minimize", "-", -68)
local closeButton = createIconButton("Close", "x", -34)
closeButton.BackgroundColor3 = Theme.Danger

local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -20, 1, -52)
content.Position = UDim2.fromOffset(10, 44)
content.BackgroundTransparency = 1
content.Parent = frame

local tabBar = Instance.new("Frame")
tabBar.Name = "Tabs"
tabBar.Size = UDim2.new(1, 0, 0, 34)
tabBar.BackgroundTransparency = 1
tabBar.Parent = content

local function createTab(name, text, index)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.new(0.25, -3, 0, 30)
	button.Position = UDim2.new(index * 0.25, index, 0, 2)
	button.BackgroundColor3 = Theme.Button
	button.BorderSizePixel = 0
	button.Text = text
	button.Font = Enum.Font.GothamBold
	button.TextSize = isTouchOnly and 13 or 12
	button.TextColor3 = Theme.Text
	button.AutoButtonColor = false
	button.Parent = tabBar
	addCorner(button, 6)
	return button
end

local mainTab = createTab("MainTab", "Main", 0)
local clickerTab = createTab("ClickerTab", "Clicker", 1)
local teleportTab = createTab("TeleportTab", "Teleport", 2)
local settingsTab = createTab("SettingsTab", "Settings", 3)

local function createPage(name)
	local scrollingPage = Instance.new("ScrollingFrame")
	scrollingPage.Name = name
	scrollingPage.Size = UDim2.new(1, 0, 1, -40)
	scrollingPage.Position = UDim2.fromOffset(0, 40)
	scrollingPage.BackgroundTransparency = 1
	scrollingPage.BorderSizePixel = 0
	scrollingPage.Active = true
	scrollingPage.ScrollBarThickness = isTouchOnly and 4 or 6
	scrollingPage.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollingPage.CanvasSize = UDim2.fromOffset(0, 0)
	scrollingPage.CanvasPosition = Vector2.zero
	scrollingPage.Parent = content

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scrollingPage

	return scrollingPage, layout
end

local page, pageLayout = createPage("MainPage")
local clickerPage, clickerPageLayout = createPage("ClickerPage")
local teleportPage, teleportPageLayout = createPage("TeleportPage")
local settingsPage, settingsPageLayout = createPage("SettingsPage")
clickerPage.Visible = false
teleportPage.Visible = false
settingsPage.Visible = false

local function updateCanvasSize()
	page.CanvasSize = UDim2.fromOffset(0, pageLayout.AbsoluteContentSize.Y + 8)
	clickerPage.CanvasSize = UDim2.fromOffset(0, clickerPageLayout.AbsoluteContentSize.Y + 8)
	teleportPage.CanvasSize = UDim2.fromOffset(0, teleportPageLayout.AbsoluteContentSize.Y + 8)
	settingsPage.CanvasSize = UDim2.fromOffset(0, settingsPageLayout.AbsoluteContentSize.Y + 8)
end

local function selectTab(name)
	local mainActive = name == "Main"
	local clickerActive = name == "Clicker"
	local teleportActive = name == "Teleport"
	local settingsActive = name == "Settings"
	page.Visible = mainActive
	clickerPage.Visible = clickerActive
	teleportPage.Visible = teleportActive
	settingsPage.Visible = settingsActive
	mainTab.BackgroundColor3 = mainActive and Theme.AccentDark or Theme.Button
	clickerTab.BackgroundColor3 = clickerActive and Theme.AccentDark or Theme.Button
	teleportTab.BackgroundColor3 = teleportActive and Theme.AccentDark or Theme.Button
	settingsTab.BackgroundColor3 = settingsActive and Theme.AccentDark or Theme.Button
end

track(pageLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize))
track(clickerPageLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize))
track(teleportPageLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize))
track(settingsPageLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize))
track(mainTab.MouseButton1Click:Connect(function()
	selectTab("Main")
end))
track(clickerTab.MouseButton1Click:Connect(function()
	selectTab("Clicker")
end))
track(teleportTab.MouseButton1Click:Connect(function()
	selectTab("Teleport")
end))
track(settingsTab.MouseButton1Click:Connect(function()
	selectTab("Settings")
end))
selectTab("Main")

local miniButton = Instance.new("TextButton")
miniButton.Name = "OpenButton"
miniButton.Size = collapsedSize
miniButton.Position = collapsed and clampOffsetPosition(collapsedPosition, collapsedSize) or frame.Position
miniButton.BackgroundColor3 = Theme.AccentDark
miniButton.BorderSizePixel = 0
miniButton.Text = "◆"
miniButton.Font = Enum.Font.GothamBold
miniButton.TextSize = 18
miniButton.TextColor3 = Theme.Text
miniButton.Visible = collapsed
miniButton.Active = true
miniButton.Parent = screenGui
addCorner(miniButton, 8)
addStroke(miniButton, Theme.Stroke, 0.2)

local miniStatus = Instance.new("TextLabel")
miniStatus.Name = "ActiveStatus"
miniStatus.Size = UDim2.new(1, -4, 0, 12)
miniStatus.Position = UDim2.new(0, 2, 1, -14)
miniStatus.BackgroundTransparency = 1
miniStatus.Text = ""
miniStatus.Font = Enum.Font.GothamBold
miniStatus.TextSize = 9
miniStatus.TextColor3 = Theme.Text
miniStatus.TextXAlignment = Enum.TextXAlignment.Center
miniStatus.Parent = miniButton

local clickTargetSize = UDim2.fromOffset(36, 36)

local function getDefaultClickTargetPosition()
	local viewport = getViewportSize()
	return UDim2.fromOffset(math.floor(viewport.X * 0.5 - clickTargetSize.X.Offset * 0.5), math.floor(viewport.Y * 0.5 - clickTargetSize.Y.Offset * 0.5))
end

local function getClickTargetPosition()
	if type(Config.ClickTargetX) == "number" and type(Config.ClickTargetY) == "number" then
		return clampOffsetPosition(UDim2.fromOffset(Config.ClickTargetX - clickTargetSize.X.Offset * 0.5, Config.ClickTargetY - clickTargetSize.Y.Offset * 0.5), clickTargetSize)
	end
	return clampOffsetPosition(getDefaultClickTargetPosition(), clickTargetSize)
end

local function saveClickTargetPosition(position)
	local clamped = clampOffsetPosition(position, clickTargetSize)
	Config.ClickTargetX = math.floor(clamped.X.Offset + clickTargetSize.X.Offset * 0.5)
	Config.ClickTargetY = math.floor(clamped.Y.Offset + clickTargetSize.Y.Offset * 0.5)
	sessionState.Settings.ClickTarget = {
		X = Config.ClickTargetX,
		Y = Config.ClickTargetY,
	}
	queueSaveSettings()
	return clamped
end

local clickTargetMarker = Instance.new("Frame")
clickTargetMarker.Name = "ClickTarget"
clickTargetMarker.Size = clickTargetSize
clickTargetMarker.Position = getClickTargetPosition()
clickTargetMarker.BackgroundColor3 = Theme.Accent
clickTargetMarker.BackgroundTransparency = 0.18
clickTargetMarker.BorderSizePixel = 0
clickTargetMarker.Active = true
clickTargetMarker.Visible = Config.ClickTargetEnabled
clickTargetMarker.ZIndex = 20
clickTargetMarker.Parent = screenGui
addCorner(clickTargetMarker, 18)
addStroke(clickTargetMarker, Theme.Text, 0.05)

local clickTargetMark = Instance.new("TextLabel")
clickTargetMark.Name = "Mark"
clickTargetMark.Size = UDim2.new(1, 0, 1, 0)
clickTargetMark.BackgroundTransparency = 1
clickTargetMark.Text = "+"
clickTargetMark.Font = Enum.Font.GothamBold
clickTargetMark.TextSize = 22
clickTargetMark.TextColor3 = Theme.Text
clickTargetMark.ZIndex = 21
clickTargetMark.Parent = clickTargetMarker

clickTargetMarker.Position = saveClickTargetPosition(clickTargetMarker.Position)

local ESP = {
	Enabled = false,
	_highlights = {},
	_playerConnections = {},
	_humanoidConnections = {},
	_playerAdded = nil,
	_playerRemoving = nil,
	_colorLoop = 0,
}

local espFillColor = Color3.fromRGB(20, 255, 90)
local espOutlineColor = Color3.fromRGB(185, 255, 195)
local espRedFillColor = Color3.fromRGB(255, 55, 55)
local espRedOutlineColor = Color3.fromRGB(255, 190, 190)
local espBlueFillColor = Color3.fromRGB(45, 135, 255)
local espBlueOutlineColor = Color3.fromRGB(180, 215, 255)
local espRedOccludedFillColor = Color3.fromRGB(255, 70, 180)
local espRedOccludedOutlineColor = Color3.fromRGB(255, 190, 230)
local espBlueOccludedFillColor = Color3.fromRGB(155, 75, 255)
local espBlueOccludedOutlineColor = Color3.fromRGB(210, 175, 255)

local function appendESPText(parts, value)
	if value == nil then
		return
	end

	local valueType = typeof(value)
	if valueType == "Color3" then
		if value.R > 0.55 and value.B < 0.45 then
			table.insert(parts, "red")
		elseif value.B > 0.55 and value.R < 0.45 then
			table.insert(parts, "blue")
		end
	elseif valueType == "BrickColor" then
		table.insert(parts, string.lower(value.Name))
		table.insert(parts, string.lower(tostring(value)))
	elseif valueType == "string" or valueType == "number" or valueType == "boolean" then
		table.insert(parts, string.lower(tostring(value)))
	end
end

local function isESPTeamKey(name)
	name = string.lower(tostring(name))
	return string.find(name, "team", 1, true)
		or string.find(name, "side", 1, true)
		or string.find(name, "faction", 1, true)
		or string.find(name, "color", 1, true)
		or string.find(name, "army", 1, true)
		or string.find(name, "force", 1, true)
		or string.find(name, "nation", 1, true)
		or string.find(name, "squad", 1, true)
end

local function appendESPInstanceData(parts, object, includeDescendants)
	if not object then
		return
	end

	pcall(function()
		for name, value in pairs(object:GetAttributes()) do
			if isESPTeamKey(name) then
				appendESPText(parts, name)
				appendESPText(parts, value)
			elseif value == "Red" or value == "Blue" or value == "red" or value == "blue" then
				appendESPText(parts, value)
			end
		end
	end)

	local objects = includeDescendants and object:GetDescendants() or object:GetChildren()
	local limit = 140
	for index, child in ipairs(objects) do
		if index > limit then
			break
		end

		local childName = string.lower(tostring(child.Name))
		local matchedName = isESPTeamKey(childName)
		if matchedName or string.find(childName, "red%-shirt") or string.find(childName, "blue%-shirt") or string.find(childName, "red%-pants") or string.find(childName, "blue%-pants") then
			appendESPText(parts, childName)
		end
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") then
			appendESPText(parts, childName)
		end
		if child:IsA("StringValue") or child:IsA("NumberValue") or child:IsA("IntValue") or child:IsA("BoolValue") or child:IsA("BrickColorValue") or child:IsA("Color3Value") then
			if matchedName or tostring(child.Value) == "Red" or tostring(child.Value) == "Blue" or tostring(child.Value) == "red" or tostring(child.Value) == "blue" then
				appendESPText(parts, child.Value)
			end
		end
	end
end

local function getESPColors(player, character)
	local parts = {}
	if player.Team then
		appendESPText(parts, player.Team.Name)
	end
	pcall(function()
		appendESPText(parts, player.TeamColor)
	end)
	pcall(function()
		appendESPText(parts, player.TeamColor.Name)
	end)
	pcall(function()
		appendESPText(parts, player.TeamColor.Color)
	end)

	appendESPInstanceData(parts, player, false)
	appendESPInstanceData(parts, character, true)

	local teamText = table.concat(parts, " ")
	if string.find(teamText, "red", 1, true) then
		return espRedFillColor, espRedOutlineColor, "red"
	end
	if string.find(teamText, "blue", 1, true) then
		return espBlueFillColor, espBlueOutlineColor, "blue"
	end

	return espFillColor, espOutlineColor, nil
end

local function isESPVisible(character)
	local camera = Workspace.CurrentCamera
	if not camera or not character then
		return true
	end

	local targetPart = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not targetPart or not targetPart:IsA("BasePart") then
		return true
	end

	local ignoreList = { character }
	local localCharacter = LocalPlayer.Character
	if localCharacter then
		table.insert(ignoreList, localCharacter)
	end

	local obscuredOk, obstructingParts = pcall(function()
		return camera:GetPartsObscuringTarget({ targetPart.Position }, ignoreList)
	end)
	if obscuredOk then
		return #obstructingParts == 0
	end

	local direction = targetPart.Position - camera.CFrame.Position
	if direction.Magnitude < 0.001 then
		return true
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.FilterDescendantsInstances = ignoreList
	return Workspace:Raycast(camera.CFrame.Position, direction, params) == nil
end

local function updateESPColor(player)
	local highlight = ESP._highlights[player]
	if not highlight then
		return
	end

	local fillColor, outlineColor, teamColor = getESPColors(player, player.Character)
	if not isESPVisible(player.Character) then
		if teamColor == "red" then
			fillColor = espRedOccludedFillColor
			outlineColor = espRedOccludedOutlineColor
		elseif teamColor == "blue" then
			fillColor = espBlueOccludedFillColor
			outlineColor = espBlueOccludedOutlineColor
		end
	end
	highlight.FillColor = fillColor
	highlight.OutlineColor = outlineColor
end

local function getEspHighlight(player)
	local highlight = ESP._highlights[player]
	if highlight and highlight.Parent then
		updateESPColor(player)
		return highlight
	end

	highlight = Instance.new("Highlight")
	highlight.Name = "ESP_" .. player.Name
	highlight.FillColor = espFillColor
	highlight.FillTransparency = 0.45
	highlight.OutlineColor = espOutlineColor
	highlight.OutlineTransparency = 0.03
	highlight.Enabled = false
	pcall(function()
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	end)
	highlight.Parent = screenGui
	ESP._highlights[player] = highlight
	updateESPColor(player)

	return highlight
end

local function disconnectEspPlayer(player)
	local connections = ESP._playerConnections[player]
	if connections then
		for _, connection in ipairs(connections) do
			disconnect(connection)
		end
		ESP._playerConnections[player] = nil
	end
	disconnect(ESP._humanoidConnections[player])
	ESP._humanoidConnections[player] = nil
end

local function removeEspHighlight(player)
	local highlight = ESP._highlights[player]
	if highlight then
		highlight:Destroy()
		ESP._highlights[player] = nil
	end
end

local function applyESPToPlayer(player)
	if not ESP.Enabled then
		return
	end

	local highlight = getEspHighlight(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if character and humanoid and humanoid.Health > 0 then
		updateESPColor(player)
		highlight.Adornee = character
		highlight.Enabled = true
		disconnect(ESP._humanoidConnections[player])
		ESP._humanoidConnections[player] = humanoid.Died:Connect(function()
			highlight.Enabled = false
			highlight.Adornee = nil
		end)
	else
		highlight.Enabled = false
		highlight.Adornee = nil
	end
end

local function bindESPPlayer(player)
	if ESP._playerConnections[player] then
		applyESPToPlayer(player)
		return
	end

	ESP._playerConnections[player] = {
		player.AttributeChanged:Connect(function()
			updateESPColor(player)
		end),
		player:GetPropertyChangedSignal("Team"):Connect(function()
			updateESPColor(player)
		end),
		player:GetPropertyChangedSignal("TeamColor"):Connect(function()
			updateESPColor(player)
		end),
		player.CharacterAdded:Connect(function(character)
			task.defer(function()
				if ESP.Enabled and character.Parent then
					if not character:FindFirstChildOfClass("Humanoid") then
						character:WaitForChild("Humanoid", 5)
					end
					applyESPToPlayer(player)
				end
			end)
		end),
		player.CharacterRemoving:Connect(function()
			local highlight = ESP._highlights[player]
			if highlight then
				highlight.Enabled = false
				highlight.Adornee = nil
			end
			disconnect(ESP._humanoidConnections[player])
			ESP._humanoidConnections[player] = nil
		end),
	}

	applyESPToPlayer(player)
end

function ESP.start()
	if ESP.Enabled then
		return true
	end
	ESP.Enabled = true

	for _, player in ipairs(Players:GetPlayers()) do
		bindESPPlayer(player)
	end

	ESP._playerAdded = Players.PlayerAdded:Connect(function(player)
		bindESPPlayer(player)
	end)
	ESP._playerRemoving = Players.PlayerRemoving:Connect(function(player)
		disconnectEspPlayer(player)
		removeEspHighlight(player)
	end)
	ESP._colorLoop += 1
	local colorLoop = ESP._colorLoop
	task.spawn(function()
		while ESP.Enabled and ESP._colorLoop == colorLoop do
			for player in pairs(ESP._highlights) do
				updateESPColor(player)
			end
			task.wait(0.2)
		end
	end)

	return true
end

function ESP.stop()
	if not ESP.Enabled and not ESP._playerAdded and not ESP._playerRemoving then
		return true
	end
	ESP.Enabled = false
	ESP._colorLoop += 1
	disconnect(ESP._playerAdded)
	disconnect(ESP._playerRemoving)
	ESP._playerAdded = nil
	ESP._playerRemoving = nil

	for player in pairs(ESP._playerConnections) do
		disconnectEspPlayer(player)
	end
	for player in pairs(ESP._highlights) do
		removeEspHighlight(player)
	end

	return true
end

function ESP.toggle(state)
	if state then
		return ESP.start()
	end
	return ESP.stop()
end

local FullBright = {
	Enabled = false,
	_savedLighting = nil,
	_savedEffects = {},
	_changed = nil,
	_childAdded = nil,
	_pending = false,
	_applying = false,
}

local fullBrightTargets = {
	Brightness = 2.4,
	ClockTime = 14,
	Ambient = Color3.fromRGB(185, 185, 185),
	OutdoorAmbient = Color3.fromRGB(190, 190, 190),
	FogStart = 0,
	FogEnd = 100000,
	FogColor = Color3.fromRGB(235, 240, 255),
	GlobalShadows = false,
	ExposureCompensation = 0.15,
}

local function saveLightingState()
	if FullBright._savedLighting then
		return
	end

	FullBright._savedLighting = {}
	for property in pairs(fullBrightTargets) do
		pcall(function()
			FullBright._savedLighting[property] = Lighting[property]
		end)
	end
end

local function saveLightingEffect(effect)
	if FullBright._savedEffects[effect] then
		return
	end

	local data = {}
	if effect:IsA("Atmosphere") then
		for _, property in ipairs({ "Density", "Offset", "Haze", "Glare" }) do
			pcall(function()
				data[property] = effect[property]
			end)
		end
	elseif effect:IsA("ColorCorrectionEffect") then
		for _, property in ipairs({ "Enabled", "Brightness", "Contrast", "Saturation", "TintColor" }) do
			pcall(function()
				data[property] = effect[property]
			end)
		end
	end

	if next(data) then
		FullBright._savedEffects[effect] = data
	end
end

local function applyLightingEffect(effect)
	saveLightingEffect(effect)
	if effect:IsA("Atmosphere") then
		pcall(function()
			effect.Density = 0
			effect.Offset = 0
			effect.Haze = 0
			effect.Glare = 0
		end)
	elseif effect:IsA("ColorCorrectionEffect") then
		pcall(function()
			effect.Enabled = false
		end)
	end
end

local function applyFullBright()
	if not FullBright.Enabled or FullBright._applying then
		return
	end

	FullBright._applying = true
	pcall(function()
		for property, value in pairs(fullBrightTargets) do
			pcall(function()
				Lighting[property] = value
			end)
		end
		for _, effect in ipairs(Lighting:GetChildren()) do
			applyLightingEffect(effect)
		end
	end)
	FullBright._applying = false
end

local function requestFullBrightApply()
	if not FullBright.Enabled or FullBright._applying or FullBright._pending then
		return
	end

	FullBright._pending = true
	task.delay(0.1, function()
		FullBright._pending = false
		applyFullBright()
	end)
end

local function restoreFullBright()
	if FullBright._savedLighting then
		for property, value in pairs(FullBright._savedLighting) do
			pcall(function()
				Lighting[property] = value
			end)
		end
	end

	for effect, data in pairs(FullBright._savedEffects) do
		if effect and effect.Parent then
			for property, value in pairs(data) do
				pcall(function()
					effect[property] = value
				end)
			end
		end
	end

	FullBright._savedLighting = nil
	FullBright._savedEffects = {}
end

function FullBright.start()
	if FullBright.Enabled then
		return true
	end

	FullBright.Enabled = true
	saveLightingState()
	applyFullBright()
	FullBright._changed = Lighting.Changed:Connect(function()
		requestFullBrightApply()
	end)
	FullBright._childAdded = Lighting.ChildAdded:Connect(function(effect)
		if FullBright.Enabled then
			task.defer(function()
				if effect.Parent then
					applyLightingEffect(effect)
				end
			end)
		end
	end)
	return true
end

function FullBright.stop()
	if not FullBright.Enabled and not FullBright._changed and not FullBright._childAdded then
		return true
	end

	FullBright.Enabled = false
	disconnect(FullBright._changed)
	disconnect(FullBright._childAdded)
	FullBright._changed = nil
	FullBright._childAdded = nil
	FullBright._pending = false
	restoreFullBright()
	return true
end

function FullBright.toggle(state)
	if state then
		return FullBright.start()
	end
	return FullBright.stop()
end

local Vegetation = {
	Enabled = false,
	_descendantAdded = nil,
	_originalTransparency = setmetatable({}, { __mode = "k" }),
	_terrain = nil,
	_terrainChanged = nil,
	_terrainDecoration = nil,
	_terrainDecorationSaved = false,
}

local vegetationKeywords = {
	"grass",
	"tree",
	"leaf",
	"leaves",
	"branch",
	"bush",
	"shrub",
	"foliage",
	"plant",
	"fern",
	"vine",
	"weed",
	"flower",
}

local function isVegetationPart(part)
	if not part:IsA("BasePart") then
		return false
	end

	local current = part
	while current and current ~= Workspace do
		local name = string.lower(current.Name)
		for _, keyword in ipairs(vegetationKeywords) do
			if string.find(name, keyword, 1, true) then
				return true
			end
		end
		current = current.Parent
	end

	local materialName = part.Material.Name
	return materialName == "Grass" or materialName == "LeafyGrass"
end

local function hideVegetationPart(part)
	if not isVegetationPart(part) then
		return
	end
	if Vegetation._originalTransparency[part] == nil then
		Vegetation._originalTransparency[part] = part.LocalTransparencyModifier
	end
	part.LocalTransparencyModifier = 1
end

function Vegetation.start()
	if Vegetation.Enabled then
		return true
	end

	Vegetation.Enabled = true
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		hideVegetationPart(descendant)
	end

	Vegetation._descendantAdded = Workspace.DescendantAdded:Connect(function(descendant)
		if Vegetation.Enabled then
			hideVegetationPart(descendant)
		end
	end)

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local ok, decoration = pcall(function()
			return terrain.Decoration
		end)
		if ok then
			Vegetation._terrain = terrain
			Vegetation._terrainDecoration = decoration
			Vegetation._terrainDecorationSaved = true
			local function disableTerrainDecoration()
				pcall(function()
					if terrain.Decoration then
						terrain.Decoration = false
					end
				end)
			end
			disableTerrainDecoration()
			Vegetation._terrainChanged = terrain:GetPropertyChangedSignal("Decoration"):Connect(function()
				if Vegetation.Enabled then
					disableTerrainDecoration()
				end
			end)
		end
	end

	return true
end

function Vegetation.stop()
	if not Vegetation.Enabled and not Vegetation._descendantAdded then
		return true
	end

	Vegetation.Enabled = false
	disconnect(Vegetation._descendantAdded)
	disconnect(Vegetation._terrainChanged)
	Vegetation._descendantAdded = nil
	Vegetation._terrainChanged = nil

	for part, originalTransparency in pairs(Vegetation._originalTransparency) do
		if part.Parent then
			part.LocalTransparencyModifier = originalTransparency
		end
	end
	table.clear(Vegetation._originalTransparency)

	if Vegetation._terrainDecorationSaved and Vegetation._terrain and Vegetation._terrain.Parent then
		pcall(function()
			Vegetation._terrain.Decoration = Vegetation._terrainDecoration
		end)
	end
	Vegetation._terrain = nil
	Vegetation._terrainDecoration = nil
	Vegetation._terrainDecorationSaved = false

	return true
end

function Vegetation.toggle(state)
	if state then
		return Vegetation.start()
	end
	return Vegetation.stop()
end

local function createRow(name, order, parentPage)
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, -2, 0, rowHeight)
	row.BackgroundColor3 = Theme.Panel
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parentPage or page
	addCorner(row, 7)
	addStroke(row, Theme.Stroke, 0.45)
	return row
end

local updateMiniStatus = nil

local function createSwitch(text, order, onChanged, parentPage)
	local row = createRow(text .. "Row", order, parentPage)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -86, 1, 0)
	label.Position = UDim2.fromOffset(12, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.TextColor3 = Theme.Text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local switchWidth = isTouchOnly and 56 or 50
	local switchHeight = isTouchOnly and 30 or 26
	local knobSize = switchHeight - 6

	local switch = Instance.new("Frame")
	switch.Name = "Switch"
	switch.Size = UDim2.fromOffset(switchWidth, switchHeight)
	switch.Position = UDim2.new(1, -(switchWidth + 12), 0.5, -math.floor(switchHeight * 0.5))
	switch.BackgroundColor3 = Theme.Off
	switch.BorderSizePixel = 0
	switch.Parent = row
	addCorner(switch, math.floor(switchHeight * 0.5))

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(knobSize, knobSize)
	knob.Position = UDim2.fromOffset(3, 3)
	knob.BackgroundColor3 = Theme.Text
	knob.BorderSizePixel = 0
	knob.Parent = switch
	addCorner(knob, math.floor(knobSize * 0.5))

	local enabled = false
	local busy = false

	local control = {}

	local function render(animated)
		local color = enabled and Theme.Accent or Theme.Off
		local knobPosition = enabled and UDim2.fromOffset(switchWidth - knobSize - 3, 3) or UDim2.fromOffset(3, 3)

		if animated then
			tween(switch, 0.16, { BackgroundColor3 = color })
			tween(knob, 0.16, { Position = knobPosition })
		else
			switch.BackgroundColor3 = color
			knob.Position = knobPosition
		end
	end

	function control.setState(state)
		enabled = state == true
		render(false)
		if updateMiniStatus then
			updateMiniStatus()
		end
	end

	function control.set(state)
		if busy or enabled == state then
			return
		end

		busy = true
		local previous = enabled
		enabled = state == true
		render(true)

		local ok, result, message = pcall(onChanged, enabled)
		if not ok or result == false then
			enabled = previous
			render(true)
			if not ok then
				warn("[" .. text .. "]", result)
			elseif message then
				warn("[" .. text .. "]", message)
			end
		end

		busy = false
		if updateMiniStatus then
			updateMiniStatus()
		end
	end

	function control.toggle()
		control.set(not enabled)
	end

	function control.isEnabled()
		return enabled
	end

	local pressPosition = nil

	track(row.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressPosition = input.Position
		end
	end))

	track(row.InputEnded:Connect(function(input)
		if not pressPosition then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local moved = (input.Position - pressPosition).Magnitude
		pressPosition = nil
		if moved <= 10 then
			control.toggle()
		end
	end))

	render(false)

	return control
end

local flyControl = createSwitch("Fly", 1, Fly.toggle)
local antiAfkControl = createSwitch("AntiAFK", 2, AntiAFK.toggle)
local noClipControl = createSwitch("NoClip", 3, NoClip.toggle)
local espControl = createSwitch("ESP", 4, ESP.toggle)
local fullBrightControl = createSwitch("FullBright", 5, FullBright.toggle)
local invisibilityControl = nil
if Invisibility.isSupported() then
	invisibilityControl = createSwitch("Invisibility", 6, Invisibility.toggle)
end
local vegetationControl = createSwitch("No foliage", 7, Vegetation.toggle)

local speedRow = createRow("FlySpeedRow", 9)

local speedLabel = Instance.new("TextLabel")
speedLabel.Name = "Label"
speedLabel.Size = UDim2.new(0.5, -12, 1, 0)
speedLabel.Position = UDim2.fromOffset(12, 0)
speedLabel.BackgroundTransparency = 1
speedLabel.Text = "Fly speed"
speedLabel.Font = Enum.Font.GothamMedium
speedLabel.TextSize = 14
speedLabel.TextColor3 = Theme.Text
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
speedLabel.Parent = speedRow

local speedBox = Instance.new("TextBox")
speedBox.Name = "SpeedBox"
speedBox.Size = UDim2.fromOffset(82, 30)
speedBox.Position = UDim2.new(1, -94, 0.5, -15)
speedBox.BackgroundColor3 = Theme.PanelSoft
speedBox.BorderSizePixel = 0
speedBox.Font = Enum.Font.GothamMedium
speedBox.TextSize = 14
speedBox.TextColor3 = Theme.Text
speedBox.PlaceholderColor3 = Theme.Muted
speedBox.Text = tostring(Config.FlySpeed)
speedBox.PlaceholderText = "Speed"
speedBox.ClearTextOnFocus = false
speedBox.Parent = speedRow
addCorner(speedBox, 6)

track(speedBox.FocusLost:Connect(function()
	local value = clampNumber(speedBox.Text, Config.MinSpeed, Config.MaxSpeed)
	if value then
		Config.FlySpeed = value
		saveConfigValue("FlySpeed")
	end
	speedBox.Text = tostring(Config.FlySpeed)
end))

local clickerControl = createSwitch("Auto clicker", 1, Clicker.toggle, clickerPage)

local clickDelayRow = createRow("ClickDelayRow", 2, clickerPage)

local clickDelayLabel = Instance.new("TextLabel")
clickDelayLabel.Name = "Label"
clickDelayLabel.Size = UDim2.new(0.5, -12, 1, 0)
clickDelayLabel.Position = UDim2.fromOffset(12, 0)
clickDelayLabel.BackgroundTransparency = 1
clickDelayLabel.Text = "Click delay"
clickDelayLabel.Font = Enum.Font.GothamMedium
clickDelayLabel.TextSize = 14
clickDelayLabel.TextColor3 = Theme.Text
clickDelayLabel.TextXAlignment = Enum.TextXAlignment.Left
clickDelayLabel.Parent = clickDelayRow

local clickDelayBox = Instance.new("TextBox")
clickDelayBox.Name = "DelayBox"
clickDelayBox.Size = UDim2.fromOffset(82, 30)
clickDelayBox.Position = UDim2.new(1, -94, 0.5, -15)
clickDelayBox.BackgroundColor3 = Theme.PanelSoft
clickDelayBox.BorderSizePixel = 0
clickDelayBox.Font = Enum.Font.GothamMedium
clickDelayBox.TextSize = 14
clickDelayBox.TextColor3 = Theme.Text
clickDelayBox.PlaceholderColor3 = Theme.Muted
clickDelayBox.Text = tostring(Config.ClickInterval)
clickDelayBox.PlaceholderText = "Delay"
clickDelayBox.ClearTextOnFocus = false
clickDelayBox.Parent = clickDelayRow
addCorner(clickDelayBox, 6)

track(clickDelayBox.FocusLost:Connect(function()
	local value = clampNumber(clickDelayBox.Text, Config.MinClickInterval, Config.MaxClickInterval)
	if value then
		Config.ClickInterval = value
		saveConfigValue("ClickInterval")
	end
	clickDelayBox.Text = tostring(Config.ClickInterval)
end))

local clickModeRow = createRow("ClickModeRow", 3, clickerPage)

local clickModeLabel = Instance.new("TextLabel")
clickModeLabel.Name = "Label"
clickModeLabel.Size = UDim2.new(0.5, -12, 1, 0)
clickModeLabel.Position = UDim2.fromOffset(12, 0)
clickModeLabel.BackgroundTransparency = 1
clickModeLabel.Text = "Click mode"
clickModeLabel.Font = Enum.Font.GothamMedium
clickModeLabel.TextSize = 14
clickModeLabel.TextColor3 = Theme.Text
clickModeLabel.TextXAlignment = Enum.TextXAlignment.Left
clickModeLabel.Parent = clickModeRow

local clickModeButton = Instance.new("TextButton")
clickModeButton.Name = "ModeButton"
clickModeButton.Size = UDim2.fromOffset(82, 30)
clickModeButton.Position = UDim2.new(1, -94, 0.5, -15)
clickModeButton.BackgroundColor3 = Theme.PanelSoft
clickModeButton.BorderSizePixel = 0
clickModeButton.Font = Enum.Font.GothamBold
clickModeButton.TextSize = 13
clickModeButton.TextColor3 = Theme.Text
clickModeButton.AutoButtonColor = true
clickModeButton.Text = Config.ClickButton
clickModeButton.Parent = clickModeRow
addCorner(clickModeButton, 6)

track(clickModeButton.MouseButton1Click:Connect(function()
	Config.ClickButton = Config.ClickButton == "Left" and "Right" or "Left"
	clickModeButton.Text = Config.ClickButton
	saveConfigValue("ClickButton")
end))

local clickTargetRow = createRow("ClickTargetRow", 4, clickerPage)

local clickTargetLabel = Instance.new("TextLabel")
clickTargetLabel.Name = "Label"
clickTargetLabel.Size = UDim2.new(0.5, -12, 1, 0)
clickTargetLabel.Position = UDim2.fromOffset(12, 0)
clickTargetLabel.BackgroundTransparency = 1
clickTargetLabel.Text = "Click target"
clickTargetLabel.Font = Enum.Font.GothamMedium
clickTargetLabel.TextSize = 14
clickTargetLabel.TextColor3 = Theme.Text
clickTargetLabel.TextXAlignment = Enum.TextXAlignment.Left
clickTargetLabel.Parent = clickTargetRow

local clickTargetButton = Instance.new("TextButton")
clickTargetButton.Name = "TargetButton"
clickTargetButton.Size = UDim2.fromOffset(82, 30)
clickTargetButton.Position = UDim2.new(1, -94, 0.5, -15)
clickTargetButton.BackgroundColor3 = Theme.PanelSoft
clickTargetButton.BorderSizePixel = 0
clickTargetButton.Font = Enum.Font.GothamBold
clickTargetButton.TextSize = 13
clickTargetButton.TextColor3 = Theme.Text
clickTargetButton.AutoButtonColor = true
clickTargetButton.Text = Config.ClickTargetEnabled and "Target" or "Mouse"
clickTargetButton.Parent = clickTargetRow
addCorner(clickTargetButton, 6)

track(clickTargetButton.MouseButton1Click:Connect(function()
	Config.ClickTargetEnabled = not Config.ClickTargetEnabled
	clickTargetButton.Text = Config.ClickTargetEnabled and "Target" or "Mouse"
	clickTargetMarker.Visible = Config.ClickTargetEnabled
	saveClickTargetPosition(clickTargetMarker.Position)
	saveConfigValue("ClickTargetEnabled")
end))

local teleportPoints = {}
if type(sessionState.TeleportPoints) == "table" then
	for _, savedPoint in ipairs(sessionState.TeleportPoints) do
		local x = tonumber(savedPoint.X)
		local y = tonumber(savedPoint.Y)
		local z = tonumber(savedPoint.Z)
		if x and y and z and #teleportPoints < 40 then
			local name = type(savedPoint.Name) == "string" and savedPoint.Name or "Point " .. tostring(#teleportPoints + 1)
			table.insert(teleportPoints, { Name = string.sub(name, 1, 28), X = x, Y = y, Z = z })
		end
	end
end
sessionState.TeleportPoints = teleportPoints

local teleportRows = {}
local function saveTeleportPoints()
	sessionState.TeleportPoints = teleportPoints
	queueSaveSettings()
end

local function teleportToPoint(point)
	local root, humanoid = getRootAndHumanoid()
	if not root or not humanoid or humanoid.Health <= 0 then
		return false
	end
	root.CFrame = CFrame.new(point.X, point.Y, point.Z)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

local function renderTeleportPoints()
	for _, row in ipairs(teleportRows) do
		row:Destroy()
	end
	table.clear(teleportRows)

	if #teleportPoints == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyTeleportList"
		empty.Size = UDim2.new(1, -4, 0, rowHeight)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.GothamMedium
		empty.TextSize = 13
		empty.TextColor3 = Theme.Muted
		empty.Text = "No saved markers"
		empty.LayoutOrder = 4
		empty.Parent = teleportPage
		table.insert(teleportRows, empty)
		updateCanvasSize()
		return
	end

	for index, point in ipairs(teleportPoints) do
		local row = createRow("TeleportPoint_" .. tostring(index), index + 3, teleportPage)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -150, 1, 0)
		label.Position = UDim2.fromOffset(12, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 13
		label.TextColor3 = Theme.Text
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = point.Name
		label.Parent = row

		local goButton = Instance.new("TextButton")
		goButton.Size = UDim2.fromOffset(56, 30)
		goButton.Position = UDim2.new(1, -140, 0.5, -15)
		goButton.BackgroundColor3 = Theme.AccentDark
		goButton.BorderSizePixel = 0
		goButton.Font = Enum.Font.GothamBold
		goButton.TextSize = 12
		goButton.TextColor3 = Theme.Text
		goButton.Text = "Go"
		goButton.Parent = row
		addCorner(goButton, 6)
		goButton.MouseButton1Click:Connect(function()
			teleportToPoint(point)
		end)

		local deleteButton = Instance.new("TextButton")
		deleteButton.Size = UDim2.fromOffset(64, 30)
		deleteButton.Position = UDim2.new(1, -76, 0.5, -15)
		deleteButton.BackgroundColor3 = Theme.Danger
		deleteButton.BorderSizePixel = 0
		deleteButton.Font = Enum.Font.GothamBold
		deleteButton.TextSize = 12
		deleteButton.TextColor3 = Theme.Text
		deleteButton.Text = "Delete"
		deleteButton.Parent = row
		addCorner(deleteButton, 6)
		deleteButton.MouseButton1Click:Connect(function()
			table.remove(teleportPoints, index)
			saveTeleportPoints()
			renderTeleportPoints()
		end)

		table.insert(teleportRows, row)
	end
	updateCanvasSize()
end

local teleportNameRow = createRow("TeleportNameRow", 1, teleportPage)
local teleportNameLabel = Instance.new("TextLabel")
teleportNameLabel.Size = UDim2.new(0.5, -12, 1, 0)
teleportNameLabel.Position = UDim2.fromOffset(12, 0)
teleportNameLabel.BackgroundTransparency = 1
teleportNameLabel.Font = Enum.Font.GothamMedium
teleportNameLabel.TextSize = 14
teleportNameLabel.TextColor3 = Theme.Text
teleportNameLabel.TextXAlignment = Enum.TextXAlignment.Left
teleportNameLabel.Text = "Marker name"
teleportNameLabel.Parent = teleportNameRow

local teleportNameBox = Instance.new("TextBox")
teleportNameBox.Size = UDim2.fromOffset(126, 30)
teleportNameBox.Position = UDim2.new(1, -138, 0.5, -15)
teleportNameBox.BackgroundColor3 = Theme.PanelSoft
teleportNameBox.BorderSizePixel = 0
teleportNameBox.Font = Enum.Font.GothamMedium
teleportNameBox.TextSize = 13
teleportNameBox.TextColor3 = Theme.Text
teleportNameBox.PlaceholderColor3 = Theme.Muted
teleportNameBox.PlaceholderText = "Point name"
teleportNameBox.ClearTextOnFocus = false
teleportNameBox.Parent = teleportNameRow
addCorner(teleportNameBox, 6)

local teleportAddRow = createRow("TeleportAddRow", 2, teleportPage)
local teleportAddLabel = Instance.new("TextLabel")
teleportAddLabel.Size = UDim2.new(1, -100, 1, 0)
teleportAddLabel.Position = UDim2.fromOffset(12, 0)
teleportAddLabel.BackgroundTransparency = 1
teleportAddLabel.Font = Enum.Font.GothamMedium
teleportAddLabel.TextSize = 14
teleportAddLabel.TextColor3 = Theme.Text
teleportAddLabel.TextXAlignment = Enum.TextXAlignment.Left
teleportAddLabel.Text = "Save current position"
teleportAddLabel.Parent = teleportAddRow

local teleportAddButton = Instance.new("TextButton")
teleportAddButton.Size = UDim2.fromOffset(82, 30)
teleportAddButton.Position = UDim2.new(1, -94, 0.5, -15)
teleportAddButton.BackgroundColor3 = Theme.AccentDark
teleportAddButton.BorderSizePixel = 0
teleportAddButton.Font = Enum.Font.GothamBold
teleportAddButton.TextSize = 13
teleportAddButton.TextColor3 = Theme.Text
teleportAddButton.Text = "Add"
teleportAddButton.Parent = teleportAddRow
addCorner(teleportAddButton, 6)
teleportAddButton.MouseButton1Click:Connect(function()
	local root, humanoid = getRootAndHumanoid()
	if not root or not humanoid or humanoid.Health <= 0 or #teleportPoints >= 40 then
		return
	end
	local name = string.match(teleportNameBox.Text, "^%s*(.-)%s*$")
	if not name or name == "" then
		name = "Point " .. tostring(#teleportPoints + 1)
	end
	name = string.sub(name, 1, 28)
	local position = root.Position
	table.insert(teleportPoints, {
		Name = name,
		X = math.floor(position.X * 100) / 100,
		Y = math.floor(position.Y * 100) / 100,
		Z = math.floor(position.Z * 100) / 100,
	})
	teleportNameBox.Text = ""
	saveTeleportPoints()
	renderTeleportPoints()
end)

local teleportListLabel = Instance.new("TextLabel")
teleportListLabel.Size = UDim2.new(1, -4, 0, 22)
teleportListLabel.BackgroundTransparency = 1
teleportListLabel.Font = Enum.Font.GothamBold
teleportListLabel.TextSize = 13
teleportListLabel.TextColor3 = Theme.Muted
teleportListLabel.TextXAlignment = Enum.TextXAlignment.Left
teleportListLabel.Text = "Saved markers"
teleportListLabel.LayoutOrder = 3
teleportListLabel.Parent = teleportPage

renderTeleportPoints()

local bindingHotkey = nil
local hotkeyBindings = {}

local function updateHotkeyBindings()
	for _, binding in ipairs(hotkeyBindings) do
		binding.value.Text = Config[binding.configKey].Name
		binding.button.Text = bindingHotkey == binding and "..." or "Bind"
		binding.button.BackgroundColor3 = bindingHotkey == binding and Theme.AccentDark or Theme.Button
	end
end

local function createHotkeyRow(text, order, configKey, parentPage)
	local row = createRow(text .. "HotkeyRow", order, parentPage)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -132, 1, 0)
	label.Position = UDim2.fromOffset(12, 0)
	label.BackgroundTransparency = 1
	label.Text = text .. " bind"
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.TextColor3 = Theme.Text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.Size = UDim2.fromOffset(42, 30)
	value.Position = UDim2.new(1, -112, 0.5, -15)
	value.BackgroundColor3 = Theme.PanelSoft
	value.BorderSizePixel = 0
	value.Text = Config[configKey].Name
	value.Font = Enum.Font.GothamBold
	value.TextSize = 13
	value.TextColor3 = Theme.Text
	value.Parent = row
	addCorner(value, 6)

	local button = Instance.new("TextButton")
	button.Name = "Bind"
	button.Size = UDim2.fromOffset(62, 30)
	button.Position = UDim2.new(1, -66, 0.5, -15)
	button.BackgroundColor3 = Theme.Button
	button.BorderSizePixel = 0
	button.Text = "Bind"
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextColor3 = Theme.Text
	button.AutoButtonColor = true
	button.Parent = row
	addCorner(button, 6)

	local binding = {
		button = button,
		value = value,
		configKey = configKey,
	}

	table.insert(hotkeyBindings, binding)

	track(button.MouseButton1Click:Connect(function()
		bindingHotkey = if bindingHotkey == binding then nil else binding
		updateHotkeyBindings()
	end))

	return binding
end

createHotkeyRow("Fly", 1, "Hotkey", settingsPage)
createHotkeyRow("AntiAFK", 2, "AntiAFKHotkey", settingsPage)
createHotkeyRow("NoClip", 3, "NoClipHotkey", settingsPage)
createHotkeyRow("Clicker", 4, "ClickerHotkey", settingsPage)
createHotkeyRow("ESP", 5, "ESPHotkey", settingsPage)
createHotkeyRow("GUI", 6, "GuiHotkey", settingsPage)

local fastSpeedRow = createRow("FastFlySpeedRow", 8, settingsPage)

local fastSpeedLabel = Instance.new("TextLabel")
fastSpeedLabel.Name = "Label"
fastSpeedLabel.Size = UDim2.new(0.5, -12, 1, 0)
fastSpeedLabel.Position = UDim2.fromOffset(12, 0)
fastSpeedLabel.BackgroundTransparency = 1
fastSpeedLabel.Text = "Fast fly speed"
fastSpeedLabel.Font = Enum.Font.GothamMedium
fastSpeedLabel.TextSize = 14
fastSpeedLabel.TextColor3 = Theme.Text
fastSpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
fastSpeedLabel.Parent = fastSpeedRow

local fastSpeedBox = Instance.new("TextBox")
fastSpeedBox.Name = "FastSpeedBox"
fastSpeedBox.Size = UDim2.fromOffset(82, 30)
fastSpeedBox.Position = UDim2.new(1, -94, 0.5, -15)
fastSpeedBox.BackgroundColor3 = Theme.PanelSoft
fastSpeedBox.BorderSizePixel = 0
fastSpeedBox.Font = Enum.Font.GothamMedium
fastSpeedBox.TextSize = 14
fastSpeedBox.TextColor3 = Theme.Text
fastSpeedBox.PlaceholderColor3 = Theme.Muted
fastSpeedBox.Text = tostring(Config.FastSpeed)
fastSpeedBox.PlaceholderText = "Speed"
fastSpeedBox.ClearTextOnFocus = false
fastSpeedBox.Parent = fastSpeedRow
addCorner(fastSpeedBox, 6)

track(fastSpeedBox.FocusLost:Connect(function()
	local value = clampNumber(fastSpeedBox.Text, Config.MinFastSpeed, Config.MaxFastSpeed)
	if value then
		Config.FastSpeed = value
		saveConfigValue("FastSpeed")
	end
	fastSpeedBox.Text = tostring(Config.FastSpeed)
end))

local antiAfkIntervalRow = createRow("AntiAFKIntervalRow", 9, settingsPage)

local antiAfkIntervalLabel = Instance.new("TextLabel")
antiAfkIntervalLabel.Name = "Label"
antiAfkIntervalLabel.Size = UDim2.new(0.5, -12, 1, 0)
antiAfkIntervalLabel.Position = UDim2.fromOffset(12, 0)
antiAfkIntervalLabel.BackgroundTransparency = 1
antiAfkIntervalLabel.Text = "AntiAFK sec"
antiAfkIntervalLabel.Font = Enum.Font.GothamMedium
antiAfkIntervalLabel.TextSize = 14
antiAfkIntervalLabel.TextColor3 = Theme.Text
antiAfkIntervalLabel.TextXAlignment = Enum.TextXAlignment.Left
antiAfkIntervalLabel.Parent = antiAfkIntervalRow

local antiAfkIntervalBox = Instance.new("TextBox")
antiAfkIntervalBox.Name = "IntervalBox"
antiAfkIntervalBox.Size = UDim2.fromOffset(82, 30)
antiAfkIntervalBox.Position = UDim2.new(1, -94, 0.5, -15)
antiAfkIntervalBox.BackgroundColor3 = Theme.PanelSoft
antiAfkIntervalBox.BorderSizePixel = 0
antiAfkIntervalBox.Font = Enum.Font.GothamMedium
antiAfkIntervalBox.TextSize = 14
antiAfkIntervalBox.TextColor3 = Theme.Text
antiAfkIntervalBox.PlaceholderColor3 = Theme.Muted
antiAfkIntervalBox.Text = tostring(Config.AntiAFKInterval)
antiAfkIntervalBox.PlaceholderText = "Seconds"
antiAfkIntervalBox.ClearTextOnFocus = false
antiAfkIntervalBox.Parent = antiAfkIntervalRow
addCorner(antiAfkIntervalBox, 6)

track(antiAfkIntervalBox.FocusLost:Connect(function()
	local value = clampNumber(antiAfkIntervalBox.Text, Config.MinAntiAFKInterval, Config.MaxAntiAFKInterval)
	if value then
		Config.AntiAFKInterval = value
		saveConfigValue("AntiAFKInterval")
	end
	antiAfkIntervalBox.Text = tostring(Config.AntiAFKInterval)
end))

local resetRow = createRow("ResetSettingsRow", 10, settingsPage)

local resetLabel = Instance.new("TextLabel")
resetLabel.Name = "Label"
resetLabel.Size = UDim2.new(1, -100, 1, 0)
resetLabel.Position = UDim2.fromOffset(12, 0)
resetLabel.BackgroundTransparency = 1
resetLabel.Text = "Reset settings"
resetLabel.Font = Enum.Font.GothamMedium
resetLabel.TextSize = 14
resetLabel.TextColor3 = Theme.Text
resetLabel.TextXAlignment = Enum.TextXAlignment.Left
resetLabel.Parent = resetRow

local resetButton = Instance.new("TextButton")
resetButton.Name = "Reset"
resetButton.Size = UDim2.fromOffset(82, 30)
resetButton.Position = UDim2.new(1, -94, 0.5, -15)
resetButton.BackgroundColor3 = Theme.Danger
resetButton.BorderSizePixel = 0
resetButton.Font = Enum.Font.GothamBold
resetButton.TextSize = 13
resetButton.TextColor3 = Theme.Text
resetButton.AutoButtonColor = true
resetButton.Text = "Reset"
resetButton.Parent = resetRow
addCorner(resetButton, 6)

local resetSettings = nil

track(resetButton.MouseButton1Click:Connect(function()
	if resetSettings then
		resetSettings()
	end
end))

updateHotkeyBindings()
updateCanvasSize()

updateMiniStatus = function()
	local active = {}
	if flyControl.isEnabled() then
		table.insert(active, "F")
	end
	if antiAfkControl.isEnabled() then
		table.insert(active, "A")
	end
	if noClipControl.isEnabled() then
		table.insert(active, "N")
	end
	if clickerControl.isEnabled() then
		table.insert(active, "C")
	end
	if invisibilityControl and invisibilityControl.isEnabled() then
		table.insert(active, "I")
	end
	if espControl.isEnabled() then
		table.insert(active, "E")
	end
	if fullBrightControl.isEnabled() then
		table.insert(active, "B")
	end
	if vegetationControl.isEnabled() then
		table.insert(active, "G")
	end
	miniStatus.Text = table.concat(active, " ")
end
updateMiniStatus()

local function setContentVisible(visible)
	topBar.Visible = visible
	content.Visible = visible
end

local function setMiniPosition(position)
	collapsedPosition = clampOffsetPosition(position, collapsedSize)
	miniButton.Position = collapsedPosition
	savePosition("CollapsedPosition", collapsedPosition)
end

local function collapseGui()
	if collapsed or animatingCollapse then
		return
	end

	collapsed = true
	animatingCollapse = true
	sessionState.Collapsed = true
	queueSaveSettings()
	expandedPosition = clampOffsetPosition(frame.Position, expandedSize)
	savePosition("ExpandedPosition", expandedPosition)
	local targetPosition = clampOffsetPosition(expandedPosition, collapsedSize)
	setMiniPosition(targetPosition)
	setContentVisible(false)
	local activeTween = tween(frame, 0.24, { Position = targetPosition, Size = collapsedSize })

	activeTween.Completed:Connect(function()
		if destroyed then
			return
		end
		frame.Visible = false
		miniButton.Visible = true
		animatingCollapse = false
	end)
end

local function expandGui()
	if not collapsed or animatingCollapse then
		return
	end

	collapsed = false
	animatingCollapse = true
	sessionState.Collapsed = false
	queueSaveSettings()
	frame.Position = miniButton.Position
	frame.Size = collapsedSize
	frame.Visible = true
	miniButton.Visible = false
	local targetPosition = clampOffsetPosition(miniButton.Position, expandedSize)
	expandedPosition = targetPosition
	savePosition("ExpandedPosition", expandedPosition)
	local activeTween = tween(frame, 0.24, { Position = targetPosition, Size = expandedSize })

	activeTween.Completed:Connect(function()
		if destroyed then
			return
		end
		setContentVisible(true)
		animatingCollapse = false
	end)
end

resetSettings = function()
	Config.FlySpeed = 50
	Config.FastSpeed = 120
	Config.Hotkey = Enum.KeyCode.F
	Config.AntiAFKHotkey = Enum.KeyCode.G
	Config.NoClipHotkey = Enum.KeyCode.N
	Config.ClickerHotkey = Enum.KeyCode.C
	Config.ESPHotkey = Enum.KeyCode.V
	Config.GuiHotkey = Enum.KeyCode.RightShift
	Config.AntiAFKInterval = 120
	Config.ClickInterval = 0.1
	Config.ClickButton = "Left"
	Config.ClickTargetEnabled = false
	Config.ClickTargetX = nil
	Config.ClickTargetY = nil
	sessionState.Hotkeys = {}
	sessionState.Settings = {}
	sessionState.Collapsed = false
	sessionState.ExpandedPosition = nil
	sessionState.CollapsedPosition = nil
	collapsed = false
	animatingCollapse = false
	expandedSize = getExpandedSize()
	collapsedSize = getCollapsedSize()
	expandedPosition = clampOffsetPosition(defaultExpandedPosition(), expandedSize)
	collapsedPosition = expandedPosition
	frame.Size = expandedSize
	frame.Position = expandedPosition
	frame.Visible = true
	miniButton.Size = collapsedSize
	miniButton.Position = collapsedPosition
	miniButton.Visible = false
	setContentVisible(true)
	speedBox.Text = tostring(Config.FlySpeed)
	fastSpeedBox.Text = tostring(Config.FastSpeed)
	antiAfkIntervalBox.Text = tostring(Config.AntiAFKInterval)
	clickDelayBox.Text = tostring(Config.ClickInterval)
	clickModeButton.Text = Config.ClickButton
	clickTargetButton.Text = "Mouse"
	clickTargetMarker.Visible = false
	clickTargetMarker.Position = saveClickTargetPosition(getDefaultClickTargetPosition())
	updateHotkeyBindings()
	updateMiniStatus()
	queueSaveSettings()
	saveSettingsNow()
end

local function makeDraggable(handle, target, sizeGetter, moved)
	local dragging = false
	local dragStart = nil
	local startPosition = nil

	track(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = target.Position

			local releaseConnection
			releaseConnection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if releaseConnection then
						releaseConnection:Disconnect()
						releaseConnection = nil
					end
				end
			end)
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local delta = input.Position - dragStart
		local nextPosition = UDim2.fromOffset(startPosition.X.Offset + delta.X, startPosition.Y.Offset + delta.Y)
		nextPosition = clampOffsetPosition(nextPosition, sizeGetter())
		target.Position = nextPosition
		if moved then
			moved(nextPosition)
		end
	end))
end

makeDraggable(topBar, frame, function()
	return expandedSize
end, function(position)
	expandedPosition = position
	savePosition("ExpandedPosition", expandedPosition)
end)

makeDraggable(miniButton, miniButton, function()
	return collapsedSize
end, function(position)
	collapsedPosition = position
	savePosition("CollapsedPosition", collapsedPosition)
end)

makeDraggable(clickTargetMarker, clickTargetMarker, function()
	return clickTargetSize
end, function(position)
	clickTargetMarker.Position = saveClickTargetPosition(position)
end)

local cameraViewportConnection = nil

local function refreshGuiBounds()
	expandedSize = getExpandedSize()
	collapsedSize = getCollapsedSize()
	miniButton.Size = collapsedSize
	clickTargetMarker.Position = saveClickTargetPosition(clickTargetMarker.Position)
	updateCanvasSize()

	if collapsed then
		setMiniPosition(miniButton.Position)
	else
		expandedPosition = clampOffsetPosition(frame.Position, expandedSize)
		frame.Size = expandedSize
		frame.Position = expandedPosition
		savePosition("ExpandedPosition", expandedPosition)
	end
end

local function bindViewportWatcher()
	disconnect(cameraViewportConnection)
	cameraViewportConnection = nil
	local camera = Workspace.CurrentCamera
	if camera then
		cameraViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshGuiBounds)
	end
end

bindViewportWatcher()
track(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	bindViewportWatcher()
	refreshGuiBounds()
end))
track(minimizeButton.MouseButton1Click:Connect(collapseGui))
track(miniButton.MouseButton1Click:Connect(expandGui))

track(UserInputService.InputBegan:Connect(function(input, processed)
	if bindingHotkey then
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.Unknown then
			Config[bindingHotkey.configKey] = input.KeyCode
			sessionState.Hotkeys[bindingHotkey.configKey] = input.KeyCode.Name
			queueSaveSettings()
			bindingHotkey = nil
			updateHotkeyBindings()
		end
		return
	end

	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	if input.KeyCode == Config.Hotkey then
		flyControl.toggle()
	elseif input.KeyCode == Config.AntiAFKHotkey then
		antiAfkControl.toggle()
	elseif input.KeyCode == Config.NoClipHotkey then
		noClipControl.toggle()
	elseif input.KeyCode == Config.ClickerHotkey then
		clickerControl.toggle()
	elseif input.KeyCode == Config.ESPHotkey then
		espControl.toggle()
	elseif input.KeyCode == Config.GuiHotkey then
		if collapsed then
			expandGui()
		else
			collapseGui()
		end
	end
end))

track(closeButton.MouseButton1Click:Connect(function()
	screenGui:Destroy()
end))

track(LocalPlayer.CharacterAdded:Connect(function()
	Fly.stop()
	NoClip.stop()
	flyControl.setState(false)
	noClipControl.setState(false)
	updateMiniStatus()
end))

track(screenGui.Destroying:Connect(function()
	if destroyed then
		return
	end

	destroyed = true
	sessionState.Collapsed = collapsed
	queueSaveSettings()
	if collapsed then
		savePosition("CollapsedPosition", miniButton.Position)
	else
		savePosition("ExpandedPosition", frame.Position)
	end
	Fly.stop()
	NoClip.stop()
	AntiAFK.toggle(false)
	Clicker.stop()
	ESP.stop()
	FullBright.stop()
	Vegetation.stop()
	if invisibilityControl then
		Invisibility.toggle(false)
	end
	disconnect(cameraViewportConnection)

	for _, connection in ipairs(uiConnections) do
		disconnect(connection)
	end

	saveSettingsNow()
	table.clear(uiConnections)
end))
