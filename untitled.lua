local function safeHttpGet(url)
    -- try game:HttpGet
    local ok, res = pcall(function()
        if type(game.HttpGet) == "function" then
            return game:HttpGet(url)
        end
    end)
    if ok and res and #res > 0 then return res end

    -- try HttpGetAsync
    ok, res = pcall(function()
        if type(game.HttpGetAsync) == "function" then
            return game:HttpGetAsync(url)
        end
    end)
    if ok and res and #res > 0 then return res end

    -- try syn.request
    ok, res = pcall(function()
        if syn and syn.request then
            local r = syn.request({Url = url, Method = "GET"})
            return r and r.Body or nil
        end
    end)
    if ok and res and #res > 0 then return res end

    -- try http_request
    ok, res = pcall(function()
        if http_request then
            local r = http_request({Url = url, Method = "GET"})
            return r and r.Body or nil
        end
    end)
    if ok and res and #res > 0 then return res end

    return nil
end

-- ---------------------------
-- Wait for player/character
-- ---------------------------
local Players = game:GetService("Players")
local plr = Players.LocalPlayer
while not plr do
    task.wait()
    plr = Players.LocalPlayer
end

local function getChar()
    local c = plr.Character or plr.CharacterAdded:Wait()
    -- ensure Humanoid exists
    while not c:FindFirstChildOfClass("Humanoid") do
        task.wait()
    end
    return c
end

local char = getChar()

-- reconnect char reference if respawned
plr.CharacterAdded:Connect(function(c)
    char = c
end)

-- ---------------------------
-- Core state variables
-- ---------------------------
local drilling = false
local selling = false
local collecting = false
local storage = false
local rebirthing = false
local selectedDrill = nil
local selectedHandDrill = nil
local selectedPlayer = nil

-- Auto dodge variables (from earlier change)
local autoDodge = false
local dodgeRadius = 6
local dodgeCooldown = 1
local lastDodgeTimes = {}
local dodgeKeywords = {"punch", "attack", "swing", "hit", "strike"}

-- Stamina force variables (new)
local forceStamina = false
local staminaInterval = 0.15 -- seconds between attempts
local staminaTarget = 100    -- percent / value to set (default 100)

-- ---------------------------
-- Core helper functions (kept mostly as original)
-- ---------------------------
local function drill()
    if not char or not char.Parent then return end

    local OreService
    pcall(function()
        OreService = game:GetService("ReplicatedStorage").Packages.Knit.Services.OreService.RE
    end)

    local function tryFireRequestRandomOre()
        if OreService and OreService.RequestRandomOre then
            pcall(function() OreService.RequestRandomOre:FireServer() end)
        end
    end

    local tool = char:FindFirstChildOfClass("Tool")

    if tool then
        -- If it's a hand drill, use RequestRandomOre as before
        if string.match(tool.Name or "", "Hand") then
            pcall(tryFireRequestRandomOre)
            return
        end

        -- For non-hand drills, try to Activate the tool and also fire request
        pcall(function()
            if tool.Activate then
                tool:Activate()
            end
        end)

        pcall(tryFireRequestRandomOre)
        return
    end

    -- No tool equipped: try to equip a Hand or Drill from backpack
    for _,v in ipairs(plr.Backpack:GetChildren()) do
        if v:IsA("Tool") and (string.match(v.Name or "", "Hand") or string.match(v.Name or "", "Drill")) then
            pcall(function()
                local humanoid = char:FindFirstChildOfClass("Humanoid")
                if humanoid then
                    humanoid:EquipTool(v)
                    task.wait(0.06)
                    if string.match(v.Name or "", "Hand") then
                        pcall(tryFireRequestRandomOre)
                    else
                        if v.Activate then
                            pcall(function() v:Activate() end)
                        end
                        pcall(tryFireRequestRandomOre)
                    end
                end
            end)
            break
        end
    end
end

local function sell()
    if not char or not char.Parent then return end
    for _,v in next, plr.Backpack:GetChildren() do
        if not string.match(v.Name or "", "Drill") then
            if v:IsA("Tool") and v:FindFirstChild("Handle") then
                local old = char:GetPivot()
                -- protect call in case Sell Shop isn't present
                local ok, shop = pcall(function() return workspace:FindFirstChild("Sell Shop") end)
                if ok and shop then
                    pcall(function()
                        char:PivotTo(shop:GetPivot())
                        task.wait(0.12)
                        game:GetService("ReplicatedStorage").Packages.Knit.Services.OreService.RE.SellAll:FireServer()
                        task.wait(0.12)
                        char:PivotTo(old)
                    end)
                end
            end
        end
    end
end

local function getPlot()
    for _,v in next, workspace.Plots:GetChildren() do
        if v:FindFirstChild("Owner") and v.Owner.Value == plr then
            return v
        end
    end
    return nil
end

local function collectDrills()
    local plot = getPlot()
    if not plot then return end
    local drillsFolder = plot:FindFirstChild("Drills")
    if not drillsFolder then return end
    for _,v in next, drillsFolder:GetChildren() do
        if v:FindFirstChild("Ores") and v.Ores:FindFirstChild("TotalQuantity") and v.Ores.TotalQuantity.Value > 0 then
            pcall(function()
                game:GetService("ReplicatedStorage").Packages.Knit.Services.PlotService.RE.CollectDrill:FireServer(v)
            end)
        end
    end
end

local function collectStorage()
    local plot = getPlot()
    if not plot then return end
    local storageFolder = plot:FindFirstChild("Storage")
    if not storageFolder then return end
    for _,v in next, storageFolder:GetChildren() do
        if v:FindFirstChild("Ores") and v.Ores:FindFirstChild("TotalQuantity") and v.Ores.TotalQuantity.Value > 0 then
            -- NOTE: original script also called CollectDrill for storage; keeping same method name
            pcall(function()
                game:GetService("ReplicatedStorage").Packages.Knit.Services.PlotService.RE.CollectDrill:FireServer(v)
            end)
        end
    end
end

local function rebirth()
    local success, reb = pcall(function()
        return plr.PlayerGui:WaitForChild("Menu", 2).CanvasGroup.Rebirth.Background
    end)
    if not success or not reb then return end

    local progress = reb.Progress and reb.Progress.Checkmark and reb.Progress.Checkmark.Image == "rbxassetid://131015443699741"
    local ores = reb.RequiredOres and reb.RequiredOres:GetChildren() or {}

    if #ores >= 2 then
        local ore1 = ores[1]:FindFirstChild("Checkmark")
        local ore2 = ores[2]:FindFirstChild("Checkmark")

        if progress
        and ore1 and ore1.Image == "rbxassetid://131015443699741"
        and ore2 and ore2.Image == "rbxassetid://131015443699741" then
            pcall(function()
                game:GetService("ReplicatedStorage").Packages.Knit.Services.RebirthService.RE.RebirthRequest:FireServer()
            end)
        end
    end
end

-- Auto dodge helpers (kept from prior implementation)
local function isAttackTrack(track)
    if not track then return false end
    local name = ""
    pcall(function()
        name = tostring(track.Name or ""):lower()
    end)
    if name and #name > 0 then
        for _, kw in ipairs(dodgeKeywords) do
            if string.find(name, kw, 1, true) then
                return true
            end
        end
    end

    local animId = ""
    pcall(function()
        if track.Animation then
            animId = tostring(track.Animation.Name or track.Animation.AnimationId or "")
        end
    end)
    if animId and #animId > 0 then
        animId = animId:lower()
        for _, kw in ipairs(dodgeKeywords) do
            if string.find(animId, kw, 1, true) then
                return true
            end
        end
    end

    return false
end

local function tryDodgeFrom(attacker)
    if not char or not char.Parent then return end
    if not attacker or not attacker.Character then return end

    local now = tick()
    lastDodgeTimes[attacker] = lastDodgeTimes[attacker] or 0
    if now - lastDodgeTimes[attacker] < dodgeCooldown then
        return
    end

    local myRoot = char:FindFirstChild("HumanoidRootPart")
    local attRoot = attacker.Character:FindFirstChild("HumanoidRootPart")
    if not myRoot or not attRoot then return end

    local dir = (myRoot.Position - attRoot.Position)
    if dir.Magnitude == 0 then
        dir = Vector3.new(1,0,0)
    end
    local right = dir:Cross(Vector3.new(0,1,0))
    if right.Magnitude == 0 then
        right = Vector3.new(1,0,0)
    else
        right = right.Unit
    end

    local side = right
    if math.random() < 0.5 then side = -right end

    local targetPos = myRoot.Position + side * math.clamp(dodgeRadius, 2, 12)
    targetPos = Vector3.new(targetPos.X, math.max(myRoot.Position.Y, targetPos.Y + 2), targetPos.Z)

    local ok, err = pcall(function()
        char:PivotTo(CFrame.new(targetPos, targetPos + (char.HumanoidRootPart and char.HumanoidRootPart.CFrame.LookVector or Vector3.new(0,0,1))))
    end)
    if not ok then
        pcall(function()
            local h = char:FindFirstChildOfClass("Humanoid")
            if h then
                h:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end)
    end

    lastDodgeTimes[attacker] = now
end

local function autoDodgeLogic()
    if not char or not char.Parent then return end
    local myRoot = char:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= plr and p.Character and p.Character.Parent then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            local animController = p.Character:FindFirstChildOfClass("Animator") or (hum and hum:FindFirstChildOfClass("Animator"))
            local attRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if attRoot and animController and myRoot then
                local dist = (attRoot.Position - myRoot.Position).Magnitude
                if dist <= dodgeRadius then
                    local ok, tracks = pcall(function()
                        return animController:GetPlayingAnimationTracks()
                    end)
                    if ok and tracks and #tracks > 0 then
                        for _, track in ipairs(tracks) do
                            local success, isAttack = pcall(isAttackTrack, track)
                            if success and isAttack then
                                pcall(function() tryDodgeFrom(p) end)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Stamina forcing implementation (NEW)
local function trySetStaminaToFull()
    if not char or not char.Parent then return false end
    local succeeded = false

    -- 1) Try Humanoid Attribute "Stamina" or "Energy"
    pcall(function()
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            local attrs = {"Stamina", "Energy"}
            for _, a in ipairs(attrs) do
                if hum.GetAttribute and hum:GetAttribute(a) ~= nil then
                    hum:SetAttribute(a, staminaTarget)
                    succeeded = true
                end
            end
        end
    end)

    -- 2) Try NumberValue / IntValue named "Stamina" or "Energy" under Character or Player
    pcall(function()
        local candidates = {
            char:FindFirstChild("Stamina"),
            char:FindFirstChild("Energy"),
            plr:FindFirstChild("Stamina"),
            plr:FindFirstChild("Energy"),
            plr:FindFirstChild("leaderstats") and plr.leaderstats:FindFirstChild("Stamina"),
            plr:FindFirstChild("leaderstats") and plr.leaderstats:FindFirstChild("Energy"),
        }
        for _, cv in ipairs(candidates) do
            if cv and (cv:IsA("NumberValue") or cv:IsA("IntValue") or cv:IsA("NumberRangeValue")) then
                cv.Value = staminaTarget
                succeeded = true
            end
        end
    end)

    -- 3) Try common remote services (Knit pattern) to request refill
    pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        if rs and rs:FindFirstChild("Packages") and rs.Packages:FindFirstChild("Knit") and rs.Packages.Knit:FindFirstChild("Services") then
            local servicesRoot = rs.Packages.Knit.Services
            local possibleServices = {"StaminaService", "EnergyService", "PlayerStatsService"}
            for _, svcName in ipairs(possibleServices) do
                local svc = servicesRoot:FindFirstChild(svcName)
                if svc and svc:FindFirstChild("RE") then
                    local re = svc.RE
                    local remoteFuncs = {"RefillStamina", "RestoreStamina", "RefillEnergy", "SetStamina", "SetEnergy"}
                    for _, f in ipairs(remoteFuncs) do
                        if re:FindFirstChild(f) and re[f].FireServer then
                            pcall(function()
                                -- some remotes accept no args, some accept value
                                local ok, _ = pcall(function() re[f]:FireServer() end)
                                if not ok then
                                    pcall(function() re[f]:FireServer(staminaTarget) end)
                                end
                            end)
                            succeeded = true
                        end
                    end
                end
            end
        end
    end)

    return succeeded
end

-- ---------------------------
-- UI helpers (existing)
-- ---------------------------
local function formatPrice(num)
    local formatted = tostring(num)
    local k
    while true do
        formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return "$" .. formatted
end

local function getDrillsSortedByPrice()
    local drills = {}
    local gui = plr:FindFirstChild("PlayerGui") and plr.PlayerGui:FindFirstChild("Menu")
    if not gui then return drills end

    for _, frame in pairs(plr.PlayerGui.Menu.CanvasGroup.Buy.Background.DrillList:GetChildren()) do
        if frame:IsA("Frame") then
            local priceLabel = frame:FindFirstChild("Buy") and frame.Buy:FindFirstChild("TextLabel")
            local titleLabel = frame:FindFirstChild("Title")

            if priceLabel and titleLabel then
                local priceText = priceLabel.Text
                local cleanPriceText = priceText:gsub("[%$,]", "")
                local price = tonumber(cleanPriceText)

                if price then
                    table.insert(drills, {
                        name = titleLabel.Text,
                        price = price,
                        frame = frame
                    })
                end
            end
        end
    end

    table.sort(drills, function(a, b)
        return a.price < b.price
    end)

    return drills
end

local function getHandDrillsSortedByPrice()
    local drills = {}
    local gui = plr:FindFirstChild("PlayerGui") and plr.PlayerGui:FindFirstChild("Menu")
    if not gui then return drills end

    for _, frame in pairs(plr.PlayerGui.Menu.CanvasGroup.HandDrills.Background.HandDrillList:GetChildren()) do
        if frame:IsA("Frame") then
            local priceLabel = frame:FindFirstChild("Buy") and frame.Buy:FindFirstChild("TextLabel")
            local titleLabel = frame:FindFirstChild("Title")

            if priceLabel and titleLabel then
                local priceText = priceLabel.Text
                local cleanPriceText = priceText:gsub("[%$,]", "")
                local price = tonumber(cleanPriceText)

                if price then
                    table.insert(drills, {
                        name = titleLabel.Text,
                        price = price,
                        frame = frame
                    })
                end
            end
        end
    end

    table.sort(drills, function(a, b)
        return a.price < b.price
    end)

    return drills
end

local function getDrillPrice()
    if not selectedDrill then return end
    for _,v in next, plr.PlayerGui.Menu.CanvasGroup.Buy.Background.DrillList:GetDescendants() do
        if v:IsA("TextLabel") and v.Name == "Title" and v.Text == selectedDrill then
            return v.Parent:FindFirstChild("Buy").TextLabel.Text
        end
    end
end

local function getHandDrillPrice()
    if not selectedHandDrill then return end
    for _,v in next, plr.PlayerGui.Menu.CanvasGroup.HandDrills.Background.HandDrillList:GetDescendants() do
        if v:IsA("TextLabel") and v.Name == "Title" and v.Text == selectedHandDrill then
            return v.Parent:FindFirstChild("Buy").TextLabel.Text
        end
    end
end

local function getPlayersList()
    local t = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p == plr then continue end
        t[#t + 1] = p.Name
    end
    return t
end

-- ---------------------------
-- Try loading WindUI (with fallback)
-- ---------------------------
local ui = nil
local windUrlCandidates = {
    -- raw path - often more direct than the releases redirect
    "https://raw.githubusercontent.com/Footagesus/WindUI/main/main.lua",
    -- the original release redirect (may fail depending on executor)
    "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
}

local loadedUI = false
for _, url in ipairs(windUrlCandidates) do
    local body = safeHttpGet(url)
    if body then
        local ok, lib = pcall(function() return loadstring(body)() end)
        if ok and type(lib) == "table" then
            ui = lib
            loadedUI = true
            break
        end
    end
end

if not loadedUI then
    warn("[Delta-compatible] Could not fetch WindUI. GUI will not be shown. The automation logic still runs.")
    -- If you want a very small local GUI fallback, we can add it here.
    -- For now we rely on the automation running without the WindUI.
end

-- ---------------------------
-- Build GUI and bind actions (if UI loaded)
-- ---------------------------
if ui then
    local win = ui:CreateWindow({
        Title = "Untitled Drill Game (Delta)",
        Icon = "terminal",
        Folder = nil,
        Size = UDim2.fromOffset(580, 460),
        Transparent = true,
        Theme = "Dark",
        SideBarWidth = 200,
        Background = "",
    })

    local tabMain = win:Tab({
        Title = "Main",
        Icon = "pickaxe",
    })

    tabMain:Section({
        Title = "Farming",
        TextXAlignment = "Left",
        TextSize = 17,
    })

    tabMain:Toggle({
        Title = "Drill Ores",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            drilling = state
            if drilling then
                task.spawn(function()
                    while drilling do
                        drill()
                        task.wait(0.1)
                    end
                end)
            end
        end
    })

    -- Auto Dodge toggle (kept from earlier change)
    tabMain:Toggle({
        Title = "Auto Dodge",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            autoDodge = state
            if autoDodge then
                task.spawn(function()
                    while autoDodge do
                        pcall(autoDodgeLogic)
                        task.wait(0.08)
                    end
                end)
            end
        end
    })

    -- NEW: Force Stamina toggle (the requested feature)
    tabMain:Toggle({
        Title = "Force Stamina 100%",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            forceStamina = state
            if forceStamina then
                task.spawn(function()
                    while forceStamina do
                        pcall(function()
                            trySetStaminaToFull()
                        end)
                        task.wait(staminaInterval)
                    end
                end)
            end
        end
    })

    -- Slider to control how often stamina is forced (smaller = more aggressive)
    tabMain:Slider({
        Title = "Stamina Interval (s)",
        Step = 0.05,
        Value = {
            Min = 0.05,
            Max = 1,
            Default = staminaInterval,
        },
        Callback = function(value)
            staminaInterval = value
        end
    })

    -- Optionally allow adjusting target value (useful if game uses different scale)
    tabMain:Slider({
        Title = "Stamina Target Value",
        Step = 1,
        Value = {
            Min = 1,
            Max = 1000,
            Default = staminaTarget,
        },
        Callback = function(value)
            staminaTarget = value
        end
    })

    tabMain:Toggle({
        Title = "Sell Ores",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            selling = state
            if selling then
                task.spawn(function()
                    while selling do
                        sell()
                        task.wait()
                    end
                end)
            end
        end
    })

    tabMain:Toggle({
        Title = "Collect Ores From Drills",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            collecting = state
            if collecting then
                task.spawn(function()
                    while collecting do
                        collectDrills()
                        task.wait()
                    end
                end)
            end
        end
    })

    tabMain:Toggle({
        Title = "Collect Ores From Storage",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            storage = state
            if storage then
                task.spawn(function()
                    while storage do
                        collectStorage()
                        task.wait()
                    end
                end)
            end
        end
    })

    tabMain:Toggle({
        Title = "Rebirth",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            rebirthing = state
            if rebirthing then
                task.spawn(function()
                    while rebirthing do
                        rebirth()
                        task.wait(1)
                    end
                end)
            end
        end
    })

    tabMain:Section({
        Title = "Buying",
        TextXAlignment = "Left",
        TextSize = 17,
    })

    local Paragraph = tabMain:Paragraph({
        Title = "Selected Drill Price: N/A",
        Locked = false,
    })

    local sortedDrills = getDrillsSortedByPrice()
    local drillNames = {}
    for _, drill in ipairs(sortedDrills) do
        table.insert(drillNames, drill.name)
    end

    local DropdownDrill = tabMain:Dropdown({
        Title = "Drill List",
        Values = drillNames,
        Value = nil,
        Callback = function(option)
            selectedDrill = option
            local price = getDrillPrice() or "N/A"
            Paragraph:SetTitle("Selected Drill Price: " .. price)
        end
    })

    tabMain:Button({
        Title = "Buy Drill",
        Locked = false,
        Callback = function()
            if selectedDrill then
                pcall(function()
                    game:GetService("ReplicatedStorage").Packages.Knit.Services.OreService.RE.BuyDrill:FireServer(selectedDrill)
                end)
            end
        end
    })

    local Paragraph2 = tabMain:Paragraph({
        Title = "Selected Hand Drill Price: N/A",
        Locked = false,
    })

    local sortedHandDrills = getHandDrillsSortedByPrice()
    local handDrillNames = {}
    for _, drill in ipairs(sortedHandDrills) do
        table.insert(handDrillNames, drill.name)
    end

    local DropdownHand = tabMain:Dropdown({
        Title = "Hand Drill List",
        Values = handDrillNames,
        Value = nil,
        Callback = function(option)
            selectedHandDrill = option
            local price = getHandDrillPrice() or "N/A"
            Paragraph2:SetTitle("Selected Hand Drill Price: " .. price)
        end
    })

    tabMain:Button({
        Title = "Buy Hand Drill",
        Locked = false,
        Callback = function()
            if selectedHandDrill then
                pcall(function()
                    game:GetService("ReplicatedStorage").Packages.Knit.Services.OreService.RE.BuyHandDrill:FireServer(selectedHandDrill)
                end)
            end
        end
    })

    local tabMisc = win:Tab({
        Title = "Miscellaneous",
        Icon = "person-standing",
    })

    tabMisc:Section({
        Title = "Player",
        TextXAlignment = "Left",
        TextSize = 17,
    })

    tabMisc:Slider({
        Title = "WalkSpeed",
        Step = 1,
        Value = {
            Min = 0,
            Max = 500,
            Default = (char and char:FindFirstChildOfClass("Humanoid")) and char:FindFirstChildOfClass("Humanoid").WalkSpeed or 16,
        },
        Callback = function(value)
            pcall(function()
                if char and char:FindFirstChildOfClass("Humanoid") then
                    char:FindFirstChildOfClass("Humanoid").WalkSpeed = value
                end
            end)
        end
    })

    tabMisc:Slider({
        Title = "JumpPower",
        Step = 1,
        Value = {
            Min = 0,
            Max = 500,
            Default = (char and char:FindFirstChildOfClass("Humanoid")) and char:FindFirstChildOfClass("Humanoid").JumpPower or 50,
        },
        Callback = function(value)
            pcall(function()
                if char and char:FindFirstChildOfClass("Humanoid") then
                    char:FindFirstChildOfClass("Humanoid").JumpPower = value
                end
            end)
        end
    })

    local DropdownPlayers = tabMisc:Dropdown({
        Title = "Select Player",
        Values = getPlayersList(),
        Value = nil,
        Callback = function(option)
            selectedPlayer = option
        end
    })

    Players.PlayerAdded:Connect(function()
        DropdownPlayers:Refresh(getPlayersList())
    end)

    tabMisc:Button({
        Title = "Teleport To Player",
        Locked = false,
        Callback = function()
            if selectedPlayer and Players:FindFirstChild(selectedPlayer) and Players[selectedPlayer].Character then
                pcall(function()
                    char:PivotTo(Players[selectedPlayer].Character:GetPivot())
                end)
            end
        end
    })
else
    -- UI failed to load. Still run the automation if the user toggles variables manually in code or from REPL.
    -- Optionally, you could implement a small Roblox-based ScreenGui here as a fallback.
end

-- ---------------------------
-- End
-- ---------------------------
print("[Delta-compatible] Script initialized. If UI didn't show, check the executor output for warnings.")
