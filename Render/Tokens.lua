local ADDON, ns = ...

--[[
Renders a slide's elements onto a MapCanvas and handles dragging them.

Tokens are children of the canvas so they inherit its clipping, and they keep a
constant pixel size regardless of zoom -- a token that shrank as you zoomed out
would become unreadable exactly when you want the overview.
]]

local TOKEN_SIZE = 26

local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES"

--[[
Role tokens are the portable primitive. A pack authored with "Tank 1 / Healer 2"
means something to anyone who imports it; one authored with your guild's names
does not. See PACKS.md.
]]
ns.ROLES = {
	{ key = "TANK",    short = "T", label = "Tank",   r = 0.40, g = 0.60, b = 1.00 },
	{ key = "HEALER",  short = "H", label = "Healer", r = 0.40, g = 0.90, b = 0.50 },
	{ key = "DAMAGER", short = "D", label = "DPS",    r = 1.00, g = 0.45, b = 0.45 },
}

ns.ROLE_BY_KEY = {}
for _, role in ipairs(ns.ROLES) do ns.ROLE_BY_KEY[role.key] = role end

ns.ROLE_TEXTURE = ROLE_TEXTURE

function ns.RoleTexCoords(key)
	if GetTexCoordsForRole then
		return GetTexCoordsForRole(key)
	end
	return 0, 1, 0, 1
end

-- "T2", in the role's colour. The number is the identity of a role token.
function ns.RoleLabel(role, index)
	return ("|cff%02x%02x%02x%s%d|r"):format(role.r * 255, role.g * 255, role.b * 255, role.short, index or 1)
end

--[[
Paths: arrows and drawn lines. The element's own position is the end the
arrowhead is on, and its token is only the handle there -- what is dragged to
move the path and right-clicked to delete it. The lines belong to that token,
so they come and go with it, and are placed in canvas pixels like the tokens
are: a path keeps its thickness and the size of its head at any zoom.

A path stores its colour as an index into this list, so the shades can be
retuned without touching anyone's boards. Only ever add to the end of it.
]]
ns.PATH_COLORS = {
	{ name = "White",  1.00, 1.00, 1.00 },
	{ name = "Yellow", 1.00, 0.82, 0.00 },
	{ name = "Red",    1.00, 0.30, 0.30 },
	{ name = "Green",  0.35, 0.90, 0.45 },
	{ name = "Blue",   0.35, 0.65, 1.00 },
	{ name = "Purple", 0.80, 0.50, 1.00 },
}

local PATH_THICKNESS = 3
local PATH_HANDLE = 18
local HEAD_LENGTH = 12
local HEAD_COS, HEAD_SIN = math.cos(math.rad(28)), math.sin(math.rad(28))

local function PlaceLine(line, canvas, fromX, fromY, toX, toY)
	line:SetStartPoint("TOPLEFT", canvas, fromX, fromY)
	line:SetEndPoint("TOPLEFT", canvas, toX, toY)
end

-- One line a segment, then two for the head. tipX, tipY is where the element
-- itself sits; every other point is an offset from it.
local function LayoutPath(token, canvas, tipX, tipY)
	local element = token.element
	local pts, units = element.data.pts or {}, ns.Model.PATH_UNITS
	local count = math.floor(#pts / 2)
	local fromX, fromY

	for i = 1, count do
		local x, y = canvas:NormalizedToOffset(
			element.x + pts[2 * i - 1] / units, element.y + pts[2 * i] / units)
		if fromX then PlaceLine(token.lines[i - 1], canvas, fromX, fromY, x, y) end
		fromX, fromY = x, y
	end
	if not fromX then return end

	PlaceLine(token.lines[count], canvas, fromX, fromY, tipX, tipY)

	-- The head points along the last segment, swept back either side of it.
	local dx, dy = fromX - tipX, fromY - tipY
	local length = math.sqrt(dx * dx + dy * dy)
	if length < 0.01 then dx, dy, length = -1, 0, 1 end
	dx, dy = dx / length * HEAD_LENGTH, dy / length * HEAD_LENGTH

	PlaceLine(token.lines[count + 1], canvas, tipX, tipY,
		tipX + dx * HEAD_COS - dy * HEAD_SIN, tipY + dx * HEAD_SIN + dy * HEAD_COS)
	PlaceLine(token.lines[count + 2], canvas, tipX, tipY,
		tipX + dx * HEAD_COS + dy * HEAD_SIN, tipY - dx * HEAD_SIN + dy * HEAD_COS)
end

local LayerMixin = {}

function LayerMixin:SetSlide(slide)
	self.slide = slide
	self:Refresh()
end

function LayerMixin:AcquireToken(index)
	local token = self.pool[index]
	if token then return token end

	local layer = self
	local canvas = self.canvas
	token = CreateFrame("Button", nil, canvas)
	token:SetSize(TOKEN_SIZE, TOKEN_SIZE)

	token.icon = token:CreateTexture(nil, "OVERLAY")
	token.lines = {}

	token.label = token:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- Outlined, because unoutlined text vanishes against busy map artwork.
	local fontPath, fontSize = token.label:GetFont()
	if fontPath then token.label:SetFont(fontPath, fontSize, "OUTLINE") end

	if layer.readOnly then
		-- Read-only is structural, not a promise not to click: with the mouse
		-- off, a token cannot be moved or deleted, and right-drag panning works
		-- straight over the top of one instead of being swallowed by it.
		token:EnableMouse(false)
	else
		token:RegisterForDrag("LeftButton")
		token:RegisterForClicks("RightButtonUp")

		token.highlight = token:CreateTexture(nil, "HIGHLIGHT")
		token.highlight:SetAllPoints()
		token.highlight:SetColorTexture(1, 1, 1, 0.25)

		token:SetScript("OnDragStart", function(self)
			self.dragging = true
			-- Captured for undo: the model only learns about the move on drag stop.
			self.fromX, self.fromY = self.element.x, self.element.y
		end)

		token:SetScript("OnDragStop", function(self)
			if not self.dragging then return end
			self.dragging = false
			ns.Model:MoveElement(self.element, self.fromX, self.fromY, self.element.x, self.element.y)
		end)

		token:SetScript("OnUpdate", function(self)
			if not self.dragging then return end
			local nx, ny = canvas:CursorToNormalized()
			if nx then
				self.element.x, self.element.y = nx, ny
				self:Reposition()
			end
		end)

		-- The owning layer, not the ns.TokenLayer global: presentation mode adds
		-- a second layer, and deleting from whichever one happens to be global
		-- would remove an element off the slide you are not looking at.
		token:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				ns.Model:RemoveElement(layer.slide, self.element)
			end
		end)
	end

	function token:Reposition()
		local ox, oy = canvas:NormalizedToOffset(self.element.x, self.element.y)
		self:ClearAllPoints()
		self:SetPoint("CENTER", canvas, "TOPLEFT", ox, oy)
		if self.element.kind == "path" then LayoutPath(self, canvas, ox, oy) end
	end

	self.pool[index] = token
	return token
end

local function StyleMarker(token, element)
	token.icon:Show()
	token.icon:ClearAllPoints()
	token.icon:SetAllPoints()
	token.icon:SetTexture(RAID_ICON:format(element.data.index or 1))
	token.icon:SetTexCoord(0, 1, 0, 1)
	token.label:SetText("")
	token:SetSize(TOKEN_SIZE, TOKEN_SIZE)
end

local function StylePlayer(token, element, board)
	local display = board.tokenDisplay or "both"
	local layout = board.tokenLayout or "vertical"

	local showIcon = display ~= "name"
	local showName = display ~= "icon"

	token.icon:ClearAllPoints()
	token.label:ClearAllPoints()

	if showIcon then
		token.icon:Show()
		token.icon:SetSize(TOKEN_SIZE, TOKEN_SIZE)
		token.icon:SetPoint("CENTER")

		if element.data.specIcon then
			token.icon:SetTexture(element.data.specIcon)
			token.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		else
			token.icon:SetTexture(ns.Roster.CLASS_TEXTURE)
			local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[element.data.class]
			token.icon:SetTexCoord(unpack(coords or { 0, 1, 0, 1 }))
		end
		token:SetSize(TOKEN_SIZE, TOKEN_SIZE)
	else
		token.icon:Hide()
	end

	if showName then
		local r, g, b = ns.Roster:ClassColor(element.data.class)
		token.label:SetText(("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, element.data.name or "?"))

		if not showIcon then
			token.label:SetPoint("CENTER")
			token:SetSize(math.max(20, token.label:GetStringWidth() + 4), 16)
		elseif layout == "horizontal" then
			token.label:SetPoint("LEFT", token.icon, "RIGHT", 3, 0)
		else
			token.label:SetPoint("TOP", token.icon, "BOTTOM", 0, -1)
		end
	else
		token.label:SetText("")
	end
end

local function StyleRole(token, element)
	local role = ns.ROLE_BY_KEY[element.data.role] or ns.ROLES[1]

	token.icon:Show()
	token.icon:ClearAllPoints()
	token.icon:SetSize(TOKEN_SIZE, TOKEN_SIZE)
	token.icon:SetPoint("CENTER")
	token.icon:SetTexture(ROLE_TEXTURE)
	token.icon:SetTexCoord(ns.RoleTexCoords(role.key))

	-- The number is the identity of a role token, so it is always drawn.
	token.label:ClearAllPoints()
	token.label:SetPoint("TOP", token.icon, "BOTTOM", 0, -1)
	token.label:SetText(ns.RoleLabel(role, element.data.index))

	token:SetSize(TOKEN_SIZE, TOKEN_SIZE)
end

local function StylePath(token, element)
	token.icon:Hide()
	token.label:SetText("")
	token:SetSize(PATH_HANDLE, PATH_HANDLE)

	local color = ns.PATH_COLORS[element.data.color] or ns.PATH_COLORS[1]
	local points = math.floor(#(element.data.pts or {}) / 2)
	local count = points > 0 and points + 2 or 0

	for i = 1, count do
		local line = token.lines[i]
		if not line then
			line = token:CreateLine(nil, "ARTWORK")
			line:SetThickness(PATH_THICKNESS)
			token.lines[i] = line
		end
		line:SetColorTexture(color[1], color[2], color[3], 1)
		line:Show()
	end
	for i = count + 1, #token.lines do
		token.lines[i]:Hide()
	end
end

local STYLES = { marker = StyleMarker, player = StylePlayer, role = StyleRole, path = StylePath }

-- Paths lie under the tokens standing on them. Set on every styling, because
-- a pooled token is a path one refresh and a raid marker the next.
local function Dress(token, element, board, canvas)
	local isPath = element.kind == "path"
	if not isPath then
		for _, line in ipairs(token.lines) do line:Hide() end
	end
	token:SetFrameLevel(canvas:GetFrameLevel() + (isPath and 1 or 2))
	STYLES[element.kind](token, element, board)
	token:Reposition()
	token:Show()
end

function LayerMixin:Refresh()
	-- A closed presentation window should not pay for every edit made in the
	-- editor behind it; it re-syncs from scratch when it opens. Driven by an
	-- explicit flag rather than IsVisible, because the first refresh happens
	-- from OnShow and should not depend on when visibility propagates.
	if self.paused then return end

	local slide = self.slide
	local count = slide and #slide.elements or 0
	local board = ns:CurrentBoard()

	for i = 1, count do
		local element = slide.elements[i]
		local token = self:AcquireToken(i)
		token.element = element

		if STYLES[element.kind] then
			Dress(token, element, board, self.canvas)
		else
			-- A kind from a newer version than this one. Not drawn, rather
			-- than drawn as whatever this token was last.
			token:Hide()
		end
	end

	for i = count + 1, #self.pool do
		self.pool[i]:Hide()
	end
end

-- A path that is still being drawn: on screen, but no slide's element yet.
-- nil takes it down again.
function LayerMixin:SetPreview(element)
	if not element then
		if self.pool.preview then self.pool.preview:Hide() end
		return
	end

	local token = self:AcquireToken("preview")
	-- Or it would sit under the pointer and take the mouse the stroke needs.
	token:EnableMouse(false)
	token.element = element
	Dress(token, element, nil, self.canvas)
end

function LayerMixin:RepositionAll()
	local count = self.slide and #self.slide.elements or 0
	for i = 1, count do
		local token = self.pool[i]
		if token and token:IsShown() then token:Reposition() end
	end
end

-- readOnly builds the layer presentation mode uses: same rendering, no editing.
function ns.CreateTokenLayer(canvas, readOnly)
	local layer = setmetatable({ canvas = canvas, pool = {}, readOnly = readOnly },
		{ __index = LayerMixin })

	ns.Events:On("CANVAS_VIEW_CHANGED", function(changed)
		if changed == canvas then layer:RepositionAll() end
	end)

	ns.Events:On("ELEMENTS_CHANGED", function()
		layer:Refresh()
	end)

	return layer
end
