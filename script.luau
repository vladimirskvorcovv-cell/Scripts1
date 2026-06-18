--!nonstrict
-- GetGUI — live GUI text scraper.
--
-- Walks every reachable GUI (CoreGui / gethui, every PlayerGui, StarterGui)
-- and pulls the actual on-screen DATA out of it: every TextLabel / TextButton /
-- TextBox text, every visible value. This is how you read things like shop
-- "stock" counts and the current "weather" straight from the game's own UI —
-- no remote/file digging, just whatever the UI is already displaying.
--
-- Output goes three ways:
--   1) printed to the executor console (grouped by ScreenGui),
--   2) copied to the clipboard,
--   3) shown in a small searchable on-screen window (filter by "stock", "weather", …).

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------
-- Executor shims
----------------------------------------------------------------------
local function getHidden()
	if typeof(gethui) == "function" then
		local ok, res = pcall(gethui)
		if ok and res then return res end
	end
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	return pg or CoreGui
end

local function setClip(text)
	local fn = setclipboard or (syn and syn.write_clipboard) or toclipboard or set_clipboard
	if typeof(fn) == "function" then
		return (pcall(fn, text))
	end
	return false
end

----------------------------------------------------------------------
-- Collect GUI roots
----------------------------------------------------------------------
local function collectRoots()
	local roots, seen = {}, {}
	local function add(label, c)
		if c and not seen[c] then
			seen[c] = true
			table.insert(roots, { label = label, container = c })
		end
	end
	if typeof(gethui) == "function" then
		local ok, hui = pcall(gethui)
		if ok and hui then add("HiddenUI", hui) end
	end
	pcall(add, "CoreGui", CoreGui)
	for _, plr in ipairs(Players:GetPlayers()) do
		local pg = plr:FindFirstChildOfClass("PlayerGui")
		if pg then add("PlayerGui:" .. plr.Name, pg) end
	end
	pcall(add, "StarterGui", StarterGui)
	return roots
end

----------------------------------------------------------------------
-- Extract every piece of text/data from a root.
-- Returns an array of { path, class, text, visible }
----------------------------------------------------------------------
local function cleanText(s)
	-- collapse whitespace / newlines so each entry is one tidy line
	s = tostring(s):gsub("%s+", " ")
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isVisibleChain(inst, stopAt)
	local node = inst
	while node and node ~= stopAt do
		local okVis, vis = pcall(function() return node.Visible end)
		if okVis and vis == false then return false end
		local okEn, en = pcall(function() return node.Enabled end)
		if okEn and en == false then return false end
		node = node.Parent
	end
	return true
end

local function scrapeRoot(root)
	local out = {}
	local okKids, all = pcall(function() return root:GetDescendants() end)
	if not okKids then return out end
	for _, inst in ipairs(all) do
		-- Anything text-bearing.
		local ok, txt = pcall(function() return inst.Text end)
		if ok and typeof(txt) == "string" and cleanText(txt) ~= "" then
			-- Relative path from the root for readability.
			local full = inst:GetFullName()
			table.insert(out, {
				inst = inst,
				path = full,
				class = inst.ClassName,
				text = cleanText(txt),
				visible = isVisibleChain(inst, root.Parent),
			})
		end
	end
	return out
end

local function scrapeAll(onlyVisible)
	local groups = {} -- { rootLabel, entries = {...} }
	for _, r in ipairs(collectRoots()) do
		local entries = scrapeRoot(r.container)
		if onlyVisible then
			local filtered = {}
			for _, e in ipairs(entries) do
				if e.visible then table.insert(filtered, e) end
			end
			entries = filtered
		end
		if #entries > 0 then
			table.insert(groups, { label = r.label, entries = entries })
		end
	end
	return groups
end

local function groupsToText(groups)
	local lines = {}
	for _, g in ipairs(groups) do
		table.insert(lines, "")
		table.insert(lines, "==== " .. g.label .. " (" .. #g.entries .. ") ====")
		for _, e in ipairs(g.entries) do
			table.insert(lines, string.format("[%s]%s  %s",
				e.class,
				e.visible and "" or " (hidden)",
				e.text))
			table.insert(lines, "    " .. e.path)
		end
	end
	return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local hidden = getHidden()
local old = hidden:FindFirstChild("GetGUI_Scraper")
if old then old:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "GetGUI_Scraper"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 999999
screenGui.Parent = hidden
pcall(function() if syn and syn.protect_gui then syn.protect_gui(screenGui) end end)
pcall(function() if protect_gui then protect_gui(screenGui) end end)

local C_BG     = Color3.fromRGB(22, 23, 29)
local C_PANEL  = Color3.fromRGB(31, 33, 41)
local C_PANEL2 = Color3.fromRGB(40, 42, 52)
local C_ACCENT = Color3.fromRGB(86, 132, 255)
local C_TEXT   = Color3.fromRGB(232, 234, 240)
local C_SUBTLE = Color3.fromRGB(150, 154, 168)
local C_HL     = Color3.fromRGB(245, 205, 90)

local function corner(p, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = p; return c
end
local function pad(p, n)
	local u = Instance.new("UIPadding")
	u.PaddingTop = UDim.new(0, n); u.PaddingBottom = UDim.new(0, n)
	u.PaddingLeft = UDim.new(0, n); u.PaddingRight = UDim.new(0, n); u.Parent = p; return u
end

local win = Instance.new("Frame")
win.Size = UDim2.fromOffset(560, 440)
win.Position = UDim2.new(0.5, -280, 0.5, -220)
win.BackgroundColor3 = C_BG
win.BorderSizePixel = 0
win.Active = true
win.Parent = screenGui
corner(win, 10)
do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(58, 62, 80); s.Parent = win end

-- Title bar
local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 36)
bar.BackgroundColor3 = C_PANEL
bar.BorderSizePixel = 0
bar.Active = true
bar.Parent = win
corner(bar, 10)

local titleText = Instance.new("TextLabel")
titleText.BackgroundTransparency = 1
titleText.Position = UDim2.fromOffset(12, 0)
titleText.Size = UDim2.new(1, -90, 1, 0)
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 14
titleText.TextColor3 = C_TEXT
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.Text = "GetGUI · live data scraper"
titleText.Parent = bar

local function barBtn(sym, xoff, col)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(24, 24)
	b.Position = UDim2.new(1, xoff, 0.5, -12)
	b.BackgroundColor3 = C_PANEL2
	b.Text = sym; b.Font = Enum.Font.GothamBold; b.TextSize = 15
	b.TextColor3 = col or C_TEXT
	b.Parent = bar
	corner(b, 6)
	return b
end
local closeBtn = barBtn("×", -30, Color3.fromRGB(224, 86, 92))

-- Controls row
local controls = Instance.new("Frame")
controls.Size = UDim2.new(1, -16, 0, 30)
controls.Position = UDim2.fromOffset(8, 42)
controls.BackgroundTransparency = 1
controls.Parent = win

local searchBox = Instance.new("TextBox")
searchBox.Size = UDim2.new(1, -250, 1, 0)
searchBox.BackgroundColor3 = C_PANEL
searchBox.BorderSizePixel = 0
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 13
searchBox.TextColor3 = C_TEXT
searchBox.PlaceholderText = "filter… (try: stock, weather)"
searchBox.PlaceholderColor3 = C_SUBTLE
searchBox.Text = ""
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.ClearTextOnFocus = false
searchBox.Parent = controls
corner(searchBox, 6); pad(searchBox, 8)

local function ctlBtn(text, w, x)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 30)
	b.Position = UDim2.new(1, x, 0, 0)
	b.BackgroundColor3 = C_PANEL2
	b.Font = Enum.Font.GothamMedium; b.TextSize = 12; b.TextColor3 = C_TEXT
	b.Text = text; b.Parent = controls
	corner(b, 6)
	return b
end
local refreshBtn = ctlBtn("Rescan", 64, -64)
local copyBtn    = ctlBtn("Copy all", 70, -132)
local printBtn   = ctlBtn("Print", 56, -192)

-- Visible-only toggle
local visToggle = Instance.new("TextButton")
visToggle.Size = UDim2.fromOffset(0, 0)
visToggle.Visible = false
visToggle.Parent = controls
local onlyVisible = false

-- Result list
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 1, -110)
scroll.Position = UDim2.fromOffset(8, 80)
scroll.BackgroundColor3 = C_PANEL
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new()
scroll.Parent = win
corner(scroll, 8)
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 2)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scroll
pad(scroll, 6)

-- Status / count
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 18)
status.Position = UDim2.new(0, 8, 1, -24)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextColor3 = C_SUBTLE
status.TextXAlignment = Enum.TextXAlignment.Left
status.Text = ""
status.Parent = win

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------
local currentGroups = {}

local function clearList()
	for _, c in ipairs(scroll:GetChildren()) do
		if not (c:IsA("UIListLayout") or c:IsA("UIPadding")) then c:Destroy() end
	end
end

local function escapeRich(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function render()
	clearList()
	local term = string.lower(searchBox.Text)
	local order = 0
	local shown = 0
	local total = 0

	for _, g in ipairs(currentGroups) do
		-- Filter this group's entries.
		local matched = {}
		for _, e in ipairs(g.entries) do
			total += 1
			if term == "" or string.find(string.lower(e.text .. " " .. e.path .. " " .. e.class), term, 1, true) then
				table.insert(matched, e)
			end
		end
		if #matched == 0 then continue end

		-- Group header
		order += 1
		local header = Instance.new("TextLabel")
		header.Size = UDim2.new(1, 0, 0, 20)
		header.BackgroundColor3 = C_PANEL2
		header.BorderSizePixel = 0
		header.Font = Enum.Font.GothamBold
		header.TextSize = 12
		header.TextColor3 = C_ACCENT
		header.TextXAlignment = Enum.TextXAlignment.Left
		header.Text = "  " .. g.label .. "  (" .. #matched .. ")"
		header.LayoutOrder = order
		header.Parent = scroll
		corner(header, 4)

		for _, e in ipairs(matched) do
			shown += 1
			order += 1
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, 0, 0, 0)
			row.AutomaticSize = Enum.AutomaticSize.Y
			row.BackgroundColor3 = C_BG
			row.BackgroundTransparency = 0.25
			row.AutoButtonColor = false
			row.Text = ""
			row.LayoutOrder = order
			row.Parent = scroll
			corner(row, 4)

			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.new(1, -10, 0, 0)
			lbl.Position = UDim2.fromOffset(6, 0)
			lbl.AutomaticSize = Enum.AutomaticSize.Y
			lbl.Font = Enum.Font.Code
			lbl.TextSize = 12
			lbl.TextWrapped = true
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.RichText = true
			lbl.Text = string.format(
				'<font color="#f5cd5a">%s</font>  <font color="#9aa0b4">[%s]%s</font>\n<font color="#6b6f80">%s</font>',
				escapeRich(e.text),
				e.class,
				e.visible and "" or " (hidden)",
				escapeRich(e.path)
			)
			lbl.Parent = row

			local padr = Instance.new("UIPadding")
			padr.PaddingTop = UDim.new(0, 4); padr.PaddingBottom = UDim.new(0, 4)
			padr.Parent = row

			row.MouseButton1Click:Connect(function()
				setClip(e.text)
				status.Text = "Copied: " .. e.text:sub(1, 60)
			end)
			row.MouseEnter:Connect(function() row.BackgroundTransparency = 0 end)
			row.MouseLeave:Connect(function() row.BackgroundTransparency = 0.25 end)
		end
	end

	status.Text = string.format("%d shown / %d total · click a row to copy its value",
		shown, total)
end

local function rescan()
	currentGroups = scrapeAll(onlyVisible)
	render()
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
searchBox:GetPropertyChangedSignal("Text"):Connect(render)
refreshBtn.MouseButton1Click:Connect(rescan)
closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

copyBtn.MouseButton1Click:Connect(function()
	local ok = setClip(groupsToText(currentGroups))
	status.Text = ok and "All data copied to clipboard" or "No clipboard function available"
end)

printBtn.MouseButton1Click:Connect(function()
	print(groupsToText(currentGroups))
	status.Text = "Printed to console (" .. #currentGroups .. " sources)"
end)

-- Drag
do
	local dragging, dragStart, startPos
	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true; dragStart = input.Position; startPos = win.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

----------------------------------------------------------------------
-- Go
----------------------------------------------------------------------
rescan()
