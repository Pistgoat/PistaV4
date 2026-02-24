
--[[
    ██╗    ██╗ ██████╗ ██╗     ███████╗    ██╗   ██╗██╗  ██╗██████╗ ███████╗
    ██║    ██║██╔═══██╗██║     ██╔════╝    ██║   ██║╚██╗██╔╝██╔══██╗██╔════╝
    ██║ █╗ ██║██║   ██║██║     █████╗      ██║   ██║ ╚███╔╝ ██████╔╝█████╗
    ██║███╗██║██║   ██║██║     ██╔══╝      ╚██╗ ██╔╝ ██╔██╗ ██╔═══╝ ██╔══╝
    ╚███╔███╔╝╚██████╔╝███████╗██║          ╚████╔╝ ██╔╝ ██╗██║     ███████╗
     ╚══╝╚══╝  ╚═════╝ ╚══════╝╚═╝           ╚═══╝  ╚═╝  ╚═╝╚═╝     ╚══════╝

    WOLFVXPE  (PISTA V5)
    Originally by pistademon | Rewritten & Enhanced Edition
    Vape Kill Aura Engine  •  KB Reducer  •  Aim Assist  •  ESP  •  FPS

    V5 CHANGES (Kill Aura only — everything else is V4 identical):
      - Kill Aura now uses Vape's bedwars SwordController:swingSwordAtMouse()
      - HitFix: hookClientGet selfPosition ping compensation (Vape AttackEntity hook)
      - HitBoxes: debug.setconstant on swingSwordInRegion constant (Vape Sword mode)
      - entitylib: full Vape entity tracking for precise target finding
      - hasSwordEquipped: Vape ItemMeta hotbar check
      - FireServer fallback kept for non-bedwars envs
      - All other V4 systems (KB, Aim, ESP, FPS) untouched
]]

-- ══════════════════════════════════════════════════════════════
-- SERVICES  (cached once at top — fastest possible lookup)
-- ══════════════════════════════════════════════════════════════
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local Lighting         = game:GetService("Lighting")
local Stats            = game:GetService("Stats")
local CoreGui          = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
local Mouse       = LocalPlayer:GetMouse()
local Camera      = workspace.CurrentCamera

-- Fast local refs to built-ins (micro-optimise hot paths)
local tinsert, tremove, tclone = table.insert, table.remove, table.clone
local mfloor, mcos, mrad, mabs = math.floor, math.cos, math.rad, math.abs
local v3new, cf3new = Vector3.new, CFrame.new

-- ══════════════════════════════════════════════════════════════
-- PROFILE SAVING
-- ══════════════════════════════════════════════════════════════
local PROFILE_FILE = "WolfVXPE_V5_Profile.txt"

local function serializeProfile(t)
    local parts = {}
    for k, v in pairs(t) do
        tinsert(parts, k .. "=" .. tostring(v))
    end
    return table.concat(parts, ";")
end

local function deserializeProfile(str)
    local t = {}
    for pair in str:gmatch("[^;]+") do
        local k, v = pair:match("^(.-)=(.+)$")
        if k and v then
            if     v == "true"  then t[k] = true
            elseif v == "false" then t[k] = false
            elseif tonumber(v)  then t[k] = tonumber(v)
            else                     t[k] = v end
        end
    end
    return t
end

local savedProfile = {}
pcall(function()
    if isfile and isfile(PROFILE_FILE) then
        savedProfile = deserializeProfile(readfile(PROFILE_FILE))
    end
end)

local function saveProfile(data)
    pcall(function()
        if writefile then writefile(PROFILE_FILE, serializeProfile(data)) end
    end)
end

local function P(key, default)
    local v = savedProfile[key]
    return v ~= nil and v or default
end

-- ══════════════════════════════════════════════════════════════
-- CHARACTER HELPERS
-- ══════════════════════════════════════════════════════════════
local function getChar()     return LocalPlayer.Character end
local function getRoot()     local c=getChar(); return c and c:FindFirstChild("HumanoidRootPart") end
local function getHumanoid() local c=getChar(); return c and c:FindFirstChild("Humanoid") end

-- Anti-AFK
local ok, VirtualUser = pcall(function() return game:GetService("VirtualUser") end)
if ok and VirtualUser then
    LocalPlayer.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.zero, Camera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.zero, Camera.CFrame)
    end)
end

-- ══════════════════════════════════════════════════════════════
-- VAPE ENTITY LIB  (extracted from paste #1 — needed by KA)
-- Full entity tracking: adds/removes players, health updates,
-- team check, wall check, isVulnerable. Used by KA target loop.
-- ══════════════════════════════════════════════════════════════
local cloneref = cloneref or function(obj) return obj end

local vapeEvents = setmetatable({}, {
    __index = function(self, index)
        self[index] = Instance.new("BindableEvent")
        return self[index]
    end
})

local playersService = cloneref(game:GetService("Players"))
local inputService   = cloneref(game:GetService("UserInputService"))
local lplr           = playersService.LocalPlayer
local gameCamera     = workspace.CurrentCamera

local entitylib = {
    isAlive   = false,
    character = {},
    List      = {},
    Connections       = {},
    PlayerConnections = {},
    EntityThreads     = {},
    Running   = false,
    Events    = setmetatable({}, {
        __index = function(self, ind)
            self[ind] = {
                Connections = {},
                Connect = function(rself, func)
                    tinsert(rself.Connections, func)
                    return { Disconnect = function()
                        local i = table.find(rself.Connections, func)
                        if i then tremove(rself.Connections, i) end
                    end }
                end,
                Fire = function(rself, ...)
                    for _, v in rself.Connections do task.spawn(v, ...) end
                end,
                Destroy = function(rself)
                    table.clear(rself.Connections)
                    table.clear(rself)
                end
            }
            return self[ind]
        end
    })
}

local function _waitForChildOfType(obj, name, timeout, prop)
    local deadline = tick() + timeout
    local returned
    repeat
        returned = prop and obj[name] or obj:FindFirstChildOfClass(name)
        if returned or deadline < tick() then break end
        task.wait()
    until false
    return returned
end

entitylib.isVulnerable = function(ent)
    return ent.Health > 0 and not ent.Character:FindFirstChildWhichIsA("ForceField")
end

entitylib.targetCheck = function(ent)
    if ent.TeamCheck then return ent:TeamCheck() end
    if ent.NPC then return true end
    if not lplr.Team then return true end
    if not ent.Player.Team then return true end
    if ent.Player.Team ~= lplr.Team then return true end
    return #ent.Player.Team:GetPlayers() == #playersService:GetPlayers()
end

entitylib.IgnoreObject = RaycastParams.new()
entitylib.IgnoreObject.RespectCanCollide = true

entitylib.Wallcheck = function(origin, position, ignoreobject)
    if typeof(ignoreobject) ~= "Instance" then
        local ignorelist = {gameCamera, lplr.Character}
        for _, v in entitylib.List do
            if v.Targetable then tinsert(ignorelist, v.Character) end
        end
        if typeof(ignoreobject) == "table" then
            for _, v in ignoreobject do tinsert(ignorelist, v) end
        end
        ignoreobject = entitylib.IgnoreObject
        ignoreobject.FilterDescendantsInstances = ignorelist
    end
    return workspace:Raycast(origin, (position - origin), ignoreobject)
end

entitylib.getUpdateConnections = function(ent)
    local hum = ent.Humanoid
    return {
        hum:GetPropertyChangedSignal("Health"),
        hum:GetPropertyChangedSignal("MaxHealth"),
    }
end

entitylib.getEntity = function(char)
    for i, v in entitylib.List do
        if v.Player == char or v.Character == char then return v, i end
    end
end

entitylib.addEntity = function(char, plr, teamfunc)
    if not char then return end
    entitylib.EntityThreads[char] = task.spawn(function()
        local hum        = _waitForChildOfType(char, "Humanoid", 10)
        local humrootpart = hum and _waitForChildOfType(hum, "RootPart", workspace.StreamingEnabled and 9e9 or 10, true)
        local head        = char:WaitForChild("Head", 10) or humrootpart

        if hum and humrootpart then
            local entity = {
                Connections     = {},
                Character       = char,
                Health          = hum.Health,
                Head            = head,
                Humanoid        = hum,
                HumanoidRootPart = humrootpart,
                HipHeight       = hum.HipHeight + (humrootpart.Size.Y / 2) + (hum.RigType == Enum.HumanoidRigType.R6 and 2 or 0),
                MaxHealth       = hum.MaxHealth,
                NPC             = plr == nil,
                Player          = plr,
                RootPart        = humrootpart,
                TeamCheck       = teamfunc,
            }

            if plr == lplr then
                entitylib.character = entity
                entitylib.isAlive   = true
                entitylib.Events.LocalAdded:Fire(entity)
            else
                entity.Targetable = entitylib.targetCheck(entity)
                for _, v in entitylib.getUpdateConnections(entity) do
                    tinsert(entity.Connections, v:Connect(function()
                        entity.Health    = hum.Health
                        entity.MaxHealth = hum.MaxHealth
                        entitylib.Events.EntityUpdated:Fire(entity)
                    end))
                end
                tinsert(entitylib.List, entity)
                entitylib.Events.EntityAdded:Fire(entity)
            end
        end
        entitylib.EntityThreads[char] = nil
    end)
end

entitylib.removeEntity = function(char, localcheck)
    if localcheck then
        if entitylib.isAlive then
            entitylib.isAlive = false
            for _, v in entitylib.character.Connections do v:Disconnect() end
            table.clear(entitylib.character.Connections)
            entitylib.Events.LocalRemoved:Fire(entitylib.character)
        end
        return
    end
    if char then
        if entitylib.EntityThreads[char] then
            task.cancel(entitylib.EntityThreads[char])
            entitylib.EntityThreads[char] = nil
        end
        local entity, ind = entitylib.getEntity(char)
        if ind then
            for _, v in entity.Connections do v:Disconnect() end
            table.clear(entity.Connections)
            tremove(entitylib.List, ind)
            entitylib.Events.EntityRemoved:Fire(entity)
        end
    end
end

entitylib.refreshEntity = function(char, plr)
    entitylib.removeEntity(char)
    entitylib.addEntity(char, plr)
end

entitylib.addPlayer = function(plr)
    if plr.Character then entitylib.refreshEntity(plr.Character, plr) end
    entitylib.PlayerConnections[plr] = {
        plr.CharacterAdded:Connect(function(char) entitylib.refreshEntity(char, plr) end),
        plr.CharacterRemoving:Connect(function(char) entitylib.removeEntity(char, plr == lplr) end),
        plr:GetPropertyChangedSignal("Team"):Connect(function()
            for _, v in entitylib.List do
                if v.Targetable ~= entitylib.targetCheck(v) then
                    entitylib.refreshEntity(v.Character, v.Player)
                end
            end
            if plr == lplr then entitylib.start()
            else entitylib.refreshEntity(plr.Character, plr) end
        end),
    }
end

entitylib.removePlayer = function(plr)
    if entitylib.PlayerConnections[plr] then
        for _, v in entitylib.PlayerConnections[plr] do v:Disconnect() end
        table.clear(entitylib.PlayerConnections[plr])
        entitylib.PlayerConnections[plr] = nil
    end
    entitylib.removeEntity(plr)
end

entitylib.start = function()
    if entitylib.Running then entitylib.stop() end
    tinsert(entitylib.Connections, playersService.PlayerAdded:Connect(function(v) entitylib.addPlayer(v) end))
    tinsert(entitylib.Connections, playersService.PlayerRemoving:Connect(function(v) entitylib.removePlayer(v) end))
    for _, v in playersService:GetPlayers() do entitylib.addPlayer(v) end
    tinsert(entitylib.Connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        gameCamera = workspace.CurrentCamera or workspace:FindFirstChildWhichIsA("Camera")
    end))
    entitylib.Running = true
end

entitylib.stop = function()
    for _, v in entitylib.Connections do v:Disconnect() end
    for _, v in entitylib.PlayerConnections do
        for _, v2 in v do v2:Disconnect() end
        table.clear(v)
    end
    entitylib.removeEntity(nil, true)
    local cloned = tclone(entitylib.List)
    for _, v in cloned do entitylib.removeEntity(v.Character) end
    for _, v in entitylib.EntityThreads do task.cancel(v) end
    table.clear(entitylib.PlayerConnections)
    table.clear(entitylib.EntityThreads)
    table.clear(entitylib.Connections)
    table.clear(cloned)
    entitylib.Running = false
end

entitylib.kill = function()
    if entitylib.Running then entitylib.stop() end
    for _, v in entitylib.Events do v:Destroy() end
end

-- ══════════════════════════════════════════════════════════════
-- VAPE: waitForBedwars  (extracted from paste #1 verbatim)
-- ══════════════════════════════════════════════════════════════
local function waitForBedwars()
    local attempts = 0
    while attempts < 100 do
        attempts = attempts + 1
        local success, knit = pcall(function()
            return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9)
        end)
        if success and knit then
            local startAttempts = 0
            while not debug.getupvalue(knit.Start, 1) and startAttempts < 50 do
                startAttempts = startAttempts + 1
                task.wait(0.1)
            end
            if debug.getupvalue(knit.Start, 1) then
                print("[PISTAV5] Bedwars loaded after " .. attempts .. " attempts")
                return knit
            end
        end
        task.wait(0.1)
    end
    warn("[PISTAV5] Bedwars failed to load")
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- VAPE: bedwars component table + store  (KA-relevant only)
-- Matches Vape's store/bedwars exactly for swingSwordAtMouse
-- ══════════════════════════════════════════════════════════════
local bedwars = {}
local bedwarsReady = false

-- store mirrors Vape's store (hand, inventory, hotbar only — KA needs these)
local vapeStore = {
    hand = { toolType = "", tool = nil, amount = 0 },
    inventory = { inventory = { items = {}, armor = {} }, hotbar = {}, hotbarSlot = 0 },
    equippedKit = "",
}

-- ── Vape: getItemMeta helper ──────────────────────────────────
local function getItemMeta(itemType)
    if bedwars.ItemMeta and bedwars.ItemMeta[itemType] then
        return bedwars.ItemMeta[itemType]
    end
    return nil
end

-- ── Vape: getSword (uses store.inventory.inventory.items like Vape) ──
local function vapeSword()
    local bestSword, bestSwordSlot, bestSwordDamage = nil, nil, 0
    local items = vapeStore.inventory.inventory and vapeStore.inventory.inventory.items or {}
    for slot, item in pairs(items) do
        local meta = getItemMeta(item.itemType)
        if meta and meta.sword then
            local dmg = meta.sword.damage or 0
            if dmg > bestSwordDamage then
                bestSword, bestSwordSlot, bestSwordDamage = item, slot, dmg
            end
        end
    end
    return bestSword, bestSwordSlot
end

-- ── Vape: hasSwordEquipped (ItemMeta hotbar check — exact from paste #1) ──
local function hasSwordEquipped()
    local inv = vapeStore.inventory
    if not inv or not inv.hotbar then return false end
    local hotbarSlot = inv.hotbarSlot
    if hotbarSlot == nil then return false end
    local slotItem = inv.hotbar[hotbarSlot + 1]
    if not slotItem or not slotItem.item then return false end
    local meta = getItemMeta(slotItem.item.itemType)
    return meta and meta.sword ~= nil
end

-- ── Vape: updateStore (matches paste #1 updateStore exactly) ──
local function vapeUpdateStore(new, old)
    if new.Bedwars ~= old.Bedwars then
        vapeStore.equippedKit = (new.Bedwars and new.Bedwars.kit ~= "none") and new.Bedwars.kit or ""
    end
    if new.Inventory ~= old.Inventory then
        local newinv = (new.Inventory and new.Inventory.observedInventory) or { inventory = {} }
        local oldinv = (old.Inventory and old.Inventory.observedInventory) or { inventory = {} }
        vapeStore.inventory = newinv

        if newinv ~= oldinv then
            vapeEvents.InventoryChanged:Fire()
        end

        if newinv.inventory and oldinv.inventory and newinv.inventory.hand ~= oldinv.inventory.hand then
            local currentHand = newinv.inventory.hand
            local toolType = ""
            if currentHand then
                local handData = getItemMeta(currentHand.itemType)
                if handData then
                    toolType = handData.sword and "sword"
                           or handData.block and "block"
                           or (currentHand.itemType:find("bow") and "bow" or "")
                end
            end
            vapeStore.hand = {
                tool     = currentHand and currentHand.tool,
                amount   = currentHand and currentHand.amount or 0,
                toolType = toolType,
            }
        end
    end
end

-- ══════════════════════════════════════════════════════════════
-- VAPE: HitFix — hookClientGet (extracted from paste #1 verbatim)
-- Adjusts selfPosition toward target with ping compensation on
-- every AttackEntity FireServer call, exactly as Vape does it.
-- ══════════════════════════════════════════════════════════════
local OldGet     = nil
local remotes    = {}
local HitFixEnabled = true   -- controlled by ka.hitfix toggle at runtime

local function getPingMs()
    local ping = 0
    pcall(function()
        ping = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    return ping
end

local function hookClientGet()
    if not bedwars.Client or OldGet then return end
    OldGet = bedwars.Client.Get
    bedwars.Client.Get = function(self, remoteName)
        local call = OldGet(self, remoteName)
        if remoteName == (remotes.AttackEntity or "AttackEntity") then
            return {
                instance = call.instance,
                SendToServer = function(_, attackTable, ...)
                    if attackTable and attackTable.validate and HitFixEnabled then
                        local selfpos   = attackTable.validate.selfPosition   and attackTable.validate.selfPosition.value
                        local targetpos = attackTable.validate.targetPosition and attackTable.validate.targetPosition.value
                        if selfpos and targetpos then
                            local distance         = (selfpos - targetpos).Magnitude
                            local pingCompensation = math.min(getPingMs() / 1000 * 50, 8)
                            local adjustmentDist   = math.max(distance - 12, 0) + pingCompensation
                            if adjustmentDist > 0 then
                                local direction = CFrame.lookAt(selfpos, targetpos).LookVector
                                attackTable.validate.selfPosition.value = selfpos + (direction * adjustmentDist)
                                if pingCompensation > 2 then
                                    attackTable.validate.targetPosition.value = targetpos - (direction * math.min(pingCompensation * 0.3, 2))
                                end
                            end
                        end
                    end
                    return call:SendToServer(attackTable, ...)
                end,
            }
        end
        return call
    end
end

-- ══════════════════════════════════════════════════════════════
-- VAPE: HitBoxes — applySwordHitbox  (Vape "Sword" mode)
-- Uses debug.setconstant on swingSwordInRegion constant index 6.
-- Exactly as paste #1 applySwordHitbox does it.
-- ══════════════════════════════════════════════════════════════
local hitboxSet = nil
local HITBOX_DEFAULT_CONSTANT = 3.8

local function applySwordHitbox(enabled, expandAmount)
    if not bedwars.SwordController or not bedwars.SwordController.swingSwordInRegion then return false end
    local success = pcall(function()
        if enabled then
            debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, (expandAmount or 38) / 3)
            hitboxSet = true
        else
            debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, HITBOX_DEFAULT_CONSTANT)
            hitboxSet = nil
        end
    end)
    return success
end

-- ══════════════════════════════════════════════════════════════
-- VAPE: Reach patch — CombatConstant  (from paste #1 setupHitFix)
-- Expands RAYCAST_SWORD_CHARACTER_DISTANCE to match Vape's reach
-- ══════════════════════════════════════════════════════════════
local originalReachDistance = nil
local originalFunctions     = {}

local function applyReachPatch(enabled)
    pcall(function()
        if bedwars.CombatConstant then
            if enabled then
                if originalReachDistance == nil then
                    originalReachDistance = bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE
                end
                local pingMult = getPingMs() < 50 and 1.0 or getPingMs() < 100 and 1.2 or getPingMs() < 200 and 1.5 or 2.0
                bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = 18 + math.min(2 * pingMult, 6)
            else
                if originalReachDistance ~= nil then
                    bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = originalReachDistance
                end
            end
        end
    end)
end

local function applyDebugPatch(enabled)
    pcall(function()
        if bedwars.SwordController and bedwars.SwordController.swingSwordAtMouse then
            debug.setconstant(bedwars.SwordController.swingSwordAtMouse, 23, enabled and "raycast" or "Raycast")
            debug.setupvalue(bedwars.SwordController.swingSwordAtMouse, 4, enabled and (bedwars.QueryUtil or workspace) or workspace)
        end
    end)
end

-- ══════════════════════════════════════════════════════════════
-- VAPE: setupBedwars  (KA-relevant components only from paste #1)
-- Loads: SwordController, ItemMeta, Store, Client, CombatConstant,
--        QueryUtil, KnockbackUtil. Wires store listener.
-- ══════════════════════════════════════════════════════════════
task.spawn(function()
    local knit = waitForBedwars()
    if not knit then return end

    local ok = pcall(function()
        -- SwordController: provides swingSwordAtMouse + swingSwordInRegion
        bedwars.SwordController = knit.Controllers.SwordController

        -- ItemMeta: sword/block type detection (hasSwordEquipped uses this)
        bedwars.ItemMeta = debug.getupvalue(
            require(ReplicatedStorage.TS.item["item-meta"]).getItemMeta, 1
        )

        -- Redux store: hand/hotbar state tracking
        bedwars.Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore

        -- Client remotes: needed by hookClientGet (HitFix)
        bedwars.Client = require(ReplicatedStorage.TS.remotes).default.Client

        -- QueryUtil: optional, for debug patch on swingSwordAtMouse
        pcall(function()
            bedwars.QueryUtil = require(
                ReplicatedStorage["rbxts_include"]["node_modules"]["@easy-games"]["game-core"].out
            ).GameQueryUtil
        end)

        -- CombatConstant: reach distance — try all 3 Vape paths
        local comboPaths = {
            function() return require(ReplicatedStorage.TS.combat["combat-constant"]).CombatConstant end,
            function() return require(ReplicatedStorage.TS.combat.CombatConstant) end,
            function() return knit.Controllers.SwordController.CombatConstant end,
        }
        for _, fn in ipairs(comboPaths) do
            local s, r = pcall(fn)
            if s and r and r.RAYCAST_SWORD_CHARACTER_DISTANCE then
                bedwars.CombatConstant = r; break
            end
        end

        -- Dump AttackEntity remote name (Vape pattern from paste #1)
        pcall(function()
            local function dumpRemote(tab)
                for i, v in tab do
                    if v == "Client" then return tab[i + 1] end
                end
                return ""
            end
            local r = dumpRemote(debug.getconstants(bedwars.SwordController.sendServerRequest or function() end))
            if r and r ~= "" then remotes.AttackEntity = r end
        end)

        -- Wire store listener (matches paste #1 pcall block exactly)
        pcall(function()
            local storeConn = bedwars.Store.changed:connect(vapeUpdateStore)
            vapeUpdateStore(bedwars.Store:getState(), {})
        end)
    end)

    if ok then
        bedwarsReady = true
        applyReachPatch(true)
        applyDebugPatch(true)
        hookClientGet()
        print("[PISTAV5] Vape KA Engine ready")
    else
        warn("[PISTAV5] Bedwars setup failed — FireServer fallback will be used")
    end
end)

-- ══════════════════════════════════════════════════════════════
-- SPLASH SCREEN  (V4 identical — only text updated to V5)
-- ══════════════════════════════════════════════════════════════
local splashGui = Instance.new("ScreenGui")
splashGui.Name           = "WolfVXPE_Splash"
splashGui.ResetOnSpawn   = false
splashGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
splashGui.Parent          = CoreGui

local splashFrame = Instance.new("Frame", splashGui)
splashFrame.Size                    = UDim2.new(0, 400, 0, 110)
splashFrame.Position                = UDim2.new(0.5, -200, 0.5, -55)
splashFrame.BackgroundColor3        = Color3.fromRGB(8, 8, 14)
splashFrame.BackgroundTransparency  = 0
splashFrame.BorderSizePixel         = 0

Instance.new("UICorner", splashFrame).CornerRadius = UDim.new(0, 12)

local sStroke = Instance.new("UIStroke", splashFrame)
sStroke.Color     = Color3.fromRGB(255, 80, 80)
sStroke.Thickness = 1.6

local sGrad = Instance.new("UIGradient", splashFrame)
sGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(12, 6, 22)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(28, 10, 40)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(12, 6, 22)),
})
sGrad.Rotation = 45

local sTitleLbl = Instance.new("TextLabel", splashFrame)
sTitleLbl.Size               = UDim2.new(1, -20, 0, 40)
sTitleLbl.Position           = UDim2.new(0, 10, 0, 8)
sTitleLbl.BackgroundTransparency = 1
sTitleLbl.Text               = "WOLFVXPE  —  PISTA V5"
sTitleLbl.TextColor3         = Color3.fromRGB(255, 80, 80)
sTitleLbl.TextStrokeColor3   = Color3.fromRGB(120, 20, 20)
sTitleLbl.TextStrokeTransparency = 0.4
sTitleLbl.Font               = Enum.Font.GothamBlack
sTitleLbl.TextSize           = 22
sTitleLbl.TextXAlignment     = Enum.TextXAlignment.Left
sTitleLbl.TextTransparency   = 1

local sSubLbl = Instance.new("TextLabel", splashFrame)
sSubLbl.Size               = UDim2.new(1, -20, 0, 14)
sSubLbl.Position           = UDim2.new(0, 10, 0, 52)
sSubLbl.BackgroundTransparency = 1
sSubLbl.Text               = "Vape KA Engine  •  Aim Assist  •  ESP  •  FPS  |  pistademon"
sSubLbl.TextColor3         = Color3.fromRGB(210, 155, 155)
sSubLbl.Font               = Enum.Font.Gotham
sSubLbl.TextSize           = 11
sSubLbl.TextXAlignment     = Enum.TextXAlignment.Left
sSubLbl.TextTransparency   = 1

local sBarBg = Instance.new("Frame", splashFrame)
sBarBg.Size             = UDim2.new(1, -20, 0, 3)
sBarBg.Position         = UDim2.new(0, 10, 0, 88)
sBarBg.BackgroundColor3 = Color3.fromRGB(40, 18, 18)
sBarBg.BorderSizePixel  = 0
Instance.new("UICorner", sBarBg).CornerRadius = UDim.new(1, 0)

local sBar = Instance.new("Frame", sBarBg)
sBar.Size             = UDim2.new(0, 0, 1, 0)
sBar.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
sBar.BorderSizePixel  = 0
Instance.new("UICorner", sBar).CornerRadius = UDim.new(1, 0)

local fadeIn = TweenInfo.new(0.35, Enum.EasingStyle.Quad)
TweenService:Create(sTitleLbl, fadeIn, {TextTransparency = 0}):Play()
task.wait(0.1)
TweenService:Create(sSubLbl, fadeIn, {TextTransparency = 0}):Play()
TweenService:Create(sBar, TweenInfo.new(2.5, Enum.EasingStyle.Quad), {Size = UDim2.new(1, 0, 1, 0)}):Play()

-- ══════════════════════════════════════════════════════════════
-- LOAD UI LIBRARY  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/x2zu/OPEN-SOURCE-UI-ROBLOX/refs/heads/main/X2ZU%20UI%20ROBLOX%20OPEN%20SOURCE/DummyUi-leak-by-x2zu/fetching-main/Tools/Framework.luau"
))()

-- ══════════════════════════════════════════════════════════════
-- WINDOW  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local Window = Library:Window({
    Title  = "WOLFVXPE V5",
    Desc   = "Vape KA Engine  •  Aim Assist  •  ESP  •  FPS  |  pistademon",
    Icon   = 105059922903197,
    Theme  = "Dark",
    Config = {
        Keybind = Enum.KeyCode.RightShift,
        Size    = UDim2.new(0, 600, 0, 480),
    },
    CloseUIButton = { Enabled = true, Text = "wolf" },
})

-- ══════════════════════════════════════════════════════════════
-- STATE TABLES
-- ══════════════════════════════════════════════════════════════

-- ── Kill Aura — V4 base options + all Vape KA additions ───────
local ka = {
    -- V4 original options
    enabled      = P("ka_enabled",      false),
    range        = P("ka_range",        16),
    teamCheck    = P("ka_teamCheck",    true),
    delay        = P("ka_delay",        0.05),
    angleDeg     = P("ka_angle",        180),
    requireMouse = P("ka_requireMouse", false),
    limitToItems = P("ka_limitToItems", false),
    ignoreWalls  = P("ka_ignoreWalls",  false),
    multiHit     = P("ka_multiHit",     true),
    -- Vape additions
    hitfix        = P("ka_hitfix",        true),   -- HitFix: selfPosition ping compensation
    hitboxes      = P("ka_hitboxes",      false),  -- HitBoxes: expand swingSwordInRegion constant
    hitboxExpand  = P("ka_hitboxExpand",  38),     -- HitBoxes expand amount (Vape default 38)
    useSwingMode  = P("ka_useSwingMode",  true),   -- swingSwordAtMouse (Vape) vs FireServer fallback
}

-- ── KB Reducer  (V4 identical) ────────────────────────────────
local kb = {
    enabled      = P("kb_enabled",   false),
    strength     = P("kb_strength",  0.25),
    lastVelocity = Vector3.zero,
}

-- ── Aim Assist  (V4 identical) ────────────────────────────────
local aim = {
    enabled   = P("aim_enabled",   false),
    teamCheck = P("aim_teamCheck", false),
    range     = P("aim_range",     60),
    smoothing = P("aim_smoothing", 0.08),
    headAim   = P("aim_headAim",   true),
    target    = nil,
}

-- ── ESP  (V4 identical) ───────────────────────────────────────
local esp = {
    enabled   = P("esp_enabled",   true),
    chams     = P("esp_chams",     true),
    names     = P("esp_names",     true),
    health    = P("esp_health",    true),
    distance  = P("esp_distance",  true),
    fillAlpha = P("esp_fillAlpha", 0.6),
    objects   = {},
}

-- ── FPS  (V4 identical) ───────────────────────────────────────
local fpsState = {
    greysky     = P("fps_greysky",     false),
    greyplayers = P("fps_greyplayers", false),
    noshadows   = P("fps_noshadows",   false),
}

-- ══════════════════════════════════════════════════════════════
-- PROFILE COLLECT + SAVE  (expanded with Vape KA keys)
-- ══════════════════════════════════════════════════════════════
local function collectAndSave()
    saveProfile({
        ka_enabled      = ka.enabled,
        ka_range        = ka.range,
        ka_teamCheck    = ka.teamCheck,
        ka_delay        = ka.delay,
        ka_angle        = ka.angleDeg,
        ka_requireMouse = ka.requireMouse,
        ka_limitToItems = ka.limitToItems,
        ka_ignoreWalls  = ka.ignoreWalls,
        ka_multiHit     = ka.multiHit,
        ka_hitfix       = ka.hitfix,
        ka_hitboxes     = ka.hitboxes,
        ka_hitboxExpand = ka.hitboxExpand,
        ka_useSwingMode = ka.useSwingMode,
        kb_enabled      = kb.enabled,
        kb_strength     = kb.strength,
        aim_enabled     = aim.enabled,
        aim_teamCheck   = aim.teamCheck,
        aim_range       = aim.range,
        aim_smoothing   = aim.smoothing,
        aim_headAim     = aim.headAim,
        esp_enabled     = esp.enabled,
        esp_chams       = esp.chams,
        esp_names       = esp.names,
        esp_health      = esp.health,
        esp_distance    = esp.distance,
        esp_fillAlpha   = esp.fillAlpha,
        fps_greysky     = fpsState.greysky,
        fps_greyplayers = fpsState.greyplayers,
        fps_noshadows   = fpsState.noshadows,
    })
end

-- Auto-save every 10 s
task.spawn(function()
    while true do task.wait(10); collectAndSave() end
end)

-- ══════════════════════════════════════════════════════════════
-- TAB: KILL AURA  (Vape KA Engine — replaces V4 KA UI)
-- ══════════════════════════════════════════════════════════════
local KATab = Window:Tab({ Title = "Kill Aura", Icon = "zap" })

KATab:Section({ Title = "Kill Aura  [Q to toggle]  —  Vape Engine" })

KATab:Toggle({
    Title    = "Enable Kill Aura",
    Desc     = "Vape swingSwordAtMouse engine. Toggle with Q.",
    Value    = ka.enabled,
    Callback = function(v) ka.enabled = v; collectAndSave() end,
})

KATab:Toggle({
    Title    = "Team Check",
    Desc     = "Only attack players on the opposing team.",
    Value    = ka.teamCheck,
    Callback = function(v) ka.teamCheck = v; collectAndSave() end,
})

KATab:Toggle({
    Title    = "Multi-Hit (all in range)",
    Desc     = "Hit every valid enemy per tick instead of just the closest.",
    Value    = ka.multiHit,
    Callback = function(v) ka.multiHit = v; collectAndSave() end,
})

KATab:Section({ Title = "Fire Method" })

KATab:Toggle({
    Title    = "Vape SwingMode (swingSwordAtMouse)",
    Desc     = "ON = Vape native swingSwordAtMouse (goes through game pipeline — most legit).\nOFF = raw FireServer AttackEntity fallback.",
    Value    = ka.useSwingMode,
    Callback = function(v) ka.useSwingMode = v; collectAndSave() end,
})

KATab:Section({ Title = "HitFix  (Vape AttackEntity Hook)" })

KATab:Toggle({
    Title    = "Enable HitFix",
    Desc     = "Adjusts selfPosition toward target with ping compensation on every hit. Mirrors Vape hookClientGet exactly.",
    Value    = ka.hitfix,
    Callback = function(v)
        ka.hitfix    = v
        HitFixEnabled = v
        collectAndSave()
    end,
})

KATab:Section({ Title = "HitBoxes  (Vape swingSwordInRegion)" })

KATab:Toggle({
    Title    = "Enable HitBoxes",
    Desc     = "Expands the sword swing region constant in swingSwordInRegion via debug.setconstant. Exact Vape Sword mode.",
    Value    = ka.hitboxes,
    Callback = function(v)
        ka.hitboxes = v
        if bedwarsReady then
            applySwordHitbox(v, ka.hitboxExpand)
        end
        collectAndSave()
    end,
})

KATab:Slider({
    Title    = "HitBox Expand Amount",
    Desc     = "How much to expand the sword region constant. Vape default is 38.",
    Min = 5, Max = 80, Rounding = 0, Value = ka.hitboxExpand,
    Callback = function(v)
        ka.hitboxExpand = v
        if ka.hitboxes and bedwarsReady then
            applySwordHitbox(true, v)
        end
        collectAndSave()
    end,
})

KATab:Section({ Title = "Range & Angle" })

KATab:Slider({
    Title    = "Range (studs)",
    Desc     = "How far Kill Aura reaches. Vape default is ~16 studs.",
    Min = 4, Max = 30, Rounding = 0, Value = ka.range,
    Callback = function(v) ka.range = v; collectAndSave() end,
})

KATab:Slider({
    Title    = "Angle (degrees)",
    Desc     = "FOV cone in front of you. 45 = narrow  360 = all-around.",
    Min = 45, Max = 360, Rounding = 0, Value = ka.angleDeg,
    Callback = function(v) ka.angleDeg = v; collectAndSave() end,
})

KATab:Section({ Title = "Timing" })

KATab:Slider({
    Title    = "Hitreg Delay (ms)",
    Desc     = "Gap between hit cycles. Lower = faster. Vape fires on LMB held; this is the loop rate.",
    Min = 20, Max = 500, Rounding = 0, Value = ka.delay * 1000,
    Callback = function(v) ka.delay = v / 1000; collectAndSave() end,
})

KATab:Section({ Title = "Conditions" })

KATab:Toggle({
    Title    = "Require LMB (Left Click)",
    Desc     = "Kill Aura only fires while Left Mouse Button is held.",
    Value    = ka.requireMouse,
    Callback = function(v) ka.requireMouse = v; collectAndSave() end,
})

KATab:Toggle({
    Title    = "Limit to Sword Items",
    Desc     = "Only fires when a sword is equipped. Uses Vape's ItemMeta hotbar check when bedwars is loaded.",
    Value    = ka.limitToItems,
    Callback = function(v) ka.limitToItems = v; collectAndSave() end,
})

KATab:Toggle({
    Title    = "Ignore Behind Walls",
    Desc     = "Raycasts to target — skips enemies blocked by geometry.",
    Value    = ka.ignoreWalls,
    Callback = function(v) ka.ignoreWalls = v; collectAndSave() end,
})

KATab:Section({ Title = "Info" })
KATab:Code({
    Title = "Vape KA Engine Notes",
    Code  = [[-- Q                -> toggle Kill Aura on/off
--
-- SwingMode ON  : swingSwordAtMouse() — exact Vape AutoClicker call
--                 camera briefly points at target, game handles hitbox
--                 passes all server-side validation naturally
-- SwingMode OFF : raw FireServer AttackEntity fallback
--
-- HitFix        : nudges selfPosition toward target by
--                 (distance - 12) + pingCompensation studs
--                 mirrors Vape hookClientGet exactly
--
-- HitBoxes      : debug.setconstant(swingSwordInRegion, 6, expand/3)
--                 Vape Sword mode — expands server swing region
--
-- entitylib     : full Vape entity tracking for target finding
-- hasSwordEquipped: Vape ItemMeta hotbar slot check
-- RightShift    : open/close menu]],
})

-- ══════════════════════════════════════════════════════════════
-- TAB: COMBAT  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local CombatTab = Window:Tab({ Title = "Combat", Icon = "crosshair" })

CombatTab:Section({ Title = "Knockback Reducer" })

CombatTab:Toggle({
    Title    = "Enable KB Reducer",
    Desc     = "Dampens horizontal knockback on hit.",
    Value    = kb.enabled,
    Callback = function(v) kb.enabled = v; collectAndSave() end,
})

CombatTab:Slider({
    Title = "Reduction Strength %",
    Min = 0, Max = 100, Rounding = 0, Value = mfloor(kb.strength * 100),
    Callback = function(v) kb.strength = v / 100; collectAndSave() end,
})

CombatTab:Section({ Title = "Aim Assist  [R to toggle]" })

CombatTab:Toggle({
    Title    = "Enable Aim Assist",
    Desc     = "Locks camera to nearest enemy. Toggle with R.",
    Value    = aim.enabled,
    Callback = function(v) aim.enabled = v; if not v then aim.target = nil end; collectAndSave() end,
})

CombatTab:Toggle({
    Title = "Team Check",
    Value = aim.teamCheck,
    Callback = function(v) aim.teamCheck = v; collectAndSave() end,
})

CombatTab:Toggle({
    Title = "Head Aim",
    Desc  = "Target the head instead of body centre.",
    Value = aim.headAim,
    Callback = function(v) aim.headAim = v; collectAndSave() end,
})

CombatTab:Slider({
    Title = "Aim Range (studs)",
    Min = 10, Max = 500, Rounding = 0, Value = aim.range,
    Callback = function(v) aim.range = v; collectAndSave() end,
})

CombatTab:Slider({
    Title = "Camera Smoothing",
    Desc  = "0 = instant snap  100 = very slow follow.",
    Min = 0, Max = 100, Rounding = 0, Value = mfloor(aim.smoothing * 100),
    Callback = function(v) aim.smoothing = v / 100; collectAndSave() end,
})

-- ══════════════════════════════════════════════════════════════
-- TAB: ESP  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local ESPTab = Window:Tab({ Title = "ESP", Icon = "eye" })

ESPTab:Section({ Title = "ESP Options" })

ESPTab:Toggle({
    Title    = "Enable ESP",
    Value    = esp.enabled,
    Callback = function(v)
        esp.enabled = v
        if not v then
            for _, d in pairs(esp.objects) do
                if d.hl and d.hl.Parent then d.hl:Destroy() end
                if d.bb and d.bb.Parent then d.bb:Destroy() end
            end
            esp.objects = {}
        end
        collectAndSave()
    end,
})

ESPTab:Toggle({
    Title    = "Highlight / Chams",
    Value    = esp.chams,
    Callback = function(v)
        esp.chams = v
        for _, d in pairs(esp.objects) do
            if d.hl then d.hl.FillTransparency = v and esp.fillAlpha or 1 end
        end
        collectAndSave()
    end,
})

ESPTab:Toggle({
    Title = "Show Names",
    Value = esp.names,
    Callback = function(v) esp.names = v; collectAndSave() end,
})

ESPTab:Toggle({
    Title = "Show Health",
    Value = esp.health,
    Callback = function(v) esp.health = v; collectAndSave() end,
})

ESPTab:Toggle({
    Title = "Show Distance",
    Value = esp.distance,
    Callback = function(v) esp.distance = v; collectAndSave() end,
})

ESPTab:Slider({
    Title = "Fill Transparency",
    Min = 0, Max = 100, Rounding = 0, Value = mfloor(esp.fillAlpha * 100),
    Callback = function(v)
        esp.fillAlpha = v / 100
        for _, d in pairs(esp.objects) do
            if d.hl and esp.chams then d.hl.FillTransparency = esp.fillAlpha end
        end
        collectAndSave()
    end,
})

-- ══════════════════════════════════════════════════════════════
-- TAB: FPS BOOST  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local FPSTab = Window:Tab({ Title = "FPS Boost", Icon = "trending-up" })

FPSTab:Section({ Title = "Visual Optimisation" })

FPSTab:Toggle({
    Title    = "Grey Sky",
    Desc     = "Removes skybox and atmosphere — big FPS gain.",
    Value    = fpsState.greysky,
    Callback = function(v)
        fpsState.greysky = v
        if v then
            local sky  = Lighting:FindFirstChildOfClass("Sky")
            local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
            if sky  then sky:Destroy() end
            if atmo then atmo:Destroy() end
            Lighting.GlobalShadows            = false
            Lighting.FogEnd                   = 100000
            Lighting.Brightness               = 0.8
            Lighting.ClockTime                = 12
            Lighting.ShadowSoftness           = 0
            Lighting.OutdoorAmbient           = Color3.fromRGB(50, 50, 50)
            Lighting.Ambient                  = Color3.fromRGB(40, 40, 40)
            Lighting.EnvironmentDiffuseScale  = 0
            Lighting.EnvironmentSpecularScale = 0
        else
            Lighting.GlobalShadows            = true
            Lighting.EnvironmentDiffuseScale  = 1
            Lighting.EnvironmentSpecularScale = 1
        end
        collectAndSave()
    end,
})

FPSTab:Toggle({
    Title    = "Disable Shadows",
    Value    = fpsState.noshadows,
    Callback = function(v)
        fpsState.noshadows = v
        Lighting.GlobalShadows = not v
        collectAndSave()
    end,
})

FPSTab:Toggle({
    Title    = "Grey Players",
    Desc     = "Strips accessories and clothing from other players.",
    Value    = fpsState.greyplayers,
    Callback = function(v)
        fpsState.greyplayers = v
        local function grey(char)
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") then
                    p.BrickColor   = BrickColor.new("Medium stone grey")
                    p.Material     = Enum.Material.SmoothPlastic
                    p.Reflectance  = 0
                    for _, child in ipairs(p:GetChildren()) do
                        if (child:IsA("Decal") and child.Name ~= "face") or child:IsA("Texture") then
                            child:Destroy()
                        end
                    end
                end
                if p:IsA("Shirt") or p:IsA("Pants") or p:IsA("ShirtGraphic")
                or p:IsA("Accessory") or p:IsA("Hat") or p:IsA("Hair") then
                    p:Destroy()
                end
            end
        end
        if v then
            for _, pl in ipairs(Players:GetPlayers()) do
                if pl ~= LocalPlayer and pl.Character then grey(pl.Character) end
            end
        end
        collectAndSave()
    end,
})

FPSTab:Button({
    Title    = "FullBright",
    Callback = function()
        local function fb()
            Lighting.Ambient           = Color3.new(1, 1, 1)
            Lighting.ColorShift_Bottom = Color3.new(1, 1, 1)
            Lighting.ColorShift_Top    = Color3.new(1, 1, 1)
        end
        fb()
        Lighting.LightingChanged:Connect(fb)
        Window:Notify({ Title = "FullBright", Desc = "Enabled!", Time = 2 })
    end,
})

FPSTab:Button({
    Title    = "Nuclear FPS Boost",
    Desc     = "Removes all particles, decals, reflections and effects.",
    Callback = function()
        local t = workspace.Terrain
        t.WaterWaveSize      = 0; t.WaterWaveSpeed    = 0
        t.WaterReflectance   = 0; t.WaterTransparency = 0
        Lighting.GlobalShadows = false; Lighting.FogEnd = 9e9; Lighting.Brightness = 0
        pcall(function() settings().Rendering.QualityLevel = "Level01" end)
        for _, v in ipairs(game:GetDescendants()) do
            pcall(function()
                if v:IsA("BasePart") or v:IsA("MeshPart") or v:IsA("UnionOperation") then
                    v.Material    = Enum.Material.Plastic
                    v.Reflectance = 0
                    if v:IsA("MeshPart") then v.TextureID = "" end
                elseif v:IsA("Decal") or v:IsA("Texture") then
                    v.Transparency = 1
                elseif v:IsA("ParticleEmitter") or v:IsA("Trail") then
                    v.Lifetime = NumberRange.new(0)
                elseif v:IsA("Fire") or v:IsA("Smoke") or v:IsA("SpotLight") then
                    v.Enabled = false
                end
            end)
        end
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("ColorCorrectionEffect")
            or e:IsA("BloomEffect") or e:IsA("DepthOfFieldEffect") then
                e.Enabled = false
            end
        end
        Window:Notify({ Title = "FPS", Desc = "Nuclear boost applied!", Time = 3 })
    end,
})

FPSTab:Section({ Title = "Live Stats" })
local diagBlock = FPSTab:Code({ Title = "FPS / Ping", Code = "Measuring..." })

-- ══════════════════════════════════════════════════════════════
-- TAB: CREDITS  (V4 identical — updated to V5)
-- ══════════════════════════════════════════════════════════════
local CredTab = Window:Tab({ Title = "Credits", Icon = "star" })
CredTab:Section({ Title = "WOLFVXPE — PISTA V5" })
CredTab:Code({
    Title = "About",
    Code  = [[-- WOLFVXPE (PISTA V5)
-- Originally by : pistademon  (Discord)
-- Rewritten & Enhanced Edition
--
-- Kill Aura  — Vape engine: swingSwordAtMouse + HitFix + HitBoxes
-- KB Reducer — knockback damping
-- Aim Assist — smooth camera lock  [R]
-- ESP        — highlight + name/HP/distance
-- FPS Boost  — sky / players / nuclear / fullbright
-- Profiles   — settings auto-saved & restored
--
-- Keybinds:
--   RightShift  ->  open / close menu
--   Q           ->  toggle Kill Aura
--   R           ->  toggle Aim Assist]],
})

CredTab:Button({
    Title    = "Re-show Notice",
    Callback = function()
        Window:Notify({ Title = "WOLFVXPE V5", Desc = "Made by pistademon — Vape KA Engine", Time = 4 })
    end,
})

CredTab:Button({
    Title    = "Save Profile Now",
    Desc     = "Force-save current settings to file.",
    Callback = function()
        collectAndSave()
        Window:Notify({ Title = "Profile", Desc = "Settings saved!", Time = 2 })
    end,
})

Window:Line()

-- ══════════════════════════════════════════════════════════════
-- ESP LOGIC  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local ESPFolder    = Instance.new("Folder", PlayerGui)
ESPFolder.Name     = "WolfVXPE_ESP"

local function espColor(player)
    if player.Team then return player.Team.TeamColor.Color end
    return Color3.fromRGB(255, 55, 55)
end

local function createESPFor(player)
    if esp.objects[player] then return end
    local char = player.Character; if not char then return end
    local pRoot = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    if not pRoot then return end

    local hl = Instance.new("Highlight", ESPFolder)
    hl.Adornee             = char
    hl.FillColor           = Color3.fromRGB(10, 10, 10)
    hl.OutlineColor        = espColor(player)
    hl.FillTransparency    = esp.chams and esp.fillAlpha or 1
    hl.OutlineTransparency = 0
    hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop

    local bb = Instance.new("BillboardGui", ESPFolder)
    bb.Adornee      = pRoot
    bb.Size         = UDim2.new(0, 140, 0, 50)
    bb.StudsOffset  = Vector3.new(0, 3.8, 0)
    bb.AlwaysOnTop  = true
    bb.ResetOnSpawn = false

    local nl = Instance.new("TextLabel", bb)
    nl.Size                   = UDim2.new(1, 0, 0, 18)
    nl.BackgroundTransparency = 1
    nl.TextStrokeTransparency = 0.3
    nl.Font                   = Enum.Font.GothamBold
    nl.TextColor3             = Color3.fromRGB(255, 255, 255)
    nl.TextSize               = 13
    nl.Text                   = player.Name

    local il = Instance.new("TextLabel", bb)
    il.Size                   = UDim2.new(1, 0, 0, 13)
    il.Position               = UDim2.new(0, 0, 0, 20)
    il.BackgroundTransparency = 1
    il.TextStrokeTransparency = 0.5
    il.Font                   = Enum.Font.Gotham
    il.TextColor3             = Color3.fromRGB(195, 195, 195)
    il.TextSize               = 11
    il.Text                   = ""

    esp.objects[player] = { hl = hl, bb = bb, nl = nl, il = il }
end

local function removeESPFor(player)
    local d = esp.objects[player]; if not d then return end
    if d.hl and d.hl.Parent then d.hl:Destroy() end
    if d.bb and d.bb.Parent then d.bb:Destroy() end
    esp.objects[player] = nil
end

local espRefreshTimer = 0
local function refreshESP(dt)
    espRefreshTimer += dt
    if espRefreshTimer < 3 then return end
    espRefreshTimer = 0

    for p in pairs(esp.objects) do
        if not p.Parent then removeESPFor(p) end
    end
    if not esp.enabled then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and not esp.objects[p] then
            createESPFor(p)
        end
    end
end

local function updateESP()
    if not esp.enabled then return end
    local root = getRoot()
    for player, data in pairs(esp.objects) do
        local char  = player.Character
        local hum   = char and char:FindFirstChild("Humanoid")
        local pRoot = char and char:FindFirstChild("HumanoidRootPart")
        if not char or not hum or hum.Health <= 0 or not pRoot then
            removeESPFor(player); continue
        end
        if data.hl.Adornee ~= char then
            data.hl.Adornee = char
            data.bb.Adornee = pRoot
        end
        data.hl.OutlineColor     = espColor(player)
        data.hl.FillTransparency = esp.chams and esp.fillAlpha or 1
        data.nl.Visible          = esp.names
        data.nl.Text             = player.Name

        local parts = {}
        if esp.health then
            parts[#parts + 1] = string.format("HP %d/%d", mfloor(hum.Health), mfloor(hum.MaxHealth))
        end
        if esp.distance and root then
            parts[#parts + 1] = mfloor((root.Position - pRoot.Position).Magnitude) .. "m"
        end
        data.il.Visible = #parts > 0
        data.il.Text    = table.concat(parts, "  ")
    end
end

-- ══════════════════════════════════════════════════════════════
-- AIM ASSIST  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local function isAimEnemy(p)
    if not aim.teamCheck then return true end
    return p.Team ~= LocalPlayer.Team or p.Team == nil or LocalPlayer.Team == nil
end

local function getAimTarget()
    local root = getRoot(); if not root then return nil end
    local bestDist, best = aim.range, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer or not isAimEnemy(p) then continue end
        local char  = p.Character
        local hum   = char and char:FindFirstChild("Humanoid")
        local pRoot = char and char:FindFirstChild("HumanoidRootPart")
        if not char or not hum or hum.Health <= 0 or not pRoot then continue end
        local d = (root.Position - pRoot.Position).Magnitude
        if d < bestDist then bestDist = d; best = p end
    end
    return best
end

local function doAimAssist()
    if not aim.enabled then return end
    if aim.target and aim.target.Character then
        local hum = aim.target.Character:FindFirstChild("Humanoid")
        if not hum or hum.Health <= 0 then aim.target = nil end
    end
    if not aim.target then aim.target = getAimTarget() end
    if not aim.target then return end
    local char = aim.target.Character; if not char then return end
    local bone = (aim.headAim and char:FindFirstChild("Head")) or char:FindFirstChild("HumanoidRootPart")
    if not bone then return end
    local tgt = cf3new(Camera.CFrame.Position, bone.Position)
    Camera.CFrame = aim.smoothing < 0.01 and tgt or Camera.CFrame:Lerp(tgt, 1 - aim.smoothing)
end

-- ══════════════════════════════════════════════════════════════
-- KILL AURA  —  VAPE ENGINE
--
-- How it works:
--   Method 1 (SwingMode ON — Vape native):
--     Iterates entitylib.List for valid Targetable entities in
--     range/angle/wall. For each target, temporarily redirects
--     Camera.CFrame so swingSwordAtMouse() hits that entity,
--     then immediately restores Camera. This is the EXACT same
--     call Vape's AutoClicker makes (toolType == 'sword' branch).
--     The game's full sword pipeline handles hitbox detection,
--     animations and server validation — no manual FireServer.
--     HitFix (hookClientGet) fires transparently on the resulting
--     AttackEntity call, adjusting selfPosition by ping.
--     HitBoxes (debug.setconstant on swingSwordInRegion index 6)
--     expands the server-side swing region for the hit to land.
--
--   Method 2 (SwingMode OFF — FireServer fallback, V4 approach):
--     Raw net.FireServer with HitFix position adjustment applied
--     manually. Used when bedwars isn't loaded or as backup.
--
--   Sword check:
--     When bedwars is loaded: Vape's hasSwordEquipped() via
--     ItemMeta hotbar slot (same as paste #1).
--     Fallback: V4's generic Hand/Tool name check.
--
--   All gates: LMB, team check, range, angle, wall, sword item.
--   Multi-Hit: iterates all valid targets per cycle.
--   Q keybind toggles ka.enabled — same as V4.
-- ══════════════════════════════════════════════════════════════

-- LMB tracking  (V4 identical)
local lmbHeld = false
UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then lmbHeld = true end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then lmbHeld = false end
end)

-- Pre-compute angle cosine cache  (V4 identical)
local _cachedAngleDeg, _cachedCos = -1, 0
local function getAngleCos()
    if ka.angleDeg ~= _cachedAngleDeg then
        _cachedAngleDeg = ka.angleDeg
        _cachedCos = mcos(mrad(ka.angleDeg / 2))
    end
    return _cachedCos
end

local function inAngleCone(rootCF, targetPos)
    if ka.angleDeg >= 360 then return true end
    local toTarget = targetPos - rootCF.Position
    toTarget = v3new(toTarget.X, 0, toTarget.Z).Unit
    local forward = v3new(rootCF.LookVector.X, 0, rootCF.LookVector.Z).Unit
    return forward:Dot(toTarget) >= getAngleCos()
end

-- Wall raycast  (V4 identical)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local _rayFilterDirty = true
local function refreshRayFilter()
    if not _rayFilterDirty then return end
    _rayFilterDirty = false
    local char = getChar()
    rayParams.FilterDescendantsInstances = char and { char } or {}
end

local function isVisible(fromPos, toPos)
    if not ka.ignoreWalls then return true end
    refreshRayFilter()
    local dir    = toPos - fromPos
    local result = workspace:Raycast(fromPos, dir, rayParams)
    if not result then return true end
    local hit = result.Instance
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character and hit:IsDescendantOf(p.Character) then return true end
    end
    return false
end

-- Generic sword check (V4 fallback when ItemMeta not ready)
local function holdingSwordGeneric()
    local char = getChar(); if not char then return false end
    local handItem = char:FindFirstChild("HandInvItem")
    if handItem and handItem.Value then
        local n = handItem.Value.Name:lower()
        if n:find("sword") or n:find("blade") then return true end
    end
    for _, obj in ipairs(char:GetChildren()) do
        if obj:IsA("Tool") then
            local n = obj.Name:lower()
            if n:find("sword") or n:find("blade") then return true end
        end
    end
    return false
end

-- Sword check: uses Vape ItemMeta when available, else V4 fallback
local function checkSwordEquipped()
    if bedwarsReady and bedwars.ItemMeta then return hasSwordEquipped() end
    return holdingSwordGeneric()
end

-- FireServer fallback helpers  (V4 identical)
local _net, _inv
local function getKANet()
    if _net then return _net end
    local ok, v = pcall(function()
        return ReplicatedStorage
            .rbxts_include.node_modules
            :FindFirstChild("@rbxts")
            .net.out._NetManaged.SwordHit
    end)
    if ok and v then _net = v end
    return _net
end

local function getKAInv()
    if _inv and _inv.Parent then return _inv end
    local invRoot = ReplicatedStorage:FindFirstChild("Inventories")
    _inv = invRoot and invRoot:FindFirstChild(LocalPlayer.Name)
    return _inv
end

local SWORD_NAMES = {
    "wood_sword", "stone_sword", "iron_sword",
    "diamond_sword", "emerald_sword", "netherite_sword",
}
local function getSwordItem()
    local inv = getKAInv(); if not inv then return nil end
    for _, name in ipairs(SWORD_NAMES) do
        local found = inv:FindFirstChild(name)
        if found then return found end
    end
    for _, child in ipairs(inv:GetChildren()) do
        if child.Name:lower():find("sword") then return child end
    end
    return nil
end

-- ── MAIN KILL AURA LOOP ───────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(ka.delay)
        if not ka.enabled then continue end
        if ka.requireMouse and not lmbHeld then continue end
        if ka.limitToItems and not checkSwordEquipped() then continue end

        local root = getRoot()
        if not root then continue end
        local rootCF = root.CFrame
        local lpPos  = rootCF.Position

        -- ════════════════════════════════════════════════════
        -- METHOD 1: swingSwordAtMouse  (Vape native — primary)
        -- ════════════════════════════════════════════════════
        if ka.useSwingMode and bedwarsReady
        and bedwars.SwordController
        and bedwars.SwordController.swingSwordAtMouse then

            -- Build sorted target list from entitylib (Vape's entity system)
            local targets = {}
            for _, ent in ipairs(entitylib.List) do
                if not ent.Targetable then continue end
                if not entitylib.isVulnerable(ent) then continue end
                -- Team check via entitylib targetCheck (already applied on Targetable)
                -- but also honor ka.teamCheck override:
                if ka.teamCheck and ent.Player then
                    local localTeam = LocalPlayer.Team
                    local entTeam   = ent.Player.Team
                    if localTeam and entTeam and entTeam == localTeam then continue end
                end
                local pRoot = ent.RootPart
                if not pRoot then continue end
                local pPos = pRoot.Position
                if (lpPos - pPos).Magnitude > ka.range then continue end
                if not inAngleCone(rootCF, pPos) then continue end
                if not isVisible(lpPos, pPos) then continue end
                tinsert(targets, { ent = ent, pPos = pPos, dist = (lpPos - pPos).Magnitude })
            end

            -- Sort closest first
            table.sort(targets, function(a, b) return a.dist < b.dist end)

            if #targets > 0 then
                local savedCF = Camera.CFrame

                local function doSwing(targetPos)
                    -- Temporarily point camera at target so swingSwordAtMouse registers the hit
                    Camera.CFrame = CFrame.new(Camera.CFrame.Position, targetPos)
                    pcall(function() bedwars.SwordController:swingSwordAtMouse() end)
                end

                if ka.multiHit then
                    for _, t in ipairs(targets) do
                        doSwing(t.pPos)
                        task.wait()  -- one frame gap so server registers each hit
                    end
                else
                    doSwing(targets[1].pPos)
                end

                -- Restore camera
                Camera.CFrame = savedCF
            end

        -- ════════════════════════════════════════════════════
        -- METHOD 2: FireServer fallback (with HitFix applied)
        -- Used when bedwars not loaded or useSwingMode is OFF
        -- ════════════════════════════════════════════════════
        else
            local net   = getKANet()
            local sword = getSwordItem()
            if not net or not sword then continue end

            _rayFilterDirty = true

            local playerList = Players:GetPlayers()
            for _, p in ipairs(playerList) do
                if p == LocalPlayer then continue end
                if ka.teamCheck and p.Team == LocalPlayer.Team and LocalPlayer.Team ~= nil then continue end

                local char  = p.Character
                local pRoot = char and char:FindFirstChild("HumanoidRootPart")
                local hum   = char and char:FindFirstChild("Humanoid")
                if not char or not pRoot or not hum or hum.Health <= 0 then continue end

                local pPos = pRoot.Position
                if (lpPos - pPos).Magnitude > ka.range then continue end
                if not inAngleCone(rootCF, pPos) then continue end
                if not isVisible(lpPos, pPos) then continue end

                -- HitFix: manually adjust selfPosition when hookClientGet isn't active
                local fireSelfPos = lpPos
                if ka.hitfix then
                    local distance         = (lpPos - pPos).Magnitude
                    local pingCompensation = math.min(getPingMs() / 1000 * 50, 8)
                    local adjustmentDist   = math.max(distance - 12, 0) + pingCompensation
                    if adjustmentDist > 0 then
                        local direction = CFrame.lookAt(lpPos, pPos).LookVector
                        fireSelfPos = lpPos + (direction * adjustmentDist)
                    end
                end

                local args = {
                    {
                        entityInstance = char,
                        chargedAttack  = { chargeRatio = 0 },
                        validate = {
                            targetPosition = { value = pPos },
                            selfPosition   = { value = fireSelfPos },
                        },
                        weapon = sword,
                    }
                }
                pcall(net.FireServer, net, unpack(args))

                if not ka.multiHit then break end
            end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- KEYBINDS  (V4 identical)
-- ══════════════════════════════════════════════════════════════
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.Q then
        ka.enabled = not ka.enabled
        collectAndSave()
        Window:Notify({
            Title = "Kill Aura",
            Desc  = ka.enabled and "Kill Aura  ON  (Vape Engine)" or "Kill Aura  OFF",
            Time  = 2,
        })
    elseif input.KeyCode == Enum.KeyCode.R then
        aim.enabled = not aim.enabled
        if not aim.enabled then aim.target = nil end
        collectAndSave()
        Window:Notify({
            Title = "Aim Assist",
            Desc  = aim.enabled and "Aim Assist  ON" or "Aim Assist  OFF",
            Time  = 2,
        })
    end
end)

-- ══════════════════════════════════════════════════════════════
-- PING STABILIZER  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local pingData = {
    samples    = {},
    smooth     = 0,
    target     = 0,
    stability  = 0,
    maxSamples = 12,
    emaAlpha   = 0.15,
}

local function updatePing()
    local raw
    pcall(function() raw = Stats.Network:GetValue() * 1000 end)
    if not raw or raw ~= raw then return end

    local s = pingData.samples
    s[#s + 1] = raw
    if #s > pingData.maxSamples then tremove(s, 1) end

    local sorted = tclone(s)
    table.sort(sorted)
    local median = sorted[mfloor(#sorted / 2) + 1] or raw

    local diff = mabs(median - pingData.target)
    if diff < 8 then
        pingData.stability = math.min(pingData.stability + 2, 25)
    else
        pingData.stability = math.max(pingData.stability - 3, 0)
    end

    local blend = pingData.stability >= 12 and 1.0 or 0.3
    local alpha = blend * pingData.emaAlpha
    pingData.target = pingData.target * (1 - alpha) + median * alpha
    pingData.smooth = pingData.smooth * (1 - pingData.emaAlpha) + pingData.target * pingData.emaAlpha
end

-- ══════════════════════════════════════════════════════════════
-- MAIN LOOPS — RENDERSTEPPED + HEARTBEAT  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local fpsSamples = {}
local diagTimer  = 0

RunService.RenderStepped:Connect(function(dt)
    doAimAssist()
    updateESP()
    refreshESP(dt)

    fpsSamples[#fpsSamples + 1] = dt > 0 and 1 / dt or 60
    if #fpsSamples > 30 then tremove(fpsSamples, 1) end

    diagTimer += dt
    if diagTimer >= 1 then
        diagTimer = 0

        local sum = 0
        for _, v in ipairs(fpsSamples) do sum += v end
        local avgFps = mfloor(sum / #fpsSamples)

        updatePing()
        local pm  = mfloor(pingData.smooth)
        local pc  = pm < 50 and "LOW" or pm < 100 and "MID" or "HIGH"
        local ft  = avgFps >= 60 and "GREAT" or avgFps >= 30 and "OK" or "LOW"
        local kaS = ka.enabled  and "ON (" .. (bedwarsReady and "Vape" or "FS") .. ")" or "OFF"
        local aaS = aim.enabled and "ON" or "OFF"

        diagBlock:SetCode(string.format(
            "FPS        : %d  [%s]\nPING       : %dms  [%s]\nKill Aura  : %s  |  Aim: %s",
            avgFps, ft, pm, pc, kaS, aaS
        ))
    end
end)

local gcTimer = 0
RunService.Heartbeat:Connect(function(dt)
    local root = getRoot()
    local hum  = getHumanoid()
    if root and hum and hum.Health > 0 and kb.enabled and kb.strength > 0 then
        local cur   = root.Velocity
        local delta = (cur - kb.lastVelocity).Magnitude
        if delta > 10 then
            local m = 1 - kb.strength
            root.Velocity   = v3new(cur.X * m, cur.Y, cur.Z * m)
            kb.lastVelocity = root.Velocity
        else
            kb.lastVelocity = cur
        end
    end

    gcTimer += dt
    if gcTimer >= 60 then
        gcTimer = 0
        collectgarbage()
    end
end)

-- ══════════════════════════════════════════════════════════════
-- PLAYER / CHARACTER EVENTS  (V4 identical)
-- ══════════════════════════════════════════════════════════════
local function onNewChar(player, char)
    task.wait(0.5)
    if player == LocalPlayer then
        kb.lastVelocity = Vector3.zero
        aim.target      = nil
        return
    end
    if fpsState.greyplayers then
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then
                p.BrickColor  = BrickColor.new("Medium stone grey")
                p.Material    = Enum.Material.SmoothPlastic
                p.Reflectance = 0
            end
            if p:IsA("Shirt") or p:IsA("Pants") or p:IsA("ShirtGraphic")
            or p:IsA("Accessory") or p:IsA("Hat") or p:IsA("Hair") then
                p:Destroy()
            end
        end
    end
    if esp.enabled then
        task.wait(0.2)
        createESPFor(player)
    end
end

for _, p in ipairs(Players:GetPlayers()) do
    if p.Character then task.spawn(onNewChar, p, p.Character) end
    p.CharacterAdded:Connect(function(c) task.spawn(onNewChar, p, c) end)
end

Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function(c) task.spawn(onNewChar, p, c) end)
end)

Players.PlayerRemoving:Connect(function(p)
    removeESPFor(p)
    if aim.target == p then aim.target = nil end
end)

LocalPlayer.CharacterAdded:Connect(function()
    kb.lastVelocity = Vector3.zero
    aim.target      = nil
    _rayFilterDirty = true
end)

-- ══════════════════════════════════════════════════════════════
-- START ENTITY LIB  (Vape entitylib — used by swingSwordAtMouse
-- target loop. Must start after all connections are set up.)
-- ══════════════════════════════════════════════════════════════
entitylib.start()

-- ══════════════════════════════════════════════════════════════
-- FINISH SPLASH  +  READY TOAST  (V4 identical — text updated)
-- ══════════════════════════════════════════════════════════════
task.spawn(function()
    task.wait(2.6)

    local fo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(splashFrame, fo, {BackgroundTransparency = 1}):Play()
    TweenService:Create(sTitleLbl,   fo, {TextTransparency = 1}):Play()
    TweenService:Create(sSubLbl,     fo, {TextTransparency = 1}):Play()
    TweenService:Create(sBarBg,      fo, {BackgroundTransparency = 1}):Play()
    task.wait(0.4)
    splashGui:Destroy()

    -- Toast notification
    local tGui = Instance.new("ScreenGui", CoreGui)
    tGui.Name = "WolfVXPE_Toast"; tGui.ResetOnSpawn = false

    local toast = Instance.new("Frame", tGui)
    toast.Size               = UDim2.new(0, 370, 0, 64)
    toast.Position           = UDim2.new(0.5, -185, 1, 10)
    toast.BackgroundColor3   = Color3.fromRGB(9, 6, 18)
    toast.BackgroundTransparency = 0.04
    toast.BorderSizePixel    = 0
    Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 10)
    local ts = Instance.new("UIStroke", toast)
    ts.Color = Color3.fromRGB(255, 80, 80); ts.Thickness = 1.2

    local accent = Instance.new("Frame", toast)
    accent.Size             = UDim2.new(0, 3, 1, -14)
    accent.Position         = UDim2.new(0, 7, 0, 7)
    accent.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
    accent.BorderSizePixel  = 0
    Instance.new("UICorner", accent).CornerRadius = UDim.new(1, 0)

    local tTop = Instance.new("TextLabel", toast)
    tTop.Size               = UDim2.new(1, -20, 0, 26)
    tTop.Position           = UDim2.new(0, 16, 0, 7)
    tTop.BackgroundTransparency = 1
    tTop.Text               = "WOLFVXPE V5  —  VAPE ENGINE LOADED"
    tTop.TextColor3         = Color3.fromRGB(255, 90, 90)
    tTop.Font               = Enum.Font.GothamBold
    tTop.TextSize           = 13
    tTop.TextXAlignment     = Enum.TextXAlignment.Left

    local tSub = Instance.new("TextLabel", toast)
    tSub.Size               = UDim2.new(1, -20, 0, 14)
    tSub.Position           = UDim2.new(0, 16, 0, 36)
    tSub.BackgroundTransparency = 1
    tSub.Text               = "Q = Kill Aura  •  R = Aim Assist  •  RightShift = Menu"
    tSub.TextColor3         = Color3.fromRGB(185, 148, 148)
    tSub.Font               = Enum.Font.Gotham
    tSub.TextSize           = 11
    tSub.TextXAlignment     = Enum.TextXAlignment.Left

    local si = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    TweenService:Create(toast, si, {Position = UDim2.new(0.5, -185, 1, -78)}):Play()
    task.wait(4.5)
    local so = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(toast, so, {Position = UDim2.new(0.5, -185, 1, 10)}):Play()
    task.wait(0.35)
    tGui:Destroy()
end)

Window:Notify({ Title = "WOLFVXPE V5", Desc = "Loaded — Vape KA Engine | Q=KA  R=Aim  RightShift=Menu", Time = 5 })
print("[ WOLFVXPE V5 ] Loaded — pistademon | Vape KA Engine | Q=KA  R=Aim  RightShift=Menu")
