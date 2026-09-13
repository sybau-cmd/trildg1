-- Engine: Roblox | Language: Luau | LocalScript inside StarterPlayerScripts or PlayerGui
-- v3: UI rebuilt on Rayfield (https://sirius.menu/gen2) instead of custom CanvasGroup menu

local runService = game:GetService("RunService")
local players = game:GetService("Players")

local plr = players.LocalPlayer
local char = plr.Character
local hum = char:FindFirstChild("Humanoid")
local rootPart = char.PrimaryPart
local remotesFolder = game.ReplicatedStorage:WaitForChild("RemotesFolder")
local liveModifiers = game.ReplicatedStorage:WaitForChild("LiveModifiers")
local floor = game.ReplicatedStorage:WaitForChild("GameData").Floor.Value
local Main_Game = require(plr.PlayerGui.MainUI.Initiator.Main_Game)

local speed = 50
local speedEnabled = false
local fov = 100
local fovEnabled = false
local accEnabled = false
local antiDronesEnabled = false
local fullbrightEnabled = false
local jumpEnabled = false
local slideEnabled = false

local fullbrightColor = Color3.fromRGB(255, 255, 255)
local fullbrightBrightnessValue = 2
local defaultAmbient = game.Lighting.Ambient
local defaultOutdoorAmbient = game.Lighting.OutdoorAmbient
local defaultBrightness = game.Lighting.Brightness
local defaultClockTime = game.Lighting.ClockTime
local defaultFogEnd = game.Lighting.FogEnd

local defaultFov = Main_Game.fovtarget
local accDisabled_PartProperties = {}
local antiDronesConnection = nil
local fullbrightPropertyConnections = {}
local currentRooms = workspace:WaitForChild("CurrentRooms")

-- ---- ESP shared state ----
-- espObjects[key] = { box = Drawing "Square", line = Drawing "Line", label = Drawing "Text" }
-- key is whatever unique table/identity we're tracking per-ESP-kind (a player, or a GoldPile model)
local doorEspObjects = {}
local doorEspConnection = nil
local goldEspObjects = {}
local goldEspConnection = nil

local doorEspEnabled = false
local goldEspEnabled = false
local espShowBox = true
local espShowLine = true
local espShowDistance = true
local espBoxColor = Color3.fromRGB(255, 255, 255)
local espLineColor = Color3.fromRGB(255, 215, 0)

local instantPromptEnabled = false
local promptReachEnabled = false
local promptReachDistance = 50
local promptConnection = nil

local function getExistingProps(part)
	local p = part.CustomPhysicalProperties
	return {
		Friction        = p and p.Friction        or 0.3,
		Elasticity      = p and p.Elasticity      or 0.5,
		FrictionWeight  = p and p.FrictionWeight  or 1,
		ElasticityWeight = p and p.ElasticityWeight or 1,
	}
end

-- ============================================================
-- Shared ESP rendering (Drawing-library based: box + tracer + distance)
-- ============================================================
-- Requires an executor-provided `Drawing` global (Drawing.new / .Visible / etc).
-- If it's missing on this executor, ESP silently no-ops rather than erroring
-- out the whole script.
local hasDrawingLib = typeof(Drawing) == "table" and typeof(Drawing.new) == "function"
local camera = workspace.CurrentCamera

local function createEspObject()
	if not hasDrawingLib then
		return nil
	end
	local box = Drawing.new("Square")
	box.Thickness = 1
	box.Filled = false
	box.Visible = false

	local line = Drawing.new("Line")
	line.Thickness = 1
	line.Visible = false

	local label = Drawing.new("Text")
	label.Size = 14
	label.Center = true
	label.Outline = true
	label.Visible = false

	return { box = box, line = line, label = label }
end

local function destroyEspObject(obj)
	if not obj then
		return
	end
	if obj.box then obj.box:Remove() end
	if obj.line then obj.line:Remove() end
	if obj.label then obj.label:Remove() end
end

local function hideEspObject(obj)
	if not obj then
		return
	end
	obj.box.Visible = false
	obj.line.Visible = false
	obj.label.Visible = false
end

-- anchorPart: a BasePart in the world to draw the ESP around
-- labelText: base text to show (e.g. "Door 3", "Gold")
local function updateEspObject(obj, anchorPart, labelText)
	if not obj or not anchorPart then
		return
	end
	camera = workspace.CurrentCamera
	if not camera then
		hideEspObject(obj)
		return
	end

	local screenPos, onScreen = camera:WorldToViewportPoint(anchorPart.Position)
	if not onScreen or screenPos.Z < 0 then
		hideEspObject(obj)
		return
	end

	local distance = rootPart and (rootPart.Position - anchorPart.Position).Magnitude or 0

	-- Rough on-screen box size that shrinks with distance, clamped so it
	-- never disappears or gets absurdly huge close-up.
	local size = math.clamp(4000 / math.max(distance, 1), 12, 160)

	if espShowBox then
		obj.box.Visible = true
		obj.box.Color = espBoxColor
		obj.box.Size = Vector2.new(size, size)
		obj.box.Position = Vector2.new(screenPos.X - size / 2, screenPos.Y - size / 2)
	else
		obj.box.Visible = false
	end

	if espShowLine then
		obj.line.Visible = true
		obj.line.Color = espLineColor
		obj.line.From = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y)
		obj.line.To = Vector2.new(screenPos.X, screenPos.Y)
	else
		obj.line.Visible = false
	end

	local text = labelText
	if espShowDistance then
		text = text .. string.format(" [%d studs]", math.floor(distance))
	end
	obj.label.Visible = true
	obj.label.Color = Color3.fromRGB(255, 255, 255)
	obj.label.Text = text
	obj.label.Position = Vector2.new(screenPos.X, screenPos.Y - size / 2 - 16)
end

-- WalkAcceleration/TurnAcceleration were added to Humanoid in a 2023 engine
-- update and aren't guaranteed to exist on every build/game's Humanoid
-- instance (confirmed missing on Temu's client per the 12:43/12:52 log —
-- "WalkAcceleration is not a valid member of Humanoid"). pcall so a missing
-- property degrades silently instead of throwing and killing the rest of
-- applyNoAcc/removeNoAcc; the CustomPhysicalProperties loop above is the
-- part actually doing the acceleration-removal work either way.
local function applyNoAcc()
	for _, part in char:GetDescendants() do
		if part:IsA("BasePart") then
			local props = getExistingProps(part)
			accDisabled_PartProperties[part] = part.CustomPhysicalProperties
			part.CustomPhysicalProperties = PhysicalProperties.new(
				100, props.Friction, props.Elasticity, props.FrictionWeight, props.ElasticityWeight
			)
		end
	end
	if hum then
		pcall(function() hum.WalkAcceleration = 1000 end)
		pcall(function() hum.TurnAcceleration = 1000 end)
	end
end

local function removeNoAcc()
	for part, original in accDisabled_PartProperties do
		if part and part.Parent then
			part.CustomPhysicalProperties = original
		end
	end
	accDisabled_PartProperties = {}
	if hum then
		pcall(function() hum.WalkAcceleration = 8 end)
		pcall(function() hum.TurnAcceleration = 8 end)
	end
end

local function applyAntiDrones()
	for _, v in workspace:GetDescendants() do
		if v:IsA("RemoteEvent") and v.Name == "WalkedInto" then
			v:Destroy()
		end
	end
	antiDronesConnection = workspace.DescendantAdded:Connect(function(a0)
		if a0:IsA("RemoteEvent") and a0.Name == "WalkedInto" then
			a0:Destroy()
		end
	end)
end

local function removeAntiDrones()
	if antiDronesConnection then
		antiDronesConnection:Disconnect()
		antiDronesConnection = nil
	end
end

local function clearDoorEsp()
	for _, obj in doorEspObjects do
		destroyEspObject(obj)
	end
	doorEspObjects = {}
end

local function updateDoorEsp()
	local seenThisPass = {}
	for _, otherPlr in players:GetPlayers() do
		local currentRoom = otherPlr:GetAttribute("CurrentRoom")
		if currentRoom ~= nil then
			local targetRoomIndex = tostring(tonumber(currentRoom))
			local targetRoom = currentRooms:FindFirstChild(targetRoomIndex)
			local doorModel = targetRoom and targetRoom:FindFirstChild("Door")
			if doorModel and doorModel:IsA("Model") then
				seenThisPass[otherPlr] = true
				local anchor = doorModel.PrimaryPart or doorModel:FindFirstChildWhichIsA("BasePart")
				if anchor then
					local obj = doorEspObjects[otherPlr]
					if not obj then
						obj = createEspObject()
						doorEspObjects[otherPlr] = obj
					end

					local sign = doorModel:FindFirstChild("Sign")
					local stinker = sign and sign:FindFirstChild("Stinker")
					local doorText = (stinker and stinker:IsA("TextLabel") and stinker.Text) or doorModel.Name
					updateEspObject(obj, anchor, "Door " .. tostring(doorText))
				end
			end
		end
	end

	for otherPlr, obj in doorEspObjects do
		if not seenThisPass[otherPlr] then
			destroyEspObject(obj)
			doorEspObjects[otherPlr] = nil
		end
	end
end

local function applyDoorEsp()
	updateDoorEsp()
	doorEspConnection = runService.Heartbeat:Connect(updateDoorEsp)
end

local function removeDoorEsp()
	if doorEspConnection then
		doorEspConnection:Disconnect()
		doorEspConnection = nil
	end
	clearDoorEsp()
end

-- ============================================================
-- Gold ESP: finds any model named "GoldPile" under workspace
-- ============================================================
local function findGoldPileAnchor(model)
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function clearGoldEsp()
	for _, obj in goldEspObjects do
		destroyEspObject(obj)
	end
	goldEspObjects = {}
end

local function updateGoldEsp()
	local seenThisPass = {}
	for _, model in workspace:GetDescendants() do
		if model:IsA("Model") and model.Name == "GoldPile" then
			local anchor = findGoldPileAnchor(model)
			if anchor then
				seenThisPass[model] = true
				local obj = goldEspObjects[model]
				if not obj then
					obj = createEspObject()
					goldEspObjects[model] = obj
				end
				updateEspObject(obj, anchor, "Gold")
			end
		end
	end

	for model, obj in goldEspObjects do
		if not seenThisPass[model] or not model.Parent then
			destroyEspObject(obj)
			goldEspObjects[model] = nil
		end
	end
end

local function applyGoldEsp()
	updateGoldEsp()
	goldEspConnection = runService.Heartbeat:Connect(updateGoldEsp)
end

local function removeGoldEsp()
	if goldEspConnection then
		goldEspConnection:Disconnect()
		goldEspConnection = nil
	end
	clearGoldEsp()
end

local function getCurrentSpeed()
	local Speed = 15
	Speed += char:GetAttribute("SpeedBoost")      or 0
	Speed += char:GetAttribute("SpeedBoostBehind") or 0
	Speed += char:GetAttribute("SpeedBoostExtra")  or 0
	Speed += (floor == "Party" and 10 or 0)
	Speed += (liveModifiers:FindFirstChild("PlayerFast")    and 3  or 0)
	Speed += (liveModifiers:FindFirstChild("PlayerFaster")  and 6  or 0)
	Speed += (liveModifiers:FindFirstChild("PlayerFastest") and 20 or 0)
	Speed -= (liveModifiers:FindFirstChild("PlayerSlow")    and 3  or 0)
	if char:GetAttribute("Crouching") == true then
		if liveModifiers:FindFirstChild("PlayerCrouchSlow") then
			Speed -= 8
		elseif liveModifiers:FindFirstChild("PlayerSlow") then
			Speed -= 8
		else
			Speed -= 5
		end
	end
	return Speed
end

-- ---- Fullbright: hardened against game overrides ----
-- The prior version only re-applied on Heartbeat (up to ~16ms of visible
-- flicker if the game's own lighting script wins the frame race). This
-- hooks GetPropertyChangedSignal on each watched property so any external
-- write is caught and immediately overwritten on the same tick it happens,
-- in addition to the Heartbeat loop as a backstop for properties that
-- don't fire change signals reliably (e.g. FogEnd on some game builds).
local FULLBRIGHT_WATCHED_PROPS = { "Ambient", "OutdoorAmbient", "Brightness", "ClockTime", "FogEnd" }

local function forceFullbrightNow()
	game.Lighting.Ambient = fullbrightColor
	game.Lighting.OutdoorAmbient = fullbrightColor
	game.Lighting.Brightness = fullbrightBrightnessValue
	game.Lighting.ClockTime = 14
	game.Lighting.FogEnd = 100000
end

local function connectFullbrightWatchers()
	for _, propName in FULLBRIGHT_WATCHED_PROPS do
		local ok, conn = pcall(function()
			return game.Lighting:GetPropertyChangedSignal(propName):Connect(function()
				if fullbrightEnabled then
					forceFullbrightNow()
				end
			end)
		end)
		if ok and conn then
			table.insert(fullbrightPropertyConnections, conn)
		end
	end
end

local function disconnectFullbrightWatchers()
	for _, conn in fullbrightPropertyConnections do
		conn:Disconnect()
	end
	fullbrightPropertyConnections = {}
end

connectFullbrightWatchers() -- always listening; forceFullbrightNow() only fires while enabled

local promptPropertyConnections = {}
local hookedPrompts = {}

local function applyPromptOverrides(prompt)
	if instantPromptEnabled then
		prompt.HoldDuration = 0
	end
	if promptReachEnabled then
		prompt.MaxActivationDistance = promptReachDistance
	end
end

local function hookPrompt(prompt)
	applyPromptOverrides(prompt)
	if hookedPrompts[prompt] then
		return
	end
	hookedPrompts[prompt] = true
	local holdConn = prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
		if instantPromptEnabled and prompt.HoldDuration ~= 0 then
			prompt.HoldDuration = 0
		end
	end)
	local reachConn = prompt:GetPropertyChangedSignal("MaxActivationDistance"):Connect(function()
		if promptReachEnabled and prompt.MaxActivationDistance ~= promptReachDistance then
			prompt.MaxActivationDistance = promptReachDistance
		end
	end)
	table.insert(promptPropertyConnections, holdConn)
	table.insert(promptPropertyConnections, reachConn)
end

local function sweepExistingPrompts()
	for _, obj in workspace:GetDescendants() do
		if obj:IsA("ProximityPrompt") then
			hookPrompt(obj)
		end
	end
end

local function refreshAllPrompts()
	for _, obj in workspace:GetDescendants() do
		if obj:IsA("ProximityPrompt") then
			applyPromptOverrides(obj)
		end
	end
end

local function ensurePromptWatcher()
	sweepExistingPrompts()
	if not promptConnection then
		promptConnection = workspace.DescendantAdded:Connect(function(obj)
			if obj:IsA("ProximityPrompt") then
				hookPrompt(obj)
			end
		end)
	end
end

local function teardownPromptWatcher()
	if promptConnection then
		promptConnection:Disconnect()
		promptConnection = nil
	end
	for _, conn in promptPropertyConnections do
		conn:Disconnect()
	end
	promptPropertyConnections = {}
	hookedPrompts = {}
end

-- ============================================================
-- UI: Rayfield (real library, loaded live — not hand-built)
-- ============================================================
local Rayfield = loadstring(game:HttpGet("https://raw.githubusercontent.com/sybau-cmd/trildg/main/message.lua"))()

local window = Rayfield:CreateWindow({
	name = "TRILDG",
	subtitle = "Client",
	sidebarLayout = true,
	theme = "default",
})

local movementTab = window:CreateTab({ name = "Movement" })
local visualTab   = window:CreateTab({ name = "Visual" })
local worldTab    = window:CreateTab({ name = "World" })

-- ---- Movement ----
movementTab:CreateToggle({
	name = "Speed",
	value = false,
	callback = function(value)
		speedEnabled = value
		if not value and hum then
			hum.WalkSpeed = getCurrentSpeed()
		end
	end,
})

movementTab:CreateSlider({
	name = "Speed Value",
	range = { 0, 200 },
	increment = 1,
	value = speed,
	callback = function(value)
		speed = value
	end,
})

movementTab:CreateToggle({
	name = "No Acceleration",
	value = false,
	callback = function(value)
		accEnabled = value
		if value then
			applyNoAcc()
		else
			removeNoAcc()
		end
	end,
})

movementTab:CreateToggle({
	name = "Jump",
	value = false,
	callback = function(value)
		jumpEnabled = value
		char:SetAttribute("CanJump", value)
	end,
})

movementTab:CreateToggle({
	name = "Slide",
	value = false,
	callback = function(value)
		slideEnabled = value
		char:SetAttribute("CanSlide", value)
	end,
})

-- ---- Visual ----
visualTab:CreateToggle({
	name = "Fullbright",
	value = false,
	callback = function(value)
		fullbrightEnabled = value
		if value then
			forceFullbrightNow()
		else
			game.Lighting.Ambient = defaultAmbient
			game.Lighting.OutdoorAmbient = defaultOutdoorAmbient
			game.Lighting.Brightness = defaultBrightness
			game.Lighting.ClockTime = defaultClockTime
			game.Lighting.FogEnd = defaultFogEnd
		end
	end,
})

visualTab:CreateColorPicker({
	name = "Fullbright Color",
	color = fullbrightColor,
	callback = function(value)
		fullbrightColor = value
		if fullbrightEnabled then
			forceFullbrightNow()
		end
	end,
})

visualTab:CreateSlider({
	name = "Fullbright Strength",
	range = { 1, 10 },
	increment = 1,
	value = fullbrightBrightnessValue,
	callback = function(value)
		fullbrightBrightnessValue = value
		if fullbrightEnabled then
			forceFullbrightNow()
		end
	end,
})

visualTab:CreateToggle({
	name = "FOV",
	value = false,
	callback = function(value)
		fovEnabled = value
		Main_Game.fovtarget = value and fov or defaultFov
	end,
})

visualTab:CreateSlider({
	name = "FOV Value",
	range = { 50, 120 },
	increment = 1,
	value = fov,
	callback = function(value)
		fov = value
		if fovEnabled then
			Main_Game.fovtarget = fov
		end
	end,
})

-- ---- Visual: ESP ----
visualTab:CreateToggle({
	name = "Door ESP",
	value = false,
	callback = function(value)
		doorEspEnabled = value
		if value then
			applyDoorEsp()
		else
			removeDoorEsp()
		end
	end,
})

visualTab:CreateToggle({
	name = "Gold ESP",
	value = false,
	callback = function(value)
		goldEspEnabled = value
		if value then
			applyGoldEsp()
		else
			removeGoldEsp()
		end
	end,
})

visualTab:CreateToggle({
	name = "ESP: Show Box",
	value = true,
	callback = function(value)
		espShowBox = value
	end,
})

visualTab:CreateToggle({
	name = "ESP: Show Line",
	value = true,
	callback = function(value)
		espShowLine = value
	end,
})

visualTab:CreateToggle({
	name = "ESP: Show Distance",
	value = true,
	callback = function(value)
		espShowDistance = value
	end,
})

visualTab:CreateColorPicker({
	name = "ESP Box Color",
	color = espBoxColor,
	callback = function(value)
		espBoxColor = value
	end,
})

visualTab:CreateColorPicker({
	name = "ESP Line Color",
	color = espLineColor,
	callback = function(value)
		espLineColor = value
	end,
})

-- ---- World ----
worldTab:CreateToggle({
	name = "Anti Drones",
	value = false,
	callback = function(value)
		antiDronesEnabled = value
		if value then
			applyAntiDrones()
		else
			removeAntiDrones()
		end
	end,
})

worldTab:CreateToggle({
	name = "Instant Prompt",
	value = false,
	callback = function(value)
		instantPromptEnabled = value
		if value or promptReachEnabled then
			ensurePromptWatcher()
		end
		if value then
			refreshAllPrompts()
		end
		if not instantPromptEnabled and not promptReachEnabled then
			teardownPromptWatcher()
		end
	end,
})

worldTab:CreateToggle({
	name = "Prompt Reach",
	value = false,
	callback = function(value)
		promptReachEnabled = value
		if value or instantPromptEnabled then
			ensurePromptWatcher()
		end
		if value then
			refreshAllPrompts()
		end
		if not instantPromptEnabled and not promptReachEnabled then
			teardownPromptWatcher()
		end
	end,
})

worldTab:CreateSlider({
	name = "Prompt Reach Distance",
	range = { 5, 200 },
	increment = 1,
	value = promptReachDistance,
	callback = function(value)
		promptReachDistance = value
		if promptReachEnabled then
			refreshAllPrompts()
		end
	end,
})

-- ============================================================
-- Main loop
-- ============================================================
runService.Heartbeat:Connect(function()
	if speedEnabled then
		remotesFolder.Crouch:FireServer(speedEnabled, true)
		if hum then hum.WalkSpeed = getCurrentSpeed() + speed end
	end
	if fovEnabled then
		Main_Game.fovtarget = fov
	end
	if fullbrightEnabled then
		-- backstop re-apply every frame in addition to the property-changed
		-- hooks above, in case the game overrides a property that doesn't
		-- fire a change signal on this build
		forceFullbrightNow()
	end
	if jumpEnabled then
		char:SetAttribute("CanJump", true)
	end
	if slideEnabled then
		char:SetAttribute("CanSlide", true)
	end
end)
