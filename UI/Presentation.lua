local ADDON, ns = ...

local LibDD = LibStub("LibUIDropDownMenu-4.0")

--[[
Presentation mode -- the read-only view for the twenty-four people who are not
authoring, and the one place a pack is presented from.

It has a place of its own in the current pack: a board and a slide that are
this window's, not the editor's. Two things move it and nothing else does. Its
own buttons and menus do, and for anyone who may publish that is presenting:
the move goes out to the group as a focus. And a focus that comes in from
somebody else presenting does. The editor is on neither end of that. It sends
no focus and follows none, so paging through a pack to work on it moves
nobody's view, and a presenter cannot pull an author off the slide in front of
them.

What it draws is still the pack's own boards and slides, never a copy of them,
so an edit or an update that lands mid-fight is on screen as soon as it does.

Read-only is structural rather than a matter of leaving buttons out:

  - tokens in this layer have their mouse disabled entirely (Tokens.lua), so
    they cannot be dragged or right-click deleted, and right-drag panning works
    over the top of them;
  - panning and zooming here are local, because MainFrame writes slide.view for
    its own canvas only -- framing a room during a pull cannot dirty the pack or
    bump a revision;
  - notes are a FontString, not an edit box. An edit box that takes focus eats
    the movement keys, which is a bad thing to hand somebody mid-fight.
]]

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local WINDOW_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local NOTES_HEIGHT = 84
local NAV_HEIGHT = 22

local frame
local hintShown = false

-- Where this window is: { board = <board id>, slide = <index> }. Nothing until
-- it is first asked for, and this session's only.
local place

------------------------------------------------------------------- state reads

--[[
The board this window is on. With no place yet it starts where the editor is,
which is what someone opening it from the editor expects to see. It goes back
there too when its board is no longer in the current pack: deleted, or the pack
was changed, which the Pack menu does for both windows.
]]
local function CurrentBoard()
	local pack = ns:CurrentPack()
	if not pack then return nil end

	if place then
		for _, board in ipairs(pack.boards) do
			if board.id == place.board then return board end
		end
	end

	local board = ns:CurrentBoard()
	place = { board = board.id, slide = board.currentSlide or 1 }
	return board
end

-- Clamped on the way out: a slide can be deleted from under the place.
local function CurrentSlide()
	local board = CurrentBoard()
	if not board then return nil end
	local index = math.max(1, math.min(place.slide or 1, #board.slides))
	return board.slides[index], index, board
end

------------------------------------------------------------------- persistence

local function Settings()
	return ns.db.profile.present
end

local function SavePosition()
	local s = Settings()
	local point, _, relPoint, x, y = frame:GetPoint()
	s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
	s.width, s.height = frame:GetWidth(), frame:GetHeight()
end

local function RestorePosition()
	local s = Settings()
	frame:ClearAllPoints()
	frame:SetSize(s.width, s.height)
	frame:SetPoint(s.point, UIParent, s.relPoint, s.x, s.y)
end

--------------------------------------------------------------------- rendering

local function RefreshNotes()
	local slide, _, board = CurrentSlide()
	if not board then return end

	local scope = Settings().scope or "slide"
	local text

	if scope == "board" then
		frame.notes.header:SetText("Whole board")
		text = board.notes
	else
		frame.notes.header:SetText(slide and slide.name or "Slide")
		text = slide and slide.notes
	end

	if not text or text == "" then
		text = "|cff666666(no notes)|r"
	end

	-- The scroll frame's OnSizeChanged may not have run yet on the very first
	-- open, and an unsized FontString reports a useless height.
	local width = frame.notes.scroll:GetWidth()
	if width and width > 1 then
		frame.notes.content:SetWidth(width)
		frame.notes.text:SetWidth(width)
	end

	frame.notes.text:SetText(text)
	frame.notes.content:SetHeight(math.max(1, frame.notes.text:GetStringHeight() + 4))
	frame.notes.scroll:SetVerticalScroll(0)

	frame.notes.slideTab:SetEnabled(scope ~= "slide")
	frame.notes.boardTab:SetEnabled(scope ~= "board")
end

local function Sync()
	if not frame or not frame:IsShown() then return end

	local pack = ns:CurrentPack()
	local slide, index, board = CurrentSlide()
	if not pack or not board or not slide then return end

	-- Only reload art when the map actually changed: re-resolving the catalog
	-- and re-laying twelve tiles on every slide step flickers for no reason.
	if frame.shownMapKey ~= slide.mapKey then
		local entry = ns.Catalog:Find(slide.mapKey)
		frame.canvas:SetArt(entry and entry.art or { kind = "blank" })
		frame.shownMapKey = slide.mapKey
	end

	frame.canvas:SetView(slide.view.cx, slide.view.cy, slide.view.zoom)
	frame.tokens:SetSlide(slide, board)

	frame.slideButton:SetText(("%s  |  %d/%d  %s"):format(board.name, index, #board.slides, slide.name))
	frame.prev:SetEnabled(index > 1)
	frame.next:SetEnabled(index < #board.slides)

	RefreshNotes()
	if ns.Comm.BroadcastPresence then ns.Comm:BroadcastPresence() end
end

-------------------------------------------------------------------- navigation

-- A move made in this window. For anyone who may publish that is presenting,
-- and it goes out to the group; for everyone else it is silently local.
local function Go(board, index)
	index = math.max(1, math.min(index, #board.slides))
	place = { board = board.id, slide = index }

	if ns.Comm:CanPublish() then ns.Comm:PublishFocus(index, board) end

	Sync()
end

local function Step(delta)
	local _, index, board = CurrentSlide()
	if not board then return end

	local target = index + delta
	if target < 1 or target > #board.slides then return end

	Go(board, target)
end

------------------------------------------------------------------------- menus

local function BuildBoardMenu(_, level)
	level = level or 1

	local pack = ns:CurrentPack()
	local current = CurrentBoard()
	if not pack or not current then return end

	local info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = "Boards", true, true
	LibDD:UIDropDownMenu_AddButton(info, level)

	for i, board in ipairs(pack.boards) do
		info = LibDD:UIDropDownMenu_CreateInfo()
		info.text = board.name
		info.checked = (board == current)
		info.func = function()
			-- From its first slide: the next boss is presented from the top,
			-- not from wherever the editor was last left on it.
			local chosen = ns:CurrentPack().boards[i]
			if chosen then Go(chosen, 1) end
			LibDD:CloseDropDownMenus()
		end
		LibDD:UIDropDownMenu_AddButton(info, level)
	end
end

local function BuildSlideMenu(_, level, menuList)
	level = level or 1
	if level == 2 and menuList == "boards" then return BuildBoardMenu(nil, level) end
	if level ~= 1 then return end

	local _, current, board = CurrentSlide()
	if not board then return end

	local info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = board.name, true, true
	LibDD:UIDropDownMenu_AddButton(info, level)

	for i, slide in ipairs(board.slides) do
		info = LibDD:UIDropDownMenu_CreateInfo()
		info.text = ("%d. %s"):format(i, slide.name)
		info.checked = (i == current)
		info.func = function()
			local _, _, shown = CurrentSlide()
			if shown then Go(shown, i) end
			LibDD:CloseDropDownMenus()
		end
		LibDD:UIDropDownMenu_AddButton(info, level)
	end
	info = LibDD:UIDropDownMenu_CreateInfo()
	info.text, info.notCheckable, info.hasArrow, info.menuList = "Boards", true, true, "boards"
	LibDD:UIDropDownMenu_AddButton(info, level)
end

------------------------------------------------------------------ construction

local function CreateNotesStrip(parent)
	local notes = CreateFrame("Frame", nil, parent, BACKDROP_TEMPLATE)
	notes:SetHeight(NOTES_HEIGHT)

	if notes.SetBackdrop then
		notes:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		notes:SetBackdropColor(0, 0, 0, 0.45)
		notes:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	end

	local header = notes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	header:SetPoint("TOPLEFT", 8, -6)
	notes.header = header

	local slideTab = CreateFrame("Button", nil, notes, "UIPanelButtonTemplate")
	slideTab:SetSize(48, 16)
	slideTab:SetPoint("TOPRIGHT", -56, -5)
	slideTab:SetText("Slide")
	slideTab:SetScript("OnClick", function()
		Settings().scope = "slide"
		RefreshNotes()
	end)
	notes.slideTab = slideTab

	local boardTab = CreateFrame("Button", nil, notes, "UIPanelButtonTemplate")
	boardTab:SetSize(48, 16)
	boardTab:SetPoint("LEFT", slideTab, "RIGHT", 4, 0)
	boardTab:SetText("Board")
	boardTab:SetScript("OnClick", function()
		Settings().scope = "board"
		RefreshNotes()
	end)
	notes.boardTab = boardTab

	local scroll = CreateFrame("ScrollFrame", "RaidMapPresentNotesScroll", notes,
		"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -24)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)

	-- A ScrollFrame needs a frame as its child, so the FontString rides inside
	-- one whose height tracks the wrapped text.
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)

	local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("TOPLEFT")
	text:SetJustifyH("LEFT")
	text:SetJustifyV("TOP")

	scroll:SetScrollChild(content)

	scroll:SetScript("OnSizeChanged", function(self, width)
		if not width or width < 1 then return end
		content:SetWidth(width)
		text:SetWidth(width)
		content:SetHeight(math.max(1, text:GetStringHeight() + 4))
	end)

	-- Explicit rather than relying on the template, whose wheel handling varies
	-- between clients.
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange() or 0
		self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 20)))
	end)

	notes.scroll, notes.content, notes.text = scroll, content, text
	return notes
end

local function CreateWindow()
	frame = CreateFrame("Frame", "RaidMapPresentFrame", UIParent, BACKDROP_TEMPLATE)
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:Hide()

	if frame.SetBackdrop then
		frame:SetBackdrop(WINDOW_BACKDROP)
		frame:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
	end

	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(380, 280)
	elseif frame.SetMinResize then
		frame:SetMinResize(380, 280)
	end
	frame:SetClampedToScreen(true)

	-- A narrow drag strip and a close button are the entire header.
	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT", 6, -4)
	titleBar:SetPoint("TOPRIGHT", -6, -4)
	titleBar:SetHeight(18)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)

	local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
	close:SetSize(24, 24)
	close:SetPoint("RIGHT", 2, 0)
	close:SetScript("OnClick", function() frame:Hide() end)
	frame.closeButton = close

	-- Board selection lives in the navigation menu below the map.
	-- Notes strip along the bottom
	local notes = CreateNotesStrip(frame)
	notes:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)
	notes:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 8)
	frame.notes = notes

	-- Navigation row
	local nav = CreateFrame("Frame", nil, frame)
	nav:SetHeight(NAV_HEIGHT)

	local prev = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	prev:SetSize(30, NAV_HEIGHT)
	prev:SetPoint("LEFT", 0, 0)
	prev:SetText("<")
	prev:SetScript("OnClick", function() Step(-1) end)
	frame.prev = prev

	local nextButton = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	nextButton:SetSize(30, NAV_HEIGHT)
	nextButton:SetPoint("LEFT", prev, "RIGHT", 4, 0)
	nextButton:SetText(">")
	nextButton:SetScript("OnClick", function() Step(1) end)
	frame.next = nextButton

	local slideMenu = LibDD:Create_UIDropDownMenu("RaidMapPresentSlideMenu", frame)
	slideMenu:Hide()
	LibDD:UIDropDownMenu_Initialize(slideMenu, BuildSlideMenu, "MENU")

	local slideButton = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	slideButton:SetPoint("LEFT", nextButton, "RIGHT", 6, 0)
	slideButton:SetPoint("RIGHT", nav, "RIGHT", -78, 0)
	slideButton:SetHeight(NAV_HEIGHT)
	slideButton:SetScript("OnClick", function()
		LibDD:ToggleDropDownMenu(1, nil, slideMenu, "cursor", 0, 0)
	end)
	slideButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Choose a board or slide")
		GameTooltip:AddLine("Wheel zooms and right-drag pans the map.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	slideButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	frame.slideButton = slideButton

	local notesToggle = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
	notesToggle:SetSize(70, NAV_HEIGHT)
	notesToggle:SetPoint("RIGHT", 0, 0)
	notesToggle:SetText("Notes")

	-- Canvas fills whatever is left between the header and the nav row.
	local canvas = ns.CreateMapCanvas(frame)
	canvas:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -26)
	canvas:SetPoint("BOTTOMRIGHT", nav, "TOPRIGHT", 0, 4)
	frame.canvas = canvas

	frame.tokens = ns.CreateTokenLayer(canvas, true)
	-- Nothing to draw until the window is actually up.
	frame.tokens.paused = true

	local function UpdateLayout()
		local showNotes = Settings().showNotes and true or false
		notes:SetShown(showNotes)

		nav:ClearAllPoints()
		if showNotes then
			nav:SetPoint("BOTTOMLEFT", notes, "TOPLEFT", 0, 4)
			nav:SetPoint("BOTTOMRIGHT", notes, "TOPRIGHT", 0, 4)
		else
			nav:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
			nav:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
		end

		canvas:Layout()
	end

	notesToggle:SetScript("OnClick", function()
		local s = Settings()
		s.showNotes = not s.showNotes
		UpdateLayout()
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

	-- Escape can close this without going through the toggle, so the persisted
	-- flag is driven by the frame itself rather than by whoever asked it to hide.
	frame:SetScript("OnShow", function()
		Settings().shown = true
		frame.tokens.paused = false
		-- Force the art to reload: the slide may have changed while we were shut.
		frame.shownMapKey = nil
		Sync()
	end)
	frame:SetScript("OnHide", function()
		Settings().shown = false
		frame.tokens.paused = true
		if ns.Comm.BroadcastPresence then ns.Comm:BroadcastPresence() end
	end)

	tinsert(UISpecialFrames, "RaidMapPresentFrame")

	RestorePosition()
	UpdateLayout()
end

--------------------------------------------------------------------- interface

function ns.ShowPresentation()
	if not frame then CreateWindow() end
	frame:Show()
end

function ns.TogglePresentation()
	if not frame then CreateWindow() end
	if frame:IsShown() then frame:Hide() else frame:Show() end
end

function ns.IsPresentationShown()
	return frame ~= nil and frame:IsShown()
end

--[[
Somebody is presenting and this player does not have the window that shows it
open. The editor being open is no reason to keep quiet: it does not follow.
Said once per session. The shown flag persists, so anyone who opens this even
once gets it back on the next login and never sees the hint again.
]]
local function NotifyPresenting(from)
	if hintShown then return end
	if frame and frame:IsShown() then return end

	hintShown = true
	ns:Print("%s is presenting. Type |cffffd100/rm present|r to follow along.",
		from or "Someone")
end

--[[
Somebody presenting has moved. Follow the board too, when we hold it. A board we
do not recognise means they are on a pack we do not have open; moving the slide
anyway is the closest useful thing we can do.

The place moves whether or not the window is up, so that opening it lands where
the presenter is.
]]
local function Follow(from, index, boardID)
	local board = CurrentBoard()
	if not board then return end

	if boardID then
		for _, candidate in ipairs(ns:CurrentPack().boards) do
			if candidate.id == boardID then
				board = candidate
				break
			end
		end
	end

	place = { board = board.id, slide = math.max(1, math.min(index, #board.slides)) }

	Sync()
	NotifyPresenting(from)
end

------------------------------------------------------------------------ wiring

-- What is on the slide can change under this window, from an edit in the
-- editor beside it or an update arriving, and it redraws for those. Which
-- slide the editor is on is not something it hears about.
ns.Events:On("SLIDES_CHANGED", Sync)
ns.Events:On("PACK_CHANGED", Sync)
ns.Events:On("BOARD_REPLACED", Sync)
ns.Events:On("REMOTE_FOCUS", Follow)

ns.Events:On("READY", function()
	if ns.db.profile.present.shown then ns.ShowPresentation() end
end)
