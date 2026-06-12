local CONFIG = {
    API_URL  = "http://127.0.0.1:8000/api/stock",
    API_KEY  = "CHANGE-ME-secret-key",
    TIMEOUT  = 15,

    MODE = "dump",

    DUMP_MAX_DEPTH   = 60,
    DUMP_MAX_NODES   = 200000,
    DUMP_SHOW_TEXT   = true,
    DUMP_TEXT_MAXLEN = 400,
    DUMP_INCLUDE_HIDDEN = true,
    DUMP_SCAN_COREGUI = true,

    SCAN_INTERVAL   = 30,
    ONLY_ON_CHANGE  = true,
    DEBUG           = true,

    SHOP_NAME_KEYWORDS = { "seed", "gear", "egg", "shop", "store", "stock", "event", "cosmetic" },

    MANUAL_SHOPS = {
    },

    parseItem = nil,
}

local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local httpRequest =
    (syn and syn.request)
    or (http and http.request)
    or http_request
    or request
    or (fluxus and fluxus.request)
    or (krnl and krnl.request)

local function log(...)
    if CONFIG.DEBUG then
        print("[GAG2-Stock]", ...)
    end
end

local function warnLog(...)
    warn("[GAG2-Stock]", ...)
end

local function extractQuantity(text)
    if type(text) ~= "string" then return nil end
    local t = text:lower()
    if t:find("no%s*stock") or t:find("out%s*of%s*stock") or t:find("sold%s*out") then
        return 0
    end
    local q = t:match("x%s*(%d+)")
    if q then return tonumber(q) end
    q = t:match("(%d+)%s*x")
    if q then return tonumber(q) end
    q = t:match("stock[:%s]+(%d+)")
    if q then return tonumber(q) end
    q = t:match("(%d+)%s*in%s*stock") or t:match("(%d+)%s*left") or t:match("(%d+)%s*avail")
    if q then return tonumber(q) end
    q = t:match("qty[:%s]+(%d+)") or t:match("amount[:%s]+(%d+)")
    if q then return tonumber(q) end
    q = t:match("^%s*(%d+)%s*$")
    if q then return tonumber(q) end
    return nil
end

local function parseItemDefault(itemFrame)
    local labels = {}
    for _, d in ipairs(itemFrame:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local txt = (d.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if txt ~= "" then
                table.insert(labels, { obj = d, text = txt })
            end
        end
    end
    if #labels == 0 then return nil end

    local quantity, nameCandidate
    for _, l in ipairs(labels) do
        local q = extractQuantity(l.text)
        if q ~= nil and not quantity then
            quantity = q
        elseif not l.text:match("^[%dxX%s:%$]+$") then
            nameCandidate = nameCandidate or l.text
        end
    end

    if not nameCandidate then
        local best = ""
        for _, l in ipairs(labels) do
            if #l.text > #best and not l.text:match("^[%dxX%s:%$]+$") then
                best = l.text
            end
        end
        if best ~= "" then nameCandidate = best end
    end

    if not nameCandidate then return nil end
    return { name = nameCandidate, quantity = quantity or 0 }
end

local function parseItem(itemFrame)
    if CONFIG.parseItem then
        local ok, res = pcall(CONFIG.parseItem, itemFrame)
        if ok then return res end
        warnLog("CONFIG.parseItem упал:", res)
    end
    return parseItemDefault(itemFrame)
end

local function parseShopContainer(container)
    local items = {}
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("GuiObject") and not child:IsA("UIListLayout")
           and not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
            local ok, item = pcall(parseItem, child)
            if ok and item and item.name then
                if item.quantity and item.quantity > 0 then
                    table.insert(items, { name = item.name, quantity = item.quantity })
                end
            end
        end
    end
    return items
end

local function findItemsContainer(root)
    local best, bestCount = nil, 0
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("ScrollingFrame") or d:IsA("Frame") then
            local frameChildren = 0
            for _, c in ipairs(d:GetChildren()) do
                if c:IsA("Frame") or c:IsA("ImageButton") or c:IsA("TextButton") then
                    frameChildren += 1
                end
            end
            if frameChildren > bestCount then
                best, bestCount = d, frameChildren
            end
        end
    end
    return best, bestCount
end

local function resolvePath(root, path)
    local node = root
    for _, seg in ipairs(path) do
        node = node:FindFirstChild(seg)
        if not node then return nil end
    end
    return node
end

local function discoverShops()
    local shops = {}

    for _, m in ipairs(CONFIG.MANUAL_SHOPS) do
        local container = resolvePath(PlayerGui, m.path)
        if container then
            table.insert(shops, { name = m.name, container = container })
        else
            warnLog("MANUAL_SHOP не найден по пути:", m.name)
        end
    end
    if #shops > 0 then return shops end

    for _, gui in ipairs(PlayerGui:GetChildren()) do
        if gui:IsA("ScreenGui") or gui:IsA("Folder") then
            local lname = gui.Name:lower()
            local matched = false
            for _, kw in ipairs(CONFIG.SHOP_NAME_KEYWORDS) do
                if lname:find(kw, 1, true) then matched = true break end
            end
            if matched then
                local container, count = findItemsContainer(gui)
                if container and count > 0 then
                    table.insert(shops, { name = gui.Name, container = container })
                end
            end
        end
    end
    return shops
end

local lastPayloadHash = nil

local function buildPayload(shopsData)
    return {
        source = "gag2-stock-scraper",
        shops  = shopsData,
    }
end

local function send(payload)
    if not httpRequest then
        warnLog("Executor не предоставляет HTTP-функцию. Отправка невозможна.")
        return false
    end
    local body = HttpService:JSONEncode(payload)

    local ok, resp = pcall(httpRequest, {
        Url = CONFIG.API_URL,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["X-API-Key"]    = CONFIG.API_KEY,
        },
        Body = body,
    })

    if not ok then
        warnLog("HTTP-запрос упал:", resp)
        return false
    end

    local status = resp.StatusCode or resp.Status or 0
    if status >= 200 and status < 300 then
        log("Отправлено. Статус:", status)
        return true
    else
        warnLog("Сервер вернул статус", status, resp.Body)
        return false
    end
end

local function getGuiRoots()
    local roots = { { name = "PlayerGui", inst = PlayerGui } }
    if CONFIG.DUMP_SCAN_COREGUI then
        local ok, hui = pcall(function() return gethui and gethui() end)
        if ok and hui then
            table.insert(roots, { name = "gethui()", inst = hui })
        end
        local ok2, core = pcall(function() return game:GetService("CoreGui") end)
        if ok2 and core then
            table.insert(roots, { name = "CoreGui", inst = core })
        end
    end
    return roots
end

local function truncate(s, n)
    s = tostring(s):gsub("[\r\n]+", " ")
    if n and n > 0 and #s > n then return s:sub(1, n) .. "…" end
    return s
end

local function dumpNode(inst, depth, lines, counter)
    if counter.n >= CONFIG.DUMP_MAX_NODES then return end
    if depth > CONFIG.DUMP_MAX_DEPTH then return end

    if inst:IsA("GuiObject") and CONFIG.DUMP_INCLUDE_HIDDEN == false and inst.Visible == false then
        return
    end

    counter.n += 1
    local indent = string.rep("  ", depth)
    local line = indent .. inst.ClassName .. " \"" .. inst.Name .. "\""

    if inst:IsA("GuiObject") and inst.Visible == false then
        line = line .. " [hidden]"
    end

    local okText, txt = pcall(function() return inst.Text end)
    if CONFIG.DUMP_SHOW_TEXT and okText and type(txt) == "string" and txt ~= "" then
        line = line .. "  Text=\"" .. truncate(txt, CONFIG.DUMP_TEXT_MAXLEN) .. "\""
    end

    table.insert(lines, line)

    local okKids, kids = pcall(function() return inst:GetChildren() end)
    if okKids then
        for _, child in ipairs(kids) do
            dumpNode(child, depth + 1, lines, counter)
        end
    end
end

local function buildDump()
    local lines = {}
    local counter = { n = 0 }
    table.insert(lines, "===== GAG2 GUI DUMP =====")
    table.insert(lines, "place=" .. tostring(game.PlaceId) .. "  maxDepth=" .. CONFIG.DUMP_MAX_DEPTH)
    table.insert(lines, "")

    for _, root in ipairs(getGuiRoots()) do
        table.insert(lines, "### ROOT: " .. root.name .. " ###")
        local ok, err = pcall(function()
            for _, child in ipairs(root.inst:GetChildren()) do
                dumpNode(child, 0, lines, counter)
            end
        end)
        if not ok then
            table.insert(lines, "  <ошибка обхода: " .. tostring(err) .. ">")
        end
        table.insert(lines, "")
    end

    table.insert(lines, "===== END (" .. counter.n .. " nodes) =====")
    return table.concat(lines, "\n"), counter.n
end

local LINES_PER_CHUNK = 150
local LINE_HEIGHT = 16
local CHAR_WIDTH = 7.6

local function protectGui(gui)
    pcall(function()
        if syn and syn.protect_gui then syn.protect_gui(gui) end
    end)
    pcall(function()
        if protect_gui then protect_gui(gui) end
    end)
end

local function newCorner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = p
    return c
end

local function newStroke(p, col, th)
    local s = Instance.new("UIStroke")
    s.Color = col
    s.Thickness = th
    s.Parent = p
    return s
end

local function showDumpGui(fullText, nodeCount)
    local UIS = game:GetService("UserInputService")

    local allLines = string.split(fullText, "\n")

    local screen = Instance.new("ScreenGui")
    screen.Name = "GAG2_DumpGui"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.DisplayOrder = 999999
    protectGui(screen)

    local parent = PlayerGui
    local okHui, hui = pcall(function() return gethui and gethui() end)
    if okHui and hui then parent = hui end

    local old = parent:FindFirstChild("GAG2_DumpGui")
    if old then old:Destroy() end
    local oldPg = PlayerGui:FindFirstChild("GAG2_DumpGui")
    if oldPg then oldPg:Destroy() end

    screen.Parent = parent

    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, 660, 0, 500)
    main.Position = UDim2.new(0.5, -330, 0.5, -250)
    main.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
    main.BorderSizePixel = 0
    main.Active = true
    main.ClipsDescendants = true
    main.Parent = screen
    newCorner(main, 8)
    newStroke(main, Color3.fromRGB(90, 90, 110), 1.5)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 38)
    title.BackgroundColor3 = Color3.fromRGB(48, 48, 60)
    title.BorderSizePixel = 0
    title.Text = "  GAG2 GUI Dump   |   " .. nodeCount .. " nodes   |   " .. #allLines .. " строк"
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.Parent = main
    newCorner(title, 8)

    local search = Instance.new("TextBox")
    search.Size = UDim2.new(1, -132, 0, 30)
    search.Position = UDim2.new(0, 10, 0, 46)
    search.BackgroundColor3 = Color3.fromRGB(44, 44, 54)
    search.BorderSizePixel = 0
    search.PlaceholderText = "фильтр строк (подстрока, регистронезависимо)"
    search.PlaceholderColor3 = Color3.fromRGB(150, 150, 165)
    search.Text = ""
    search.TextColor3 = Color3.fromRGB(235, 235, 240)
    search.Font = Enum.Font.Gotham
    search.TextSize = 14
    search.TextXAlignment = Enum.TextXAlignment.Left
    search.ClearTextOnFocus = false
    search.Parent = main
    newCorner(search, 6)
    newStroke(search, Color3.fromRGB(95, 95, 115), 1)
    local sPad = Instance.new("UIPadding")
    sPad.PaddingLeft = UDim.new(0, 10)
    sPad.Parent = search

    local wrapBtn = Instance.new("TextButton")
    wrapBtn.Size = UDim2.new(0, 112, 0, 30)
    wrapBtn.Position = UDim2.new(1, -122, 0, 46)
    wrapBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 88)
    wrapBtn.BorderSizePixel = 0
    wrapBtn.Text = "Перенос: ВЫКЛ"
    wrapBtn.TextColor3 = Color3.fromRGB(235, 235, 240)
    wrapBtn.Font = Enum.Font.GothamMedium
    wrapBtn.TextSize = 13
    wrapBtn.Parent = main
    newCorner(wrapBtn, 6)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -20, 1, -132)
    scroll.Position = UDim2.new(0, 10, 0, 84)
    scroll.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 10
    scroll.ScrollBarImageColor3 = Color3.fromRGB(120, 120, 140)
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.ScrollingDirection = Enum.ScrollingDirection.XY
    scroll.Parent = main
    newCorner(scroll, 6)
    newStroke(scroll, Color3.fromRGB(80, 80, 100), 1)
    local scPad = Instance.new("UIPadding")
    scPad.PaddingLeft = UDim.new(0, 10); scPad.PaddingTop = UDim.new(0, 8)
    scPad.PaddingRight = UDim.new(0, 10); scPad.PaddingBottom = UDim.new(0, 8)
    scPad.Parent = scroll

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0.5, -14, 0, 36)
    copyBtn.Position = UDim2.new(0, 10, 1, -44)
    copyBtn.BackgroundColor3 = Color3.fromRGB(52, 140, 82)
    copyBtn.BorderSizePixel = 0
    copyBtn.Text = "Копировать всё"
    copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextSize = 15
    copyBtn.Parent = main
    newCorner(copyBtn, 6)

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0.5, -14, 0, 36)
    closeBtn.Position = UDim2.new(0.5, 4, 1, -44)
    closeBtn.BackgroundColor3 = Color3.fromRGB(150, 64, 64)
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "Закрыть"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 15
    closeBtn.Parent = main
    newCorner(closeBtn, 6)

    local grip = Instance.new("TextButton")
    grip.Size = UDim2.new(0, 20, 0, 20)
    grip.Position = UDim2.new(1, -22, 1, -68)
    grip.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
    grip.BorderSizePixel = 0
    grip.Text = "::"
    grip.TextColor3 = Color3.fromRGB(220, 220, 230)
    grip.Font = Enum.Font.GothamBold
    grip.TextSize = 13
    grip.AutoButtonColor = false
    grip.Parent = main
    newCorner(grip, 5)

    local wrapOn = false

    local function clearLabels()
        for _, ch in ipairs(scroll:GetChildren()) do
            if ch:IsA("TextLabel") then ch:Destroy() end
        end
    end

    local function render(linesToShow)
        clearLabels()
        local total = #linesToShow
        local maxChars = 1
        for _, ln in ipairs(linesToShow) do
            if #ln > maxChars then maxChars = #ln end
        end
        local contentW = math.floor(maxChars * CHAR_WIDTH) + 16

        local y = 0
        for i = 1, total, LINES_PER_CHUNK do
            local last = math.min(i + LINES_PER_CHUNK - 1, total)
            local count = last - i + 1
            local slice = table.concat(linesToShow, "\n", i, last)

            local lbl = Instance.new("TextLabel")
            lbl.BackgroundTransparency = 1
            lbl.Font = Enum.Font.Code
            lbl.TextSize = 14
            lbl.TextColor3 = Color3.fromRGB(210, 215, 220)
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.TextYAlignment = Enum.TextYAlignment.Top
            lbl.RichText = false
            lbl.Text = slice
            lbl.Position = UDim2.new(0, 0, 0, y)

            if wrapOn then
                lbl.TextWrapped = true
                lbl.Size = UDim2.new(1, -20, 0, count * LINE_HEIGHT)
            else
                lbl.TextWrapped = false
                lbl.Size = UDim2.new(0, contentW, 0, count * LINE_HEIGHT)
            end

            lbl.Parent = scroll
            y += count * LINE_HEIGHT
        end

        if wrapOn then
            scroll.CanvasSize = UDim2.new(0, 0, 0, y + 10)
        else
            scroll.CanvasSize = UDim2.new(0, contentW + 10, 0, y + 10)
        end
        scroll.CanvasPosition = Vector2.new(0, 0)
    end

    local function safeRender(linesToShow)
        local ok, err = pcall(render, linesToShow)
        if not ok then warnLog("render упал:", err) end
    end

    local function applyFilter()
        local q = search.Text:lower()
        if q == "" then safeRender(allLines); return end
        local filtered = {}
        for _, ln in ipairs(allLines) do
            if ln:lower():find(q, 1, true) then
                table.insert(filtered, ln)
            end
        end
        if #filtered == 0 then filtered = { "(ничего не найдено: " .. search.Text .. ")" } end
        safeRender(filtered)
    end

    search:GetPropertyChangedSignal("Text"):Connect(applyFilter)

    wrapBtn.MouseButton1Click:Connect(function()
        wrapOn = not wrapOn
        wrapBtn.Text = wrapOn and "Перенос: ВКЛ" or "Перенос: ВЫКЛ"
        applyFilter()
    end)

    local clip = setclipboard or toclipboard or (syn and syn.write_clipboard) or set_clipboard
    copyBtn.MouseButton1Click:Connect(function()
        if clip then
            local ok = pcall(clip, fullText)
            copyBtn.Text = ok and "Скопировано!" or "Ошибка копирования"
        else
            copyBtn.Text = "setclipboard недоступен"
        end
        task.delay(2, function() copyBtn.Text = "Копировать всё" end)
    end)

    closeBtn.MouseButton1Click:Connect(function() screen:Destroy() end)

    local dragging, dragStart, startPos = false, nil, nil
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    local resizing, rStart, rStartSize = false, nil, nil
    grip.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            resizing = true
            rStart = input.Position
            rStartSize = main.AbsoluteSize
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then resizing = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - rStart
            local w = math.max(380, rStartSize.X + delta.X)
            local h = math.max(260, rStartSize.Y + delta.Y)
            main.Size = UDim2.new(0, w, 0, h)
        end
    end)

    safeRender(allLines)

    log("Dump-GUI показан. Узлов:", nodeCount, "строк:", #allLines)
end

local function runDump()
    local text, n = buildDump()
    if CONFIG.DEBUG then print(text) end
    local clip = setclipboard or toclipboard or (syn and syn.write_clipboard) or set_clipboard
    if clip then pcall(clip, text) end
    showDumpGui(text, n)
end

local function scanOnce()
    local shops = discoverShops()
    if #shops == 0 then
        log("Магазины не найдены.")
        return
    end

    local shopsData = {}
    local totalItems = 0
    for _, shop in ipairs(shops) do
        local items = parseShopContainer(shop.container)
        totalItems += #items
        table.insert(shopsData, {
            shop       = shop.name,
            items      = items,
            restock_in = nil,
        })
        log(("Магазин %q: %d товаров"):format(shop.name, #items))
    end

    if totalItems == 0 then
        log("Сток пустой — пропускаю отправку.")
        return
    end

    local payload = buildPayload(shopsData)
    local hash = HttpService:JSONEncode(payload.shops)
    if CONFIG.ONLY_ON_CHANGE and hash == lastPayloadHash then
        log("Сток не изменился — не отправляю.")
        return
    end

    if send(payload) then
        lastPayloadHash = hash
    end
end

local function startScrape()
    log("Режим SCRAPE. API:", CONFIG.API_URL)
    if not httpRequest then
        warnLog("HTTP-функция не найдена — данные не уйдут на сервер.")
    end
    while true do
        local ok, err = pcall(scanOnce)
        if not ok then
            warnLog("scanOnce упал:", err)
        end
        task.wait(CONFIG.SCAN_INTERVAL)
    end
end

local function start()
    if CONFIG.MODE == "dump" then
        log("Режим DUMP — собираю дерево всех GUI.")
        local ok, err = pcall(runDump)
        if not ok then warnLog("runDump упал:", err) end
    else
        startScrape()
    end
end

task.spawn(start)
