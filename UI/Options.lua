local ADDON, ns = ...

--[[
RaidMap's page under Options > AddOns.

The board's own settings live on the editor, next to what they change. This
page is for what has no home there, which so far is the minimap button.
]]

-- Starts hidden. The options window shows it when its page is picked, and
-- OnShow fills it in then.
local panel = CreateFrame("Frame")
panel:Hide()

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("RaidMap")

-- Labels at LEFT, controls at LEFT + CONTROL. A row's y is its middle.
local LEFT = 16
local CONTROL = 130

local function section(y, heading)
	local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", LEFT, y)
	header:SetText(heading)
end

local toggles = {}

local function createToggle(y, text, get, set)
	local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("LEFT", panel, "TOPLEFT", LEFT, y)
	label:SetText(text)

	-- The checkbox art has some padding on its left.
	local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	check:SetPoint("LEFT", panel, "TOPLEFT", LEFT + CONTROL - 4, y)
	check.get = get
	check:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)
	toggles[#toggles + 1] = check
	return check
end

section(-56, "Minimap")
panel.minimapToggle = createToggle(-86, "Show minimap icon",
	function() return not ns.db.profile.minimap.hide end,
	function(on) ns.SetMinimapShown(on) end)

-- Read on every show, because the icon can also be hidden from its own menu
-- and brought back with /rm minimap while this page is shut.
panel:SetScript("OnShow", function()
	for _, check in ipairs(toggles) do
		check:SetChecked(check.get())
	end
end)

ns.optionsPanel = panel

if Settings and Settings.RegisterCanvasLayoutCategory then
	Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "RaidMap"))
elseif InterfaceOptions_AddCategory then
	-- A client from before the Settings window, which lists a page by its name.
	panel.name = "RaidMap"
	InterfaceOptions_AddCategory(panel)
end
