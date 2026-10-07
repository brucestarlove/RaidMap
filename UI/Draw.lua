local ADDON, ns = ...

--[[
Drawing on the map. With a tool armed, a left-drag over bare map draws: an
arrow runs straight from where the button went down to where it came up, a path
follows the pointer between the two. Either way the result is one "path"
element (Model:PathShape), so moving, deleting, undo, copying a slide and
publishing all treat it like any other token.

A tool stays armed until it is clicked again. Nothing else uses a left-drag on
bare map, a token under the pointer still takes the mouse first, and three
arrows should not take three trips to the toolbar.
]]

local Draw = {}
ns.Draw = Draw

-- Pointer travel, in screen pixels: before a path gets its next point, and
-- before a press counts as a stroke at all rather than a stray click.
local STEP = 8
local MIN_LENGTH = 10

-- A path that reaches this many points drops every other one and takes them
-- half as often from then on. However long the stroke, it stays a bounded
-- number of points, which is what it costs to publish.
local MAX_POINTS = 40

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

-- Where the pointer is on the map. A stroke that leaves the map carries on
-- along its edge.
local function Pointer(canvas)
	local x, y = canvas:CursorToNormalized()
	if not x then return nil end
	return { clamp01(x), clamp01(y) }
end

local function Distance(canvas, a, b)
	local ax, ay = canvas:NormalizedToOffset(a[1], a[2])
	local bx, by = canvas:NormalizedToOffset(b[1], b[2])
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

function Draw:Color()
	local index = ns.db.profile.drawColor or 1
	return ns.PATH_COLORS[index] and index or 1
end

function Draw:NextColor()
	ns.db.profile.drawColor = self:Color() % #ns.PATH_COLORS + 1
	ns.Events:Fire("DRAW_CHANGED")
end

-- Clicking the armed tool puts it away.
function Draw:SetTool(tool)
	self.tool = (self.tool ~= tool) and tool or nil
	self:Cancel()
	ns.Events:Fire("DRAW_CHANGED")
end

-- The points the stroke would be if it ended now, and how long that is on
-- screen.
function Draw:Shape(canvas)
	local stroke = self.stroke
	local pointer = Pointer(canvas) or stroke.points[#stroke.points]
	local points

	if stroke.tool == "arrow" then
		points = { stroke.points[1], pointer }
	else
		points = {}
		for i, point in ipairs(stroke.points) do points[i] = point end
		-- The pointer is the end of the path, unless it is still on the last
		-- point taken.
		if Distance(canvas, points[#points], pointer) >= 1 then
			points[#points + 1] = pointer
		end
	end

	local length = 0
	for i = 2, #points do
		length = length + Distance(canvas, points[i - 1], points[i])
	end
	return points, length
end

function Draw:Begin(canvas)
	local pointer = Pointer(canvas)
	if not pointer then return end
	self.stroke = { tool = self.tool, points = { pointer }, step = STEP }
end

function Draw:Follow(canvas)
	local stroke = self.stroke
	local pointer = Pointer(canvas)

	if pointer and stroke.tool == "path" then
		local points = stroke.points
		if Distance(canvas, points[#points], pointer) >= stroke.step then
			points[#points + 1] = pointer
		end
		if #points >= MAX_POINTS then
			local thinned = {}
			for i = 1, #points, 2 do thinned[#thinned + 1] = points[i] end
			stroke.points, stroke.step = thinned, stroke.step * 2
		end
	end

	local points = self:Shape(canvas)
	if #points < 2 then return end

	local x, y, pts = ns.Model:PathShape(points)
	self.layer:SetPreview({ kind = "path", x = x, y = y, data = { pts = pts, color = self:Color() } })
end

function Draw:Finish(canvas)
	if not self.stroke then return end

	local points, length = self:Shape(canvas)
	self:Cancel()
	if #points < 2 or length < MIN_LENGTH then return end

	local slide, board = self.layer.slide, ns:CurrentBoard()
	if not slide or not board then return end

	local x, y, pts = ns.Model:PathShape(points)
	ns.Model:AddElement(slide, ns.Model:NewElement(board, "path", x, y, { pts = pts, color = self:Color() }))
end

function Draw:Cancel()
	self.stroke = nil
	if self.layer then self.layer:SetPreview(nil) end
end

-- The editor's canvas only: presentation mode has one of its own, and nothing
-- can be drawn there.
function Draw:Attach(canvas, layer)
	self.layer = layer

	canvas:HookScript("OnMouseDown", function(self, button)
		if button == "LeftButton" and Draw.tool then Draw:Begin(self) end
	end)

	canvas:HookScript("OnMouseUp", function(self, button)
		if button == "LeftButton" then Draw:Finish(self) end
	end)

	canvas:HookScript("OnUpdate", function(self)
		if Draw.stroke then Draw:Follow(self) end
	end)

	-- Escape closes the window with the button still down, and the release
	-- then goes nowhere.
	canvas:HookScript("OnHide", function() Draw:Cancel() end)
end
