local ADDON, ns = ...

--[[
The slide strip. Slides are how a board expresses phases: "P1 spread",
"P2 stack behind pillar". Each carries its own map, framing and tokens.

The strip is one row, as wide as the map and no wider, and a boss can have more
phases than fit in it. So "+", Copy and Delete keep their place at the end of
the row and the tabs share what is left: full width while that fits, narrower
down to TAB_MIN_WIDTH, and past that only a run of them shows, between two
arrows that page through the rest.
]]

local TAB_WIDTH, TAB_HEIGHT = 104, 22
-- Room for the number and the start of the name. The tooltip has all of it.
local TAB_MIN_WIDTH = 64
local TAB_PADDING = 10
local GAP = 3
local ARROW_WIDTH, ADD_WIDTH, ACTION_WIDTH = 24, 26, 52
local ACTIONS_WIDTH = ADD_WIDTH + 2 * (GAP + ACTION_WIDTH)

-- The rename popup is shown with the slide it is for and renames that one. It
-- is the slide and not its index, because slides can be added, removed or
-- replaced by a publish while the popup is open.
local function RenameSlide(slide, name)
	local board = ns:CurrentBoard()
	for index, candidate in ipairs(board and board.slides or {}) do
		if candidate == slide then
			ns.Model:RenameSlide(board, index, name)
			return
		end
	end
end

StaticPopupDialogs["RAIDMAP_RENAME_SLIDE"] = {
	text = "Rename slide:",
	button1 = ACCEPT or "Okay",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	maxLetters = 40,
	OnShow = function(self, slide)
		local editBox = ns.PopupEditBox(self)
		editBox:SetText(slide and slide.name or "")
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	OnAccept = function(self, slide)
		RenameSlide(slide, ns.PopupEditBox(self):GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		RenameSlide(self:GetParent().data, self:GetText())
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self)
		self:GetParent():Hide()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local StripMixin = {}

local function ShowTabTooltip(tab)
	GameTooltip:SetOwner(tab, "ANCHOR_TOP")
	GameTooltip:AddLine(tab.slideName or "")
	GameTooltip:AddLine("Right-click to rename", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

-- Tabs are pooled by where they sit in the row, not by slide: scrolled along,
-- the first tab is whichever slide the run starts at.
function StripMixin:AcquireTab(position)
	local tab = self.tabs[position]
	if tab then return tab end

	tab = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
	tab:SetSize(TAB_WIDTH, TAB_HEIGHT)
	tab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- A name longer than its tab is cut short, not run over the next one.
	tab:GetFontString():SetWordWrap(false)

	tab:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			-- Naming a slide is not going to it: the board stays where it is.
			local slide = ns:CurrentBoard().slides[self.index]
			StaticPopup_Show("RAIDMAP_RENAME_SLIDE", nil, nil, slide)
		else
			ns.SwitchSlide(self.index)
		end
	end)

	tab:SetScript("OnEnter", ShowTabTooltip)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

	self.tabs[position] = tab
	return tab
end

--[[
Lays the row out and marks the current slide. browsing is set while the user
is scrolling the tabs. Every other refresh brings the current slide's tab into
view, so the strip follows a slide change wherever it came from.
]]
function StripMixin:Refresh(browsing)
	local board = ns:CurrentBoard()
	if not board then return end

	local count = #board.slides
	local current = board.currentSlide or 1

	-- Full width until the strip has been measured: the first refresh runs
	-- before the window has a size, and OnSizeChanged follows it.
	local width, shown, paged = TAB_WIDTH, count, false
	local room = self:GetWidth() - ACTIONS_WIDTH
	if room > 0 then
		width = math.floor(room / count) - GAP
		if width < TAB_MIN_WIDTH then
			paged = true
			room = room - 2 * (ARROW_WIDTH + GAP)
			shown = math.max(1, math.floor(room / (TAB_MIN_WIDTH + GAP)))
			width = math.max(TAB_MIN_WIDTH, math.floor(room / shown) - GAP)
		end
		width = math.min(width, TAB_WIDTH)
	end

	local first = 1
	if paged then
		first = self.first
		if not browsing then
			-- No further than it takes to get the current slide's tab in.
			first = math.max(current - shown + 1, math.min(first, current))
		end
		first = math.max(1, math.min(first, count - shown + 1))
	end
	self.first, self.shown = first, shown

	local x = 0
	local function place(button)
		button:ClearAllPoints()
		button:SetPoint("LEFT", self, "LEFT", x, 0)
		x = x + button:GetWidth() + GAP
	end

	self.prevButton:SetShown(paged)
	self.nextButton:SetShown(paged)
	self.prevButton:SetEnabled(first > 1)
	self.nextButton:SetEnabled(first + shown <= count)

	if paged then place(self.prevButton) end

	for position = 1, shown do
		local index = first + position - 1
		local slide = board.slides[index]
		local tab = self:AcquireTab(position)
		tab.index = index
		tab.slideName = slide.name
		tab:SetWidth(width)
		tab:GetFontString():SetWidth(width - TAB_PADDING)
		place(tab)

		-- Lit and white: every tab's text is gold at rest, so a colour alone
		-- does not pick the current one out of a full row.
		local label = ("%d. %s"):format(index, slide.name)
		if index == current then
			label = "|cffffffff" .. label .. "|r"
			tab:LockHighlight()
		else
			tab:UnlockHighlight()
		end
		tab:SetText(label)
		tab:Show()

		-- Scrolling changes which slide is under a cursor that has not moved.
		if GameTooltip:IsOwned(tab) then ShowTabTooltip(tab) end
	end

	for position = shown + 1, #self.tabs do
		self.tabs[position]:Hide()
	end

	if paged then place(self.nextButton) end
	place(self.addButton)

	self.deleteButton:SetEnabled(count > 1)
end

function StripMixin:ScrollBy(tabs)
	self.first = self.first + tabs
	self:Refresh(true)
end

function ns.CreateFilmstrip(parent)
	local strip = CreateFrame("Frame", nil, parent)
	strip:SetHeight(TAB_HEIGHT)

	for k, v in pairs(StripMixin) do strip[k] = v end
	strip.tabs = {}
	strip.first = 1

	-- Shown only while there are more tabs than fit. They move the row, not
	-- the board: stepping through slides to find one would drag the whole
	-- raid's view along with every step.
	local function CreateArrow(text, direction, tooltip)
		local arrow = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
		arrow:SetSize(ARROW_WIDTH, TAB_HEIGHT)
		arrow:SetText(text)
		arrow:SetScript("OnClick", function() strip:ScrollBy(direction * strip.shown) end)
		-- Or the tooltip is stranded when a click greys the arrow out under it.
		if arrow.SetMotionScriptsWhileDisabled then
			arrow:SetMotionScriptsWhileDisabled(true)
		end
		arrow:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(tooltip)
			GameTooltip:AddLine("Or roll the mouse wheel over the tabs.", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)
		arrow:Hide()
		return arrow
	end
	strip.prevButton = CreateArrow("<", -1, "Earlier slides")
	strip.nextButton = CreateArrow(">", 1, "Later slides")

	local add = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	add:SetSize(ADD_WIDTH, TAB_HEIGHT)
	add:SetText("+")
	add:SetScript("OnClick", function()
		local board = ns:CurrentBoard()
		ns.SwitchSlide(ns.Model:AddSlide(board))
	end)
	add:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("New empty slide")
		GameTooltip:Show()
	end)
	add:SetScript("OnLeave", function() GameTooltip:Hide() end)
	strip.addButton = add

	local copy = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	copy:SetSize(ACTION_WIDTH, TAB_HEIGHT)
	copy:SetPoint("LEFT", add, "RIGHT", GAP, 0)
	copy:SetText("Copy")
	copy:SetScript("OnClick", function()
		local board = ns:CurrentBoard()
		ns.SwitchSlide(ns.Model:AddSlide(board, board.currentSlide or 1))
	end)
	copy:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Duplicate this slide")
		GameTooltip:AddLine("The fast way to author movement: copy, then move", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("only the tokens that changed.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	copy:SetScript("OnLeave", function() GameTooltip:Hide() end)
	strip.copyButton = copy

	local delete = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	delete:SetSize(ACTION_WIDTH, TAB_HEIGHT)
	delete:SetPoint("LEFT", copy, "RIGHT", GAP, 0)
	delete:SetText("Delete")
	delete:SetScript("OnClick", function()
		local board = ns:CurrentBoard()
		local index = board.currentSlide or 1
		if ns.Model:RemoveSlide(board, index) then
			ns.SwitchSlide(math.min(index, #board.slides))
		end
	end)
	strip.deleteButton = delete

	strip:EnableMouseWheel(true)
	strip:SetScript("OnMouseWheel", function(self, delta) self:ScrollBy(-delta) end)

	-- The strip is as wide as the map, which the window's grip and the notes
	-- panel both change.
	strip:SetScript("OnSizeChanged", function(self) self:Refresh() end)

	ns.Events:On("SLIDES_CHANGED", function() strip:Refresh() end)

	return strip
end
