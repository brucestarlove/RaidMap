local ADDON, ns = ...

--[[
Typing text onto the map. With the Text tool armed, a click on bare map opens
a box there; a click on text already on the slide, armed or not, opens the
same box over it. Enter, or a click anywhere else, keeps what was typed.
Escape throws it away, and text typed away to nothing is deleted.

Nothing reaches the slide while the box is open. The text is written once,
when typing ends (Model:SetText), so however many keys it took it is one step
to undo and one change to publish, and nobody is sent half a word.
]]

local Text = {}
ns.Text = Text

-- Pointer travel, in screen pixels, past which a press on the map is a drag
-- rather than a click, and opens nothing.
local CLICK_SLOP = 6

-- How far the box reaches past the last letter. More than the widest letter,
-- so the next one always fits before the box grows: a box that is ever too
-- narrow scrolls its text sideways, and might not scroll it back.
local ROOM = 30

local box, measure, canvas, layer

-- As wide as what is in it, and the room for one more letter.
local function Fit()
	measure:SetText(box:GetText())
	box:SetWidth(measure:GetStringWidth() + ROOM)
end

-- Where the pointer is, on the map and in canvas pixels.
local function Pressed()
	local x, y = canvas:CursorToNormalized()
	if not x then return nil end
	local ox, oy = canvas:NormalizedToOffset(x, y)
	return { x = x, y = y, ox = ox, oy = oy }
end

function Text:IsOpen() return self.open ~= nil end

function Text:Place()
	local ox, oy = canvas:NormalizedToOffset(self.open.x, self.open.y)
	box:ClearAllPoints()
	box:SetPoint("LEFT", canvas, "TOPLEFT", ox, oy)
end

-- edit says what is being typed: the slide, and either the element being
-- changed or, for new text, where it goes and in what colour.
function Text:Open(edit, text)
	self:Finish(true)
	self.open = edit
	layer:SetEditing(edit.element)

	local color = ns.PATH_COLORS[edit.color] or ns.PATH_COLORS[1]
	box:SetTextColor(color[1], color[2], color[3], 1)
	box:SetText(text or "")
	-- Not left to OnTextChanged, which an empty box opened empty never sees.
	Fit()
	self:Place()
	-- Over the tokens, which are at most two above the canvas. Set on each
	-- opening, as the tokens' are on each drawing, since raising the window
	-- moves the canvas.
	box:SetFrameLevel(canvas:GetFrameLevel() + 5)
	box:Show()
	box:SetFocus()
end

-- A click on text already on the slide.
function Text:Edit(element)
	self:Open({
		slide = layer.slide, element = element,
		x = element.x, y = element.y, color = element.data.color,
	}, ns.Model:CleanText(element.data.text))
end

-- keep false is Escape: whatever was typed goes, and the text is as it was.
function Text:Finish(keep)
	local edit = self.open
	if not edit then return end

	-- Cleared first: hiding the box takes its focus, which comes back here.
	self.open = nil
	self.closedAt = GetTime()
	local text = box:GetText()
	box:ClearFocus()
	box:Hide()
	layer:SetEditing(nil)

	if not keep then return end
	if edit.element then
		ns.Model:SetText(edit.slide, edit.element, text)
	else
		text = ns.Model:CleanText(text)
		if text == "" or not edit.board then return end
		ns.Model:AddElement(edit.slide,
			ns.Model:NewElement(edit.board, "text", edit.x, edit.y, { text = text, color = edit.color }))
	end
end

local function CreateBox()
	box = CreateFrame("EditBox", nil, canvas)
	box:Hide()
	box:SetAutoFocus(false)
	box:SetMaxLetters(ns.Model.TEXT_LETTERS)
	ns.SetTextFont(box)
	box:SetTextInsets(0, 0, 0, 0)
	box:SetHeight(ns.TEXT_HEIGHT)

	-- A shade behind the letters, so the caret can be found on a busy map.
	-- Reaches back past the first letter rather than moving it: the text in
	-- the box starts exactly where the finished text will.
	local shade = box:CreateTexture(nil, "BACKGROUND")
	shade:SetPoint("TOPLEFT", -3, 0)
	shade:SetPoint("BOTTOMRIGHT", 0, 0)
	shade:SetColorTexture(0, 0, 0, 0.45)

	measure = box:CreateFontString(nil, "OVERLAY")
	ns.SetTextFont(measure)
	measure:Hide()

	box:SetScript("OnTextChanged", function(self)
		local text = self:GetText()
		-- Taken out as they are typed, so the box never shows a code the
		-- finished text will not.
		if text:find("|", 1, true) then
			self:SetText((text:gsub("|", "")))
			return
		end
		Fit()
	end)

	box:SetScript("OnEnterPressed", function() Text:Finish(true) end)
	box:SetScript("OnEscapePressed", function() Text:Finish(false) end)
	-- Another box took the keyboard: chat opened, say.
	box:SetScript("OnEditFocusLost", function() Text:Finish(true) end)

	-- A press anywhere but the box keeps the text. Polled, because no event
	-- says the mouse went down somewhere else in both clients. A press on the
	-- map is caught sooner, by the canvas itself, below.
	box:SetScript("OnUpdate", function(self)
		if not Text.open then return end
		if layer.slide ~= Text.open.slide then return Text:Finish(true) end
		if (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) and not self:IsMouseOver() then
			Text:Finish(true)
		end
	end)
end

-- The editor's canvas only: presentation mode has one of its own, and nothing
-- can be typed there.
function Text:Attach(mapCanvas, tokenLayer)
	canvas, layer = mapCanvas, tokenLayer
	CreateBox()

	canvas:HookScript("OnMouseDown", function(_, button)
		Text.press = nil
		-- A press on the map while typing only finishes the text, whether it
		-- is caught here or by the box a moment before.
		if Text.open then return Text:Finish(true) end
		if Text.closedAt == GetTime() then return end
		if button == "LeftButton" and ns.Draw.tool == "text" then Text.press = Pressed() end
	end)

	canvas:HookScript("OnMouseUp", function(_, button)
		local press = Text.press
		Text.press = nil
		if button ~= "LeftButton" or not press or ns.Draw.tool ~= "text" then return end

		local now = Pressed()
		if not now or math.sqrt((now.ox - press.ox) ^ 2 + (now.oy - press.oy) ^ 2) > CLICK_SLOP then return end

		local x, y = math.max(0, math.min(1, press.x)), math.max(0, math.min(1, press.y))
		Text:Open({ slide = layer.slide, board = ns:CurrentBoard(), x = x, y = y, color = ns.Draw:Color() })
	end)

	-- The box rides along with a zoom or a pan.
	ns.Events:On("CANVAS_VIEW_CHANGED", function(changed)
		if changed == canvas and Text.open then Text:Place() end
	end)

	-- Text deleted while it was being typed over, by an undo or by a pack
	-- arriving from someone else: there is nothing left to keep it in.
	ns.Events:On("ELEMENTS_CHANGED", function()
		local edit = Text.open
		if not edit or not edit.element then return end
		for _, element in ipairs(edit.slide.elements) do
			if element == edit.element then return end
		end
		Text:Finish(false)
	end)

	-- The window closing keeps the text, as a click away would.
	canvas:HookScript("OnHide", function() Text:Finish(true) end)
end
