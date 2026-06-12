local CONFIG = {
    -- ── Сеть ───────────────────────────────────────────────────────
    API_URL  = "http://127.0.0.1:8000/api/stock", -- эндпойнт твоего server.py
    API_KEY  = "CHANGE-ME-secret-key",            -- == API_KEY в server.py
    TIMEOUT  = 15,                                 -- сек на HTTP-запрос (не у всех executor'ов учитывается)

    -- ── Режим работы ───────────────────────────────────────────────
    -- "dump"   — обойти ВСЕ GUI, показать дерево в игре с кнопкой "копировать".
    --            Ничего на сервер не шлёт. Используй сейчас, до релиза/настройки.
    -- "scrape" — обычный парсинг стока и отправка на API.
    MODE = "dump",

    -- ── Дамп GUI (MODE="dump") ─────────────────────────────────────
    -- Цель — прочитать ВЁ дерево целиком. Лимиты подняты до значений,
    -- которые в реальных GUI не достигаются, но защищают от вечного цикла.
    DUMP_MAX_DEPTH   = 60,     -- макс. глубина обхода дерева
    DUMP_MAX_NODES   = 200000, -- предохранитель от гигантских деревьев
    DUMP_SHOW_TEXT   = true,   -- показывать .Text у лейблов/кнопок/полей
    DUMP_TEXT_MAXLEN = 400,    -- макс. длина показываемого .Text (0 = без обрезки)
    DUMP_INCLUDE_HIDDEN = true, -- включать невидимые (Visible=false) элементы
    DUMP_SCAN_COREGUI = true,  -- пробовать gethui()/CoreGui (скрытые от игры GUI)

    -- ── Сканирование (MODE="scrape") ───────────────────────────────
    SCAN_INTERVAL   = 30,   -- как часто пересканировать GUI (сек), запасной поллинг
    ONLY_ON_CHANGE  = true, -- слать на сервер только когда сток реально изменился
    DEBUG           = true, -- печатать в консоль executor'а что нашли/отправили

    -- ── Где искать магазины ────────────────────────────────────────
    -- Скрипт ищет в PlayerGui все ScreenGui, чьё имя содержит одно из
    -- этих слов (без учёта регистра). Дополни/поправь под реальные имена.
    SHOP_NAME_KEYWORDS = { "seed", "gear", "egg", "shop", "store", "stock", "event", "cosmetic" },

    -- Если авто-поиск не сработает — задай магазины вручную:
    -- путь = последовательность имён от PlayerGui до контейнера с item-фреймами.
    -- Пример: { name="Seed Shop", path={"Seed_Shop","Frame","ScrollingFrame"} }
    MANUAL_SHOPS = {
        -- { name = "Seed Shop", path = {"Seed_Shop", "Frame", "ScrollingFrame"} },
    },

    -- ── Кастомный парсер одного item-фрейма (опционально) ───────────
    -- Верни { name=string, quantity=number } или nil чтобы пропустить.
    -- Если nil — используется встроенная эвристика parseItemDefault().
    parseItem = nil,
}

-- =====================================================================
--  Сервисы и окружение executor'а
-- =====================================================================
local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- Универсальная HTTP-функция: разные executor'ы называют её по-разному.
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

-- =====================================================================
--  Парсинг
-- =====================================================================

-- Достаёт первое число вида "x5" / "X 5" / "5x" / "Stock: 5" из строки.
local function extractQuantity(text)
    if type(text) ~= "string" then return nil end
    local t = text:lower()
    -- "no stock" / "out of stock" / "sold out" -> 0
    if t:find("no%s*stock") or t:find("out%s*of%s*stock") or t:find("sold%s*out") then
        return 0
    end
    -- "x5" или "x 5"
    local q = t:match("x%s*(%d+)")
    if q then return tonumber(q) end
    -- "5x"
    q = t:match("(%d+)%s*x")
    if q then return tonumber(q) end
    -- "stock: 5" / "stock 5"
    q = t:match("stock[:%s]+(%d+)")
    if q then return tonumber(q) end
    return nil
end

-- Встроенная эвристика: из контейнера одного товара вытащить имя и кол-во.
-- Стратегия: среди TextLabel-потомков ищем тот, где есть количество (xN),
-- а имя берём из самого "крупного"/первого осмысленного текстового лейбла.
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
            -- не чисто число/цена -> вероятно название
            nameCandidate = nameCandidate or l.text
        end
    end

    -- если имя не нашли — берём самый длинный нечисловой лейбл
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

-- Из контейнера магазина собрать список товаров.
-- Контейнер обычно ScrollingFrame/Frame, дети — карточки товаров.
local function parseShopContainer(container)
    local items = {}
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("GuiObject") and not child:IsA("UIListLayout")
           and not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
            local ok, item = pcall(parseItem, child)
            if ok and item and item.name then
                -- сток 0 обычно значит "нет в наличии" — не шлём
                if item.quantity and item.quantity > 0 then
                    table.insert(items, { name = item.name, quantity = item.quantity })
                end
            end
        end
    end
    return items
end

-- =====================================================================
--  Поиск магазинов в GUI
-- =====================================================================

-- Эвристика: внутри ScreenGui найти контейнер, где лежат карточки товаров
-- (ScrollingFrame с наибольшим числом фреймов-детей).
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

-- Собрать список { name=, container= } всех магазинов.
local function discoverShops()
    local shops = {}

    -- 1) Ручные пути имеют приоритет
    for _, m in ipairs(CONFIG.MANUAL_SHOPS) do
        local container = resolvePath(PlayerGui, m.path)
        if container then
            table.insert(shops, { name = m.name, container = container })
        else
            warnLog("MANUAL_SHOP не найден по пути:", m.name)
        end
    end
    if #shops > 0 then return shops end

    -- 2) Авто-поиск по ключевым словам в имени ScreenGui
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

-- =====================================================================
--  Отправка на API
-- =====================================================================
local lastPayloadHash = nil

local function buildPayload(shopsData)
    -- Формат под server.py (current_stock: shop, items, restock_in):
    -- { shops = { { shop=, items={{name,quantity}...}, restock_in=nil } } }
    return {
        source     = "gag2-stock-scraper",
        shops      = shopsData,
    }
end

local function send(payload)
    if not httpRequest then
        warnLog("Executor не предоставляет HTTP-функцию (request/http_request). Отправка невозможна.")
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

-- =====================================================================
--  Режим DUMP — обойти ВСЕ GUI и собрать текстовое дерево
-- =====================================================================

-- Корни, где живут интерфейсы. PlayerGui — основной; gethui()/CoreGui —
-- скрытые/защищённые GUI (если executor даёт доступ).
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

-- Рекурсивно строит строки дерева. Возвращает количество обработанных узлов.
local function dumpNode(inst, depth, lines, counter)
    if counter.n >= CONFIG.DUMP_MAX_NODES then return end
    if depth > CONFIG.DUMP_MAX_DEPTH then return end

    -- скрытое можно пропустить ещё ДО инкремента счётчика
    if inst:IsA("GuiObject") and CONFIG.DUMP_INCLUDE_HIDDEN == false and inst.Visible == false then
        return
    end

    counter.n += 1
    local indent = string.rep("  ", depth)
    local line = indent .. inst.ClassName .. " \"" .. inst.Name .. "\""

    if inst:IsA("GuiObject") and inst.Visible == false then
        line = line .. " [hidden]"
    end

    -- текст у любых текстовых элементов, целиком (с учётом DUMP_TEXT_MAXLEN)
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

-- ── In-game оверлей с результатом и кнопкой копирования ────────────
local function showDumpGui(text, nodeCount)
    -- куда парентить: gethui()/CoreGui надёжнее (не закроется вместе с игровым GUI)
    local parent = PlayerGui
    local okHui, hui = pcall(function() return gethui and gethui() end)
    if okHui and hui then parent = hui end

    -- снести прошлый, если перезапустили
    local old = parent:FindFirstChild("GAG2_DumpGui")
    if old then old:Destroy() end

    local screen = Instance.new("ScreenGui")
    screen.Name = "GAG2_DumpGui"
    screen.ResetOnSpawn = false
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.DisplayOrder = 9999
    screen.Parent = parent

    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, 560, 0, 420)
    main.Position = UDim2.new(0.5, -280, 0.5, -210)
    main.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true -- перетаскивание окна
    main.Parent = screen
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = main

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 34)
    title.BackgroundColor3 = Color3.fromRGB(36, 36, 42)
    title.BorderSizePixel = 0
    title.Text = "GAG2 GUI Dump  ("  .. nodeCount .. " nodes)  —  перетаскивай за шапку"
    title.TextColor3 = Color3.fromRGB(235, 235, 235)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Parent = main
    local tCorner = Instance.new("UICorner"); tCorner.CornerRadius = UDim.new(0, 8); tCorner.Parent = title

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -20, 1, -90)
    box.Position = UDim2.new(0, 10, 0, 42)
    box.BackgroundColor3 = Color3.fromRGB(16, 16, 18)
    box.BorderSizePixel = 0
    box.TextColor3 = Color3.fromRGB(210, 210, 210)
    box.Font = Enum.Font.Code
    box.TextSize = 12
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.TextYAlignment = Enum.TextYAlignment.Top
    box.ClearTextOnFocus = false
    box.MultiLine = true
    box.TextWrapped = false
    box.Text = text
    box.Parent = main
    local bCorner = Instance.new("UICorner"); bCorner.CornerRadius = UDim.new(0, 6); bCorner.Parent = box
    local bPad = Instance.new("UIPadding")
    bPad.PaddingLeft = UDim.new(0, 6); bPad.PaddingTop = UDim.new(0, 4)
    bPad.Parent = box

    -- кнопка "Копировать"
    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0.5, -14, 0, 34)
    copyBtn.Position = UDim2.new(0, 10, 1, -42)
    copyBtn.BackgroundColor3 = Color3.fromRGB(46, 120, 70)
    copyBtn.BorderSizePixel = 0
    copyBtn.Text = "📋 Копировать всё"
    copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextSize = 14
    copyBtn.Parent = main
    local cCorner = Instance.new("UICorner"); cCorner.CornerRadius = UDim.new(0, 6); cCorner.Parent = copyBtn

    -- кнопка "Закрыть"
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0.5, -14, 0, 34)
    closeBtn.Position = UDim2.new(0.5, 4, 1, -42)
    closeBtn.BackgroundColor3 = Color3.fromRGB(90, 50, 50)
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "Закрыть"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 14
    closeBtn.Parent = main
    local clCorner = Instance.new("UICorner"); clCorner.CornerRadius = UDim.new(0, 6); clCorner.Parent = closeBtn

    -- функция копирования: разные executor'ы дают разные имена
    local clip = setclipboard or toclipboard or (syn and syn.write_clipboard) or set_clipboard
    copyBtn.MouseButton1Click:Connect(function()
        if clip then
            local ok = pcall(clip, text)
            copyBtn.Text = ok and "✅ Скопировано!" or "⚠ Ошибка копирования"
        else
            -- фолбэк: выделить текст в поле, чтобы скопировать вручную (Ctrl+C)
            box:CaptureFocus()
            copyBtn.Text = "⚠ setclipboard нет — выдели в поле и Ctrl+C"
        end
        task.delay(2, function()
            copyBtn.Text = "📋 Копировать всё"
        end)
    end)

    closeBtn.MouseButton1Click:Connect(function()
        screen:Destroy()
    end)

    log("Dump-GUI показан. Узлов:", nodeCount)
end

local function runDump()
    local text, n = buildDump()
    -- продублируем в консоль executor'а на всякий случай
    if CONFIG.DEBUG then print(text) end
    -- и сразу положим в буфер, если можем
    local clip = setclipboard or toclipboard or (syn and syn.write_clipboard) or set_clipboard
    if clip then pcall(clip, text) end
    showDumpGui(text, n)
end

-- =====================================================================
--  Главный цикл
-- =====================================================================
local function scanOnce()
    local shops = discoverShops()
    if #shops == 0 then
        log("Магазины не найдены (GUI закрыт или имена не совпали с keywords).")
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
            restock_in = nil, -- TODO: распарсить таймер рестока, когда увидим GUI
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
        warnLog("ВНИМАНИЕ: HTTP-функция не найдена — данные не уйдут на сервер.")
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
        -- в dump-режиме цикл не нужен: открыл нужный GUI в игре -> перезапусти скрипт
    else
        startScrape()
    end
end

task.spawn(start)
