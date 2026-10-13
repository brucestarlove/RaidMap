local ADDON, ns = ...

ns.ADDON = ADDON

-- This client has moved the addon-info globals into C_AddOns; the bare globals
-- are gone. Keep the fallback so the addon survives on either.
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
local version = GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")
-- The packager writes the release tag over a placeholder in the TOC, which
-- says "dev" when loaded straight from the repository. This covers a TOC that
-- ends up with neither: no version at all, or the placeholder left in.
if not version or version:find("@", 1, true) then version = "dev" end
ns.VERSION = version

--[[
Which game this is, for CONTENT decisions only -- which instance maps to offer.
API differences are feature-detected at each call site, never keyed off this.

WoW Forever reports a classic-range interface number (1.60.1 -> 16001) while
running the retail UI, so its project ID has to be checked before the number.
]]
local function DetectFlavor()
	if WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
		return "forever"
	end
	local interface = select(4, GetBuildInfo())
	if interface < 20000 then return "vanilla" end
	if interface < 30000 then return "tbc" end
	return "retail"
end

ns.FLAVOR = DetectFlavor()

-- Registering an event the client does not know is a hard error on the
-- retail-UI clients, and the two clients disagree on talent/spec events.
function ns.RegisterEvents(frame, ...)
	local IsEventValid = C_EventUtils and C_EventUtils.IsEventValid
	for i = 1, select("#", ...) do
		local event = select(i, ...)
		if not IsEventValid or IsEventValid(event) then
			pcall(frame.RegisterEvent, frame, event)
		end
	end
end

-- Retail-UI clients hand back "secret values" in restricted states (boss
-- encounters, chat lockdown). They throw if compared, indexed with, or fed to
-- string functions, so anything that might be secret is checked first.
local issecretvalue = _G.issecretvalue
function ns.AnySecret(...)
	if not issecretvalue then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return true end
	end
	return false
end

-- A StaticPopup's edit box. Both clients build their dialogs from
-- GameDialogMixin, which keeps it at dialog.EditBox behind GetEditBox(); the
-- lowercase dialog.editBox of the older UI is nil there.
function ns.PopupEditBox(dialog)
	if dialog.GetEditBox then return dialog:GetEditBox() end
	return dialog.EditBox or dialog.editBox
end

-- The last things the addon said or tripped over, for a bug report to quote.
-- This session's only: a report is written in the session that went wrong.
local LOG_LINES = 40
ns.log = {}

function ns.Log(text)
	local log = ns.log
	-- Without the colour codes: a report is read as plain text.
	text = tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	log[#log + 1] = date("%H:%M:%S") .. "  " .. text
	if #log > LOG_LINES then table.remove(log, 1) end
end

-- Minimal event emitter. The Model/Render split means Render listens for model
-- changes rather than the model reaching into frames.
local Events = {}
ns.Events = Events

local handlers = {}

function Events:On(event, fn)
	handlers[event] = handlers[event] or {}
	table.insert(handlers[event], fn)
	return fn
end

function Events:Off(event, fn)
	local list = handlers[event]
	if not list then return end
	for i = #list, 1, -1 do
		if list[i] == fn then table.remove(list, i) end
	end
end

function Events:Fire(event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok then
			local message = ("RaidMap: handler for '%s' failed: %s"):format(event, err)
			ns.Log(message)
			geterrorhandler()(message)
		end
	end
end

local defaults = {
	profile = {
		window = {
			width = 1060,
			height = 660,
			point = "CENTER",
			relPoint = "CENTER",
			x = 0,
			y = 0,
			shown = false,
		},
		-- Presentation mode keeps its own geometry: it is a different shape of
		-- window doing a different job, and a raider who never opens the editor
		-- should not inherit its size.
		present = {
			width = 560,
			height = 440,
			point = "CENTER",
			relPoint = "CENTER",
			x = 0,
			y = 0,
			shown = false,
			showNotes = true,
			scope = "slide",
		},
		-- Last viewed map, so reopening lands where you left off.
		lastMap = "blacktemple",
		showNotes = true,
		-- The minimap button. LibDBIcon is handed this table and keeps the
		-- button's place round the minimap in it as well.
		minimap = { hide = false },
	},
}

function ns:Print(fmt, ...)
	local msg = select("#", ...) > 0 and fmt:format(...) or fmt
	ns.Log(msg)
	print("|cff66ccffRaidMap|r: " .. msg)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
	if name ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")

	ns.db = LibStub("AceDB-3.0"):New("RaidMapDB", defaults, true)

	ns.Events:Fire("READY")

	SLASH_RAIDMAP1 = "/raidmap"
	SLASH_RAIDMAP2 = "/rm"
	SlashCmdList.RAIDMAP = function(msg)
		msg = (msg or ""):lower():match("^%s*(.-)%s*$")
		if msg == "selftest" then
			ns.Serialize:SelfTest(ns:CurrentPack())
		elseif msg == "present" then
			ns.TogglePresentation()
		elseif msg == "census" then
			ns.Census:Run()
		elseif msg == "publish" then
			ns.Comm:PublishPack()
		elseif msg == "bug" then
			ns.ShowBugReport()
		elseif msg == "minimap" then
			-- The way back for an icon hidden from its own menu.
			local shown = ns.db.profile.minimap.hide
			ns.SetMinimapShown(shown)
			ns:Print(shown and "Minimap icon shown." or "Minimap icon hidden.")
		elseif msg == "restore" then
			-- Escape hatch: an incoming pack replaced work you wanted.
			local backup = ns.db.profile.backupPack
			if backup then
				ns.db.profile.backupPack = nil
				-- Restore must republish as a NEWER revision than the one it
				-- replaces, or every client that already holds the offending
				-- version will ignore it. That version can be several ahead.
				local replaced = ns.db.profile.packs[backup.uid]
				backup.revision = math.max(backup.revision or 1, replaced and replaced.revision or 0) + 1
				ns.Pack:Add(backup)
				ns.db.profile.currentPack = backup.uid
				ns.History:Clear()
				ns.Events:Fire("PACK_CHANGED")
				ns.Events:Fire("BOARD_REPLACED")
				ns:Print("Restored \"%s\" as rev %d. Publish to push it to the raid.",
					backup.title or "pack", backup.revision)
			else
				ns:Print("Nothing to restore.")
			end
		elseif msg == "reset" then
			local w = ns.db.profile.window
			w.point, w.relPoint, w.x, w.y = "CENTER", "CENTER", 0, 0
			w.width, w.height = defaults.profile.window.width, defaults.profile.window.height
			ns.Events:Fire("WINDOW_RESET")
			ns:Print("Window position reset.")
		else
			ns.Events:Fire("TOGGLE_WINDOW")
		end
	end
end)
