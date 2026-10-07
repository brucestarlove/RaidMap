local ADDON, ns = ...

-- Blizzard's UIDropDownMenu_* globals do not exist in this client. Every addon
-- here that needs a dropdown vendors this library instead.
local LibDD = LibStub("LibUIDropDownMenu-4.0")

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local WINDOW_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"

-- Height of the row of captions over the dropdowns. Everything under the title
-- bar sits this much lower to make room for it.
local CAPTION_ROW = 14

local frame

-- Clamped, because undoing a slide add can leave currentSlide past the end.
local function CurrentSlide()
	local board = ns:CurrentBoard()
	local index = math.max(1, math.min(board.currentSlide or 1, #board.slides))
	board.currentSlide = index
	return board.slides[index]
end

local function SavePosition()
	local w = ns.db.profile.window
	local point, _, relPoint, x, y = frame:GetPoint()
	w.point, w.relPoint, w.x, w.y = point, relPoint, x, y
	w.width, w.height = frame:GetWidth(), frame:GetHeight()
end

local function RestorePosition()
	local w = ns.db.profile.window
	frame:ClearAllPoints()
	frame:SetSize(w.width, w.height)
	frame:SetPoint(w.point, UIParent, w.relPoint, w.x, w.y)
end

local function SelectMap(key, skipSave)
	local entry = ns.Catalog:Find(key)
	if not entry then
		ns:Print("Unknown map '%s'.", tostring(key))
		return
	end

	local ok = frame.canvas:SetArt(entry.art)
	if frame.mapDropdown then
		LibDD:UIDropDownMenu_SetText(frame.mapDropdown, entry.name)
	end

	if not skipSave then
		local slide = CurrentSlide()
		slide.mapKey = key
		slide.view.cx, slide.view.cy, slide.view.zoom = 0.5, 0.5, 1
		frame.canvas:SetView(0.5, 0.5, 1)
		-- An edit like any other: without this a map change never syncs.
		ns.Model:Touch()
	end

	ns.db.profile.lastMap = key

	if not ok then
		ns:Print("|cffff5555Failed to resolve art for '%s'.|r", entry.name)
	end
end

local function AddMapButton(text, key, level)
	local info = LibDD:UIDropDownMenu_CreateInfo()
	info.text = text
	info.notCheckable = true
	info.func = function()
		SelectMap(key)
		LibDD:CloseDropDownMenus()
	end
	LibDD:UIDropDownMenu_AddButton(info, level)
end

local function AddSubmenu(text, menuList, level)
	local info = LibDD:UIDropDownMenu_CreateInfo()
	info.text = text
	info.notCheckable = true
	info.hasArrow = true
	info.menuList = menuList
	LibDD:UIDropDownMenu_AddButton(info, level)
end

-- A one-floor instance is simply a map; a multi-floor one opens its floors.
local function AddInstance(inst, level)
	if #inst.floors == 1 then
		AddMapButton(inst.name, inst.floors[1].key, level)
	else
		AddSubmenu(inst.name, { floorsOf = inst }, level)
	end
end

--[[
Raids > instance > floor, Dungeons > instance > floor, Battlegrounds,
Zones > continent > zone. LibUIDropDownMenu nests three levels, which is
exactly the depth this needs.
]]
local function BuildMapMenu(self, level, menuList)
	level = level or 1
	local Catalog = ns.Catalog

	if level == 1 then
		local raids = Catalog:GetInstancesOfKind("raid")
		local dungeons = Catalog:GetInstancesOfKind("dungeon")
		local _, zoneGroups = Catalog:GetZoneGroups()
		local hasBattlegrounds = zoneGroups.Battlegrounds or #Catalog:GetInstancesOfKind("bg") > 0

		if #raids > 0 then AddSubmenu("Raids", { instancesOf = "raid" }, level) end
		if #dungeons > 0 then AddSubmenu("Dungeons", { instancesOf = "dungeon" }, level) end
		if hasBattlegrounds then AddSubmenu("Battlegrounds", { battlegrounds = true }, level) end
		AddSubmenu("Zones", { zones = true }, level)
		AddMapButton(Catalog.blank.name, Catalog.blank.key, level)

	elseif menuList.instancesOf then
		for _, inst in ipairs(Catalog:GetInstancesOfKind(menuList.instancesOf)) do
			AddInstance(inst, level)
		end

	elseif menuList.floorsOf then
		for _, floor in ipairs(menuList.floorsOf.floors) do
			AddMapButton(floor.label, floor.key, level)
		end

	elseif menuList.battlegrounds then
		local _, zoneGroups = Catalog:GetZoneGroups()
		for _, entry in ipairs(zoneGroups.Battlegrounds or {}) do
			AddMapButton(entry.name, entry.key, level)
		end
		for _, inst in ipairs(Catalog:GetInstancesOfKind("bg")) do
			AddInstance(inst, level)
		end

	elseif menuList.zones then
		local order = Catalog:GetZoneGroups()
		for _, group in ipairs(order) do
			if group ~= "Battlegrounds" then
				AddSubmenu(group, { zoneGroup = group }, level)
			end
		end

	elseif menuList.zoneGroup then
		local _, zoneGroups = Catalog:GetZoneGroups()
		for _, entry in ipairs(zoneGroups[menuList.zoneGroup] or {}) do
			AddMapButton(entry.name, entry.key, level)
		end
	end
end

-- With no position given (a click rather than a drag) a token lands where the
-- user is looking, not at a fixed spot, so adding one while zoomed into a room
-- does not fling it across the map.
local function AddMarker(index, x, y)
	if not x then x, y = frame.canvas:GetView() end
	local element = ns.Model:NewElement(ns:CurrentBoard(), "marker", x, y, { index = index })
	ns.Model:AddElement(CurrentSlide(), element)
end

-- Role tokens auto-number per slide, so adding Tank three times gives you
-- T1, T2, T3 rather than three identical icons.
local function NextRoleIndex(roleKey)
	local highest = 0
	for _, element in ipairs(CurrentSlide().elements) do
		if element.kind == "role" and element.data.role == roleKey then
			highest = math.max(highest, element.data.index or 0)
		end
	end
	return highest + 1
end

local function AddRole(roleKey, x, y)
	if not x then x, y = frame.canvas:GetView() end
	local element = ns.Model:NewElement(ns:CurrentBoard(), "role", x, y, {
		role = roleKey,
		index = NextRoleIndex(roleKey),
	})
	ns.Model:AddElement(CurrentSlide(), element)
end

--[[
A toolbar button that makes tokens two ways: a click adds one where you are
looking, a drag adds one where you let go. add(x, y) creates the token and
ghost() returns what the drag shows -- caption, texture, texcoords.
]]
local function MakePaletteButton(button, add, ghost)
	button:RegisterForDrag("LeftButton")

	button:SetScript("OnClick", function()
		-- Letting go of a drag is not also a click.
		if ns.PlaceDrag:IsBusy() then return end
		add()
	end)

	button:SetScript("OnDragStart", function()
		ns.PlaceDrag:Start(add, ghost())
	end)

	button:SetScript("OnDragStop", function(self)
		-- Released without leaving the button: a click that wobbled far enough
		-- to count as a drag, and still meant as a click.
		local wobbled = self:IsMouseOver()
		ns.PlaceDrag:Stop()
		if wobbled then add() end
	end)

	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local PALETTE_HINT = "Click to add, or drag onto the map."

local DISPLAY_NEXT = { both = "icon", icon = "name", name = "both" }
local DISPLAY_LABEL = { both = "Show: Both", icon = "Show: Icon", name = "Show: Name" }

local function CreateWindow()
	frame = CreateFrame("Frame", "RaidMapFrame", UIParent, BACKDROP_TEMPLATE)
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:Hide()

	if frame.SetBackdrop then
		frame:SetBackdrop(WINDOW_BACKDROP)
		frame:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
	end

	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(900, 500)
	elseif frame.SetMinResize then
		frame:SetMinResize(900, 500)
	end
	frame:SetClampedToScreen(true)

	-- Title bar
	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT", 6, -6)
	titleBar:SetPoint("TOPRIGHT", -6, -6)
	titleBar:SetHeight(24)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)

	local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", 4, 0)
	title:SetText("RaidMap")

	local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
	close:SetPoint("RIGHT", 2, 0)
	close:SetScript("OnClick", function() frame:Hide() end)

	-- Row 1: pack -> board -> map, narrowing scope left to right.
	local packDD, boardDD, refreshLibrary = ns.CreateLibraryDropdowns(frame)
	packDD:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", -8, -2 - CAPTION_ROW)
	boardDD:SetPoint("LEFT", packDD, "RIGHT", -16, 0)
	frame.packDropdown, frame.boardDropdown = packDD, boardDD

	local dropdown = LibDD:Create_UIDropDownMenu("RaidMapMapDropDown", frame)
	dropdown:SetPoint("LEFT", boardDD, "RIGHT", -16, 0)
	LibDD:UIDropDownMenu_SetWidth(dropdown, 130)
	LibDD:UIDropDownMenu_SetText(dropdown, "Select map")
	LibDD:UIDropDownMenu_Initialize(dropdown, BuildMapMenu)
	frame.mapDropdown = dropdown

	-- Each dropdown shows only its current choice, which does not say what it
	-- is a choice of: someone new could not tell the pack from the board. The
	-- inset lines the caption up with the box, which starts that far inside
	-- the dropdown's frame.
	frame.captions = {}
	for _, pair in ipairs({ { packDD, "Packs" }, { boardDD, "Boards" }, { dropdown, "Maps" } }) do
		local caption = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		caption:SetPoint("BOTTOMLEFT", pair[1], "TOPLEFT", 20, 0)
		caption:SetText(pair[2])
		frame.captions[#frame.captions + 1] = caption
	end

	local resetZoom = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	resetZoom:SetSize(90, 20)
	resetZoom:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -34 - CAPTION_ROW)
	resetZoom:SetText("Reset view")
	resetZoom:SetScript("OnClick", function()
		frame.canvas:SetView(0.5, 0.5, 1)
	end)

	-- Row 2: tools
	local toolbar = CreateFrame("Frame", nil, frame)
	toolbar:SetPoint("TOPLEFT", packDD, "BOTTOMLEFT", 16, 0)
	toolbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -60 - CAPTION_ROW)
	toolbar:SetHeight(24)

	for i = 1, 8 do
		local button = CreateFrame("Button", nil, toolbar)
		button:SetSize(22, 22)
		button:SetPoint("LEFT", (i - 1) * 25, 0)
		button:SetNormalTexture(RAID_ICON:format(i))
		button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

		MakePaletteButton(button,
			function(x, y) AddMarker(i, x, y) end,
			function() return nil, RAID_ICON:format(i) end)

		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("Add " .. (_G["RAID_TARGET_" .. i] or "marker"))
			GameTooltip:AddLine(PALETTE_HINT, 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
	end

	for i, role in ipairs(ns.ROLES) do
		local button = CreateFrame("Button", nil, toolbar)
		button:SetSize(22, 22)
		button:SetPoint("LEFT", 8 * 25 + 10 + (i - 1) * 25, 0)

		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints()
		icon:SetTexture(ns.ROLE_TEXTURE)
		icon:SetTexCoord(ns.RoleTexCoords(role.key))

		button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

		-- The ghost carries the number the token will get, so you can see which
		-- one you are about to place. The token itself is numbered on release.
		MakePaletteButton(button,
			function(x, y) AddRole(role.key, x, y) end,
			function()
				return ns.RoleLabel(role, NextRoleIndex(role.key)), ns.ROLE_TEXTURE, ns.RoleTexCoords(role.key)
			end)

		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("Add " .. role.label)
			GameTooltip:AddLine(PALETTE_HINT, 0.6, 0.6, 0.6)
			GameTooltip:AddLine("Numbered automatically. Travels to anyone who", 0.6, 0.6, 0.6)
			GameTooltip:AddLine("imports this pack, unlike a player name.", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
	end

	local undo = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
	undo:SetSize(60, 20)
	undo:SetPoint("LEFT", 8 * 25 + 10 + 3 * 25 + 12, 0)
	undo:SetText("Undo")
	undo:SetScript("OnClick", function() ns.History:Undo() end)

	local redo = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
	redo:SetSize(60, 20)
	redo:SetPoint("LEFT", undo, "RIGHT", 4, 0)
	redo:SetText("Redo")
	redo:SetScript("OnClick", function() ns.History:Redo() end)

	local clear = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
	clear:SetSize(60, 20)
	clear:SetPoint("LEFT", redo, "RIGHT", 12, 0)
	clear:SetText("Clear")
	clear:SetScript("OnClick", function() ns.Model:ClearSlide(CurrentSlide()) end)

	ns.Events:On("HISTORY_CHANGED", function()
		undo:SetEnabled(ns.History:CanUndo())
		redo:SetEnabled(ns.History:CanRedo())
	end)
	undo:SetEnabled(false)
	redo:SetEnabled(false)

	-- Roster column: header, the list, then the two toggles that say how the
	-- names in it are drawn on the map.
	local rosterHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rosterHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -88 - CAPTION_ROW)
	rosterHeader:SetText("Raid")

	local demoToggle = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	demoToggle:SetSize(20, 20)
	demoToggle:SetPoint("LEFT", rosterHeader, "RIGHT", 6, 0)
	demoToggle:SetScript("OnClick", function(self)
		ns.db.profile.demoRoster = self:GetChecked() and true or nil
		ns.Roster:Build()
	end)

	local demoLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	demoLabel:SetPoint("LEFT", demoToggle, "RIGHT", 0, 0)
	demoLabel:SetText("demo")
	frame.demoToggle = demoToggle

	-- The toggles take the row the slide strip occupies under the canvas, so
	-- the list stops short of it.
	local TOGGLE_WIDTH = (ns.RosterPanel.WIDTH - 4) / 2

	local roster = ns.CreateRosterPanel(frame)
	roster:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -106 - CAPTION_ROW)
	roster:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 56)
	frame.roster = roster

	local displayToggle = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	displayToggle:SetSize(TOGGLE_WIDTH, 22)
	displayToggle:SetPoint("TOPLEFT", roster, "BOTTOMLEFT", 0, -4)

	local layoutToggle = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	layoutToggle:SetSize(TOGGLE_WIDTH, 22)
	layoutToggle:SetPoint("LEFT", displayToggle, "RIGHT", 4, 0)

	local function RefreshTokenToggles()
		local board = ns:CurrentBoard()
		if not board then return end

		local display = board.tokenDisplay or "both"
		displayToggle:SetText(DISPLAY_LABEL[display] or DISPLAY_LABEL.both)
		layoutToggle:SetText((board.tokenLayout or "vertical") == "vertical" and "Stack: Vert" or "Stack: Horiz")
		-- Stacking only means something while both the icon and the name show.
		layoutToggle:SetEnabled(display == "both")
	end

	displayToggle:SetScript("OnClick", function()
		local board = ns:CurrentBoard()
		board.tokenDisplay = DISPLAY_NEXT[board.tokenDisplay or "both"] or "both"
		RefreshTokenToggles()
		ns.Model:Touch(board)
		ns.Events:Fire("ELEMENTS_CHANGED")
	end)
	displayToggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Player tokens on this board")
		GameTooltip:AddLine("Draw each raider as their icon, their name, or both.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	displayToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

	layoutToggle:SetScript("OnClick", function()
		local board = ns:CurrentBoard()
		board.tokenLayout = ((board.tokenLayout or "vertical") == "vertical") and "horizontal" or "vertical"
		RefreshTokenToggles()
		ns.Model:Touch(board)
		ns.Events:Fire("ELEMENTS_CHANGED")
	end)
	-- Still hoverable when greyed out, to say why it is.
	if layoutToggle.SetMotionScriptsWhileDisabled then
		layoutToggle:SetMotionScriptsWhileDisabled(true)
	end
	layoutToggle:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Player tokens on this board")
		GameTooltip:AddLine("Put the name under the icon, or beside it.", 0.6, 0.6, 0.6)
		if not self:IsEnabled() then
			GameTooltip:AddLine("Only applies while both are shown.", 1, 0.5, 0.5)
		end
		GameTooltip:Show()
	end)
	layoutToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

	frame.displayToggle, frame.layoutToggle = displayToggle, layoutToggle

	-- Canvas
	local canvas = ns.CreateMapCanvas(frame)
	canvas:SetPoint("TOPLEFT", roster, "TOPRIGHT", 6, 20)
	canvas:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 58)
	frame.canvas = canvas
	ns.MainCanvas = canvas

	ns.TokenLayer = ns.CreateTokenLayer(canvas)

	-- Slide strip, anchored to the canvas so it tracks the notes panel opening
	-- and closing rather than running underneath it.
	local filmstrip = ns.CreateFilmstrip(frame)
	filmstrip:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 0, -6)
	filmstrip:SetPoint("RIGHT", canvas, "RIGHT", 0, 0)
	frame.filmstrip = filmstrip

	-- Notes
	local notes = ns.CreateNotesPanel(frame)
	notes:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -88 - CAPTION_ROW)
	notes:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 28)
	frame.notes = notes

	local function UpdateLayout()
		local showNotes = ns.db.profile.showNotes and true or false
		notes:SetShown(showNotes)

		canvas:ClearAllPoints()
		canvas:SetPoint("TOPLEFT", roster, "TOPRIGHT", 6, 20)
		canvas:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",
			-10 - (showNotes and (ns.NotesPanel.WIDTH + 8) or 0), 58)
		canvas:Layout()
	end
	frame.UpdateLayout = UpdateLayout

	local notesToggle = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	notesToggle:SetSize(70, 20)
	notesToggle:SetPoint("RIGHT", resetZoom, "LEFT", -4, 0)
	notesToggle:SetText("Notes")
	notesToggle:SetScript("OnClick", function()
		ns.db.profile.showNotes = not ns.db.profile.showNotes
		UpdateLayout()
	end)

	local present = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	present:SetSize(70, 20)
	present:SetPoint("RIGHT", notesToggle, "LEFT", -4, 0)
	present:SetText("Present")
	present:SetScript("OnClick", function() ns.TogglePresentation() end)
	present:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Open the read-only view")
		GameTooltip:AddLine("Compact, cannot be edited by accident, and follows", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("whoever is presenting. What your raiders want open.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	present:SetScript("OnLeave", function() GameTooltip:Hide() end)

	function ns.SwitchSlide(index, fromRemote)
		local board = ns:CurrentBoard()
		index = math.max(1, math.min(index, #board.slides))
		local slide = board.slides[index]

		-- A lead changing slides pushes everyone else's view along with it.
		-- Guarded on fromRemote so a received focus does not echo back out.
		if not fromRemote and ns.Comm and ns.Comm:CanPublish() then
			ns.Comm:PublishFocus(index)
		end

		-- Load the art while the OLD slide is still current, so the view-save
		-- handler writes the old view back where it belongs instead of
		-- stamping stale framing onto the slide we are moving to.
		SelectMap(slide.mapKey, true)
		board.currentSlide = index
		canvas:SetView(slide.view.cx, slide.view.cy, slide.view.zoom)
		ns.TokenLayer:SetSlide(slide)
		filmstrip:Refresh()
		notes:Refresh()

		-- Announced rather than pushed into each view, so a second view of the
		-- same slide (presentation mode) tracks the filmstrip, the lead's focus
		-- and its own buttons through one path.
		ns.Events:Fire("SLIDE_SHOWN", index)
	end

	-- After an undo/redo the slide we were viewing may no longer exist, or may
	-- have been reinserted. Resync rather than render a detached slide.
	ns.Events:On("SLIDES_CHANGED", function()
		local slide = CurrentSlide()
		if ns.TokenLayer.slide ~= slide then
			ns.SwitchSlide(ns:CurrentBoard().currentSlide)
		end
	end)

	-- Changing pack or board invalidates everything below it.
	ns.Events:On("PACK_CHANGED", function()
		refreshLibrary()
		local board = ns:CurrentBoard()
		if not board then return end
		RefreshTokenToggles()
		ns.SwitchSlide(board.currentSlide or 1, true)
	end)

	-- Persist the view so a slide reopens framed the way it was left.
	ns.Events:On("CANVAS_VIEW_CHANGED", function(changed)
		if changed ~= canvas then return end
		local slide = CurrentSlide()
		slide.view.cx, slide.view.cy, slide.view.zoom = canvas:GetView()
	end)

	-- Live coordinate readout. A development aid: it makes it obvious at a
	-- glance whether the normalized coordinate space is actually correct,
	-- which matters because every token position depends on it.
	local readout = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	readout:SetPoint("BOTTOMLEFT", 12, 10)
	frame.readout = readout

	canvas:HookScript("OnUpdate", function(self)
		local nx, ny = self:CursorToNormalized()
		if nx and self:IsMouseOver() then
			readout:SetText(("x %.3f   y %.3f   zoom %.2fx"):format(nx, ny, self.zoom))
		else
			readout:SetText(("zoom %.2fx   |cff888888right-drag pans, wheel zooms, right-click a token to delete|r"):format(self.zoom))
		end
	end)

	-- Sync controls, bottom right opposite the coordinate readout.
	local publish = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	publish:SetSize(90, 22)
	publish:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 6)
	publish:SetText("Publish")
	publish:SetScript("OnClick", function() ns.Comm:PublishPack() end)
	publish:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Send this board to the raid")
		GameTooltip:AddLine("Leader and assistants only.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	publish:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local applyPending = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	applyPending:SetSize(70, 22)
	applyPending:SetPoint("RIGHT", publish, "LEFT", -4, 0)
	applyPending:SetText("Apply")
	applyPending:Hide()
	applyPending:SetScript("OnClick", function() ns.Comm:ApplyPending() end)

	local pause = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	pause:SetSize(20, 20)
	pause:SetPoint("RIGHT", applyPending, "LEFT", -60, 0)
	pause:SetScript("OnClick", function(self)
		ns.db.profile.pauseSync = self:GetChecked() and true or nil
		ns.Events:Fire("SYNC_STATUS")
	end)

	local pauseLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	pauseLabel:SetPoint("LEFT", pause, "RIGHT", 0, 0)
	pauseLabel:SetText("pause sync")

	local syncStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	syncStatus:SetPoint("RIGHT", pause, "LEFT", -8, 0)
	syncStatus:SetJustifyH("RIGHT")

	local function RefreshSyncUI()
		publish:SetEnabled(ns.Comm:CanPublish())
		pause:SetChecked(ns.db.profile.pauseSync and true or false)
		applyPending:SetShown(ns.Comm.pendingManifest ~= nil)

		local update = ns.Comm.lastUpdate
		if update then
			local ago = time() - update.time
			syncStatus:SetText(("|cff888888%s updated this %ds ago|r"):format(update.from, ago))
		elseif not ns.Comm:Channel() then
			syncStatus:SetText("|cff666666not in a group|r")
		else
			syncStatus:SetText("")
		end
	end

	ns.Events:On("SYNC_STATUS", RefreshSyncUI)
	ns.Events:On("ROSTER_CHANGED", RefreshSyncUI)
	RefreshSyncUI()

	-- Keeps the "3s ago" honest without a per-frame update.
	C_Timer.NewTicker(5, RefreshSyncUI)

	-- A received board replaces everything; rebuild the view around it.
	ns.Events:On("BOARD_REPLACED", function()
		local board = ns:CurrentBoard()
		RefreshTokenToggles()
		ns.SwitchSlide(board.currentSlide or 1, true)
	end)

	-- Resize grip
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		SavePosition()
		canvas:Layout()
	end)

	-- Escape closes through UISpecialFrames without ever reaching TOGGLE_WINDOW,
	-- so the persisted flag has to come from the frame itself or the window
	-- reopens on the next reload after you dismissed it.
	frame:SetScript("OnShow", function() ns.db.profile.window.shown = true end)
	frame:SetScript("OnHide", function() ns.db.profile.window.shown = false end)

	function ns.IsMainShown()
		return frame and frame:IsShown()
	end

	tinsert(UISpecialFrames, "RaidMapFrame")

	RestorePosition()

	local board = ns:CurrentBoard()
	RefreshTokenToggles()
	demoToggle:SetChecked(ns.db.profile.demoRoster and true or false)
	refreshLibrary()

	UpdateLayout()
	-- fromRemote, so logging in as a raid lead does not broadcast a focus at
	-- everyone before you have touched anything.
	ns.SwitchSlide(board.currentSlide or 1, true)
	ns.Roster:Build()
end

ns.Events:On("READY", function()
	-- Dynamic content cannot live in AceDB defaults. Wraps a schema v1 bare
	-- board into a pack, or creates a first pack on a fresh install.
	ns.Pack:Migrate()

	CreateWindow()

	if ns.db.profile.window.shown then
		frame:Show()
	end
end)

ns.Events:On("TOGGLE_WINDOW", function()
	if not frame then return end
	if frame:IsShown() then frame:Hide() else frame:Show() end
end)

ns.Events:On("WINDOW_RESET", function()
	if frame then RestorePosition() end
end)
