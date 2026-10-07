local ADDON, ns = ...

--[[
MapCanvas -- renders a tiled map and owns the coordinate space everything else
places itself in.

Positions are normalized [0,1] against the map's *content* area (1002x668 for
classic art), NOT the padded 1024x768 tile grid. That matters: normalizing
against content is what makes our coordinates line up with in-game map
positions, so plotting real player positions later is possible without a
conversion layer.

The view is (centerX, centerY, zoom) where zoom 1 fits the whole map. Slides
store exactly this triple, which is how a slide can focus one room of a raid.
]]

local MIN_ZOOM, MAX_ZOOM = 1, 6

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local CanvasMixin = {}

function CanvasMixin:AcquireTile(index)
	local tile = self.tiles[index]
	if not tile then
		tile = self:CreateTexture(nil, "ARTWORK")
		self.tiles[index] = tile
	end
	return tile
end

function CanvasMixin:AcquireGridLine(index)
	local line = self.gridLines[index]
	if not line then
		line = self:CreateTexture(nil, "ARTWORK")
		line:SetColorTexture(1, 1, 1, 0.10)
		self.gridLines[index] = line
	end
	return line
end

function CanvasMixin:HideAllTiles()
	for _, tile in ipairs(self.tiles) do tile:Hide() end
	for _, line in ipairs(self.gridLines) do line:Hide() end
end

function CanvasMixin:SetArt(art)
	self.art = art
	self.descriptor = ns.Catalog:Resolve(art)
	self:HideAllTiles()
	self:Layout()
	return self.descriptor ~= nil
end

function CanvasMixin:SetView(centerX, centerY, zoom)
	self.centerX = centerX or self.centerX
	self.centerY = centerY or self.centerY
	self.zoom = clamp(zoom or self.zoom, MIN_ZOOM, MAX_ZOOM)
	self:Layout()
end

function CanvasMixin:GetView()
	return self.centerX, self.centerY, self.zoom
end

function CanvasMixin:Layout()
	local d = self.descriptor
	if not d then return end

	local fw, fh = self:GetSize()
	if not fw or fw < 1 or fh < 1 then return end

	local fit = math.min(fw / d.contentW, fh / d.contentH)
	local scale = fit * self.zoom
	local drawW, drawH = d.contentW * scale, d.contentH * scale

	-- Keep the map from being panned away from its own edges. When the map is
	-- smaller than the frame on an axis it is simply centred on that axis.
	if drawW <= fw then
		self.centerX = 0.5
	else
		local half = (fw / 2) / drawW
		self.centerX = clamp(self.centerX, half, 1 - half)
	end
	if drawH <= fh then
		self.centerY = 0.5
	else
		local half = (fh / 2) / drawH
		self.centerY = clamp(self.centerY, half, 1 - half)
	end

	local originX = fw / 2 - self.centerX * drawW
	local originY = fh / 2 - self.centerY * drawH

	self.originX, self.originY = originX, originY
	self.drawW, self.drawH = drawW, drawH
	self.scale = scale

	if d.blank then
		self:LayoutGrid()
	else
		self:LayoutTiles()
	end

	ns.Events:Fire("CANVAS_VIEW_CHANGED", self)
end

function CanvasMixin:LayoutTiles()
	local d = self.descriptor

	for row = 1, d.rows do
		for col = 1, d.cols do
			local index = (row - 1) * d.cols + col
			local tile = self:AcquireTile(index)

			local x0 = (col - 1) * d.tileW
			local y0 = (row - 1) * d.tileH

			-- Trailing tiles are partly padding; crop them so the map ends at
			-- its real edge instead of a band of transparent pixels.
			local w = math.min(d.tileW, d.contentW - x0)
			local h = math.min(d.tileH, d.contentH - y0)

			if w <= 0 or h <= 0 then
				tile:Hide()
			else
				tile:SetTexture(d.textures[index])
				tile:SetTexCoord(0, w / d.tileW, 0, h / d.tileH)
				tile:SetSize(w * self.scale, h * self.scale)
				tile:ClearAllPoints()
				tile:SetPoint("TOPLEFT", self, "TOPLEFT",
					self.originX + x0 * self.scale,
					-(self.originY + y0 * self.scale))
				tile:Show()
			end
		end
	end
end

function CanvasMixin:LayoutGrid()
	local DIVISIONS = 8
	local index = 0

	for i = 0, DIVISIONS do
		local t = i / DIVISIONS

		index = index + 1
		local v = self:AcquireGridLine(index)
		v:SetSize(1, self.drawH)
		v:ClearAllPoints()
		v:SetPoint("TOPLEFT", self, "TOPLEFT", self.originX + t * self.drawW, -self.originY)
		v:Show()

		index = index + 1
		local h = self:AcquireGridLine(index)
		h:SetSize(self.drawW, 1)
		h:ClearAllPoints()
		h:SetPoint("TOPLEFT", self, "TOPLEFT", self.originX, -(self.originY + t * self.drawH))
		h:Show()
	end
end

-- Frame offset for a normalized point, ready to feed straight into SetPoint
-- against the canvas's TOPLEFT. This is how tokens will anchor themselves.
function CanvasMixin:NormalizedToOffset(nx, ny)
	if not self.drawW then return 0, 0 end
	return self.originX + nx * self.drawW, -(self.originY + ny * self.drawH)
end

function CanvasMixin:CursorToNormalized()
	if not self.drawW then return nil end

	local cx, cy = GetCursorPosition()
	local es = self:GetEffectiveScale()
	cx, cy = cx / es, cy / es

	local left, top = self:GetLeft(), self:GetTop()
	if not left then return nil end

	local fx, fy = cx - left, top - cy
	return (fx - self.originX) / self.drawW, (fy - self.originY) / self.drawH
end

-- Zoom about the cursor, so the point under the pointer stays put. Zooming
-- about the centre instead feels like the map is sliding away from you.
function CanvasMixin:ZoomAtCursor(delta)
	local d = self.descriptor
	if not d then return end

	local left, top = self:GetLeft(), self:GetTop()
	if not left or not top then return end

	local nx, ny = self:CursorToNormalized()
	local fw, fh = self:GetSize()

	local cx, cy = GetCursorPosition()
	local es = self:GetEffectiveScale()
	local fx = cx / es - left
	local fy = top - cy / es

	local newZoom = clamp(self.zoom * (delta > 0 and 1.2 or 1 / 1.2), MIN_ZOOM, MAX_ZOOM)
	if newZoom == self.zoom then return end

	local fit = math.min(fw / d.contentW, fh / d.contentH)
	local newDrawW = d.contentW * fit * newZoom
	local newDrawH = d.contentH * fit * newZoom

	self.zoom = newZoom
	if nx then
		self.centerX = nx + (fw / 2 - fx) / newDrawW
		self.centerY = ny + (fh / 2 - fy) / newDrawH
	end

	self:Layout()
end

function ns.CreateMapCanvas(parent)
	local canvas = CreateFrame("Frame", nil, parent)

	for k, v in pairs(CanvasMixin) do canvas[k] = v end

	canvas.tiles = {}
	canvas.gridLines = {}
	canvas.centerX, canvas.centerY, canvas.zoom = 0.5, 0.5, 1

	-- Without clipping, a zoomed map spills over the rest of the UI.
	if canvas.SetClipsChildren then
		canvas:SetClipsChildren(true)
	end

	local bg = canvas:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.07, 1)

	canvas:EnableMouse(true)
	canvas:EnableMouseWheel(true)

	canvas:SetScript("OnMouseWheel", function(self, delta)
		self:ZoomAtCursor(delta)
	end)

	canvas:SetScript("OnMouseDown", function(self, button)
		if button ~= "RightButton" then return end
		local cx, cy = GetCursorPosition()
		self.panning = { cx = cx, cy = cy, centerX = self.centerX, centerY = self.centerY }
	end)

	canvas:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" then self.panning = nil end
	end)

	canvas:SetScript("OnUpdate", function(self)
		if not self.panning or not self.drawW then return end
		local cx, cy = GetCursorPosition()
		local es = self:GetEffectiveScale()
		local dx = (cx - self.panning.cx) / es
		local dy = (cy - self.panning.cy) / es
		self.centerX = self.panning.centerX - dx / self.drawW
		self.centerY = self.panning.centerY + dy / self.drawH
		self:Layout()
	end)

	canvas:SetScript("OnSizeChanged", function(self) self:Layout() end)

	return canvas
end
