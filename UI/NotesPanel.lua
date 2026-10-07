local ADDON, ns = ...

--[[
Notes. Two scopes, because they answer different questions:

	Slide notes -- "what happens in this phase"
	Board notes -- "cooldown order, loot rules, anything fight-wide"

Text edits deliberately do NOT enter the undo stack. Undo is for spatial edits;
threading every keystroke through it would bury a token move under fifty
one-character entries, and edit boxes already have their own ctrl-Z.
]]

local PANEL_WIDTH = 210
local EDIT_HEIGHT = 600

local PanelMixin = {}

function PanelMixin:GetTargetText()
	local board = ns:CurrentBoard()
	if self.scope == "board" then
		return board.notes or ""
	end
	local slide = board.slides[board.currentSlide or 1]
	return slide and slide.notes or ""
end

function PanelMixin:SaveText(text)
	local board = ns:CurrentBoard()
	if self.scope == "board" then
		board.notes = text
	else
		local slide = board.slides[board.currentSlide or 1]
		if slide then slide.notes = text end
	end
end

function PanelMixin:SetScope(scope)
	self.scope = scope
	self.slideTab:SetEnabled(scope ~= "slide")
	self.boardTab:SetEnabled(scope ~= "board")
	self:Refresh()
end

function PanelMixin:Refresh()
	-- Guard against the OnTextChanged handler firing while we programmatically
	-- repopulate, which would write the outgoing slide's text into the new one.
	self.loading = true
	self.edit:SetText(self:GetTargetText())
	self.loading = false

	if self.scope == "board" then
		self.header:SetText("Notes: whole board")
	else
		local board = ns:CurrentBoard()
		local slide = board.slides[board.currentSlide or 1]
		self.header:SetText("Notes: " .. (slide and slide.name or "slide"))
	end
end

function ns.CreateNotesPanel(parent)
	local panel = CreateFrame("Frame", nil, parent)
	panel:SetWidth(PANEL_WIDTH)

	for k, v in pairs(PanelMixin) do panel[k] = v end
	panel.scope = "slide"

	local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	header:SetPoint("TOPLEFT", 2, 0)
	header:SetPoint("TOPRIGHT", -2, 0)
	header:SetJustifyH("LEFT")
	panel.header = header

	local slideTab = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	slideTab:SetSize(60, 18)
	slideTab:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	slideTab:SetText("Slide")
	slideTab:SetScript("OnClick", function() panel:SetScope("slide") end)
	panel.slideTab = slideTab

	local boardTab = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	boardTab:SetSize(60, 18)
	boardTab:SetPoint("LEFT", slideTab, "RIGHT", 4, 0)
	boardTab:SetText("Board")
	boardTab:SetScript("OnClick", function() panel:SetScope("board") end)
	panel.boardTab = boardTab

	local backdrop = CreateFrame("Frame", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
	backdrop:SetPoint("TOPLEFT", slideTab, "BOTTOMLEFT", 0, -6)
	backdrop:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
	if backdrop.SetBackdrop then
		backdrop:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		backdrop:SetBackdropColor(0, 0, 0, 0.45)
		backdrop:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	end

	local scroll = CreateFrame("ScrollFrame", "RaidMapNotesScroll", backdrop, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(PANEL_WIDTH - 40)
	edit:SetHeight(EDIT_HEIGHT)
	edit:SetTextInsets(2, 2, 2, 2)

	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnTextChanged", function(self)
		if panel.loading then return end
		panel:SaveText(self:GetText())
		ns.Model:Touch()
	end)

	scroll:SetScrollChild(edit)
	panel.edit = edit
	panel.scroll = scroll

	-- Clicking anywhere in the box should start typing, not just on the text.
	backdrop:EnableMouse(true)
	backdrop:SetScript("OnMouseDown", function() edit:SetFocus() end)

	ns.Events:On("SLIDES_CHANGED", function()
		if panel.scope == "slide" then panel:Refresh() end
	end)

	panel:SetScope("slide")

	return panel
end

ns.NotesPanel = { WIDTH = PANEL_WIDTH }
