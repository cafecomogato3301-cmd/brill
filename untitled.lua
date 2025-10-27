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

-- Auto-dodge state
local autododge = false
local dodgeCooldown = false
local dodgeCooldownTime = 0.9 -- seconds between dodges
local dodgeRange = 14 -- consider attacker if within this range
local dodgeOffset = 12 -- how far to sidestep
local recentToolActivations = {} -- tool -> timestamp

-- ---------------------------
-- Core helper functions (kept mostly as original)
-- ---------------------------
local function drill()
    if not char or not char.Parent then return end
    local tool = char:FindFirstChildOfClass("Tool")
    if tool and string.match(tool.Name or "", "Hand") then
        pcall(function()
            game:GetService("ReplicatedStorage").Packages.Knit.Services.OreService.RE.RequestRandomOre:FireServer()
        end)
    else
        for _,v in ipairs(plr.Backpack:GetChildren()) do
            if string.match(v.Name or "", "Hand") then
                pcall(function()
                    char.Humanoid:EquipTool(v)
                    game:GetService("ReplicatedStorage").Packages.Knit.Services.OreService.RE.RequestRandomOre:FireServer()
                end)
                break
            end
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
-- Auto-Dodge: detection and dodge implementation
-- ---------------------------

-- safe helper to get humanoidrootpart
local function getHRP(c)
    if not c or not c.Parent then return nil end
    return c:FindFirstChild("HumanoidRootPart")
end

-- Attempt to sidestep/teleport a short distance perpendicular to attacker
local function tryDodgeFrom(attackerChar)
    if not char or not char.Parent or dodgeCooldown then return end
    if not attackerChar or not attackerChar.Parent then return end

    local myHRP = getHRP(char)
    local attHRP = getHRP(attackerChar)
    if not myHRP or not attHRP then return end

    local oldPivot = char:GetPivot()
    local dir = (oldPivot.Position - attHRP.Position)
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 1 then
        dir = Vector3.new(0, 0, -1)
    end
    local perp = Vector3.new(-dir.Z, 0, dir.X).Unit
    local candidates = {
        oldPivot.Position + perp * dodgeOffset,
        oldPivot.Position - perp * dodgeOffset,
        oldPivot.Position + dir.Unit * dodgeOffset * 0.6
    }

    dodgeCooldown = true
    task.spawn(function()
        task.wait(dodgeCooldownTime)
        dodgeCooldown = false
    end)

    for _,pos in ipairs(candidates) do
        local newCFrame = CFrame.new(pos + Vector3.new(0, 3, 0)) -- slightly above ground to avoid getting stuck
        local ok = pcall(function()
            char:PivotTo(newCFrame)
        end)
        if ok then
            -- small wait to let teleport take effect
            task.wait(0.04)
            return
        end
    end
end

-- Heuristic: check animation track names or animation asset ids for attack keywords
local attackKeywords = {"punch", "attack", "swing", "hit", "jab", "strike"}

local function trackLooksLikeAttack(track)
    if not track then return false end
    local name = ""
    pcall(function()
        if track.Name then name = track.Name:lower() end
    end)
    if name and name ~= "" then
        for _,k in ipairs(attackKeywords) do
            if name:find(k) then
                return true
            end
        end
    end
    -- try Animation property
    local animId = ""
    pcall(function()
        if track.Animation and track.Animation.AnimationId then
            animId = tostring(track.Animation.AnimationId):lower()
        end
    end)
    if animId and animId ~= "" then
        for _,k in ipairs(attackKeywords) do
            if animId:find(k) then
                return true
            end
        end
    end
    return false
end

-- If a tool on a character was activated recently, consider it a threat
local function toolWasActivatedRecently(tool)
    local t = recentToolActivations[tool]
    if not t then return false end
    return (tick() - t) < 0.6
end

-- Monitor a given character's tools to capture Activated events
local function monitorToolsOnCharacter(ch)
    if not ch then return end
    for _,inst in ipairs(ch:GetChildren()) do
        if inst:IsA("Tool") then
            -- connect once per tool
            if not inst:FindFirstChild("__auto_dodge_hooked") then
                local marker = Instance.new("BoolValue")
                marker.Name = "__auto_dodge_hooked"
                marker.Parent = inst
                pcall(function()
                    inst.Activated:Connect(function()
                        recentToolActivations[inst] = tick()
                    end)
                end)
            end
        end
    end
    -- watch for future tools
    ch.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            task.wait(0.01)
            if not child:FindFirstChild("__auto_dodge_hooked") then
                local marker = Instance.new("BoolValue")
                marker.Name = "__auto_dodge_hooked"
                marker.Parent = child
                pcall(function()
                    child.Activated:Connect(function()
                        recentToolActivations[child] = tick()
                    end)
                end)
            end
        end
    end)
end

-- Main loop that scans players for attack indicators
task.spawn(function()
    while true do
        if autododge and char and char.Parent and char:FindFirstChildOfClass("Humanoid") then
            for _,p in ipairs(Players:GetPlayers()) do
                if p ~= plr then
                    local ch = p.Character
                    if ch and ch.Parent then
                        -- ensure tools are monitored
                        monitorToolsOnCharacter(ch)
                        local humanoid = ch:FindFirstChildOfClass("Humanoid")
                        if humanoid then
                            -- 1) check animation tracks
                            local isAttacking = false
                            local ok, tracks = pcall(function() return humanoid:GetPlayingAnimationTracks() end)
                            if ok and tracks then
                                for _,t in ipairs(tracks) do
                                    if trackLooksLikeAttack(t) then
                                        isAttacking = true
                                        break
                                    end
                                end
                            end
                            -- 2) check if any tool was activated recently
                            for _,tool in ipairs(ch:GetChildren()) do
                                if tool:IsA("Tool") then
                                    if toolWasActivatedRecently(tool) then
                                        isAttacking = true
                                        break
                                    end
                                end
                            end

                            if isAttacking then
                                -- distance check
                                local myHRP = getHRP(char)
                                local attHRP = getHRP(ch)
                                if myHRP and attHRP then
                                    local dist = (myHRP.Position - attHRP.Position).Magnitude
                                    if dist <= dodgeRange then
                                        pcall(function()
                                            tryDodgeFrom(ch)
                                        end)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        task.wait(0.08)
    end
end)

-- Keep pruning old tool activation timestamps periodically
task.spawn(function()
    while true do
        local now = tick()
        for tool,ts in pairs(recentToolActivations) do
            if (now - ts) > 1.5 then
                recentToolActivations[tool] = nil
            end
        end
        task.wait(1.5)
    end
end)

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
    -- Fallback minimal ScreenGui so the user can toggle Auto-Dodge even if WindUI failed.
    -- This creates a small panel at the top-left with a toggle button that controls 'autododge'.
    local success, err = pcall(function()
        local playerGui = plr:WaitForChild("PlayerGui")
        -- remove existing fallback if present
        local existing = playerGui:FindFirstChild("DeltaFallbackUI")
        if existing then
            existing:Destroy()
        end

        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "DeltaFallbackUI"
        screenGui.ResetOnSpawn = false
        screenGui.Parent = playerGui

        local frame = Instance.new("Frame")
        frame.Name = "Panel"
        frame.Size = UDim2.fromOffset(220, 80)
        frame.Position = UDim2.new(0.02, 0, 0.02, 0)
        frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        frame.BorderSizePixel = 0
        frame.Parent = screenGui

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.Size = UDim2.new(1, 0, 0, 24)
        title.Position = UDim2.new(0, 0, 0, 0)
        title.BackgroundTransparency = 1
        title.Text = "Auto Dodge"
        title.TextColor3 = Color3.fromRGB(255, 255, 255)
        title.Font = Enum.Font.SourceSansBold
        title.TextSize = 18
        title.Parent = frame

        local toggleBtn = Instance.new("TextButton")
        toggleBtn.Name = "ToggleBtn"
        toggleBtn.Size = UDim2.fromOffset(200, 36)
        toggleBtn.Position = UDim2.new(0, 10, 0, 34)
        toggleBtn.AutoButtonColor = true
        toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        toggleBtn.Font = Enum.Font.SourceSans
        toggleBtn.TextSize = 16
        toggleBtn.Parent = frame

        local function updateButton()
            if autododge then
                toggleBtn.Text = "Enabled"
                toggleBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 50)
            else
                toggleBtn.Text = "Disabled"
                toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
            end
        end

        updateButton()
        toggleBtn.MouseButton1Click:Connect(function()
            autododge = not autododge
            updateButton()
        end)
    end)
    if not success then
        warn("Fallback UI failed: ", err)
    end
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
                        task.wait()
                    end
                end)
            end
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

    -- Auto-Dodge toggle (integrated like the others)
    tabMain:Toggle({
        Title = "Auto Dodge (detect punches)",
        Type = "Toggle",
        Default = false,
        Callback = function(state)
            autododge = state
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
    -- The fallback GUI above was created to toggle autododge.
end

-- ---------------------------
-- End
-- ---------------------------
print("[Delta-compatible] Script initialized. If UI didn't show, check the executor output for warnings.")
