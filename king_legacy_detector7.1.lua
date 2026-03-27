-- ═══════════════════════════════════════════════════════════════════
--  King Legacy Boss Detector v7.1
--  Area: Sea 2 | Executor: Delta Mobile (Android)
--
--  v7.1: Platform invisible (anti jatuh), hapus UI force stats, getconnections() fallback
--  v6.9: Store fruit via direct remote (DFPassive/EtcFunction brute-force)
--  v6.8: False death fix → scan ulang di chest 5 detik
--  v6.7 dari v6.5:
--    CHEST NAMES:
--      - "Spawn Pit" dihapus (false detect, bagian model permanen di map)
--      - "Gem" tetap dihapus (sama alasannya)
--      - "Bottum" bukan "Buttom" (fix typo dari v6.3)
--      - T3 tidak punya ChestSpawner (sesuai scan data)
--      - EyeRight/EyeLeft dikonfirmasi
--    TIER DETECTION:
--      - T3 = Dragon / Wing saja
--      - T1 = Top / Bottum (eksklusif T1)
--      - T2 = ChestTop/ChestBottum + SkullRetopo
--      - T4 = ChestTop/ChestBottum SAJA (tentatif)
--    BUG FIXES v6.5:
--      - [FIX-1] WEBHOOKS dipindah ke atas sebelum fungsi Discord
--      - [FIX-2] isPlayerPart: batas max 64 iterasi (cegah freeze)
--      - [FIX-3] scanChestNear: fallbackPos sekarang benar-benar bisa diisi
--      - [FIX-4] isHopping flag: cegah server hop jalan dua kali bersamaan
--      - [FIX-5] checkPreSpawnedChest: TP jika autoFight ATAU autoStore aktif
--    STORE BUAH (cara manual di game, ditiru script):
--      - Tekan slot buah (tombol "4" di keyboard)
--      - Tap di layar mana saja agar menu store muncul
--      - Pilih Store
--      - TIDAK pakai hum:EquipTool (tidak memicu UI game)
--    CHEST TP:
--      - Scan 1500m dari posisi boss mati (bukan dari player)
--      - TP ke chest hanya setelah boss benar-benar hilang dari workspace
--      - Loop scan sampai chest ditemukan (max 20 detik)
--      - Prioritas TP: ChestSpawner > tier part > non-coin part
--    ISLAND DETECTION:
--      - HydraStand = platform pulau Hydra boss
--      - Jika ditemukan HydraStand tanpa boss aktif → scan chest 1500m
--      - SeaKing island: TBD (gunakan scan 200m tool)
--    ANTI-LAG:
--      - Chest scanner jalan di task terpisah (tidak blokir main loop)
--      - charCache pakai Set lookup O(1)
--      - Semua HTTP async tanpa kecuali
--    NEARBY SCAN: tampilkan 50 item, radius 200m
-- ═══════════════════════════════════════════════════════════════════

local Players         = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService     = game:GetService("HttpService")

local lp      = Players.LocalPlayer
local PlaceID = game.PlaceId

-- ─── Constants ────────────────────────────────────────────────────
local CONFIG_FILE  = "BossDetectorConfig.json"
local VISITED_FILE = "NotSameServers.json"

local BOSS_NAMES  = { "HydraSeaKing", "SeaKing" }
local SWORD_NAMES = { "Kioru V2", "KioruV2", "Kioru" }

-- ═══════════════════════════════════════════════════════════════════
--  CHEST DATA v6.5 (dikonfirmasi dari scan lapangan)
--
--  T1: ChestSpawner, Top, Bottum, SkullRetopo, EyeRight, EyeLeft
--      + Coins, MiniCoin (reward, bukan tier marker)
--
--  T2: ChestSpawner, ChestTop, ChestBottum, SkullRetopo, EyeRight, EyeLeft
--      (tidak ada Dragon/Wing, tidak ada Top/Bottum)
--
--  T3: Dragon, Wing, ChestTop, ChestBottum, EyeRight, EyeLeft
--      (TIDAK punya ChestSpawner!)
--      (Spawn Pit dihapus karena bagian model chest permanen → false detect)
--
--  T4: ChestTop, ChestBottum SAJA (tentatif — belum ada konfirmasi)
--
--  Universal: EyeRight, EyeLeft, Coins, MiniCoin
--  Signal: MainMotor6D = chest sedang dibuka (rewards keluar)
--  Island: HydraStand = platform pulau Hydra boss
-- ═══════════════════════════════════════════════════════════════════

-- Set semua nama chest yang di-scan
local CHEST_SET = {
    -- Anchor / spawn marker
    ChestSpawner = true,
    -- Tier 1 exclusive
    Top = true, Bottum = true,
    -- Shared T1/T2/T3
    SkullRetopo = true, EyeRight = true, EyeLeft = true,
    -- Tier 2/3 top parts
    ChestTop = true, ChestBottum = true,
    -- Tier 3 exclusive
    Dragon = true, Wing = true,
    -- Reward parts (bukan tier marker, tapi muncul saat chest terbuka)
    Coins = true, MiniCoin = true,
}
-- Catatan: "Spawn Pit" dan "Gem" SENGAJA tidak ada di CHEST_SET
-- karena keduanya bagian dari model chest permanen di map → false detect

-- Set untuk TP-prioritas (bukan reward biasa)
local TP_BLACKLIST = { Coins = true, MiniCoin = true }

-- Island anchors yang diketahui
local ISLAND_ANCHORS = { "HydraStand" }  -- tambah nama lain jika ditemukan

-- ─── Webhooks ─────────────────────────────────────────────────────
local WEBHOOKS = {
    HydraSeaKing = "https://discord.com/api/webhooks/1486246249123414016/WCjK_oi1jGMQDNa8tt3IWCaVlIdr0pRd-CZ7S0YtY7L_GTqn29_WO6ChkkfSa5mgvmdZ",
    SeaKing      = "https://discord.com/api/webhooks/1486245519008333854/XSPHGAL3uXFFUlT72qODHeSiBGX3oiJ16hzIsYyHFQnX6ubqAQbq--Z-tZTN7UhywB71",
    Chest        = "https://discord.com/api/webhooks/1486599767483089059/POV3wuF0oflUCORlIIxK3qb_K6F_0-Ij71iVzy6cgU_70iWiDx-fz641ndxNg63OD38I",
}

-- ─── State ────────────────────────────────────────────────────────
local isRunning         = false
local isFighting        = false
local isPostFight       = false
local isHopping         = false   -- [FIX-4] cegah server hop ganda
local autoScan          = false
local autoFight         = false
local autoStore         = false
local foundCode         = nil
local foundBossName     = nil
local notifiedJobs      = {}
local notifiedChestJobs = {}
local visitedServers    = {}
local statusLockUntil   = 0
local serverHopCursor   = nil

-- Chest state (diupdate oleh chest task terpisah)
local lastChestParts    = {}   -- set nama chest yang terdeteksi
local lastChestKey      = ""
local lastChestPos      = nil  -- posisi chest terdekat ke player
local lastChestTier     = "?"
local lastChestDist     = nil

-- charCache: set yang diupdate setiap 2 detik
local charSet     = {}  -- { [character_model] = true }
local charCacheTime = 0

local setStatusGUI   -- forward declare
local setChestStatus -- forward declare

-- ─── Character Cache (O(1) lookup) ───────────────────────────────
local function refreshCharCache()
    local now = tick()
    if now - charCacheTime < 2 then return end
    charCacheTime = now
    charSet = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then charSet[p.Character] = true end
    end
end

-- Cek apakah obj adalah bagian dari karakter player
-- [FIX-2] Batas max 64 iterasi agar tidak freeze jika tree sangat dalam
local function isPlayerPart(obj)
    local p   = obj
    local max = 64
    while p and max > 0 do
        max = max - 1
        if charSet[p] then return true end
        if p == workspace then return false end
        p = p.Parent
    end
    return false
end

-- ─── Helpers ──────────────────────────────────────────────────────
local function getHRP()
    local char = lp.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local char = lp.Character
    return char and char:FindFirstChildOfClass("Humanoid")
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
        writefile(CONFIG_FILE, HttpService:JSONEncode({
            autoScan = autoScan, autoFight = autoFight, autoStore = autoStore,
        }))
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

-- ─── Boss Scan (fast — GetChildren first) ────────────────────────
local function findBossModel()
    -- Pass 1: direct children (O(n) — boss biasanya di sini)
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
    -- Pass 2: fallback deeper scan
    for _, obj in ipairs(workspace:GetDescendants()) do
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

-- ─── Island Anchor Scan ───────────────────────────────────────────
-- Cari platform pulau boss (HydraStand dll)
local function findIslandAnchor()
    for _, obj in ipairs(workspace:GetDescendants()) do
        for _, an in ipairs(ISLAND_ANCHORS) do
            if obj.Name == an then
                local part = obj:IsA("BasePart") and obj or obj:FindFirstChildOfClass("BasePart")
                if part then return part.Position, an end
            end
        end
    end
    return nil, nil
end

-- ─── Tier Detection v6.4 ─────────────────────────────────────────
local function detectTier(nameSet)
    -- T3: ada Dragon atau Wing
    if nameSet["Dragon"] or nameSet["Wing"] then
        return "T3 🐉"
    end
    -- T1: ada Top atau Bottum (eksklusif T1)
    if nameSet["Top"] or nameSet["Bottum"] then
        return "T1"
    end
    -- T2: ada ChestTop/ChestBottum + SkullRetopo
    if (nameSet["ChestTop"] or nameSet["ChestBottum"]) and nameSet["SkullRetopo"] then
        return "T2"
    end
    -- T4: ada ChestTop/ChestBottum tapi tidak ada marker lain (tentatif)
    if nameSet["ChestTop"] or nameSet["ChestBottum"] then
        return "T4 (?)"
    end
    -- Hanya ChestSpawner/Eye/Coins — tier tidak diketahui
    return "?"
end

-- ─── Chest Scanner (dijalankan async — tidak blokir main loop) ───
--  Cek CHEST_SET
--  Kembalikan: nameSet, nameList, nearestPart, distFromPlayer
local function scanWorkspaceForChest(originPos)
    local nameSet   = {}
    local nearPart  = nil
    local bestDist  = math.huge
    local hasMotor  = false  -- deteksi MainMotor6D

    for _, obj in ipairs(workspace:GetDescendants()) do
        -- Deteksi MainMotor6D (chest sedang dibuka)
        if obj.Name == "MainMotor6D" and not isPlayerPart(obj) then
            hasMotor = true
        end

        -- Cek nama di CHEST_SET (O(1))
        local nm = obj.Name
        local inSet = CHEST_SET[nm]
        if inSet and not isPlayerPart(obj) then
            local part = obj:IsA("BasePart") and obj or
                         (obj:IsA("Model") and obj:FindFirstChildOfClass("BasePart"))
            if part then
                nameSet[nm] = true
                if originPos then
                    local d = (part.Position - originPos).Magnitude
                    if d < bestDist then
                        bestDist = d
                        nearPart = part
                    end
                end
            end
        end
    end

    return nameSet, nearPart, bestDist < math.huge and bestDist or nil, hasMotor
end

-- Scan dalam radius dari posisi tertentu (untuk post-fight)
local function scanChestNear(center, radius)
    local nameSet         = {}
    local chestSpawnerPos = nil   -- anchor utama (T1/T2)
    local tierPartPos     = nil   -- bagian tier terkuat
    local fallbackPos     = nil   -- part lain (non-coin)
    local bestTierDist    = math.huge
    local hasMotor        = false

    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj.Name == "MainMotor6D" and not isPlayerPart(obj) then
            hasMotor = true
        end

        local nm    = obj.Name
        local inSet = CHEST_SET[nm]
        if inSet and not isPlayerPart(obj) then
            local part = obj:IsA("BasePart") and obj or
                         (obj:IsA("Model") and obj:FindFirstChildOfClass("BasePart"))
            if part then
                local d = (part.Position - center).Magnitude
                if d <= radius then
                    nameSet[nm] = true
                    -- [FIX-3] Pilih posisi TP terbaik
                    -- Prioritas: ChestSpawner > tier part (non-coin, non-spawner) > fallback
                    if nm == "ChestSpawner" and not chestSpawnerPos then
                        chestSpawnerPos = part.Position
                    elseif not TP_BLACKLIST[nm] and nm ~= "ChestSpawner" then
                        if d < bestTierDist then
                            bestTierDist = d
                            tierPartPos  = part.Position
                        end
                        -- fallbackPos diisi dari part tier yang sama (bukan blacklist)
                        if not fallbackPos then
                            fallbackPos = part.Position
                        end
                    end
                end
            end
        end
    end

    -- Kumpulkan nameList
    local nameList = {}
    for nm in pairs(nameSet) do table.insert(nameList, nm) end

    -- Posisi TP: ChestSpawner > tier part > fallback
    local tpPos = chestSpawnerPos or tierPartPos or fallbackPos
    local tier  = detectTier(nameSet)
    return tpPos, nameList, tier, hasMotor
end

-- ─── Chest Scanner Task (jalan independen setiap 1.5 detik) ──────
local function startChestScanTask()
    task.spawn(function()
        while true do
            task.wait(1.5)
            if not isRunning then continue end

            refreshCharCache()
            local hrp = getHRP()
            local hrpPos = hrp and hrp.Position or nil

            local nameSet, nearPart, dist, hasMotor = scanWorkspaceForChest(hrpPos)

            -- Update state global
            local nameList = {}
            for nm in pairs(nameSet) do table.insert(nameList, nm) end
            local tier = detectTier(nameSet)

            if #nameList > 0 then
                local key = table.concat(nameList, ",")
                if key ~= lastChestKey then
                    lastChestKey   = key
                    lastChestParts = nameSet
                    lastChestPos   = nearPart and nearPart.Position or nil
                    lastChestTier  = tier
                    lastChestDist  = dist

                    local txt = "✅ Chest [" .. tier .. "] " ..
                                (dist and math.floor(dist) .. "m" or "?m") .. "\n"
                    for _, nm in ipairs(nameList) do txt = txt .. "• " .. nm .. "\n" end
                    setChestStatus(txt)
                    -- Kirim Discord async
                    task.spawn(function()
                        local jobId = game.JobId
                        sendChestToDiscord(jobId, tier, nameList)
                    end)
                end

                -- Deteksi MainMotor6D = chest sedang dibuka
                if hasMotor and not isPostFight then
                    if autoStore then
                        task.spawn(function()
                            task.wait(0.5)
                            autoStoreFruit()
                        end)
                    end
                end
            else
                if lastChestKey ~= "" then
                    lastChestKey   = ""
                    lastChestParts = {}
                    lastChestPos   = nil
                    lastChestTier  = "?"
                    lastChestDist  = nil
                    setChestStatus("Tidak ada chest di server ini")
                end
            end
        end
    end)
end

-- ─── Discord (semua async) ────────────────────────────────────────
local notifiedDiscordJobs = {}

local function sendBossToDiscord(bossName, jobId)
    local url = WEBHOOKS[bossName]
    if not url or url == "" then return end
    local key = jobId .. "_" .. bossName
    if notifiedDiscordJobs[key] then return end
    notifiedDiscordJobs[key] = true
    local dn  = bossName == "HydraSeaKing" and "Hydra Sea King" or "Sea King"
    local clr = bossName == "HydraSeaKing" and 0x8B00FF or 0x0080FF
    task.spawn(function()
        pcall(function()
            request({
                Url     = WEBHOOKS[bossName],
                Method  = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HttpService:JSONEncode({ embeds = {{
                    title       = "🔴 Boss Found — " .. dn,
                    description =
                        jobId .. "\n\n" ..
                        "```\n" .. jobId .. "\n```\n\n" ..
                        "King Legacy → Private Servers → Paste code",
                    color  = clr,
                    footer = { text = "King Legacy Boss Detector v6.4 | Sea 2" },
                }}})
            })
        end)
    end)
end

local notifiedChestDiscord = {}

function sendChestToDiscord(jobId, tier, nameList)
    if not WEBHOOKS or not WEBHOOKS.Chest or WEBHOOKS.Chest == "" then return end
    if notifiedChestDiscord[jobId] then return end
    notifiedChestDiscord[jobId] = true
    local parts = table.concat(nameList, ", ")
    local clr   = tier:find("T3") and 0xFF4500
               or (tier == "T2" and 0xFFD700)
               or (tier:find("T4") and 0xFF8C00)
               or 0x00CED1
    task.spawn(function()
        pcall(function()
            request({
                Url     = WEBHOOKS.Chest,
                Method  = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body    = HttpService:JSONEncode({ embeds = {{
                    title       = "🧲 Chest Found — " .. tier,
                    description =
                        jobId .. "\n\n" ..
                        "```\n" .. jobId .. "\n```\n\n" ..
                        "Parts: " .. parts .. "\n" ..
                        "King Legacy → Private Servers → Paste code",
                    color  = clr,
                    footer = { text = "King Legacy Boss Detector v6.4 | Sea 2" },
                }}})
            })
        end)
    end)
end

-- ─── Equip Sword ──────────────────────────────────────────────────
local function isSwordEquipped()
    local char = lp.Character
    if not char then return false end
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Tool") and isSwordTool(c) then return true end
    end
    return false
end

local function equipSword()
    local hum = getHumanoid()
    if not hum then return false end
    local bp = lp:FindFirstChild("Backpack")
    if not bp then return false end
    local sword = nil
    for _, sn in ipairs(SWORD_NAMES) do
        sword = bp:FindFirstChild(sn)
        if sword then break end
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
        task.wait(0.3)
        pcall(function() setStatusGUI("⚔️ " .. sword.Name, Color3.fromRGB(100,255,120), 3) end)
        return true
    end
    return false
end

-- ─── Click Button (semua metode) ─────────────────────────────────
local function clickBtn(btn)
    if not btn then return end
    local VIM = game:GetService("VirtualInputManager")
    pcall(function() firesignal(btn.MouseButton1Click) end)
    task.wait(0.1)
    pcall(function()
        local pos  = btn.AbsolutePosition
        local size = btn.AbsoluteSize
        local bx   = pos.X + size.X / 2
        local by   = pos.Y + size.Y / 2
        if bx > 0 and by > 0 then
            VIM:SendMouseButtonEvent(bx, by, 0, true,  game, 1)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(bx, by, 0, false, game, 1)
        end
    end)
end

-- ─── Auto Store Fruit ─────────────────────────────────────────────
--
--  v7.0: Remote brute-force + getconnections() pada Store button
--  TIDAK lagi force UI visible (menyebabkan stats menu terbuka)
--
--  Pendekatan:
--    1. Coba remote calls langsung (DFPassive, EtcFunction, dll)
--    2. Fallback: getconnections() pada Store button → fire connections langsung
--    3. Cek apakah buah hilang dari character/backpack
--
function autoStoreFruit()
    setStatusGUI("🍎 Auto Store...", Color3.fromRGB(255,180,80), 2)

    local function hasFruitTool()
        local char = lp.Character
        if not char then return false, nil end
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") and not isSwordTool(c) then
                return true, c.Name
            end
        end
        return false, nil
    end

    local function hasBackpackFruit()
        local bp = lp:FindFirstChild("Backpack")
        if not bp then return false, nil end
        for _, c in ipairs(bp:GetChildren()) do
            if c:IsA("Tool") and not isSwordTool(c) then
                return true, c.Name
            end
        end
        return false, nil
    end

    local function fruitStillExists()
        local s1, _ = hasFruitTool()
        if s1 then return true end
        local s2, _ = hasBackpackFruit()
        return s2
    end

    local hasFruit, fruitName = hasFruitTool()
    if not hasFruit then
        hasFruit, fruitName = hasBackpackFruit()
    end

    if not hasFruit then
        setStatusGUI("🍎 Tidak ada buah untuk disimpan", Color3.fromRGB(255,200,80), 3)
        return false
    end

    setStatusGUI("🍎 Buah: " .. (fruitName or "?") .. " → Store...", Color3.fromRGB(255,180,80), 2)

    local DFPassive = nil
    local EtcFunction = nil
    local CollectFruit = nil
    local ButtonClicked = nil
    local InventoryEq = nil
    local RemoteClient = nil
    pcall(function() DFPassive     = game.ReplicatedStorage.Chest.Remotes.Functions.DFPassive end)
    pcall(function() EtcFunction   = game.ReplicatedStorage.Chest.Remotes.Functions.EtcFunction end)
    pcall(function() CollectFruit  = game.ReplicatedStorage.Chest.Remotes.Events.CollectFruit end)
    pcall(function() ButtonClicked = game.ReplicatedStorage.Chest.Remotes.Events.ButtonClicked end)
    pcall(function() InventoryEq   = game.ReplicatedStorage.Chest.Remotes.Functions.InventoryEq end)
    pcall(function() RemoteClient  = game.ReplicatedStorage.Chest.Remotes.Functions.RemoteClient end)

    local storeAttempts = {}

    if DFPassive then
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Collect"},              label = "DFP(Collect)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Collect", fruitName},   label = "DFP(Collect,f)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Store"},                label = "DFP(Store)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Store", fruitName},     label = "DFP(Store,f)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Add"},                  label = "DFP(Add)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Add", fruitName},       label = "DFP(Add,f)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {"Put"},                  label = "DFP(Put)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {fruitName},              label = "DFP(fruit)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {fruitName, "Store"},     label = "DFP(f,Store)"})
        table.insert(storeAttempts, {remote = DFPassive, type = "invoke", args = {fruitName, "Collect"},   label = "DFP(f,Collect)"})
    end

    if EtcFunction then
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"CollectFruit"},              label = "Etc(CF)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"CollectFruit", fruitName},   label = "Etc(CF,f)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"StoreFruit"},                label = "Etc(SF)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"StoreFruit", fruitName},     label = "Etc(SF,f)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"PassiveFruit"},              label = "Etc(PF)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"PassiveFruit", fruitName},   label = "Etc(PF,f)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"Passive", "Store"},          label = "Etc(P,S)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"Passive", "Collect"},        label = "Etc(P,C)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"FruitBag", fruitName},       label = "Etc(FB,f)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"Store", fruitName},          label = "Etc(S,f)"})
        table.insert(storeAttempts, {remote = EtcFunction, type = "invoke", args = {"Collect", fruitName},        label = "Etc(C,f)"})
    end

    if InventoryEq then
        table.insert(storeAttempts, {remote = InventoryEq, type = "invoke", args = {"Store", fruitName},   label = "IE(S,f)"})
        table.insert(storeAttempts, {remote = InventoryEq, type = "invoke", args = {"Collect", fruitName}, label = "IE(C,f)"})
        table.insert(storeAttempts, {remote = InventoryEq, type = "invoke", args = {"Passive", fruitName}, label = "IE(P,f)"})
    end

    if RemoteClient then
        table.insert(storeAttempts, {remote = RemoteClient, type = "invoke", args = {"StoreFruit"},              label = "RC(SF)"})
        table.insert(storeAttempts, {remote = RemoteClient, type = "invoke", args = {"StoreFruit", fruitName},   label = "RC(SF,f)"})
        table.insert(storeAttempts, {remote = RemoteClient, type = "invoke", args = {"CollectFruit"},            label = "RC(CF)"})
        table.insert(storeAttempts, {remote = RemoteClient, type = "invoke", args = {"CollectFruit", fruitName}, label = "RC(CF,f)"})
    end

    if CollectFruit then
        table.insert(storeAttempts, {remote = CollectFruit, type = "fire", args = {},                      label = "CF()"})
        table.insert(storeAttempts, {remote = CollectFruit, type = "fire", args = {fruitName},             label = "CF(f)"})
        table.insert(storeAttempts, {remote = CollectFruit, type = "fire", args = {"Store"},               label = "CF(S)"})
        table.insert(storeAttempts, {remote = CollectFruit, type = "fire", args = {"Store", fruitName},    label = "CF(S,f)"})
    end

    if ButtonClicked then
        table.insert(storeAttempts, {remote = ButtonClicked, type = "fire", args = {"Store"},              label = "BC(S)"})
        table.insert(storeAttempts, {remote = ButtonClicked, type = "fire", args = {"PassiveBag","Store"}, label = "BC(PB,S)"})
        table.insert(storeAttempts, {remote = ButtonClicked, type = "fire", args = {"Collect"},            label = "BC(C)"})
    end

    for i, attempt in ipairs(storeAttempts) do
        setStatusGUI("🍎 Try " .. i .. "/" .. #storeAttempts .. ": " .. attempt.label,
                     Color3.fromRGB(255,200,60), 1)

        pcall(function()
            if attempt.type == "fire" then
                attempt.remote:FireServer(unpack(attempt.args))
            else
                attempt.remote:InvokeServer(unpack(attempt.args))
            end
        end)

        task.wait(0.5)

        if not fruitStillExists() then
            setStatusGUI("✅ Store berhasil! (" .. attempt.label .. ")",
                         Color3.fromRGB(80,255,150), 5)
            return true
        end
    end

    -- Fallback: getconnections() — fire Store button's connections tanpa UI visible
    setStatusGUI("🍎 Fallback: getconnections()...", Color3.fromRGB(255,160,60), 2)

    local pg = lp:FindFirstChild("PlayerGui")
    if pg and getconnections then
        for _, btnPath in ipairs({"PassiveBagFrame", "SlotInfoFrame"}) do
            for _, obj in ipairs(pg:GetDescendants()) do
                if (obj:IsA("TextButton") or obj:IsA("ImageButton"))
                   and obj.Name == "Store"
                   and obj:GetFullName():find(btnPath) then
                    pcall(function()
                        local conns = getconnections(obj.MouseButton1Click)
                        for _, conn in ipairs(conns) do
                            conn:Fire()
                        end
                    end)
                    task.wait(1)
                    if not fruitStillExists() then
                        setStatusGUI("✅ Store berhasil! (getconn " .. btnPath .. ")",
                                     Color3.fromRGB(80,255,150), 5)
                        return true
                    end
                    break
                end
            end
        end
    end

    setStatusGUI("❌ Store gagal\nJalankan fruit_store_spy", Color3.fromRGB(255,80,80), 5)
    return false
end

-- ─── Server Hop ───────────────────────────────────────────────────
-- [FIX-4] isHopping mencegah hop berjalan dua kali bersamaan
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
        setStatusGUI("❌ Gagal ambil server list", Color3.fromRGB(255,80,80))
        task.wait(5)
        isHopping = false
        return
    end

    local data    = HttpService:JSONDecode(res.Body)
    local servers = data.data or {}
    serverHopCursor = data.nextPageCursor or nil

    if #servers == 0 then
        serverHopCursor = nil
        setStatusGUI("⚠️ Semua server habis, reset...", Color3.fromRGB(255,180,50))
        visitedServers = {}
        task.wait(3)
        isHopping = false
        return
    end

    for _, sv in ipairs(servers) do
        local sid = sv.id
        if sid and not visitedServers[sid] then
            visitedServers[sid] = true; saveVisited()
            setStatusGUI("🚀 Hop ke server...", Color3.fromRGB(100,200,255))
            task.wait(1)
            pcall(function() TeleportService:TeleportToPlaceInstance(PlaceID, sid, lp) end)
            task.wait(10)
            isHopping = false
            return
        end
    end
    setStatusGUI("🔄 Semua server di halaman habis...", Color3.fromRGB(180,180,100))
    task.wait(2)
    isHopping = false
end

-- ─── Teleport ke Chest ────────────────────────────────────────────
local function teleportToChest(pos, tier, nameList)
    local hrp = getHRP()
    if not hrp or not pos then return end
    setStatusGUI("🚀 TP ke chest [" .. tier .. "]...", Color3.fromRGB(100,220,255), 3)
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 4, 0))
    task.wait(1.5)
    setChestStatus("🎁 Chest [" .. tier .. "]: " .. table.concat(nameList, ", "))
    setStatusGUI("🎁 Chest claimed! [" .. tier .. "]", Color3.fromRGB(80,255,150), 4)
    -- Kirim Discord untuk chest ini (hanya sekali per server)
    task.spawn(function()
        sendChestToDiscord(game.JobId, tier, nameList)
    end)
end

-- ─── Go To Nearby Chest (post-fight) ─────────────────────────────
--  Scan 1500m dari posisi boss mati, loop hingga chest ditemukan (max 20 detik)
--  Deteksi MainMotor6D → chest sedang dibuka → trigger store
local function goToNearbyChest(bossPos)
    setStatusGUI("🧲 Cari chest 1500m...", Color3.fromRGB(255,200,60), 3)
    setChestStatus("⏳ Menunggu chest spawn...")

    local tpPos, nameList, tier = nil, {}, "?"
    local motorDetected = false

    -- Loop scan hingga chest ditemukan (max 20 detik)
    for attempt = 1, 20 do
        refreshCharCache()
        local pos, nl, t, hasMotor = scanChestNear(bossPos, 1500)
        if hasMotor then
            motorDetected = true
            setStatusGUI("⚡ Chest dibuka! (MainMotor6D)", Color3.fromRGB(255,255,80), 3)
        end
        if pos and #nl > 0 then
            tpPos    = pos
            nameList = nl
            tier     = t
            setChestStatus("✅ Chest [" .. t .. "] (" .. attempt .. "s): " .. table.concat(nl, ", "))
            break
        end
        setChestStatus("⏳ Scan chest... (" .. attempt .. "s / 20s)")
        task.wait(1)
    end

    if not tpPos then
        setChestStatus("❌ Chest tidak ditemukan dalam 20s")
        setStatusGUI("⚠️ Chest tidak ditemukan, lanjut...", Color3.fromRGB(255,100,100), 3)
        return motorDetected
    end

    -- TP ke chest
    teleportToChest(tpPos, tier, nameList)

    -- Loop: tetap di area chest, tunggu MainMotor6D (chest dibuka, rewards keluar)
    -- Maksimal 15 detik menunggu rewards
    if not motorDetected then
        setStatusGUI("⏳ Tunggu chest dibuka...", Color3.fromRGB(255,200,60), 3)
        for wait = 1, 15 do
            refreshCharCache()
            local _, _, _, hasMotor = scanChestNear(bossPos, 1500)
            if hasMotor then
                motorDetected = true
                setStatusGUI("⚡ Chest dibuka! Ambil rewards...", Color3.fromRGB(255,255,80), 3)
                task.wait(1)  -- tunggu buah muncul
                break
            end
            task.wait(1)
        end
    end

    return motorDetected
end

-- ─── Auto Fight (SkillAction Remote) ─────────────────────────────
-- v6.7: Menggunakan remote SkillAction langsung (bukan VIM click)
-- Ini bekerja meski menu terbuka (seperti NTT Hub)
-- Remote: ReplicatedStorage.Chest.Remotes.Functions.SkillAction
-- M1:  InvokeServer("SW_<sword>_M1", {MouseHit = CFrame})
-- Z:   InvokeServer("SW_<sword>_Z",  {Type="Down", MouseHit=CFrame})
-- X:   InvokeServer("SW_<sword>_X",  {Type="Down", MouseHit=CFrame})

local function getEquippedSwordName()
    local char = lp.Character
    if not char then return nil end
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("Tool") and isSwordTool(c) then return c.Name end
    end
    return nil
end

local function getSkillRemote()
    local ok, remote = pcall(function()
        return game.ReplicatedStorage.Chest.Remotes.Functions.SkillAction
    end)
    return ok and remote or nil
end

local function getPhysicsRemote()
    local ok, remote = pcall(function()
        return game.ReplicatedStorage.Chest.Remotes.Events.PhysicReplication
    end)
    return ok and remote or nil
end

local fightPlatform = nil

local function createFightPlatform(position)
    if fightPlatform and fightPlatform.Parent then
        fightPlatform.Position = position + Vector3.new(0, -3, 0)
        return fightPlatform
    end
    local p = Instance.new("Part")
    p.Name        = "FightPlatform"
    p.Size        = Vector3.new(20, 1, 20)
    p.Anchored    = true
    p.CanCollide  = true
    p.Transparency = 1
    p.Position    = position + Vector3.new(0, -3, 0)
    p.Parent      = workspace
    fightPlatform = p
    return p
end

local function removeFightPlatform()
    if fightPlatform and fightPlatform.Parent then
        fightPlatform:Destroy()
    end
    fightPlatform = nil
end

local function startFight(boss)
    if isFighting then return end
    isFighting  = true
    isPostFight = false

    task.spawn(function()
        local bossHRP      = boss:FindFirstChild("HumanoidRootPart")
        local savedBossPos = bossHRP and bossHRP.Position or nil

        task.spawn(function()
            while isFighting and isRunning do
                if not isSwordEquipped() then equipSword() end
                task.wait(0.3)
            end
        end)

        if bossHRP then
            savedBossPos = bossHRP.Position
            createFightPlatform(savedBossPos)
            local hrp = getHRP()
            if hrp then
                hrp.CFrame = CFrame.new(savedBossPos + Vector3.new(3, 2, 0))
                hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end

        local SkillAction  = getSkillRemote()
        local PhysicsRep   = getPhysicsRemote()
        local timerZ       = 0
        local timerX       = 1.5
        local timerPhysics = 0
        local useRemote    = SkillAction ~= nil
        local VIM          = game:GetService("VirtualInputManager")
        local cam          = workspace.CurrentCamera

        if useRemote then
            setStatusGUI("⚔️ Fighting boss! (Remote)", Color3.fromRGB(255,120,60), 2)
        else
            setStatusGUI("⚔️ Fighting boss! (VIM fallback)", Color3.fromRGB(255,120,60), 2)
        end

        while isFighting and isRunning do
            local dt = task.wait(0.1)

            if bossHRP and bossHRP.Parent then
                savedBossPos = bossHRP.Position
                createFightPlatform(savedBossPos)
            end

            local bossHum = boss:FindFirstChildOfClass("Humanoid")
            local bossGone = not boss.Parent
            local bossDead = bossHum and bossHum.Health <= 0

            if bossGone or bossDead or not bossHum then
                isFighting  = false
                isPostFight = true
                removeFightPlatform()
                setStatusGUI("⏳ Boss hilang → teleport chest...", Color3.fromRGB(255,255,100), 1)

                task.wait(1)

                local motorDetected = false
                if savedBossPos then
                    motorDetected = goToNearbyChest(savedBossPos)
                end

                task.wait(1)

                local bossBack = false
                setStatusGUI("🔍 Scan ulang boss 5.5 detik...", Color3.fromRGB(255,255,100), 1)
                for scanTick = 1, 5 do
                    task.wait(1)
                    if not isRunning then break end

                    for _, m in ipairs(workspace:GetChildren()) do
                        if m:IsA("Model") then
                            for _, bName in ipairs(BOSS_NAMES) do
                                if m.Name == bName then
                                    local hum2 = m:FindFirstChildOfClass("Humanoid")
                                    if hum2 and hum2.Health > 0 then
                                        bossBack = true
                                        boss     = m
                                        bossHRP  = m:FindFirstChild("HumanoidRootPart")
                                        if bossHRP then savedBossPos = bossHRP.Position end
                                    end
                                end
                            end
                        end
                        if bossBack then break end
                    end

                    if bossBack then break end
                    setStatusGUI("🔍 Scan " .. scanTick .. "/5...", Color3.fromRGB(255,255,100), 1)
                end
                task.wait(0.5)

                if bossBack then
                    setStatusGUI("⚔️ Boss masih hidup! Kembali fight...", Color3.fromRGB(255,120,60), 2)
                    isFighting  = true
                    isPostFight = false
                    createFightPlatform(savedBossPos)
                    if bossHRP and bossHRP.Parent then
                        local hrp = getHRP()
                        if hrp then
                            hrp.CFrame = CFrame.new(savedBossPos + Vector3.new(3, 2, 0))
                            hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                        end
                    end
                else
                    setStatusGUI("✅ Chest claimed! Boss mati.", Color3.fromRGB(100,255,150), 3)

                    if autoStore then
                        task.wait(1)
                        autoStoreFruit()
                    end

                    if autoScan and isRunning then
                        task.wait(4.5)
                        serverHop()
                    end

                    isPostFight = false
                    break
                end
            end

            local hrp = getHRP()
            if hrp and bossHRP and bossHRP.Parent then
                local bossPos = bossHRP.Position
                local playerPos = hrp.Position
                local dist = (Vector3.new(playerPos.X, 0, playerPos.Z) - Vector3.new(bossPos.X, 0, bossPos.Z)).Magnitude
                local tooFar = dist > 8
                local falling = playerPos.Y < bossPos.Y - 5

                if tooFar or falling then
                    hrp.CFrame = CFrame.new(bossPos + Vector3.new(3, 2, 0))
                end
                hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
            elseif hrp and savedBossPos then
                local playerPos = hrp.Position
                if playerPos.Y < savedBossPos.Y - 5 then
                    hrp.CFrame = CFrame.new(savedBossPos + Vector3.new(3, 2, 0))
                    hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                end
            end

            local swordName = getEquippedSwordName()
            local targetPos = (bossHRP and bossHRP.Parent) and bossHRP.Position or savedBossPos

            if useRemote and swordName and targetPos then
                local mouseHit = CFrame.new(targetPos)

                pcall(function()
                    SkillAction:InvokeServer("SW_" .. swordName .. "_M1", {
                        MouseHit = mouseHit,
                    })
                end)

                timerZ = timerZ + dt
                if timerZ >= 3 then
                    timerZ = 0
                    pcall(function()
                        SkillAction:InvokeServer("SW_" .. swordName .. "_Z", {
                            Type = "Down", MouseHit = mouseHit,
                        })
                    end)
                    task.wait(0.15)
                    pcall(function()
                        SkillAction:InvokeServer("SW_" .. swordName .. "_Z", {
                            Type = "Up", MouseHit = mouseHit,
                        })
                    end)
                end

                timerX = timerX + dt
                if timerX >= 3 then
                    timerX = 0
                    pcall(function()
                        SkillAction:InvokeServer("SW_" .. swordName .. "_X", {
                            Type = "Down", MouseHit = mouseHit,
                        })
                    end)
                    task.wait(0.15)
                    pcall(function()
                        SkillAction:InvokeServer("SW_" .. swordName .. "_X", {
                            Type = "Up", MouseHit = mouseHit,
                        })
                    end)
                end

                timerPhysics = timerPhysics + dt
                if timerPhysics >= 0.25 and PhysicsRep then
                    timerPhysics = 0
                    pcall(function()
                        local hrp = getHRP()
                        if hrp then
                            PhysicsRep:FireServer(hrp.CFrame)
                        end
                    end)
                end
            else
                local cx = cam.ViewportSize.X / 2
                local cy = cam.ViewportSize.Y / 2
                pcall(function()
                    VIM:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
                    task.wait(0.04)
                    VIM:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
                end)

                timerZ = timerZ + dt
                if timerZ >= 3 then
                    timerZ = 0
                    pcall(function()
                        VIM:SendKeyEvent(true,  Enum.KeyCode.Z, false, game)
                        task.wait(0.08)
                        VIM:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
                    end)
                end

                timerX = timerX + dt
                if timerX >= 3 then
                    timerX = 0
                    pcall(function()
                        VIM:SendKeyEvent(true,  Enum.KeyCode.X, false, game)
                        task.wait(0.08)
                        VIM:SendKeyEvent(false, Enum.KeyCode.X, false, game)
                    end)
                end
            end
        end

        isFighting  = false
        isPostFight = false
    end)
end

-- ─── Pre-Spawned Chest Detection (server join) ───────────────────
--  Cek apakah ada chest yang sudah spawn sebelum player join
--  (boss sudah dikalahkan oleh orang lain)
local function checkPreSpawnedChest()
    -- Cari island anchor (HydraStand dll)
    local islandPos, anchorName = findIslandAnchor()
    if not islandPos then return end

    -- Jika ada island anchor tapi tidak ada boss aktif → mungkin ada chest
    local boss, _ = findBossModel()
    if boss then return end  -- boss masih ada, tidak perlu cek chest awal

    setStatusGUI("🔍 Island terdeteksi: " .. anchorName .. "\nCek chest...",
                 Color3.fromRGB(180,200,255), 4)

    local tpPos, nameList, tier, _ = scanChestNear(islandPos, 1500)
    if tpPos and #nameList > 0 then
        setChestStatus("🎁 Chest pre-spawn [" .. tier .. "]: " .. table.concat(nameList, ", "))
        setStatusGUI("🎁 Chest ditemukan di pulau " .. anchorName, Color3.fromRGB(255,220,80), 5)
        task.spawn(function()
            sendChestToDiscord(game.JobId, tier, nameList)
        end)
        -- [FIX-5] TP jika autoFight ATAU autoStore aktif (bukan hanya autoFight)
        if autoFight or autoStore then
            isPostFight = true
            teleportToChest(tpPos, tier, nameList)
            if autoStore then
                task.wait(2); autoStoreFruit(); task.wait(2)
            end
            if autoScan and isRunning then
                task.wait(3); serverHop()
            end
            isPostFight = false
        end
    end
end

-- ─── Data Gatherer (diagnostic) ───────────────────────────────────
local function runDataGatherer(statusFn)
    statusFn("🔍 Data Gatherer...", Color3.fromRGB(200,160,255), 8)
    refreshCharCache()
    local result = { backpack = {}, storeButtons = {} }

    local bp = lp:FindFirstChild("Backpack")
    if bp then
        for i, c in ipairs(bp:GetChildren()) do
            table.insert(result.backpack, { slot = i, name = c.Name, cls = c.ClassName })
        end
    end

    -- Cek karakter yang diequip
    local char = lp.Character
    if char then
        result.equipped = {}
        for _, v in ipairs(char:GetChildren()) do
            if v:IsA("Tool") then
                table.insert(result.equipped, v.Name)
            end
        end
    end

    local pg = lp:FindFirstChild("PlayerGui")
    if pg then
        for _, obj in ipairs(pg:GetDescendants()) do
            if (obj:IsA("TextButton") or obj:IsA("ImageButton")) and obj.Name == "Store" then
                local chain = true
                local firstHidden = nil
                local p = obj.Parent
                while p and p ~= pg do
                    if p:IsA("GuiObject") and not p.Visible then
                        chain = false
                        if not firstHidden then firstHidden = p:GetFullName() end
                    end
                    p = p.Parent
                end
                table.insert(result.storeButtons, {
                    path        = obj:GetFullName(),
                    visible     = obj.Visible,
                    chainVis    = chain,
                    firstHidden = firstHidden or "none",
                    absPos      = tostring(obj.AbsolutePosition),
                    absSize     = tostring(obj.AbsoluteSize),
                    text        = obj:IsA("TextButton") and obj.Text or "",
                })
            end
        end
    end

    pcall(function() writefile("DataGatherer_Result.json", HttpService:JSONEncode(result)) end)
    statusFn(
        "🔍 Done! BP:" .. #result.backpack ..
        " StoreBtn:" .. #result.storeButtons,
        Color3.fromRGB(200,160,255), 8
    )
end

-- ─── Nearby Scan (50 items, radius 200m) ─────────────────────────
local function runNearbyScan(statusFn)
    statusFn("📍 Scan 200m (50 item)...", Color3.fromRGB(180,200,255), 10)
    local hrp = getHRP()
    if not hrp then
        statusFn("❌ Karakter tidak ada", Color3.fromRGB(255,80,80), 3)
        return
    end
    refreshCharCache()
    local pos = hrp.Position
    local found, seen = {}, {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if not isPlayerPart(obj) then
            local part = obj:IsA("BasePart") and obj or
                         (obj:IsA("Model") and obj:FindFirstChildOfClass("BasePart"))
            if part then
                local d = (part.Position - pos).Magnitude
                if d <= 200 then
                    local k = obj.Name .. "_" .. obj.ClassName .. "_" .. math.floor(d)
                    if not seen[k] then
                        seen[k] = true
                        table.insert(found, {
                            name = obj.Name,
                            dist = math.floor(d),
                            cls  = obj.ClassName,
                            path = obj:GetFullName()
                        })
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.dist < b.dist end)
    local lines = {}
    for i = 1, math.min(50, #found) do
        local f = found[i]
        table.insert(lines, f.dist .. "m: " .. f.name .. " [" .. f.cls .. "]")
    end
    statusFn(
        "📍 200m (" .. #found .. " obj):\n" .. table.concat(lines, "\n"),
        Color3.fromRGB(180,200,255), 12
    )
    pcall(function()
        writefile("NearbyModels_200m.json", HttpService:JSONEncode(found))
    end)
end

-- ─── Main Loop ────────────────────────────────────────────────────
--  Sangat ringan: hanya boss scan + hop
--  Chest scan jalan di task terpisah (startChestScanTask)
local function mainLoop()
    -- Cek chest pre-spawn (boss sudah mati sebelum player join)
    task.spawn(function()
        task.wait(3)  -- tunggu game fully loaded
        if isRunning then checkPreSpawnedChest() end
    end)

    while true do
        task.wait(1)
        if not isRunning then continue end

        refreshCharCache()

        local boss, bossName = findBossModel()

        if boss and bossName then
            local jobId = game.JobId
            foundCode     = jobId
            foundBossName = bossName
            local dn = bossName == "HydraSeaKing" and "Hydra Sea King" or "Sea King"
            setStatusGUI("✅ Boss: " .. dn, Color3.fromRGB(80,255,120))
            -- Discord async
            task.spawn(function() sendBossToDiscord(bossName, jobId) end)
            if autoFight and not isFighting and not isPostFight then
                startFight(boss)
            end
        else
            if not isFighting and not isPostFight then
                setStatusGUI("❌ No Boss Found", Color3.fromRGB(180,80,80))
                if autoScan then
                    task.spawn(serverHop)
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════
--  GUI v6.4
-- ═══════════════════════════════════════════════════════════════════

local existingGui = lp.PlayerGui:FindFirstChild("BossDetectorGui")
if existingGui then existingGui:Destroy() end

local screenGui          = Instance.new("ScreenGui")
screenGui.Name           = "BossDetectorGui"
screenGui.ResetOnSpawn   = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder   = 999
screenGui.Parent         = lp.PlayerGui

local PANEL_W = 300
local PANEL_H = 520
local TITLE_H = 44

local showBtn            = Instance.new("TextButton")
showBtn.Size             = UDim2.new(0, 46, 0, 46)
showBtn.Position         = UDim2.new(0, 8, 0, 8)
showBtn.BackgroundColor3 = Color3.fromRGB(26, 26, 50)
showBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
showBtn.Text             = "👾"
showBtn.TextSize         = 24
showBtn.Font             = Enum.Font.GothamBold
showBtn.ZIndex           = 30
showBtn.Parent           = screenGui
Instance.new("UICorner", showBtn).CornerRadius = UDim.new(0, 10)

local panel              = Instance.new("Frame")
panel.Size               = UDim2.new(0, PANEL_W, 0, PANEL_H)
panel.Position           = UDim2.new(0, 8, 0, 60)
panel.BackgroundColor3   = Color3.fromRGB(14, 14, 26)
panel.BorderSizePixel    = 0
panel.Active             = true
panel.Draggable          = true
panel.ZIndex             = 10
panel.Parent             = screenGui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local titleBar            = Instance.new("Frame")
titleBar.Size             = UDim2.new(1, 0, 0, TITLE_H)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 24, 46)
titleBar.BorderSizePixel  = 0
titleBar.ZIndex           = 11
titleBar.Parent           = panel
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 12)

local ttlLbl                  = Instance.new("TextLabel")
ttlLbl.Size                   = UDim2.new(1, -50, 1, 0)
ttlLbl.Position               = UDim2.new(0, 10, 0, 0)
ttlLbl.BackgroundTransparency = 1
ttlLbl.Text                   = "👾  BOSS DETECTOR v6.5"
ttlLbl.TextColor3             = Color3.fromRGB(110, 165, 255)
ttlLbl.TextSize               = 13
ttlLbl.Font                   = Enum.Font.GothamBold
ttlLbl.TextXAlignment         = Enum.TextXAlignment.Left
ttlLbl.ZIndex                 = 12
ttlLbl.Parent                 = titleBar

local closeBtn            = Instance.new("TextButton")
closeBtn.Size             = UDim2.new(0, 34, 0, 28)
closeBtn.Position         = UDim2.new(1, -38, 0.5, -14)
closeBtn.BackgroundColor3 = Color3.fromRGB(155, 35, 35)
closeBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
closeBtn.Text             = "✕"
closeBtn.TextSize         = 14
closeBtn.Font             = Enum.Font.GothamBold
closeBtn.ZIndex           = 13
closeBtn.Parent           = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local scroll                  = Instance.new("ScrollingFrame")
scroll.Size                   = UDim2.new(1, 0, 1, -TITLE_H)
scroll.Position               = UDim2.new(0, 0, 0, TITLE_H)
scroll.CanvasSize             = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize    = Enum.AutomaticSize.Y
scroll.ScrollBarThickness     = 5
scroll.ScrollBarImageColor3   = Color3.fromRGB(60, 100, 210)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel        = 0
scroll.ScrollingEnabled       = true
scroll.Active                 = true
scroll.ClipsDescendants       = true
scroll.ZIndex                 = 12
scroll.Parent                 = panel

Instance.new("UIListLayout", scroll).Padding = UDim.new(0, 6)
local pp         = Instance.new("UIPadding", scroll)
pp.PaddingLeft   = UDim.new(0, 10)
pp.PaddingRight  = UDim.new(0, 10)
pp.PaddingTop    = UDim.new(0, 8)
pp.PaddingBottom = UDim.new(0, 14)

local _ord = 0
local function O() _ord = _ord + 1; return _ord end

local function Sec(text)
    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, 0, 0, 20)
    l.BackgroundTransparency = 1
    l.Text                   = text
    l.TextColor3             = Color3.fromRGB(85, 145, 255)
    l.TextSize               = 11
    l.Font                   = Enum.Font.GothamBold
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.LayoutOrder            = O()
    l.ZIndex                 = 13
    l.Parent                 = scroll
    return l
end

local function Lbl(text, color, fixedH)
    local l = Instance.new("TextLabel")
    if fixedH then
        l.Size          = UDim2.new(1, 0, 0, fixedH)
        l.AutomaticSize = Enum.AutomaticSize.None
    else
        l.Size          = UDim2.new(1, 0, 0, 0)
        l.AutomaticSize = Enum.AutomaticSize.Y
    end
    l.BackgroundTransparency = 1
    l.Text                   = text
    l.TextColor3             = color or Color3.fromRGB(200, 200, 210)
    l.TextSize               = 12
    l.Font                   = Enum.Font.Gotham
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.TextWrapped            = true
    l.LayoutOrder            = O()
    l.ZIndex                 = 13
    l.Parent                 = scroll
    return l
end

local function Btn(text, color)
    local b            = Instance.new("TextButton")
    b.Size             = UDim2.new(1, 0, 0, 40)
    b.BackgroundColor3 = color or Color3.fromRGB(38, 38, 72)
    b.TextColor3       = Color3.fromRGB(255, 255, 255)
    b.Text             = text
    b.TextSize         = 13
    b.Font             = Enum.Font.GothamBold
    b.TextWrapped      = true
    b.LayoutOrder      = O()
    b.ZIndex           = 13
    b.Parent           = scroll
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    return b
end

local function TBox()
    local tb              = Instance.new("TextBox")
    tb.Size               = UDim2.new(1, 0, 0, 40)
    tb.BackgroundColor3   = Color3.fromRGB(22, 22, 42)
    tb.TextColor3         = Color3.fromRGB(255, 255, 255)
    tb.PlaceholderText    = "Masukkan kode server..."
    tb.PlaceholderColor3  = Color3.fromRGB(80, 80, 115)
    tb.Text               = ""
    tb.TextSize           = 13
    tb.Font               = Enum.Font.Gotham
    tb.ClearTextOnFocus   = false
    tb.LayoutOrder        = O()
    tb.ZIndex             = 13
    tb.Parent             = scroll
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 8)
    return tb
end

-- ── UI Content ────────────────────────────────────────────────────
Sec("── STATUS ──")
local statusLbl    = Lbl("Status: Starting...", Color3.fromRGB(155,175,225))
statusLbl.TextSize = 13

Sec("── KODE SERVER ──")
local codeLbl    = Lbl("Code: -", Color3.fromRGB(255,215,55), 34)
codeLbl.TextSize = 14
codeLbl.Font     = Enum.Font.GothamBold

local btnCopyAuto = Btn("📋 Copy Kode", Color3.fromRGB(32,62,145))
btnCopyAuto.Visible = false
local btnJoinAuto = Btn("🚀 Join Server", Color3.fromRGB(20,92,48))
btnJoinAuto.Visible = false

Sec("── AUTO ──")
local btnPause     = Btn("⏸  Pause",                 Color3.fromRGB(130,95,18))
local btnAutoScan  = Btn("[ OFF ] Auto Scan & Hop",   Color3.fromRGB(52,28,28))
local btnAutoFight = Btn("[ OFF ] Auto Fight Boss",   Color3.fromRGB(52,28,28))
local btnAutoStore = Btn("[ OFF ] Auto Store Buah",   Color3.fromRGB(52,28,28))

Sec("── MANUAL JOIN ──")
local codeInput     = TBox()
local btnJoinManual = Btn("🔑 Join Manual", Color3.fromRGB(48,38,100))

Sec("── STATUS CHEST ──")
local chestStatusLbl = Lbl("Chest: Scanning...", Color3.fromRGB(255,195,55))

Sec("── TOOLS ──")
local btnTestEquip  = Btn("🔧 Test Equip Pedang",      Color3.fromRGB(68,48,14))
local btnStoreNow   = Btn("🍎 Test Store Buah",         Color3.fromRGB(80,48,14))
local btnNearby200  = Btn("📍 Scan 200m (50 item)",     Color3.fromRGB(38,96,55))
local btnDataGath   = Btn("🔍 Data Gatherer",            Color3.fromRGB(80,65,10))
local btnScanChest  = Btn("🧲 Manual Scan Chest",        Color3.fromRGB(88,48,16))
local btnIsland     = Btn("🏝 Cek Island + Chest",       Color3.fromRGB(38,60,100))

Sec("── INFO TIER ──")
Lbl(
    "T1: ChestSpawner+Top+Bottum+SkullRetopo+EyeRight+EyeLeft\n"..
    "T2: ChestSpawner+ChestTop+ChestBottum+SkullRetopo+Eye\n"..
    "T3: Dragon+Wing+ChestTop+ChestBottum+Eye (no ChestSpawner)\n"..
    "T4: ChestTop+ChestBottum saja (tentatif)\n"..
    "Dihapus: Spawn Pit, Gem (false detect - ada di map permanen)\n"..
    "Motor: MainMotor6D = chest sedang dibuka",
    Color3.fromRGB(95,95,135)
).TextSize = 10

-- ── setStatusGUI & setChestStatus ─────────────────────────────────
setStatusGUI = function(txt, color, lockSecs)
    if tick() < statusLockUntil and (not lockSecs or lockSecs == 0) then return end
    statusLbl.Text       = "Status: " .. txt
    statusLbl.TextColor3 = color or Color3.fromRGB(155,175,225)
    if lockSecs and lockSecs > 0 then statusLockUntil = tick() + lockSecs end
end

local function forceStatus(txt, color)
    statusLockUntil = 0
    setStatusGUI(txt, color)
end

setChestStatus = function(txt)
    chestStatusLbl.Text       = txt
    chestStatusLbl.TextColor3 = Color3.fromRGB(255,195,55)
end

-- ── Toggle helper ─────────────────────────────────────────────────
local function toggle(btn, state, label)
    btn.Text             = (state and "[ ON  ] " or "[ OFF ] ") .. label
    btn.BackgroundColor3 = state and Color3.fromRGB(20,90,42) or Color3.fromRGB(52,28,28)
end

local function updateToggles()
    toggle(btnAutoScan,  autoScan,  "Auto Scan & Hop")
    toggle(btnAutoFight, autoFight, "Auto Fight Boss")
    toggle(btnAutoStore, autoStore, "Auto Store Buah")
end

-- ── Button events ─────────────────────────────────────────────────
showBtn.MouseButton1Click:Connect(function()
    panel.Visible = not panel.Visible
end)
closeBtn.MouseButton1Click:Connect(function()
    panel.Visible = false
end)

btnPause.MouseButton1Click:Connect(function()
    isRunning = not isRunning
    if isRunning then
        btnPause.Text             = "⏸  Pause"
        btnPause.BackgroundColor3 = Color3.fromRGB(130,95,18)
        forceStatus("▶ Running", Color3.fromRGB(100,220,150))
    else
        btnPause.Text             = "▶  Resume"
        btnPause.BackgroundColor3 = Color3.fromRGB(20,90,42)
        forceStatus("⏸ Paused", Color3.fromRGB(255,180,50))
    end
end)

btnAutoScan.MouseButton1Click:Connect(function()
    autoScan = not autoScan; toggle(btnAutoScan, autoScan, "Auto Scan & Hop"); saveConfig()
end)
btnAutoFight.MouseButton1Click:Connect(function()
    autoFight = not autoFight
    if not autoFight then isFighting = false; isPostFight = false end
    toggle(btnAutoFight, autoFight, "Auto Fight Boss"); saveConfig()
end)
btnAutoStore.MouseButton1Click:Connect(function()
    autoStore = not autoStore; toggle(btnAutoStore, autoStore, "Auto Store Buah"); saveConfig()
end)

btnCopyAuto.MouseButton1Click:Connect(function()
    if foundCode then
        pcall(function() setclipboard(foundCode) end)
        forceStatus("📋 Kode disalin!", Color3.fromRGB(100,255,180))
    end
end)
btnJoinAuto.MouseButton1Click:Connect(function()
    if foundCode then
        pcall(function() TeleportService:TeleportToPlaceInstance(PlaceID, foundCode, lp) end)
    end
end)
btnJoinManual.MouseButton1Click:Connect(function()
    local code = codeInput.Text
    if code ~= "" then
        pcall(function() TeleportService:TeleportToPlaceInstance(PlaceID, code, lp) end)
    end
end)

btnTestEquip.MouseButton1Click:Connect(function()
    task.spawn(equipSword)
end)
btnStoreNow.MouseButton1Click:Connect(function()
    task.spawn(autoStoreFruit)
end)
btnNearby200.MouseButton1Click:Connect(function()
    task.spawn(function() runNearbyScan(setStatusGUI) end)
end)
btnDataGath.MouseButton1Click:Connect(function()
    task.spawn(function() runDataGatherer(setStatusGUI) end)
end)
btnScanChest.MouseButton1Click:Connect(function()
    task.spawn(function()
        refreshCharCache()
        local hrp = getHRP()
        local nameSet, nearPart, dist, hasMotor = scanWorkspaceForChest(hrp and hrp.Position)
        local nameList = {}
        for nm in pairs(nameSet) do table.insert(nameList, nm) end
        local tier = detectTier(nameSet)
        if #nameList > 0 then
            local txt = "🧲 Scan [" .. tier .. "] " ..
                        (dist and math.floor(dist) .. "m" or "?m") ..
                        (hasMotor and " ⚡Motor!" or "") .. "\n"
            for _, nm in ipairs(nameList) do txt = txt .. "• " .. nm .. "\n" end
            setStatusGUI(txt, Color3.fromRGB(255,210,80), 10)
            setChestStatus(txt)
            pcall(function()
                writefile("ChestScan_Result.json", HttpService:JSONEncode({
                    tier = tier, parts = nameList,
                    dist = dist and math.floor(dist) or -1,
                    hasMainMotor = hasMotor,
                }))
            end)
        else
            setStatusGUI("🧲 Tidak ada chest", Color3.fromRGB(180,180,180), 5)
            setChestStatus("Tidak ada chest ditemukan")
        end
    end)
end)
btnIsland.MouseButton1Click:Connect(function()
    task.spawn(function()
        local islandPos, anchorName = findIslandAnchor()
        if not islandPos then
            setStatusGUI("🏝 Tidak ada island anchor terdeteksi\nHydraStand dll belum ada di server ini",
                         Color3.fromRGB(180,180,180), 6)
            return
        end
        setStatusGUI("🏝 Island: " .. anchorName, Color3.fromRGB(180,200,255), 3)
        local tpPos, nameList, tier, _ = scanChestNear(islandPos, 1500)
        if tpPos and #nameList > 0 then
            local txt = "🏝 Island [" .. anchorName .. "] → Chest [" .. tier .. "]\n"
            for _, nm in ipairs(nameList) do txt = txt .. "• " .. nm .. "\n" end
            setStatusGUI(txt, Color3.fromRGB(255,220,80), 10)
            setChestStatus(txt)
        else
            setStatusGUI("🏝 Island " .. anchorName .. " → Tidak ada chest", Color3.fromRGB(180,180,180), 5)
        end
    end)
end)

-- ── Code label updater ────────────────────────────────────────────
task.spawn(function()
    local lastCode = nil
    while true do
        task.wait(0.5)
        if foundCode ~= lastCode then
            lastCode = foundCode
            if foundCode then
                codeLbl.Text        = "Code: " .. foundCode
                btnCopyAuto.Visible = true
                btnJoinAuto.Visible = true
            else
                codeLbl.Text        = "Code: -"
                btnCopyAuto.Visible = false
                btnJoinAuto.Visible = false
            end
        end
    end
end)

-- ── Init ──────────────────────────────────────────────────────────
loadConfig()
loadVisited()
updateToggles()
isRunning = true
setStatusGUI("▶ Running v6.5...", Color3.fromRGB(100,220,150))

-- Jalankan chest scanner di task terpisah
startChestScanTask()
-- Jalankan main loop
task.spawn(mainLoop)

print("[BossDetector v6.5] Script loaded. Panel: tombol 👾 kiri atas.")
