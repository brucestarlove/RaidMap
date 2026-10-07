local ADDON, ns = ...

--[[
The roster list. Rows are a small recycled pool rendered against a scroll
offset rather than one frame per raider, so a 40-man roster costs the same as
a 5-man. The mouse wheel and the bar down the right edge both move that offset.
]]

local ROW_HEIGHT = 20
local PANEL_WIDTH = 186
local SCROLLBAR_WIDTH = 8
local WHEEL_ROWS = 3

-- Spec icon when it is known, class icon otherwise.
local function EntryIcon(entry)
	if entry.specIcon then
		return entry.specIcon, 0.07, 0.93, 0.07, 0.93
	end

	local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[entry.class]
	if coords then
		return ns.Roster.CLASS_TEXTURE, unpack(coords)
	end
	return ns.Roster.CLASS_TEXTURE, 0, 1, 0, 1
end

local PanelMixin = {}

-- Flattens groups into a single list with header rows, which is what the
-- offset-based renderer wants.
function PanelMixin:BuildItems()
	local items = {}
	local lastGroup

	for _, entry in ipairs(ns.Roster.entries) do
		if entry.subgroup ~= lastGroup then
			lastGroup = entry.subgroup
			items[#items + 1] = { header = true, text = "Group " .. tostring(lastGroup) }
		end
		items[#items + 1] = { entry = entry }
	end

	self.items = items
	return items
end

function PanelMixin:AcquireRow(index)
	local row = self.rows[index]
	if row then return row end

	row = CreateFrame("Button", nil, self)
	row:SetHeight(ROW_HEIGHT)
	row:RegisterForDrag("LeftButton")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 2, 0)

	-- Bounded on the right as well, so a long name truncates instead of
	-- running out of the column.
	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)

	row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(1, 1, 1, 0.12)

	row:SetScript("OnDragStart", function(self)
		-- Captured now: rows are recycled, and a roster update mid-drag could
		-- hand this row to somebody else.
		local entry = self.entry
		if not entry then return end

		ns.PlaceDrag:Start(function(x, y)
			local board = ns:CurrentBoard()
			local slide = board.slides[board.currentSlide or 1]

			ns.Model:AddElement(slide, ns.Model:NewElement(board, "player", x, y, {
				name = entry.name,
				class = entry.class,
				specIcon = entry.specIcon,
			}))
		end, nil, EntryIcon(entry))
	end)

	row:SetScript("OnDragStop", function()
		ns.PlaceDrag:Stop()
	end)

	self.rows[index] = row
	return row
end

function PanelMixin:Refresh()
	local items = self:BuildItems()

	local height = self:GetHeight()
	if not height or height < ROW_HEIGHT then return end

	local visible = math.floor(height / ROW_HEIGHT)
	local maxOffset = math.max(0, #items - visible)
	if self.offset > maxOffset then self.offset = maxOffset end

	-- The bar only shows while there is something to scroll, and the rows give
	-- up its width only then.
	local bar = self.scrollBar
	local scrollable = maxOffset > 0
	bar:SetShown(scrollable)
	if scrollable then
		-- Flagged, because narrowing the range can move the bar's own value and
		-- that must not be mistaken for the user dragging it.
		self.syncingBar = true
		bar:SetMinMaxValues(0, maxOffset)
		bar:SetValue(self.offset)
		self.syncingBar = false
		bar.thumb:SetHeight(math.max(16, (height - 4) * visible / #items))
	end
	local rightInset = scrollable and (SCROLLBAR_WIDTH + 6) or 4

	for i = 1, visible do
		local item = items[i + self.offset]
		local row = self:AcquireRow(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", self, "TOPLEFT", 4, -(i - 1) * ROW_HEIGHT)
		row:SetPoint("TOPRIGHT", self, "TOPRIGHT", -rightInset, -(i - 1) * ROW_HEIGHT)

		if not item then
			row:Hide()
		elseif item.header then
			row.entry = nil
			-- Nothing to drag, so nothing to light up under the cursor either.
			row:EnableMouse(false)
			row.icon:Hide()
			row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
			row.label:SetText("|cff888888" .. item.text .. "|r")
			row:Show()
		else
			local entry = item.entry
			row.entry = entry
			row:EnableMouse(true)

			row.icon:Show()
			row.label:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)

			local texture, left, right, top, bottom = EntryIcon(entry)
			row.icon:SetTexture(texture)
			row.icon:SetTexCoord(left, right, top, bottom)

			local r, g, b = ns.Roster:ClassColor(entry.class)
			local suffix = entry.isDemo and " |cff555555(demo)|r" or ""
			row.label:SetText(("|cff%02x%02x%02x%s|r%s"):format(r * 255, g * 255, b * 255, entry.name, suffix))
			row:Show()
		end
	end

	for i = visible + 1, #self.rows do
		self.rows[i]:Hide()
	end
end

function PanelMixin:ScrollBy(rows)
	local visible = math.floor(self:GetHeight() / ROW_HEIGHT)
	local maxOffset = math.max(0, #self.items - visible)
	self.offset = math.max(0, math.min(maxOffset, self.offset + rows))
	self:Refresh()
end

-- Plain textures on a Slider rather than a Blizzard scroll template: the two
-- clients ship different templates, and both ship the widget.
local function CreateScrollBar(panel)
	local bar = CreateFrame("Slider", nil, panel)
	bar:SetOrientation("VERTICAL")
	bar:SetWidth(SCROLLBAR_WIDTH)
	bar:SetPoint("TOPRIGHT", -2, -2)
	bar:SetPoint("BOTTOMRIGHT", -2, 2)
	bar:SetMinMaxValues(0, 1)
	bar:SetValueStep(1)
	if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end
	bar:SetValue(0)
	bar:EnableMouse(true)
	bar:Hide()

	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(1, 1, 1, 0.06)

	bar.thumb = bar:CreateTexture(nil, "ARTWORK")
	bar.thumb:SetColorTexture(1, 1, 1, 0.35)
	bar.thumb:SetSize(SCROLLBAR_WIDTH, 16)
	bar:SetThumbTexture(bar.thumb)

	bar:SetScript("OnValueChanged", function(_, value)
		if panel.syncingBar then return end
		local offset = math.floor(value + 0.5)
		if offset ~= panel.offset then
			panel.offset = offset
			panel:Refresh()
		end
	end)

	return bar
end

function ns.CreateRosterPanel(parent)
	local panel = CreateFrame("Frame", nil, parent)
	panel:SetWidth(PANEL_WIDTH)

	for k, v in pairs(PanelMixin) do panel[k] = v end
	panel.rows = {}
	panel.offset = 0
	panel.items = {}

	-- A faint inset, so the list reads as one column with its controls below.
	local background = panel:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 0.3)

	panel.scrollBar = CreateScrollBar(panel)

	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(self, delta)
		self:ScrollBy(-delta * WHEEL_ROWS)
	end)

	panel:SetScript("OnSizeChanged", function(self) self:Refresh() end)

	ns.Events:On("ROSTER_CHANGED", function() panel:Refresh() end)

	return panel
end

ns.RosterPanel = { WIDTH = PANEL_WIDTH }
