-- Cooldown Mouse: settings panel (Game Menu > Options > AddOns > Cooldown Mouse).
local ADDON, ns = ...

local category
local registered = {} -- key -> setting object, so Reset can push defaults into the panel

local SHAPES = {} -- built from ns.SHAPE_NAMES in Core.lua, e.g. { "star", "Star" }
for _, name in ipairs(ns.SHAPE_NAMES) do
	SHAPES[#SHAPES + 1] = { name, name:sub(1, 1):upper() .. name:sub(2) }
end
local MODES = {
	{ "auto", "Automatic (by class)" },
	{ "melee", "Melee swing" },
	{ "ranged", "Ranged / Auto Shot" },
	{ "mana", "Mana regen (5 second rule)" },
	{ "none", "Off" },
}
local STYLES = {
	{ "sweep", "Eats itself (sweep)" },
	{ "fade", "Fades out" },
}
local DIRECTIONS = {
	{ "cw", "Clockwise" },
	{ "ccw", "Counter-clockwise" },
}
local COLOR_LABELS = {
	highlight = "Highlight ring",
	melee = "Melee timer",
	ranged = "Ranged timer",
	mana = "Mana timer",
}

-------------------------------------------------------------------------------
-- Color picker
-------------------------------------------------------------------------------

function ns.PickColor(key)
	local c = ns.settings.colors[key]
	local old = { r = c.r, g = c.g, b = c.b }

	local function Set(r, g, b)
		c.r, c.g, c.b = r, g, b
		ns.Apply()
	end
	local function OnPick()
		Set(ColorPickerFrame:GetColorRGB())
	end
	local function OnCancel()
		Set(old.r, old.g, old.b)
	end

	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = c.r, g = c.g, b = c.b,
			hasOpacity = false,
			swatchFunc = OnPick,
			cancelFunc = OnCancel,
		})
	else
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.previousValues = old
		ColorPickerFrame.func = OnPick
		ColorPickerFrame.cancelFunc = OnCancel
		ColorPickerFrame:SetColorRGB(c.r, c.g, c.b)
		ShowUIPanel(ColorPickerFrame)
	end
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------

local function Register()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("Cooldown Mouse")

	local function Header(text)
		if layout and CreateSettingsListSectionHeaderInitializer then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
		end
	end

	local function Button(label, buttonText, onClick, tooltip)
		if layout and CreateSettingsButtonInitializer then
			layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
		end
	end

	local function Setting(key, varType, label)
		local setting = Settings.RegisterAddOnSetting(category, "COOLDOWNMOUSE_" .. key, key, ns.settings,
			varType, label, ns.defaults[key])
		setting:SetValueChangedCallback(function()
			ns.Apply()
			if key == "shape" then ns.RefreshShown() end
		end)
		registered[key] = setting
		return setting
	end

	local function Checkbox(key, label, tooltip)
		Settings.CreateCheckbox(category, Setting(key, Settings.VarType.Boolean, label), tooltip)
	end

	local function Slider(key, label, tooltip, min, max, step, fmt)
		local options = Settings.CreateSliderOptions(min, max, step)
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, fmt)
		return Settings.CreateSlider(category, Setting(key, Settings.VarType.Number, label), options, tooltip)
	end

	local function Dropdown(key, label, tooltip, list)
		local function Options()
			local c = Settings.CreateControlTextContainer()
			for _, o in ipairs(list) do c:Add(o[1], o[2]) end
			return c:GetData()
		end
		return Settings.CreateDropdown(category, Setting(key, Settings.VarType.String, label), Options, tooltip)
	end

	local function ColorButton(key, tooltip)
		Button(COLOR_LABELS[key] .. " color", "Choose", function() ns.PickColor(key) end, tooltip)
	end

	local pct = function(v) return string.format("%d%%", v * 100 + 0.5) end
	local num = function(v) return string.format("%d", v) end

	Checkbox("enabled", "Enabled", "Show the cursor rings.")

	Header("Highlight ring")
	local shapeInit = Dropdown("shape", "Shape", "Shape of both rings.", SHAPES)
	local lengthInit = Slider("penisLength", "How long are you?",
		"Stretches the shaft from the balls to the tip. The thickness stays the same.", 1, 12, 0.5,
		function(v) return string.format('%.1f"', v) end)
	-- Only show "How long are you?" while the penis shape is picked.
	local function IsPenis() return ns.settings.shape == "penis" end
	if lengthInit then
		if lengthInit.SetParentInitializer and shapeInit then
			lengthInit:SetParentInitializer(shapeInit, IsPenis)
		end
		if lengthInit.AddShownPredicate then
			lengthInit:AddShownPredicate(IsPenis)
		end
	end
	Slider("size", "Size", "How wide the highlight ring is.", 8, 160, 1, num)
	Slider("thickness", "Thickness", "How thick the highlight ring's line is.", 1, 10, 0.5,
		function(v) return string.format("%.1f", v) end)
	Slider("alpha", "Opacity", "How solid the highlight ring is. Lower is more see-through.", 0, 1, 0.05, pct)
	ColorButton("highlight", "Color of the ring that always follows your cursor.")
	Checkbox("combatOnly", "Only in combat",
		"Hide the highlight ring out of combat. The timer rings still show whenever a timer runs.")

	Header("Timer rings")
	local AUTO_HELP = " Automatic: Hunters show ranged first, then melee. Warriors and Rogues show melee. Mages, Priests and Warlocks show the mana rule. Druids, Shamans and Paladins show melee while auto-attacking, otherwise the mana rule."
	Dropdown("outerMode", "Outer ring tracks",
		"What the ring just outside the highlight ring shows. It only appears while that timer is running." .. AUTO_HELP,
		MODES)
	Dropdown("innerMode", "Inner ring tracks",
		"What the ring just inside the highlight ring shows. It only appears while that timer is running." .. AUTO_HELP,
		MODES)
	Dropdown("style", "Style",
		"Eats itself: the ring disappears piece by piece until it's gone. Fades out: the whole ring fades away.", STYLES)
	Dropdown("direction", "Direction", "Which way the timer rings eat themselves, starting from the top.", DIRECTIONS)
	Slider("gap", "Gap", "Space between the highlight ring and each timer ring.", 0, 20, 1, num)
	Slider("timerThickness", "Thickness", "How thick the timer rings' lines are.", 1, 10, 0.5,
		function(v) return string.format("%.1f", v) end)
	Slider("timerAlpha", "Opacity", "How solid the timer rings are.", 0.1, 1, 0.05, pct)
	ColorButton("melee", "Color of the timer ring for melee swings.")
	ColorButton("ranged", "Color of the timer ring for Auto Shot and wands.")
	ColorButton("mana", "Color of the timer ring for the mana rule, and of the flash when it ends.")
	Checkbox("manaFlash", "Flash when mana regen speeds up",
		"Flash the highlight ring when five seconds have passed since you last spent mana.")

	Header("Try it")
	Button("Test timer", "Run", function()
		local s = ns.settings
		local kind = ns.Priority(s.outerMode)[1] or ns.Priority(s.innerMode)[1] or "melee"
		ns.StartTimer(kind, 3)
	end, "Run a 3 second timer so you can see how the ring looks.")
	Button("Defaults", "Reset", function()
		ns.Reset()
		ns.Print("Settings reset.")
	end, "Put every setting, including colors, back to the defaults.")

	Settings.RegisterAddOnCategory(category)
end

-- Show or hide rows that depend on another setting (the length slider under Shape).
function ns.RefreshShown()
	if not (SettingsPanel and SettingsPanel:IsShown() and SettingsPanel.GetSettingsList) then return end
	local list = SettingsPanel:GetSettingsList()
	if not list then return end
	pcall(function()
		if SettingsInbound and SettingsInbound.RepairDisplay then
			SettingsInbound.RepairDisplay()
		elseif list.ScrollBox and list.ScrollBox.ForEachFrame then
			list.ScrollBox:ForEachFrame(function(frame)
				if frame.EvaluateState then frame:EvaluateState() end
			end)
		end
	end)
end

-- Push values changed from slash commands or Reset into the panel's controls.
function ns.RefreshOptions()
	for key, setting in pairs(registered) do
		local v = ns.settings[key]
		if v ~= nil and setting.SetValue and setting:GetValue() ~= v then
			setting:SetValue(v)
		end
	end
end

function ns.SetupOptions()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
	local ok, err = pcall(Register)
	if not ok then
		category = nil
		ns.Print("Settings panel unavailable (" .. tostring(err) .. "). Type /mouse help for slash commands.")
	end
end

function ns.OpenOptions()
	if category and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	else
		ns.Print("Settings panel unavailable. Type /mouse help for slash commands.")
	end
end

function CooldownMouse_OnAddonCompartmentClick()
	ns.OpenOptions()
end
