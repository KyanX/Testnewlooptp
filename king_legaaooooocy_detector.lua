-- ═══════════════════════════════════════════════════════════════════
--  King Legacy Boss Detector v15
--  Sea 2 | Delta Executor (Android)
--
--  Key architecture:
--    - Attack via SkillAction remote (not VIM clicks) + VIM fallback
--    - Physics sync via PhysicReplication remote every 0.25s
--    - Chest scan from ISLAND ANCHOR (not player position), r=1500m
--    - False death protection: 5.5s rescan after boss dies
--    - Anti-fall platform (invisible BasePart under boss)
--    - Pre-spawned chest check on join
--    - Auto-store fruit: equip → VIM tap → EatFruitBecky popup →
--      wait Collect visible → VIM click Collect
--
--  v15 fix (from v12 spy findings):
--    - Store = server-side EatFruitManage Script (NOT a remote call)
--    - conn.Function = nil → firesignal CANNOT work, VIM-only click
--    - Tool has attribute StoreFruit=true (game-set, not by us)
--    - NoClick BoolValue must be false before clicking
--    - Wait for Collect button Visible=true before clicking
--    - VIM touch prioritized (Android/Delta), mouse fallback
--    - Multiple click attempts with verification
-- ═══════════════════════════════════════════════════════════════════

-- ─── Services ─────────────────────────────────────────────────────
local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")

local lp      = Players.LocalPlayer
local PlaceID = game.PlaceId

-- ─── Color palette ────────────────────────────────────────────────
local COL = {
    bg      = Color3.fromRGB(12, 12, 24),
    bgCard  = Color3.fromRGB(20, 20, 38),
    title   = Color3.fromRGB(18, 18, 34),
    accent  = Color3.fromRGB(88, 140, 255),
    green   = Color3.fromRGB(50, 205, 120),
    red     = Color3.fromRGB(220, 55, 55),
    orange  = Color3.fromRGB(255, 180, 50),
    gold    = Color3.fromRGB(255, 195, 55),
    purple  = Color3.fromRGB(140, 80, 220),
    text    = Color3.fromRGB(200, 200, 215),
    textSub = Color3.fromRGB(90, 90, 120),
    white   = Color3.fromRGB(255, 255, 255),
}

-- ─── Constants ────────────────────────────────────────────────────
local CONFIG_FILE  = "BossDetectorConfig.json"
local VISITED_FILE = "NotSameServers.json"

local BOSS_NAMES  = { "HydraSeaKing", "SeaKing" }
local SWORD_NAMES = { "Kioru V2", "KioruV2", "Kioru" }

-- Island anchors — chest is scanned relative to these, NOT player position
local ISLAND_ANCHORS = { "HydraStand", "ClockTime" }

-- Chest parts v11.1 (false-positive parts removed: SpawnPit, Coins, MiniCoin, Gem)
local CHEST_NAMES = {
    "ChestSpawner",
    "Top", "Buttom",
    "SkullRetopo", "EyeRight", "EyeLeft",
    "ChestTop", "ChestBottum",
    "Dragon", "Wing",
}
local CHEST_SET = {}
for _, nm in ipairs(CHEST_NAMES) do CHEST_SET[nm] = true end

local WEBHOOKS = {
    HydraSeaKing = "https://discord.com/api/webhooks/1486246249123414016/WCjK_oi1jGMQDNa8tt3IWCaVlIdr0pRd-CZ7S0YtY7L_GTqn29_WO6ChkkfSa5mgvmdZ",
    SeaKing      = "https://discord.com/api/webhooks/1486245519008333854/XSPHGAL3uXFFUlT72qODHeSiBGX3oiJ16hzIsYyHFQnX6ubqAQbq--Z-tZTN7UhywB71",
    Chest        = "", -- Fill with full chest webhook URL
}

-- ─── State ────────────────────────────────────────────────────────
local isRunning         = false
local isFighting        = false
local isPostFight       = false
local isHopping         = false
local autoScan          = false
local autoFight         = false
local autoStore         = false
local foundCode         = nil
local notifiedJobs      = {}
local notifiedChestJobs = {}
local visitedServers    = {}
local statusLockUntil   = 0
local serverHopCursor   = nil
local lastChestKey      = nil
local fightPlatform     = nil  -- anti-fall platform instance

-- Character cache (rebuilt ≤every 3s — prevents isPlayerPart lag)
local charCache     = {}
local charCacheTime = 0

-- Descendants cache (rebuilt ≤every 3s — prevents lag from multiple GetDescendants)
local descCache     = {}
local descCacheTime = 0

-- Forward declare (defined after GUI builds)
local setStatusGUI
local setChestStatus
local sendChestToDiscord

-- ─── Character Cache ──────────────────────────────────────────────
local function refreshCharCache()
    local now = tick()
    if now - charCacheTime < 3 then return end
    charCacheTime = now
    charCache = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            charCache[p.Character] = true
            for _, part in ipairs(p.Character:GetChildren()) do
                charCache[part] = true
            end
        end
    end
end

local function isPlayerPart(obj)
    if charCache[obj] then return true end
    local par = obj.Parent
    if par and charCache[par] then return true end
    return false
end

local function getDescendantsCache()
    local now = tick()
    if now - descCacheTime < 3 then return descCache end
    descCacheTime = now
    descCache = workspace:GetDescendants()
    return descCache
end

-- ─── Helpers ──────────────────────────────────────────────────────
local function getHRP()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local c = lp.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function isSwordTool(tool)
    for _, sn in ipairs(SWORD_NAMES) do
        if tool.Name == sn or tool.Name:find(sn, 1, true) then return true end
    end
    return false
end

-- ─── Config ───────────────────────────────────────────────────────
local function loadConfig()
    pcall(function()
        if isfile and isfile(CONFIG_FILE) then
            local d = HttpService:JSONDecode(readfile(CONFIG_FILE))
            autoScan  = d.autoScan  or false
            autoFight = d.autoFight or false
            autoStore = d.autoStore or false
        end
    end)
end

local function saveConfig()
    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode({ autoScan = autoScan, autoFight = autoFight, autoStore = autoStore }))
    end)
end

-- ─── Visited Servers ──────────────────────────────────────────────
local function loadVisited()
    pcall(function()
        if isfile and isfile(VISITED_FILE) then
            for _, id in ipairs(HttpService:JSONDecode(readfile(VISITED_FILE))) do
                visitedServers[id] = true
            end
        end
    end)
end

local function saveVisited()
    pcall(function()
        local list = {}
        for id in pairs(visitedServers) do
            table.insert(list, id)
            if #list > 500 then break end
        end
        writefile(VISITED_FILE, HttpService:JSONEncode(list))
    end)
end

-- ─── Boss Detection ───────────────────────────────────────────────
-- 2-pass: GetChildren first (fast path), then GetDescendants
local function findBossModel()
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") then
            for _, bn in ipairs(BOSS_NAMES) do
                if obj.Name == bn then
                    local h = obj:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 then return obj, bn end
                end
            end
        end
    end
    for _, obj in ipairs(getDescendantsCache()) do
        if obj:IsA("Model") then
            for _, bn in ipairs(BOSS_NAMES) do
                if obj.Name == bn then
                    local h = obj:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 then return obj, bn end
                end
            end
        end
    end
    return nil, nil
end

-- ─── Island Anchor ────────────────────────────────────────────────
-- Chest is scanned FROM the island anchor, not from player position
local function findIslandAnchor()
    refreshCharCache()
    for _, obj in ipairs(getDescendantsCache()) do
        if not isPlayerPart(obj) then
            for _, an in ipairs(ISLAND_ANCHORS) do
                if obj.Name == an then
                    local part = obj:IsA("BasePart") and obj or obj:FindFirstChildOfClass("BasePart")
                    if part then return part.Position, obj.Name end
                end
            end
        end
    end
    return nil, nil
end

-- ─── Chest Scan ───────────────────────────────────────────────────
-- Tier detection v11.1
local function detectTier(nameSet)
    -- T3: Dragon or Wing
    if nameSet["Dragon"] or nameSet["Wing"]   then return "T3 Dragon" end
    -- T2: ChestTop/ChestBottum + SkullRetopo
    if (nameSet["ChestTop"] or nameSet["ChestBottum"]) and nameSet["SkullRetopo"] then return "T2" end
    -- T4? (unconfirmed): ChestTop/ChestBottum only
    if nameSet["ChestTop"] or nameSet["ChestBottum"]  then return "T4?" end
    -- T1: Top or Buttom
    if nameSet["Top"] or nameSet["Buttom"]    then return "T1" end
    return "?"
end

-- Scan chest parts within radius of center position
-- Returns: nearestPos (Vector3 or nil), nameList, tier
local function scanChestNear(center, radius)
    local nameSet, nameList = {}, {}
    local nearPart, bestDist = nil, math.huge

    for _, obj in ipairs(getDescendantsCache()) do
        if (obj:IsA("Model") or obj:IsA("BasePart")) and not isPlayerPart(obj) then
            local nm = obj.Name
            if CHEST_SET[nm] then
                local part = obj:IsA("BasePart") and obj or obj:FindFirstChildOfClass("BasePart")
                if part then
                    local d = (part.Position - center).Magnitude
                    if d <= radius then
                        if not nameSet[nm] then
                            nameSet[nm] = true
                            table.insert(nameList, nm)
                        end
                        if d < bestDist then bestDist = d; nearPart = part end
                    end
                end
            end
        end
    end

    if #nameList == 0 then return nil, {}, "?" end
    return nearPart and nearPart.Position or nil, nameList, detectTier(nameSet)
end

-- ─── Discord (always async — prevents lag) ────────────────────────
local function sendBossToDiscord(bossName, jobId)
    local url = WEBHOOKS[bossName]
    if not url or url == "" then return end
    local key = jobId .. "_" .. bossName
    if notifiedJobs[key] then return end
    notifiedJobs[key] = true
    local dn  = bossName == "HydraSeaKing" and "Hydra Sea King" or "Sea King"
    local clr = bossName == "HydraSeaKing" and 0x8B00FF or 0x0080FF
    task.spawn(function()
        pcall(function()
            request({
                Url     = url, Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HttpService:JSONEncode({ embeds = {{
                    title       = "🔴 Boss Found — " .. dn,
                    description = jobId .. "\n```\n" .. jobId .. "\n```\nKing Legacy → Private Servers → Paste code",
                    color       = clr,
                    footer      = { text = "King Legacy Boss Detector v15 | Sea 2" },
                }}})
            })
        end)
    end)
end

sendChestToDiscord = function(jobId, tier, nameList)
    local url = WEBHOOKS.Chest
    if not url or url == "" then return end
    if notifiedChestJobs[jobId] then return end
    notifiedChestJobs[jobId] = true
    local parts = table.concat(nameList, ", ")
    local clr   = tier:find("T3") and 0xFF4500 or (tier == "T2" and 0xFFD700 or 0x00CED1)
    task.spawn(function()
        pcall(function()
            request({
                Url     = url, Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HttpService:JSONEncode({ embeds = {{
                    title       = "🧲 Chest Found — " .. tier,
                    description = jobId .. "\n```\n" .. jobId .. "\n```\nParts: " .. parts ..
                                  "\nKing Legacy → Private Servers → Paste code",
                    color       = clr,
                    footer      = { text = "King Legacy Boss Detector v15 | Sea 2" },
                }}})
            })
        end)
    end)
end

-- ─── Equip Sword ──────────────────────────────────────────────────
local function isSwordEquipped()
    local c = lp.Character
    if not c then return false end
    for _, t in ipairs(c:GetChildren()) do
        if t:IsA("Tool") and isSwordTool(t) then return true end
    end
    return false
end

local function getEquippedSwordName()
    local c = lp.Character
    if not c then return nil end
    for _, t in ipairs(c:GetChildren()) do
        if t:IsA("Tool") and isSwordTool(t) then return t.Name end
    end
    return nil
end

local function equipSword()
    local hum = getHumanoid()
    if not hum then
        pcall(function() setStatusGUI("❌ No character", COL.red, 3) end)
        return false
    end
    local bp = lp:FindFirstChild("Backpack")
    if not bp then return false end

    local sword = nil
    for _, sn in ipairs(SWORD_NAMES) do
        sword = bp:FindFirstChild(sn); if sword then break end
    end
    if not sword then
        local tools = {}
        for _, c in ipairs(bp:GetChildren()) do
            if c:IsA("Tool") then table.insert(tools, c) end
        end
        sword = tools[2] or tools[1]
    end

    if sword then
        pcall(function() hum:EquipTool(sword) end)
        task.wait(0.4)
        pcall(function() setStatusGUI("⚔️ Equipped: " .. sword.Name, COL.green, 4) end)
        return true
    end
    pcall(function() setStatusGUI("❌ Sword not found!", COL.red, 6) end)
    return false
end

-- ─── Remotes (SkillAction + PhysicReplication) ────────────────────
local function getSkillRemote()
    local rs = game:GetService("ReplicatedStorage")
    return pcall(function() return rs.Chest.Remotes.Functions.SkillAction end) and
           rs:FindFirstChild("Chest") and
           rs.Chest:FindFirstChild("Remotes") and
           rs.Chest.Remotes:FindFirstChild("Functions") and
           rs.Chest.Remotes.Functions:FindFirstChild("SkillAction") or nil
end

local function getPhysicsRemote()
    local rs = game:GetService("ReplicatedStorage")
    return rs:FindFirstChild("Chest") and
           rs.Chest:FindFirstChild("Remotes") and
           rs.Chest.Remotes:FindFirstChild("Events") and
           rs.Chest.Remotes.Events:FindFirstChild("PhysicReplication") or nil
end

-- ─── Anti-Fall Platform ───────────────────────────────────────────
local function createFightPlatform(pos)
    if fightPlatform then pcall(function() fightPlatform:Destroy() end) end
    local p = Instance.new("Part")
    p.Size             = Vector3.new(3, 0.5, 2)
    p.CFrame           = CFrame.new(pos - Vector3.new(0, 2, 0))
    p.Anchored         = true
    p.CanCollide       = true
    p.Transparency     = 1
    p.CanQuery         = false
    p.CanTouch         = false
    p.CastShadow       = false
    p.Name             = "_FightPlatform"
    p.Parent           = workspace
    fightPlatform = p
end

local function removeFightPlatform()
    if fightPlatform then
        pcall(function() fightPlatform:Destroy() end)
        fightPlatform = nil
    end
end

-- ─── Server Hop ───────────────────────────────────────────────────
local function serverHop()
    if isHopping then return end
    isHopping = true

    local cur = game.JobId
    if cur ~= "" then visitedServers[cur] = true; saveVisited() end

    local url = "https://games.roblox.com/v1/games/" .. PlaceID ..
                "/servers/Public?sortOrder=Asc&limit=100"
    if serverHopCursor and serverHopCursor ~= "" then
        url = url .. "&cursor=" .. serverHopCursor
    end

    local ok, res = pcall(function() return request({ Url = url, Method = "GET" }) end)
    if not ok or not res or res.StatusCode ~= 200 then
        setStatusGUI("❌ Server list failed", COL.red); task.wait(5)
        isHopping = false; return
    end

    local data    = HttpService:JSONDecode(res.Body)
    local servers = data.data or {}
    serverHopCursor = data.nextPageCursor or nil

    if #servers == 0 then
        serverHopCursor = nil
        setStatusGUI("⚠️ Reset visited servers...", COL.orange)
        visitedServers = {}; task.wait(3)
        isHopping = false; return
    end

    for _, sv in ipairs(servers) do
        local sid = sv.id
        if sid and not visitedServers[sid] then
            visitedServers[sid] = true; saveVisited()
            setStatusGUI("🚀 Hopping...", COL.accent)
            task.wait(1)
            pcall(function() TeleportService:TeleportToPlaceInstance(PlaceID, sid, lp) end)
            task.wait(10)
            isHopping = false; return
        end
    end

    setStatusGUI("🔄 Next page...", COL.textSub)
    task.wait(2)
    isHopping = false
end

-- ─── Auto-Store Fruit ────────────────────────────────────────────
-- UI-based flow (not remote):
--   1. Equip fruit tool from backpack
--   2. Trigger popup via VIM touch/mouse + Activated:Fire() fallbacks
--   3. Wait for EatFruitBecky popup to appear (Dialogue.Visible check)
--   4. Find "Collect" ImageButton — INSIDE EatFruitBecky.Dialogue descendants
--   5. Click Collect via multiple fallback methods
--
-- CONFIRMED structure (Phase 5 deep scan, 28 Mar 2026):
--   PlayerGui.EatFruitBecky [ScreenGui]
--     ├── LocalText  (LocalScript)
--     ├── EatFruitManage  (Script)
--     ├── Dialogue  (ImageLabel) ← Visible=true when popup open
--     │     ├── Accept  (ImageButton)  ← text = "Eat"
--     │     ├── Drop    (ImageButton)
--     │     ├── Decline (ImageButton)
--     │     └── Collect (ImageButton) ← this is what we click
--     ├── NameFruit   (StringValue)
--     ├── OldToolFruit(StringValue)
--     └── NoClick     (BoolValue)  ← if true, may block clicks

local function isPopupOpen()
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return false end
    local eatGui = pg:FindFirstChild("EatFruitBecky")
    if not eatGui then return false end
    local dlg = eatGui:FindFirstChild("Dialogue")
    if not dlg then return false end
    local ok2, vis = pcall(function() return dlg.Visible end)
    if ok2 and vis then return true end
    return false
end

local function forcePopupOpen()
    pcall(function()
        local pg = lp:FindFirstChild("PlayerGui")
        if not pg then return end
        local eatGui = pg:FindFirstChild("EatFruitBecky")
        if not eatGui then return end
        eatGui.Enabled = true
        local dlg = eatGui:FindFirstChild("Dialogue")
        if dlg then dlg.Visible = true end
        local noClick = eatGui:FindFirstChild("NoClick")
        if noClick and noClick:IsA("BoolValue") then
            noClick.Value = false
        end
    end)
end

local function findCollectButton()
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return nil, "no PlayerGui" end

    local eatGui = pg:FindFirstChild("EatFruitBecky")
    if not eatGui then return nil, "EatFruitBecky not found" end

    forcePopupOpen()

    local dlg = eatGui:FindFirstChild("Dialogue")
    if dlg then
        for _, obj in ipairs(dlg:GetDescendants()) do
            if obj.Name == "Collect" and (obj:IsA("TextButton") or obj:IsA("ImageButton")) then
                forceVisibleChain(obj)
                return obj, nil
            end
        end
    end

    for _, obj in ipairs(eatGui:GetDescendants()) do
        if obj.Name == "Collect" and (obj:IsA("TextButton") or obj:IsA("ImageButton")) then
            forceVisibleChain(obj)
            return obj, nil
        end
    end

    return nil, "Collect button not found in EatFruitBecky descendants"
end

local function waitForCollectButton(timeout)
    local deadline = tick() + (timeout or 5)
    while tick() < deadline do
        forcePopupOpen()
        local btn, _ = findCollectButton()
        if btn then return btn end
        task.wait(0.25)
    end
    return nil
end

local function forceVisibleChain(obj)
    pcall(function()
        local cur = obj
        while cur and cur:IsA("GuiObject") do
            cur.Visible = true
            cur = cur.Parent
        end
    end)
end

local function clickButton(btn)
    local VIM = nil
    pcall(function() VIM = game:GetService("VirtualInputManager") end)

    forceVisibleChain(btn)

    pcall(function()
        local eatGui = lp:FindFirstChild("PlayerGui") and lp.PlayerGui:FindFirstChild("EatFruitBecky")
        if eatGui then
            local noClick = eatGui:FindFirstChild("NoClick")
            if noClick and noClick:IsA("BoolValue") then
                noClick.Value = false
            end
            pcall(function() eatGui.Enabled = true end)
        end
    end)

    task.wait(0.15)

    local ap, as
    pcall(function()
        ap = btn.AbsolutePosition
        as = btn.AbsoluteSize
    end)
    if not ap or not as then return false end

    local bx = ap.X + as.X / 2
    local by = ap.Y + as.Y / 2

    local clicked = false

    pcall(function()
        if fireclick then
            fireclick(btn)
            clicked = true
        end
    end)
    if clicked then return true end

    pcall(function()
        if VIM then
            VIM:SendTouchEvent("1", 0, bx, by, game)
            task.wait(0.08)
            VIM:SendTouchEvent("1", 1, bx, by, game)
            task.wait(0.08)
            VIM:SendTouchEvent("1", 2, bx, by, game)
            clicked = true
        end
    end)
    if clicked then return true end

    pcall(function()
        if VIM then
            VIM:SendMouseButtonEvent(bx, by, 0, true, game, 1)
            task.wait(0.06)
            VIM:SendMouseButtonEvent(bx, by, 0, false, game, 1)
            clicked = true
        end
    end)
    if clicked then return true end

    pcall(function()
        if firesignal then
            firesignal(btn.MouseButton1Click)
            clicked = true
        end
    end)
    if clicked then return true end

    pcall(function()
        if getconnections then
            local cc = getconnections(btn.MouseButton1Click)
            if cc then
                for _, c in ipairs(cc) do
                    pcall(function() c:Fire() end)
                end
                clicked = true
            end
        end
    end)
    if clicked then return true end

    pcall(function()
        btn.MouseButton1Click:Fire()
        clicked = true
    end)

    return clicked
end

local function triggerPopup(fruitTool)
    if isPopupOpen() then return true end

    local VIM = nil
    pcall(function() VIM = game:GetService("VirtualInputManager") end)
    local cx = workspace.CurrentCamera.ViewportSize.X / 2
    local cy = workspace.CurrentCamera.ViewportSize.Y / 2

    pcall(function()
        if VIM then
            VIM:SendTouchEvent("1", 0, cx, cy, game)
            task.wait(0.08)
            VIM:SendTouchEvent("1", 1, cx, cy, game)
            task.wait(0.08)
            VIM:SendTouchEvent("1", 2, cx, cy, game)
        end
    end)
    task.wait(1.2)
    if isPopupOpen() then return true end

    pcall(function()
        if VIM then
            VIM:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        end
    end)
    task.wait(1.2)
    if isPopupOpen() then return true end

    pcall(function() fruitTool.Activated:Fire() end)
    task.wait(1.2)
    if isPopupOpen() then return true end

    pcall(function()
        if getconnections then
            local cc = getconnections(fruitTool.Activated)
            if cc then
                for _, c in ipairs(cc) do
                    pcall(function() c:Fire() end)
                end
            end
        end
    end)
    task.wait(1.2)
    if isPopupOpen() then return true end

    forcePopupOpen()
    task.wait(0.5)
    return isPopupOpen()
end

local function getStoreCount()
    local cnt = -1
    pcall(function()
        local ps = lp:FindFirstChild("PlayerStats")
        if ps then
            local fs = ps:FindFirstChild("FruitStore")
            if fs and fs:IsA("StringValue") and fs.Value ~= "" then
                local data = HttpService:JSONDecode(fs.Value)
                if type(data) == "table" then
                    local c = 0
                    for _ in pairs(data) do c = c + 1 end
                    cnt = c
                end
            end
        end
    end)
    return cnt
end

local function autoStoreFruit()
    if not autoStore then return end

    local bp  = lp:FindFirstChild("Backpack")
    local hum = getHumanoid()
    if not hum then return end

    local fruits = {}
    if bp then
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and tool.Name:find("Fruit") then
                table.insert(fruits, tool)
            end
        end
    end
    local char = lp.Character
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") and tool.Name:find("Fruit") and not isSwordTool(tool) then
                table.insert(fruits, tool)
            end
        end
    end

    if #fruits == 0 then
        pcall(function() setStatusGUI("Store: no fruit in backpack", COL.textSub, 2) end)
        return
    end

    local storeFailed = 0

    for _, fruitTool in ipairs(fruits) do
        local fruitName = fruitTool.Name
        local countBefore = getStoreCount()
        pcall(function() setStatusGUI("Storing: " .. fruitName .. " [" .. countBefore .. " stored]", COL.purple, 4) end)

        pcall(function() hum:EquipTool(fruitTool) end)
        task.wait(0.8)

        local popupOk = triggerPopup(fruitTool)

        if not popupOk then
            pcall(function() setStatusGUI("Store: popup failed " .. fruitName, COL.red, 3) end)
            storeFailed = storeFailed + 1
        else
            local stored = false
            local clickAttempts = 0

            while clickAttempts < 3 and not stored do
                clickAttempts = clickAttempts + 1
                local collectBtn = waitForCollectButton(5)
                if not collectBtn then
                    pcall(function() setStatusGUI("Store: Collect btn missing " .. fruitName .. " (try " .. clickAttempts .. ")", COL.orange, 2) end)
                    task.wait(0.5)
                else
                    clickButton(collectBtn)
                    task.wait(1.5)

                    local countAfter = getStoreCount()
                    local stillHas = false
                    pcall(function()
                        local bp2 = lp:FindFirstChild("Backpack")
                        if bp2 then
                            for _, t in ipairs(bp2:GetChildren()) do
                                if t:IsA("Tool") and t.Name == fruitName then stillHas = true end
                            end
                        end
                        local ch2 = lp.Character
                        if ch2 then
                            for _, t in ipairs(ch2:GetChildren()) do
                                if t:IsA("Tool") and t.Name == fruitName then stillHas = true end
                            end
                        end
                    end)

                    if not stillHas or countAfter > countBefore then
                        stored = true
                        pcall(function() setStatusGUI("Stored: " .. fruitName .. " [" .. countAfter .. "]", COL.green, 3) end)
                        storeFailed = 0
                        task.spawn(function()
                            local url = WEBHOOKS.Chest
                            if not url or url == "" then return end
                            pcall(function()
                                request({
                                    Url     = url, Method = "POST",
                                    Headers = { ["Content-Type"] = "application/json" },
                                    Body    = HttpService:JSONEncode({ embeds = {{
                                        title       = "Fruit Stored",
                                        description = fruitName .. " [" .. countAfter .. " total]\nServer: " .. game.JobId,
                                        color       = 0x8B00FF,
                                        footer      = { text = "King Legacy Boss Detector v15 | Sea 2" },
                                    }}})
                                })
                            end)
                        end)
                    else
                        if clickAttempts < 3 then
                            pcall(function() setStatusGUI("Store: retry click " .. fruitName .. " (" .. clickAttempts .. "/3)", COL.orange, 1) end)
                            task.wait(0.3)
                        end
                    end
                end
            end

            if not stored then
                storeFailed = storeFailed + 1
                if storeFailed >= 2 then
                    pcall(function() setStatusGUI("Store: FULL? (" .. countBefore .. " stored, " .. storeFailed .. " failed)", COL.orange, 5) end)
                    break
                else
                    pcall(function() setStatusGUI("Store: failed " .. fruitName .. " (" .. countBefore .. " stored)", COL.orange, 3) end)
                end
            end
        end
        task.wait(0.5)
    end

    if not isSwordEquipped() then equipSword() end
end

-- ─── Chest Teleport ───────────────────────────────────────────────
-- Priority: ChestSpawner position first, then nearest tier part, then any part
local function selectChestPos(center, radius)
    local spawnerPos, tierPos, anyPos = nil, nil, nil
    local tierBest, anyBest = math.huge, math.huge
    local nameSet, nameList = {}, {}

    for _, obj in ipairs(getDescendantsCache()) do
        if (obj:IsA("Model") or obj:IsA("BasePart")) and not isPlayerPart(obj) then
            local nm = obj.Name
            if CHEST_SET[nm] then
                local part = obj:IsA("BasePart") and obj or obj:FindFirstChildOfClass("BasePart")
                if part then
                    local d = (part.Position - center).Magnitude
                    if d <= radius then
                        if not nameSet[nm] then
                            nameSet[nm] = true
                            table.insert(nameList, nm)
                        end
                        if nm == "ChestSpawner" then
                            spawnerPos = part.Position
                        elseif nm ~= "ChestSpawner" and d < tierBest then
                            tierBest = d; tierPos = part.Position
                        end
                        if d < anyBest then anyBest = d; anyPos = part.Position end
                    end
                end
            end
        end
    end

    if #nameList == 0 then return nil, {}, "?" end
    local pos = spawnerPos or tierPos or anyPos
    return pos, nameList, detectTier(nameSet)
end

local function teleportToChest(pos, tier, nameList)
    local hrp = getHRP()
    if not hrp or not pos then return end
    setStatusGUI("🚀 Teleport → chest [" .. tier .. "]", COL.accent, 3)
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 4, 0))
    task.wait(1.5)
    sendChestToDiscord(game.JobId, tier, nameList)
    setChestStatus("🎁 Chest [" .. tier .. "]: " .. table.concat(nameList, ", "))
    setStatusGUI("🎁 Chest [" .. tier .. "]!", COL.gold, 4)
end

-- ─── Go to Nearby Chest (post-fight) ─────────────────────────────
-- Scans 1500m from saved boss position, waits up to 20s
local function goToNearbyChest(bossPos)
    local RADIUS = 1500
    setStatusGUI("🧲 Searching chest (1500m)...", COL.gold, 3)
    setChestStatus("⏳ Waiting for chest to spawn...")

    local chestPos, nameList, tier = nil, {}, "?"
    for attempt = 1, 20 do
        descCacheTime = 0
        refreshCharCache()
        chestPos, nameList, tier = scanChestNear(bossPos, RADIUS)
        if chestPos then break end
        setChestStatus("⏳ Waiting for chest... (" .. attempt .. "s)")
        task.wait(1)
    end

    if not chestPos then
        setChestStatus("❌ No chest found (1500m, 20s)")
        setStatusGUI("⚠️ No chest found", COL.red, 3)
        return
    end

    teleportToChest(chestPos, tier, nameList)

    -- Wait for MainMotor6D (chest opening animation signal, max 15s)
    setChestStatus("⏳ Waiting for chest open (MainMotor6D)...")
    local motorDeadline = tick() + 15
    while tick() < motorDeadline do
        local found = false
        descCacheTime = 0
        for _, obj in ipairs(getDescendantsCache()) do
            if obj.Name == "MainMotor6D" and not isPlayerPart(obj) then
                found = true; break
            end
        end
        if found then break end
        task.wait(1)
    end
    setChestStatus("✅ Chest opened!")

    task.wait(2)
    autoStoreFruit()
end

-- ─── Pre-Spawned Chest Check ─────────────────────────────────────
-- On join: wait 3s, check if chest already exists (boss killed by others)
local function checkPreSpawnedChest()
    task.wait(3)
    if not isRunning then return end
    refreshCharCache()

    local islandPos, anchorName = findIslandAnchor()
    if not islandPos then return end  -- no island = no chest

    -- Only act if there's no live boss (someone else already killed it)
    local boss, _ = findBossModel()
    if boss then return end  -- boss alive, main loop handles it

    local chestPos, nameList, tier = scanChestNear(islandPos, 1500)
    if not chestPos then return end

    setChestStatus("⚡ Pre-spawned chest! [" .. tier .. "]")
    setStatusGUI("⚡ Chest found on join [" .. tier .. "]!", COL.gold, 5)
    sendChestToDiscord(game.JobId, tier, nameList)

    if autoFight and not isFighting then
        isPostFight = true
        teleportToChest(chestPos, tier, nameList)
        task.wait(5)
        autoStoreFruit()
        task.wait(2)
        isPostFight = false
        if autoScan and isRunning then serverHop() end
    end
end

-- ─── Auto Fight ───────────────────────────────────────────────────
local function startFight(boss)
    if isFighting then return end
    isFighting = true; isPostFight = false

    task.spawn(function()
        local bossHRP     = boss:FindFirstChild("HumanoidRootPart")
        local savedBossPos = bossHRP and bossHRP.Position or nil

        -- Equip loop (parallel)
        task.spawn(function()
            while isFighting and isRunning do
                if not isSwordEquipped() then equipSword() end
                task.wait(0.3)
            end
        end)

        -- Create anti-fall platform under boss
        if bossHRP then
            createFightPlatform(bossHRP.Position)
        end

        -- Teleport to boss
        if bossHRP then
            local hrp = getHRP()
            if hrp then hrp.CFrame = bossHRP.CFrame + Vector3.new(3, 2, 0) end
        end

        setStatusGUI("⚔️ Fighting boss!", COL.orange, 2)

        local VIM        = nil
        pcall(function() VIM = game:GetService("VirtualInputManager") end)
        local timerZ     = 0
        local timerX     = 1.5
        local physAccum  = 0
        local cx         = workspace.CurrentCamera.ViewportSize.X / 2
        local cy         = workspace.CurrentCamera.ViewportSize.Y / 2
        local cachedSkillRemote  = getSkillRemote()
        local cachedPhysRemote   = getPhysicsRemote()

        while isFighting and isRunning do
            local dt = task.wait(0.1)

            -- Keep saved boss position updated
            if bossHRP and bossHRP.Parent then
                savedBossPos = bossHRP.Position
            end

            -- Check boss still alive
            local bossHum = boss:FindFirstChildOfClass("Humanoid")
            if not bossHum or bossHum.Health <= 0 then
                isFighting = false; isPostFight = true
                removeFightPlatform()
                setStatusGUI("✅ Boss defeated!", COL.green, 3)

                -- Go to nearby chest (1500m, 20s timeout)
                if savedBossPos then
                    goToNearbyChest(savedBossPos)
                end

                -- False death protection: wait 5.5s then re-check boss
                task.wait(5.5)
                local bossAgain, _ = findBossModel()
                if bossAgain and isRunning then
                    setStatusGUI("⚠️ Boss alive again! Resuming fight...", COL.orange, 3)
                    isPostFight = false
                    startFight(bossAgain)  -- resume
                    return
                end

                -- Truly dead — hop
                isPostFight = false
                if autoScan and isRunning then
                    task.wait(2)
                    serverHop()
                end
                return
            end

            -- Stay within 8 studs of boss (only if still fighting)
            if isFighting and bossHRP and bossHRP.Parent then
                local hrp = getHRP()
                if hrp and (hrp.Position - bossHRP.Position).Magnitude > 8 then
                    hrp.CFrame = bossHRP.CFrame + Vector3.new(3, 2, 0)
                end
                createFightPlatform(bossHRP.Position)
            end

            -- ── Attack: SkillAction remote (confirmed path) ────────
            local swordName  = getEquippedSwordName()
            if cachedSkillRemote and swordName and bossHRP and bossHRP.Parent then
                -- M1 attack every 0.1s via remote
                pcall(function()
                    cachedSkillRemote:InvokeServer(
                        "SW_" .. swordName .. "_M1",
                        { MouseHit = CFrame.new(bossHRP.Position) }
                    )
                end)
            else
                -- VIM fallback if remote unavailable
                pcall(function()
                    VIM:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
                    task.wait(0.05)
                    VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
                end)
            end

            -- ── Skill Z (every 3s) ────────────────────────────────
            timerZ = timerZ + dt
            if timerZ >= 3 then
                timerZ = 0
                if cachedSkillRemote and swordName and bossHRP and bossHRP.Parent then
                    pcall(function()
                        local args = { Type = "Down", MouseHit = CFrame.new(bossHRP.Position) }
                        cachedSkillRemote:InvokeServer("SW_" .. swordName .. "_Z", args)
                        task.wait(0.15)
                        args.Type = "Up"
                        cachedSkillRemote:InvokeServer("SW_" .. swordName .. "_Z", args)
                    end)
                else
                    pcall(function()
                        VIM:SendKeyEvent(true,  Enum.KeyCode.Z, false, game)
                        task.wait(0.1)
                        VIM:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
                    end)
                end
            end

            -- ── Skill X (every 3s, offset 1.5s from Z) ───────────
            timerX = timerX + dt
            if timerX >= 3 then
                timerX = 0
                if cachedSkillRemote and swordName and bossHRP and bossHRP.Parent then
                    pcall(function()
                        local args = { Type = "Down", MouseHit = CFrame.new(bossHRP.Position) }
                        cachedSkillRemote:InvokeServer("SW_" .. swordName .. "_X", args)
                        task.wait(0.15)
                        args.Type = "Up"
                        cachedSkillRemote:InvokeServer("SW_" .. swordName .. "_X", args)
                    end)
                else
                    pcall(function()
                        VIM:SendKeyEvent(true,  Enum.KeyCode.X, false, game)
                        task.wait(0.1)
                        VIM:SendKeyEvent(false, Enum.KeyCode.X, false, game)
                    end)
                end
            end

            -- ── Physics sync (every 0.25s) ────────────────────────
            physAccum = physAccum + dt
            if physAccum >= 0.25 then
                physAccum = 0
                local hrp = getHRP()
                if cachedPhysRemote and hrp then
                    pcall(function() cachedPhysRemote:FireServer(hrp.CFrame) end)
                end
            end
        end

        isFighting = false; isPostFight = false
        removeFightPlatform()
    end)
end

-- ─── Chest Scanner Task (parallel, every 1.5s) ────────────────────
-- Scans from ISLAND ANCHOR, not player position
local function startChestScanTask()
    task.spawn(function()
        while true do
            task.wait(3)
            if not isRunning then continue end
            refreshCharCache()

            local islandPos, anchorName = findIslandAnchor()
            if not islandPos then
                if lastChestKey ~= nil then
                    lastChestKey = nil
                    setChestStatus("No island detected")
                end
                continue
            end

            local chestPos, nameList, tier = scanChestNear(islandPos, 1500)
            if #nameList > 0 then
                local key = table.concat(nameList, ",")
                if key ~= lastChestKey then
                    lastChestKey = key
                    local txt = "✅ Chest [" .. tier .. "] " ..
                                "(" .. anchorName .. "):\n"
                    for _, nm in ipairs(nameList) do txt = txt .. "• " .. nm .. "\n" end
                    setChestStatus(txt)
                    sendChestToDiscord(game.JobId, tier, nameList)
                end
            else
                if lastChestKey ~= nil then
                    lastChestKey = nil
                    setChestStatus("Island detected, no chest")
                end
            end
        end
    end)
end

-- ─── Main Loop (boss scan every 2s) ──────────────────────────────
local function mainLoop()
    while true do
        task.wait(2)
        if not isRunning then continue end
        refreshCharCache()

        local boss, bossName = findBossModel()

        if boss and bossName then
            local jobId = game.JobId
            foundCode = jobId
            local dn = bossName == "HydraSeaKing" and "Hydra Sea King" or "Sea King"
            setStatusGUI("✅ Boss: " .. dn, COL.green)
            sendBossToDiscord(bossName, jobId)
            if autoFight and not isFighting and not isPostFight then
                startFight(boss)
            end
        else
            if not isFighting and not isPostFight then
                setStatusGUI("❌ No Boss Found", COL.red)
                if autoScan and not isHopping then serverHop() end
            end
        end
    end
end

-- ─── Data Gatherer ────────────────────────────────────────────────
local function runDataGatherer(statusFn)
    statusFn("🔍 Data Gatherer...", COL.purple, 8)
    refreshCharCache()
    local result = {
        backpack     = {},
        equippedTool = "none",
        storeButtons = {},
    }

    -- Backpack slots
    local bp = lp:FindFirstChild("Backpack")
    if bp then
        for i, c in ipairs(bp:GetChildren()) do
            if c:IsA("Tool") then
                table.insert(result.backpack, { slot = i, name = c.Name, cls = c.ClassName })
            end
        end
    end

    -- Currently equipped
    local char = lp.Character
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then result.equippedTool = c.Name; break end
        end
    end

    -- Find all Store buttons in PlayerGui
    local pg = lp:FindFirstChild("PlayerGui")
    if pg then
        for _, obj in ipairs(pg:GetDescendants()) do
            if (obj:IsA("TextButton") or obj:IsA("ImageButton")) and obj.Name == "Store" then
                -- Build visibility chain
                local vis, p = true, obj
                while p and p ~= pg do
                    if not p.Visible then vis = false; break end
                    p = p.Parent
                end
                table.insert(result.storeButtons, {
                    path         = obj:GetFullName(),
                    visible      = obj.Visible,
                    chainVisible = vis,
                    absPos       = tostring(obj.AbsolutePosition),
                    absSize      = tostring(obj.AbsoluteSize),
                    text         = obj:IsA("TextButton") and obj.Text or "",
                })
            end
        end
    end

    pcall(function() writefile("DataGatherer_Result.json", HttpService:JSONEncode(result)) end)
    statusFn(
        "🔍 Done! BP:" .. #result.backpack ..
        " Equipped:" .. result.equippedTool ..
        " StoreBtns:" .. #result.storeButtons,
        COL.purple, 8
    )
end

-- ═══════════════════════════════════════════════════════════════════
--  GUI v11.1 — Mini bar (always visible) + collapsible panel
-- ═══════════════════════════════════════════════════════════════════

local existingGui = lp.PlayerGui:FindFirstChild("BossDetectorGui")
if existingGui then existingGui:Destroy() end

local screenGui          = Instance.new("ScreenGui")
screenGui.Name           = "BossDetectorGui"
screenGui.ResetOnSpawn   = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder   = 999
screenGui.Parent         = lp.PlayerGui

-- ─── GUI helpers ─────────────────────────────────────────────────
local function UICorner(parent, r)
    local c = Instance.new("UICorner", parent)
    c.CornerRadius = UDim.new(0, r or 8)
    return c
end

local function UIPad(parent, l, r, t, b)
    local p = Instance.new("UIPadding", parent)
    p.PaddingLeft   = UDim.new(0, l or 10)
    p.PaddingRight  = UDim.new(0, r or 10)
    p.PaddingTop    = UDim.new(0, t or 8)
    p.PaddingBottom = UDim.new(0, b or 8)
    return p
end

local function UIList(parent, gap)
    local l = Instance.new("UIListLayout", parent)
    l.Padding   = UDim.new(0, gap or 5)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    return l
end

local function makeStroke(parent, color, thick)
    local s = Instance.new("UIStroke", parent)
    s.Color = color or Color3.fromRGB(50, 50, 80)
    s.Thickness = thick or 1
    return s
end

-- Card = rounded container with background
local function Card(parent)
    local f = Instance.new("Frame")
    f.BackgroundColor3 = COL.bgCard
    f.BorderSizePixel  = 0
    f.Size             = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize    = Enum.AutomaticSize.Y
    f.LayoutOrder      = 0
    f.Parent           = parent
    UICorner(f, 8)
    UIPad(f, 10, 10, 8, 8)
    UIList(f, 4)
    return f
end

-- Section header (small accent label)
local function SecHdr(parent, text)
    local l                  = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size                   = UDim2.new(1, 0, 0, 16)
    l.Text                   = text
    l.TextColor3             = COL.accent
    l.TextSize               = 10
    l.Font                   = Enum.Font.GothamBold
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.LayoutOrder            = 0
    l.Parent                 = parent
    return l
end

local _lo = 0
local function LO() _lo = _lo + 1; return _lo end

local function Lbl(parent, text, color, fixedH)
    local l = Instance.new("TextLabel")
    if fixedH then
        l.Size = UDim2.new(1, 0, 0, fixedH); l.AutomaticSize = Enum.AutomaticSize.None
    else
        l.Size = UDim2.new(1, 0, 0, 0); l.AutomaticSize = Enum.AutomaticSize.Y
    end
    l.BackgroundTransparency = 1
    l.Text                   = text
    l.TextColor3             = color or COL.text
    l.TextSize               = 12
    l.Font                   = Enum.Font.Gotham
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.TextWrapped            = true
    l.LayoutOrder            = LO()
    l.ZIndex                 = 13
    l.Parent                 = parent
    return l
end

local function Btn(text, color, parent)
    local b            = Instance.new("TextButton")
    b.Size             = UDim2.new(1, 0, 0, 38)
    b.BackgroundColor3 = color or COL.bgCard
    b.TextColor3       = COL.white
    b.Text             = text
    b.TextSize         = 12
    b.Font             = Enum.Font.GothamBold
    b.TextWrapped      = true
    b.LayoutOrder      = LO()
    b.ZIndex           = 13
    b.Parent           = parent
    UICorner(b, 7)
    return b
end

local function TBox(parent)
    local tb              = Instance.new("TextBox")
    tb.Size               = UDim2.new(1, 0, 0, 38)
    tb.BackgroundColor3   = Color3.fromRGB(16, 16, 30)
    tb.TextColor3         = COL.white
    tb.PlaceholderText    = "Paste server code..."
    tb.PlaceholderColor3  = COL.textSub
    tb.Text               = ""
    tb.TextSize           = 12
    tb.Font               = Enum.Font.Gotham
    tb.ClearTextOnFocus   = false
    tb.LayoutOrder        = LO()
    tb.ZIndex             = 13
    tb.Parent             = parent
    UICorner(tb, 7)
    makeStroke(tb, Color3.fromRGB(40, 40, 70), 1)
    return tb
end

-- ─── Mini bar (always visible at top-left) ────────────────────────
local miniBar             = Instance.new("Frame")
miniBar.Name              = "MiniBar"
miniBar.Size              = UDim2.new(0, 310, 0, 46)
miniBar.Position          = UDim2.new(0, 6, 0, 6)
miniBar.BackgroundColor3  = COL.bg
miniBar.BorderSizePixel   = 0
miniBar.ZIndex            = 20
miniBar.Parent            = screenGui
UICorner(miniBar, 10)
makeStroke(miniBar, Color3.fromRGB(35, 35, 65), 1)

-- BD toggle button
local bdBtn            = Instance.new("TextButton")
bdBtn.Size             = UDim2.new(0, 40, 1, -8)
bdBtn.Position         = UDim2.new(0, 4, 0, 4)
bdBtn.BackgroundColor3 = COL.accent
bdBtn.TextColor3       = COL.white
bdBtn.Text             = "BD"
bdBtn.TextSize         = 12
bdBtn.Font             = Enum.Font.GothamBold
bdBtn.ZIndex           = 21
bdBtn.Parent           = miniBar
UICorner(bdBtn, 7)

-- Mini status labels (right of BD button)
local miniStatus                   = Instance.new("TextLabel")
miniStatus.Size                    = UDim2.new(1, -50, 0, 18)
miniStatus.Position                = UDim2.new(0, 48, 0, 4)
miniStatus.BackgroundTransparency  = 1
miniStatus.Text                    = "Status: Starting..."
miniStatus.TextColor3              = COL.text
miniStatus.TextSize                = 10
miniStatus.Font                    = Enum.Font.Gotham
miniStatus.TextXAlignment          = Enum.TextXAlignment.Left
miniStatus.TextTruncate            = Enum.TextTruncate.AtEnd
miniStatus.ZIndex                  = 21
miniStatus.Parent                  = miniBar

local miniChest                    = Instance.new("TextLabel")
miniChest.Size                     = UDim2.new(1, -50, 0, 16)
miniChest.Position                 = UDim2.new(0, 48, 0, 24)
miniChest.BackgroundTransparency   = 1
miniChest.Text                     = "Chest: scanning..."
miniChest.TextColor3               = COL.gold
miniChest.TextSize                 = 10
miniChest.Font                     = Enum.Font.Gotham
miniChest.TextXAlignment           = Enum.TextXAlignment.Left
miniChest.TextTruncate             = Enum.TextTruncate.AtEnd
miniChest.ZIndex                   = 21
miniChest.Parent                   = miniBar

-- ─── Main panel ───────────────────────────────────────────────────
local PANEL_W = 296
local panel              = Instance.new("Frame")
panel.Name               = "Panel"
panel.Size               = UDim2.new(0, PANEL_W, 0, 362)
panel.Position           = UDim2.new(0, 6, 0, 58)
panel.BackgroundColor3   = COL.bg
panel.BorderSizePixel    = 0
panel.ClipsDescendants   = false
panel.Active             = true
panel.Draggable          = true
panel.Visible            = false  -- hidden by default
panel.ZIndex             = 10
panel.Parent             = screenGui
UICorner(panel, 12)
makeStroke(panel, Color3.fromRGB(35, 35, 65), 1)

-- Title bar
local titleBar            = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, 42)
titleBar.BackgroundColor3 = COL.title
titleBar.BorderSizePixel  = 0
titleBar.ZIndex           = 11
titleBar.Parent           = panel
UICorner(titleBar, 12)

local ttlLbl                   = Instance.new("TextLabel")
ttlLbl.Size                    = UDim2.new(1, -80, 1, 0)
ttlLbl.Position                = UDim2.new(0, 10, 0, 0)
ttlLbl.BackgroundTransparency  = 1
ttlLbl.Text                    = "BOSS DETECTOR  v15"
ttlLbl.TextColor3              = COL.accent
ttlLbl.TextSize                = 12
ttlLbl.Font                    = Enum.Font.GothamBold
ttlLbl.TextXAlignment          = Enum.TextXAlignment.Left
ttlLbl.ZIndex                  = 12
ttlLbl.Parent                  = titleBar

local minBtn            = Instance.new("TextButton")
minBtn.Size             = UDim2.new(0, 28, 0, 24)
minBtn.Position         = UDim2.new(1, -62, 0.5, -12)
minBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 88)
minBtn.TextColor3       = COL.white
minBtn.Text             = "—"
minBtn.TextSize         = 12
minBtn.Font             = Enum.Font.GothamBold
minBtn.ZIndex           = 13
minBtn.Parent           = titleBar
UICorner(minBtn, 6)

local closeBtn            = Instance.new("TextButton")
closeBtn.Size             = UDim2.new(0, 28, 0, 24)
closeBtn.Position         = UDim2.new(1, -32, 0.5, -12)
closeBtn.BackgroundColor3 = COL.red
closeBtn.TextColor3       = COL.white
closeBtn.Text             = "✕"
closeBtn.TextSize         = 12
closeBtn.Font             = Enum.Font.GothamBold
closeBtn.ZIndex           = 13
closeBtn.Parent           = titleBar
UICorner(closeBtn, 6)

-- Panel scroll content
local scroll                   = Instance.new("ScrollingFrame")
scroll.Size                    = UDim2.new(1, 0, 0, 320)
scroll.Position                = UDim2.new(0, 0, 0, 42)
scroll.CanvasSize              = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize     = Enum.AutomaticSize.Y
scroll.ScrollBarThickness      = 6
scroll.ScrollBarImageColor3    = COL.accent
scroll.BackgroundTransparency  = 1
scroll.BorderSizePixel         = 0
scroll.ScrollingEnabled        = true
scroll.Active                  = true
scroll.ClipsDescendants        = true
scroll.ZIndex                  = 12
scroll.Parent                  = panel

UIList(scroll, 8)
UIPad(scroll, 8, 8, 8, 12)

-- ─── STATUS card ─────────────────────────────────────────────────
do
    local card = Card(scroll); card.LayoutOrder = LO()
    SecHdr(card, "STATUS").LayoutOrder = LO()
    local statusLblInner = Lbl(card, "Starting...", COL.text)
    statusLblInner.TextSize = 13
    local chestLblInner  = Lbl(card, "Chest: scanning...", COL.gold)

    -- ── SERVER CODE ──
    SecHdr(card, "SERVER CODE").LayoutOrder = LO()
    local codeLbl = Lbl(card, "—", COL.gold, 30)
    codeLbl.TextSize = 13; codeLbl.Font = Enum.Font.GothamBold; codeLbl.LayoutOrder = LO()
    local btnCopy = Btn("📋 Copy Code", Color3.fromRGB(30, 60, 140), card)
    btnCopy.Visible = false; btnCopy.LayoutOrder = LO()
    local btnJoinD = Btn("🚀 Join Server", COL.green, card)
    btnJoinD.Visible = false; btnJoinD.LayoutOrder = LO()

    -- ── AUTO ──
    SecHdr(card, "AUTO").LayoutOrder = LO()
    local btnPause    = Btn("⏸  Pause",               COL.orange,                card); btnPause.LayoutOrder    = LO()
    local btnScanT    = Btn("[ OFF ] Auto Scan & Hop", Color3.fromRGB(52,28,28),  card); btnScanT.LayoutOrder    = LO()
    local btnFightT   = Btn("[ OFF ] Auto Fight Boss", Color3.fromRGB(52,28,28),  card); btnFightT.LayoutOrder   = LO()
    local btnStoreT   = Btn("[ OFF ] Auto Store Fruit", Color3.fromRGB(52,28,28), card); btnStoreT.LayoutOrder   = LO()

    -- ── MANUAL JOIN ──
    SecHdr(card, "MANUAL JOIN").LayoutOrder = LO()
    local codeBox    = TBox(card); codeBox.LayoutOrder = LO()
    local btnJoinMan = Btn("🔑 Join Manual", COL.purple, card); btnJoinMan.LayoutOrder = LO()

    -- ── TOOLS ──
    SecHdr(card, "TOOLS").LayoutOrder = LO()
    local btnStoreFruit = Btn("🍎 Store Fruit Now", COL.purple, card); btnStoreFruit.LayoutOrder = LO()
    local btnGather = Btn("🔍 Data Gatherer", Color3.fromRGB(70, 55, 12), card); btnGather.LayoutOrder = LO()

    -- ── setStatusGUI + setChestStatus (defined here — GUI is ready) ──
    setStatusGUI = function(txt, color, lockSecs)
        if tick() < statusLockUntil and (not lockSecs or lockSecs == 0) then return end
        statusLblInner.Text       = txt
        statusLblInner.TextColor3 = color or COL.text
        miniStatus.Text           = txt
        miniStatus.TextColor3     = color or COL.text
        if lockSecs and lockSecs > 0 then
            statusLockUntil = tick() + lockSecs
        end
    end

    local function forceStatus(txt, color)
        statusLockUntil = 0; setStatusGUI(txt, color)
    end

    setChestStatus = function(txt)
        chestLblInner.Text       = txt
        chestLblInner.TextColor3 = COL.gold
        miniChest.Text           = txt
        miniChest.TextColor3     = COL.gold
    end

    -- ── Toggle helpers ──
    local function toggleBtn(btn, state, label)
        btn.Text             = (state and "[ ON  ] " or "[ OFF ] ") .. label
        btn.BackgroundColor3 = state and Color3.fromRGB(20,90,42) or Color3.fromRGB(52,28,28)
    end

    local function updateToggles()
        toggleBtn(btnScanT,  autoScan,  "Auto Scan & Hop")
        toggleBtn(btnFightT, autoFight, "Auto Fight Boss")
        toggleBtn(btnStoreT, autoStore, "Auto Store Fruit")
    end

    -- ── Button connections ──
    bdBtn.MouseButton1Click:Connect(function()
        panel.Visible = not panel.Visible
    end)
    minBtn.MouseButton1Click:Connect(function()
        panel.Visible = false
    end)
    closeBtn.MouseButton1Click:Connect(function()
        panel.Visible = false
    end)

    btnPause.MouseButton1Click:Connect(function()
        isRunning = not isRunning
        if isRunning then
            btnPause.Text = "⏸  Pause"; btnPause.BackgroundColor3 = COL.orange
            forceStatus("▶ Resumed", COL.green)
        else
            isFighting = false; isPostFight = false; isHopping = false
            btnPause.Text = "▶  Resume"; btnPause.BackgroundColor3 = Color3.fromRGB(30,135,62)
            forceStatus("⏸ Paused", COL.textSub)
        end
    end)

    btnScanT.MouseButton1Click:Connect(function()
        autoScan = not autoScan; updateToggles(); saveConfig()
    end)
    btnFightT.MouseButton1Click:Connect(function()
        autoFight = not autoFight
        if not autoFight then
            isFighting = false
            isPostFight = false
            removeFightPlatform()
        end
        updateToggles(); saveConfig()
    end)
    btnStoreT.MouseButton1Click:Connect(function()
        autoStore = not autoStore; updateToggles(); saveConfig()
    end)

    btnCopy.MouseButton1Click:Connect(function()
        if foundCode then
            pcall(function() setclipboard(foundCode) end)
            btnCopy.Text = "✅ Copied!"
            task.wait(2); btnCopy.Text = "📋 Copy Code"
        end
    end)

    btnJoinD.MouseButton1Click:Connect(function()
        if foundCode then
            forceStatus("🚀 Joining...", COL.purple)
            pcall(function() TeleportService:TeleportToPlaceInstance(PlaceID, foundCode, lp) end)
        end
    end)

    btnJoinMan.MouseButton1Click:Connect(function()
        local code = codeBox.Text
        if code ~= "" then
            forceStatus("🚀 Joining...", COL.purple)
            pcall(function() TeleportService:TeleportToPlaceInstance(PlaceID, code, lp) end)
        else
            forceStatus("Enter code first!", COL.red)
        end
    end)

    btnStoreFruit.MouseButton1Click:Connect(function()
        task.spawn(function()
            local savedAutoStore = autoStore
            autoStore = true
            autoStoreFruit()
            autoStore = savedAutoStore
        end)
    end)

    btnGather.MouseButton1Click:Connect(function()
        task.spawn(function() runDataGatherer(setStatusGUI) end)
    end)

    -- Auto-update code label
    task.spawn(function()
        local last = nil
        while true do
            if foundCode ~= last then
                last = foundCode
                if foundCode then
                    codeLbl.Text    = foundCode
                    btnCopy.Visible = true
                    btnJoinD.Visible = true
                end
            end
            task.wait(0.5)
        end
    end)

    -- Initial toggle state
    updateToggles()
end

-- ═══════════════════════════════════════════════════════════════════
--  START
-- ═══════════════════════════════════════════════════════════════════
loadConfig()
loadVisited()

isRunning = true

-- Start all tasks
task.spawn(mainLoop)
task.spawn(startChestScanTask)
task.spawn(checkPreSpawnedChest)

setStatusGUI("v15 ready!", COL.green, 3)
print("[BossDetector v15] Active. Tap 'BD' to open menu.")
