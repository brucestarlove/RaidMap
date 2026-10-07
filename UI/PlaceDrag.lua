local ADDON, ns = ...

--[[
Drag-to-place. A ghost icon follows the cursor and, on release over the canvas,
the caller's place(x, y) runs with the normalized point under it. Roster rows,
raid markers and role icons all come through here, so they drop the same way.
]]

local PlaceDrag = {}
ns.PlaceDrag = PlaceDrag

local ghost

local function FollowCursor(self)
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	self:ClearAllPoints()
	self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
end

local function CreateGhost()
	ghost = CreateFrame("Frame", nil, UIParent)
	ghost:SetSize(28, 28)
	ghost:SetFrameStrata("TOOLTIP")
	ghost:Hide()

	ghost.icon = ghost:CreateTexture(nil, "OVERLAY")
	ghost.icon:SetAllPoints()

	-- Drawn the way a token draws its label, so the ghost previews the token.
	ghost.caption = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ghost.caption:SetPoint("TOP", ghost, "BOTTOM", 0, -1)
	local fontPath, fontSize = ghost.caption:GetFont()
	if fontPath then ghost.caption:SetFont(fontPath, fontSize, "OUTLINE") end

	ghost:SetScript("OnUpdate", FollowCursor)
end

-- caption may be nil; the texcoords default to the whole texture.
function PlaceDrag:Start(place, caption, texture, left, right, top, bottom)
	if not ghost then CreateGhost() end

	self.place = place

	ghost.icon:SetTexture(texture)
	ghost.icon:SetTexCoord(left or 0, right or 1, top or 0, bottom or 1)
	ghost.caption:SetText(caption or "")

	-- Positioned now rather than on the next frame, or the ghost flashes
	-- wherever the previous drag left it.
	FollowCursor(ghost)
	ghost:Show()
end

function PlaceDrag:Stop()
	local place = self.place
	if not place then return end

	self.place = nil
	self.stoppedAt = GetTime()
	ghost:Hide()

	local canvas = ns.MainCanvas
	if not canvas or not canvas:IsMouseOver() then return end

	local nx, ny = canvas:CursorToNormalized()
	if not nx then return end

	place(nx, ny)
end

-- True while dragging and for the rest of the frame a drag ended in. A button
-- that is both clickable and draggable checks this so that letting go of a
-- drag is never also treated as a click, whichever order the client reports
-- the two in.
function PlaceDrag:IsBusy()
	return self.place ~= nil or self.stoppedAt == GetTime()
end
