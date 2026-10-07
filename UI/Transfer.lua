local ADDON, ns = ...

--[[
Export strings, import, and chat links.

The chat link carries no payload. Server-side filtering only tolerates known
link types, so the proven approach (WeakAuras does exactly this in this client,
see Transmission.lua:161) is a `garrmission` link whose *visible text* holds the
identifying information, parsed back out in a SetItemRef hook. Clicking it asks
the linker for the pack over the addon channel; the link itself is just a
handle.
]]

local LINK_PREFIX = "garrmission:raidmap"

local function stripHistory(pack, fn)
	-- Snapshots would multiply the string size for no benefit to the recipient.
	local saved = pack.history
	pack.history = nil
	local result = fn()
	pack.history = saved
	return result
end

------------------------------------------------------------------ text frame

-- Named, because UISpecialFrames takes a global frame name: registering a name
-- nothing answers to means Escape does not close these.
local function CreateTextFrame(name, title, editable)
	local frame = CreateFrame("Frame", name, UIParent,
		BackdropTemplateMixin and "BackdropTemplate" or nil)
	frame:SetSize(560, 320)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 32, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		frame:SetBackdropColor(0.08, 0.08, 0.10, 0.97)
	end

	local heading = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("TOPLEFT", 14, -12)
	heading:SetText(title)
	frame.heading = heading

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
	frame.hint = hint

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() frame:Hide() end)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -50)
	scroll:SetPoint("BOTTOMRIGHT", -34, 46)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(500)
	edit:SetHeight(900)
	edit:SetScript("OnEscapePressed", function() frame:Hide() end)
	scroll:SetScrollChild(edit)
	frame.edit = edit

	if not editable then
		-- Read-only in effect: any keystroke restores the string, so it can be
		-- selected and copied but not accidentally mangled.
		edit:SetScript("OnTextChanged", function(self, user)
			if user and frame.protected then
				self:SetText(frame.protected)
				self:HighlightText()
			end
		end)
	end

	tinsert(UISpecialFrames, name)
	return frame
end

local exportFrame, importFrame

function ns.ShowExport(pack)
	pack = pack or ns:CurrentPack()
	if not pack then return end

	if not exportFrame then
		exportFrame = CreateTextFrame("RaidMapExportFrame", "Export pack", false)
	end

	local text = stripHistory(pack, function()
		return ns.Serialize:PackForExport(pack, "pack")
	end)

	exportFrame.protected = text
	exportFrame.heading:SetText(("Export \"%s\""):format(pack.title or "pack"))
	exportFrame.hint:SetText(("%d boards, %d characters. Ctrl+A then Ctrl+C to copy.")
		:format(#pack.boards, #text))
	exportFrame.edit:SetText(text)
	exportFrame.edit:HighlightText()
	exportFrame.edit:SetFocus()
	exportFrame:Show()
end

local function DoImport(text)
	text = (text or ""):gsub("%s+", "")
	if text == "" then return end

	local incoming, err, payload = ns.Serialize:UnpackFromExport(text)
	if not incoming then
		ns:Print("|cffff5555Import failed: %s|r", err or "unreadable string")
		return
	end

	-- A bare board from an older export still deserves a home.
	if payload and payload.kind == "board" then
		local wrapper = ns.Pack:New(incoming.name or "Imported board")
		wrapper.boards = { incoming }
		incoming = wrapper
	end

	if type(incoming.boards) ~= "table" or #incoming.boards == 0 then
		ns:Print("|cffff5555That string does not contain a pack.|r")
		return
	end

	local existing = ns.db.profile.packs[incoming.uid]
	if existing and (existing.revision or 0) >= (incoming.revision or 0) then
		ns:Print("You already have \"%s\" at revision %d.",
			existing.title, existing.revision or 0)
		return
	end

	-- Local-only state is ours and survives the import. The lock is the
	-- author's and comes with the pack.
	if existing then
		incoming.history = existing.history
	end

	ns.Pack:Add(incoming)
	ns.Pack:Select(incoming.uid)

	ns:Print("Imported \"%s\" by %s -- %d boards.",
		incoming.title or "pack", ns.Pack.DisplayName(incoming.author), #incoming.boards)

	if incoming.author ~= ns.Pack.AuthorName() then
		ns:Print("It stays linked to %s, so their updates will reach you. Use Fork as mine to break that.",
			incoming.author and ns.Pack.DisplayName(incoming.author) or "the author")
	end
end

function ns.ShowImport()
	if not importFrame then
		importFrame = CreateTextFrame("RaidMapImportFrame", "Import pack", true)

		local button = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
		button:SetSize(110, 22)
		button:SetPoint("BOTTOMRIGHT", -16, 14)
		button:SetText("Import")
		button:SetScript("OnClick", function()
			DoImport(importFrame.edit:GetText())
			importFrame:Hide()
		end)
	end

	importFrame.heading:SetText("Import pack")
	importFrame.hint:SetText("Paste a RaidMap string, then press Import.")
	importFrame.edit:SetText("")
	importFrame.edit:SetFocus()
	importFrame:Show()
end

--------------------------------------------------------------- chat linking

--[[
What actually travels through chat is PLAIN TEXT: "[RaidMap: Title from
Author]". The server strips hyperlink types it does not know, so sending a real
`|H...|h` link would not survive. Instead every recipient's own addon rewrites
that plain text into a clickable link locally, via a chat filter. WeakAuras
does exactly this (Transmission.lua:146-170) and it is proven in this client.

Consequence worth knowing: people without RaidMap see the plain text, which
is a readable "go get this pack" rather than broken markup.
]]

local PLAIN_PATTERN = "%[RaidMap: (.-) from ([^%]]+)%]"

-- The retail-UI clients (WoW Forever) moved these into ChatFrameUtil; the old
-- globals there are shims that only exist while deprecation fallbacks are on.
local ChatUtil = ChatFrameUtil or {}
local GetActiveWindow = ChatUtil.GetActiveWindow or ChatEdit_GetActiveWindow
local ChooseBoxForSend = ChatUtil.ChooseBoxForSend or ChatEdit_ChooseBoxForSend
local ActivateChat = ChatUtil.ActivateChat or ChatEdit_ActivateChat
local AddMessageEventFilter = ChatUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter

function ns.LinkPackInChat(pack)
	pack = pack or ns:CurrentPack()
	if not pack then return end

	-- The name in the link is the whisper target of whoever clicks it.
	local plain = ("[RaidMap: %s from %s]"):format(pack.title or "pack", ns.Pack.WhisperName())

	local editBox = GetActiveWindow and GetActiveWindow()
	if not editBox and ChooseBoxForSend then
		editBox = ChooseBoxForSend(DEFAULT_CHAT_FRAME)
	end
	if not editBox then
		editBox = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox
	end

	if editBox then
		if ActivateChat then ActivateChat(editBox) end
		editBox:Insert(plain)
	else
		ns:Print("Could not find a chat box. Paste this yourself: %s", plain)
	end
end

local function LinkFilter(_, _, msg, ...)
	-- Chat text arrives secret during chat lockdown (instanced encounters);
	-- string functions on it would throw on every line of raid chat.
	if not msg or ns.AnySecret(msg) then return false end
	-- Plain find: "%" would be a literal character here, not an escape.
	if not msg:find("[RaidMap: ", 1, true) then return false end

	local rewritten = msg:gsub(PLAIN_PATTERN, function(title, author)
		return ("|Hgarrmission:raidmap|h|cff66ccff[RaidMap: %s from %s]|h|r")
			:format(title, author)
	end)

	return false, rewritten, ...
end

if AddMessageEventFilter then
	local CHAT_EVENTS = {
		"CHAT_MSG_CHANNEL", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
		"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
		"CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
		"CHAT_MSG_SAY", "CHAT_MSG_YELL",
		"CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
	}
	for _, event in ipairs(CHAT_EVENTS) do
		AddMessageEventFilter(event, LinkFilter)
	end
end

hooksecurefunc("SetItemRef", function(link, text)
	if ns.AnySecret(link, text) then return end
	if link ~= LINK_PREFIX and link ~= "garrmission:raidmap" then return end

	local title, author = text:match(PLAIN_PATTERN)
	if not title or not author then return end

	-- Strip any colouring that rode along inside the captures.
	title = title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	author = author:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")

	if author == ns.Pack.WhisperName() then
		ns:Print("That is your own pack.")
		return
	end

	ns:Print("Asking %s for \"%s\"...", author, title)
	ns.Comm:RequestLinkedPack(author, title)
end)
