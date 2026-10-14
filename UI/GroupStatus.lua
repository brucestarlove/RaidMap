local ADDON, ns = ...

local frame
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local function Refresh()
	if not frame or not frame:IsShown() then return end
	local rows, watching, total, thisPack, outdated, latest = ns.Comm:GetGroupStatus()
	frame.summary:SetText(("Present open: %d/%d   |   This pack: %d   |   Older versions: %d")
		:format(watching, total, thisPack, outdated))
	frame.latest:SetText("Newest version in this group: " .. latest)
	for i, member in ipairs(rows) do
		local row = frame.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, frame.content)
			row:SetHeight(20)
			row:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
			row:SetPoint("RIGHT", frame.content, "RIGHT", 0, 0)
			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.name:SetPoint("LEFT", 0, 0)
			row.name:SetWidth(190)
			row.name:SetJustifyH("LEFT")
			row.version = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.version:SetPoint("LEFT", 196, 0)
			row.version:SetWidth(125)
			row.version:SetJustifyH("LEFT")
			row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.state:SetPoint("LEFT", 327, 0)
			frame.rows[i] = row
		end
		row.name:SetText(ns.Pack.DisplayName(member.name) .. (member.mine and " (you)" or ""))
		row.version:SetText(member.version and (member.outdated and ("|cffff9933" .. member.version .. " (old)|r")
			or member.version) or "Unknown")
		row.state:SetText(member.state)
		row:Show()
	end
	for i = #rows + 1, #frame.rows do frame.rows[i]:Hide() end
	frame.content:SetHeight(math.max(1, #rows * 20))
end

local function CreateWindow()
	frame = CreateFrame("Frame", "RaidMapGroupStatusFrame", UIParent, BACKDROP_TEMPLATE)
	frame:SetSize(500, 430)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	frame:Hide()
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 32, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 } })
		frame:SetBackdropColor(0.06, 0.06, 0.08, 0.98)
	end
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 14, -14)
	title:SetText("RaidMap — Group status")
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() frame:Hide() end)
	frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.summary:SetPoint("TOPLEFT", 14, -42)
	frame.latest = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.latest:SetPoint("TOPLEFT", 14, -62)
	for _, column in ipairs({ { "Player", 14 }, { "Version", 210 }, { "Present mode", 341 } }) do
		local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", column[2], -90)
		label:SetText(column[1])
	end
	local scroll = CreateFrame("ScrollFrame", "RaidMapGroupStatusScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -112)
	scroll:SetPoint("BOTTOMRIGHT", -32, 66)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(450, 1)
	scroll:SetScrollChild(content)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange() or 0
		self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
	end)
	frame.content, frame.rows = content, {}
	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 14, 45)
	hint:SetText("No reply means status is unavailable; the addon may still be installed.")
	local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	refresh:SetSize(90, 22)
	refresh:SetPoint("BOTTOMRIGHT", -14, 14)
	refresh:SetText("Refresh")
	refresh:SetScript("OnClick", function() ns.Comm:RequestGroupStatus() Refresh() end)
	frame:SetScript("OnShow", Refresh)
	tinsert(UISpecialFrames, "RaidMapGroupStatusFrame")
end

function ns.ToggleGroupStatus()
	if not frame then CreateWindow() end
	if frame:IsShown() then frame:Hide() else
		frame:Show()
		ns.Comm:RequestGroupStatus()
	end
end

ns.Events:On("GROUP_STATUS", Refresh)
