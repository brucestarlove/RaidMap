local ADDON, ns = ...

--[[
The slide strip. Slides are how a board expresses phases: "P1 spread",
"P2 stack behind pillar". Each carries its own map, framing and tokens.
]]

local TAB_WIDTH, TAB_HEIGHT = 104, 22

StaticPopupDialogs["RAIDMAP_RENAME_SLIDE"] = {
	text = "Rename slide:",
	button1 = ACCEPT or "Okay",
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	maxLetters = 40,
	OnShow = function(self)
		local board = ns:CurrentBoard()
		local slide = board.slides[board.currentSlide or 1]
		local editBox = ns.PopupEditBox(self)
		editBox:SetText(slide and slide.name or "")
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	OnAccept = function(self)
		local board = ns:CurrentBoard()
		ns.Model:RenameSlide(board, board.currentSlide or 1, ns.PopupEditBox(self):GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local board = ns:CurrentBoard()
		ns.Model:RenameSlide(board, board.currentSlide or 1, self:GetText())
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

function StripMixin:AcquireTab(index)
	local tab = self.tabs[index]
	if tab then return tab end

	tab = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
	tab:SetSize(TAB_WIDTH, TAB_HEIGHT)
	tab:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	tab:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			ns:CurrentBoard().currentSlide = self.index
			StaticPopup_Show("RAIDMAP_RENAME_SLIDE")
		else
			ns.SwitchSlide(self.index)
		end
	end)

	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(self.slideName or "")
		GameTooltip:AddLine("Right-click to rename", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

	self.tabs[index] = tab
	return tab
end

function StripMixin:Refresh()
	local board = ns:CurrentBoard()
	local current = board.currentSlide or 1

	for i, slide in ipairs(board.slides) do
		local tab = self:AcquireTab(i)
		tab.index = i
		tab.slideName = slide.name
		tab:ClearAllPoints()
		tab:SetPoint("LEFT", self, "LEFT", (i - 1) * (TAB_WIDTH + 3), 0)

		local label = ("%d. %s"):format(i, slide.name)
		if i == current then
			label = "|cffffd100" .. label .. "|r"
		end
		tab:SetText(label)
		tab:Show()
	end

	for i = #board.slides + 1, #self.tabs do
		self.tabs[i]:Hide()
	end

	local count = #board.slides
	self.addButton:ClearAllPoints()
	self.addButton:SetPoint("LEFT", self, "LEFT", count * (TAB_WIDTH + 3), 0)
	self.copyButton:ClearAllPoints()
	self.copyButton:SetPoint("LEFT", self.addButton, "RIGHT", 3, 0)
	self.deleteButton:ClearAllPoints()
	self.deleteButton:SetPoint("LEFT", self.copyButton, "RIGHT", 3, 0)

	self.deleteButton:SetEnabled(count > 1)
end

function ns.CreateFilmstrip(parent)
	local strip = CreateFrame("Frame", nil, parent)
	strip:SetHeight(TAB_HEIGHT)

	for k, v in pairs(StripMixin) do strip[k] = v end
	strip.tabs = {}

	local add = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	add:SetSize(26, TAB_HEIGHT)
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
	copy:SetSize(52, TAB_HEIGHT)
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
	delete:SetSize(52, TAB_HEIGHT)
	delete:SetText("Delete")
	delete:SetScript("OnClick", function()
		local board = ns:CurrentBoard()
		local index = board.currentSlide or 1
		if ns.Model:RemoveSlide(board, index) then
			ns.SwitchSlide(math.min(index, #board.slides))
		end
	end)
	strip.deleteButton = delete

	ns.Events:On("SLIDES_CHANGED", function() strip:Refresh() end)

	return strip
end
