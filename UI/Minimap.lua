local ADDON, ns = ...

--[[
The minimap button: left click opens the editor, right click a short menu.

LibDBIcon draws it, lets it be dragged round the minimap, and keeps where it
is and whether it is hidden in the table it is handed, which is the profile's
`minimap`. It is fed from a LibDataBroker object, so a broker bar shows
RaidMap as well, with the same clicks and the same tooltip.
]]

local LibDD = LibStub("LibUIDropDownMenu-4.0")
local LibDBIcon = LibStub("LibDBIcon-1.0")

local NAME = "RaidMap"

-- "left click: open or close the editor", with the click in grey.
local HINT = "|cffcfcfcf%s|r: %s"

-- Says nothing itself: the options panel's tick shows what happened there, and
-- the callers with nothing on screen to show it say so in chat.
function ns.SetMinimapShown(shown)
	ns.db.profile.minimap.hide = not shown
	if shown then LibDBIcon:Show(NAME) else LibDBIcon:Hide(NAME) end
end

local menuFrame

local function ShowMenu()
	menuFrame = menuFrame or LibDD:Create_UIDropDownMenu("RaidMapMinimapMenu", UIParent)
	LibDD:EasyMenu({
		{ text = NAME, isTitle = true, notCheckable = true },
		{
			text = "Hide Minimap Icon",
			notCheckable = true,
			func = function()
				ns.SetMinimapShown(false)
				-- The button that would undo it has just gone.
				ns:Print("Minimap icon hidden. /rm minimap brings it back, and so does Options > AddOns > RaidMap.")
			end,
		},
	}, menuFrame, "cursor", 0, 0, "MENU", 2)
end

local object = LibStub("LibDataBroker-1.1"):NewDataObject(NAME, {
	type = "launcher",
	icon = "Interface\\AddOns\\RaidMap\\Art\\Icon",

	OnClick = function(_, button)
		if button == "LeftButton" then
			ns.Events:Fire("TOGGLE_WINDOW")
		elseif button == "RightButton" then
			-- Tooltips sit on a higher strata than menus, and this one would
			-- stay up over the menu until the mouse left the button.
			LibDBIcon.tooltip:Hide()
			ShowMenu()
		end
	end,

	OnTooltipShow = function(tooltip)
		tooltip:AddLine(NAME, 1, 1, 1)
		tooltip:AddLine(HINT:format("left click", "open or close the editor"))
		tooltip:AddLine(HINT:format("right click", "quick menu"))
	end,
})

ns.Events:On("READY", function()
	LibDBIcon:Register(NAME, object, ns.db.profile.minimap)
end)
