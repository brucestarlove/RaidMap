local ADDON, ns = ...

--[[
The data model. Deliberately free of any frame references so it can be
serialized straight to a pack and, later, tested outside the game.

	Board -> Slide[] -> Element[]

Slides reference maps by *catalog key*, never by art table. Art can never be
transmitted over an addon channel, so a shared pack has to name a map both
sides already possess. Keys are that shared vocabulary.
]]

local Model = {}
ns.Model = Model

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

function Model:NewSlide(name, mapKey)
	return {
		name = name or "Slide 1",
		mapKey = mapKey or ns.Catalog:DefaultKey(),
		view = { cx = 0.5, cy = 0.5, zoom = 1 },
		elements = {},
	}
end

-- Stable per-board id, so per-board hashing can drive delta sync: change one
-- boss and only that boss's payload moves.
function Model:NewBoardID()
	return ("b%d%04x"):format(time(), math.random(0, 0xFFFF))
end

function Model:NewBoard(name)
	return {
		id = self:NewBoardID(),
		name = name or "Untitled Board",
		nextID = 0,
		-- Board-wide defaults for how player tokens draw. Per-token overrides
		-- can layer on top later without changing this shape.
		tokenDisplay = "both",      -- "both" | "icon" | "name"
		tokenLayout = "vertical",   -- "vertical" | "horizontal"
		slides = { self:NewSlide() },
	}
end

function Model:NextID(board)
	board.nextID = (board.nextID or 0) + 1
	return board.nextID
end

--[[
One generic element with variants, so the serializer, hit-testing and undo all
have a single implementation.

	kind = "marker"  data.index = 1..8   (raid target icons)
	kind = "player"  data.name, data.class, data.spec   (Phase 2)
	kind = "role"    data.role
	kind = "text"    data.text
]]
function Model:NewElement(board, kind, x, y, data)
	return {
		id = self:NextID(board),
		kind = kind,
		x = clamp01(x or 0.5),
		y = clamp01(y or 0.5),
		data = data or {},
	}
end

local function indexOf(list, item)
	for i = 1, #list do
		if list[i] == item then return i end
	end
end

--[[
Per-board version, changed on every edit. This is what makes delta sync work:
the manifest carries each board's version, and a receiver requests only the
boards whose version differs from the one it holds.

Deliberately NOT a content hash. LibSerialize walks tables with pairs(), whose
order varies between clients, so two clients holding identical content can
produce different bytes.

The version is the pair (rev, stamp), compared for equality. The counter alone
only orders the edits of ONE client: a raider who drags a token five times has
a higher rev than the lead's next edit, and a rollback has a lower one, so
"am I behind?" answers wrong in both. The random stamp says whose edit this is.
]]
function Model:Touch(board)
	board = board or ns:CurrentBoard()
	if not board then return end

	-- Applying a received pack fires the same events as a local edit; bumping
	-- here would make every receiver look one revision ahead of the sender.
	if ns.applyingRemote then return end

	board.rev = (board.rev or 1) + 1
	board.stamp = math.random(0, 0xFFFF) * 0x10000 + math.random(0, 0xFFFF)

	local pack = ns:CurrentPack()
	if pack then pack.modified = true end
end

function Model:AddElement(slide, element)
	table.insert(slide.elements, element)

	ns.History:Push({
		desc = "Add " .. element.kind,
		undo = function() table.remove(slide.elements, indexOf(slide.elements, element)) end,
		redo = function() table.insert(slide.elements, element) end,
	})

	Model:Touch()
	ns.Events:Fire("ELEMENTS_CHANGED")
	return element
end

function Model:RemoveElement(slide, element)
	local index = indexOf(slide.elements, element)
	if not index then return end

	table.remove(slide.elements, index)

	ns.History:Push({
		desc = "Remove " .. element.kind,
		undo = function() table.insert(slide.elements, index, element) end,
		redo = function() table.remove(slide.elements, indexOf(slide.elements, element)) end,
	})

	Model:Touch()
	ns.Events:Fire("ELEMENTS_CHANGED")
end

-- Called once on drag *stop*, not per frame -- otherwise a single drag would
-- bury the undo stack under a hundred one-pixel moves.
function Model:MoveElement(element, fromX, fromY, toX, toY)
	toX, toY = clamp01(toX), clamp01(toY)
	element.x, element.y = toX, toY

	if math.abs(fromX - toX) < 0.0005 and math.abs(fromY - toY) < 0.0005 then
		return
	end

	Model:Touch()

	ns.History:Push({
		desc = "Move " .. element.kind,
		undo = function() element.x, element.y = fromX, fromY end,
		redo = function() element.x, element.y = toX, toY end,
	})

	-- The dragged token has already moved itself on screen, but any *other*
	-- view of this slide -- presentation mode open alongside the editor -- has
	-- not. Once per drag, not per frame, so it is cheap.
	ns.Events:Fire("ELEMENTS_CHANGED")
end

function Model:ClearSlide(slide)
	if #slide.elements == 0 then return end

	local saved = {}
	for i, element in ipairs(slide.elements) do saved[i] = element end

	wipe(slide.elements)

	ns.History:Push({
		desc = "Clear slide",
		undo = function()
			for i, element in ipairs(saved) do slide.elements[i] = element end
		end,
		redo = function() wipe(slide.elements) end,
	})

	Model:Touch()
	ns.Events:Fire("ELEMENTS_CHANGED")
end

local function copyData(data)
	local copy = {}
	for k, v in pairs(data or {}) do copy[k] = v end
	return copy
end

--[[
Slides. A slide owns its map, its view (so a slide can frame one room), and its
elements. Duplicating the previous slide is the fast path for authoring
movement: copy, then nudge the tokens that moved.
]]
function Model:AddSlide(board, copyFromIndex)
	local slide

	if copyFromIndex and board.slides[copyFromIndex] then
		local src = board.slides[copyFromIndex]
		slide = self:NewSlide(src.name .. " (copy)", src.mapKey)
		slide.view.cx, slide.view.cy, slide.view.zoom = src.view.cx, src.view.cy, src.view.zoom

		for i, element in ipairs(src.elements) do
			slide.elements[i] = {
				id = self:NextID(board),
				kind = element.kind,
				x = element.x,
				y = element.y,
				data = copyData(element.data),
			}
		end
	else
		slide = self:NewSlide("Slide " .. (#board.slides + 1))
	end

	table.insert(board.slides, slide)
	local index = #board.slides

	ns.History:Push({
		desc = "Add slide",
		undo = function() table.remove(board.slides, index) end,
		redo = function() table.insert(board.slides, index, slide) end,
	})

	Model:Touch()
	ns.Events:Fire("SLIDES_CHANGED")
	return index
end

function Model:RemoveSlide(board, index)
	-- A board always has at least one slide; there is nothing to show otherwise.
	if #board.slides <= 1 then return false end

	local slide = table.remove(board.slides, index)

	ns.History:Push({
		desc = "Remove slide",
		undo = function() table.insert(board.slides, index, slide) end,
		redo = function() table.remove(board.slides, index) end,
	})

	Model:Touch()
	ns.Events:Fire("SLIDES_CHANGED")
	return true
end

function Model:RenameSlide(board, index, name)
	local slide = board.slides[index]
	if not slide or name == "" or name == slide.name then return end

	local previous = slide.name
	slide.name = name

	ns.History:Push({
		desc = "Rename slide",
		undo = function() slide.name = previous end,
		redo = function() slide.name = name end,
	})

	Model:Touch()
	ns.Events:Fire("SLIDES_CHANGED")
end

--[[
Undo stack. Command pattern rather than snapshots: cheap now, and it stays
cheap when a board holds 40 tokens across 6 slides.
]]
local History = {}
ns.History = History

History.stack = {}
History.pos = 0

function History:Push(entry)
	-- A new action after undoing discards the redo tail.
	for i = #self.stack, self.pos + 1, -1 do
		self.stack[i] = nil
	end
	self.stack[#self.stack + 1] = entry
	self.pos = #self.stack
	ns.Events:Fire("HISTORY_CHANGED")
end

function History:CanUndo() return self.pos > 0 end
function History:CanRedo() return self.pos < #self.stack end

-- Undo does not know whether it just reversed an element edit or a slide edit,
-- so it announces both. Listeners are cheap; a stale view is not.
function History:Undo()
	if not self:CanUndo() then return end
	self.stack[self.pos].undo()
	self.pos = self.pos - 1
	Model:Touch()
	ns.Events:Fire("SLIDES_CHANGED")
	Model:Touch()
	ns.Events:Fire("ELEMENTS_CHANGED")
	ns.Events:Fire("HISTORY_CHANGED")
end

function History:Redo()
	if not self:CanRedo() then return end
	self.pos = self.pos + 1
	self.stack[self.pos].redo()
	Model:Touch()
	ns.Events:Fire("SLIDES_CHANGED")
	Model:Touch()
	ns.Events:Fire("ELEMENTS_CHANGED")
	ns.Events:Fire("HISTORY_CHANGED")
end

function History:Clear()
	wipe(self.stack)
	self.pos = 0
	ns.Events:Fire("HISTORY_CHANGED")
end
