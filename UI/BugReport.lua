local ADDON, ns = ...

--[[
The bug report window: what the player says went wrong, on top of what the
addon knows about itself, as text to copy out and email.

The game can neither send mail nor reach the clipboard, so the report is
something the player selects and copies themselves, the way an export string
is. The address is in the report's first line as well as on the window, so it
is still in front of them once they have pasted into a mail program.
]]

local EMAIL = "lavitzstarlove@pm.me"

local NOTE_HEIGHT = 70

-- Each line is worked out on its own. A report is asked for when something is
-- already wrong, and whatever cannot be read then, or is being kept secret by
-- the client, should cost its own line rather than the report.
local function add(lines, label, value)
	local ok, line = pcall(function() return label .. ": " .. value() end)
	if not ok then
		line = ("%s: (could not read: %s)"):format(label, tostring(line))
	elseif ns.AnySecret(line) then
		line = label .. ": (kept secret by the client just now)"
	end
	lines[#lines + 1] = line
end

local function state(window)
	if not window or not window:IsShown() then return "closed" end
	return ("open at %dx%d"):format(window:GetWidth(), window:GetHeight())
end

-- "2 marker, 1 path, 3 role"
local function tally(elements)
	local counts, kinds = {}, {}
	for _, element in ipairs(elements) do
		if not counts[element.kind] then
			counts[element.kind] = 0
			kinds[#kinds + 1] = element.kind
		end
		counts[element.kind] = counts[element.kind] + 1
	end
	if #kinds == 0 then return "nothing on it" end

	table.sort(kinds)
	for i, kind in ipairs(kinds) do
		kinds[i] = counts[kind] .. " " .. kind
	end
	return table.concat(kinds, ", ")
end

local function BuildReport(note)
	local lines = { ("=== RaidMap bug report, for %s ==="):format(EMAIL) }

	add(lines, "version", function() return ns.VERSION end)
	add(lines, "client", function()
		local version, build, _, interface = GetBuildInfo()
		return ("%s (%s), interface %s, %s"):format(version, build, interface, ns.FLAVOR)
	end)
	add(lines, "locale", function() return GetLocale() end)
	add(lines, "screen", function()
		local width, height = GetPhysicalScreenSize()
		return ("%dx%d, UI scale %.2f"):format(width, height, UIParent:GetEffectiveScale())
	end)
	add(lines, "when", function() return date("%Y-%m-%d %H:%M") end)
	add(lines, "character", function()
		local _, class = UnitClass("player")
		return ("%s, %s level %d"):format(ns.Pack.AuthorName(), class, UnitLevel("player"))
	end)
	add(lines, "zone", function()
		local zone = GetRealZoneText()
		local _, kind = IsInInstance()
		if kind and kind ~= "none" then return ("%s (%s instance)"):format(zone, kind) end
		return zone
	end)
	add(lines, "group", function()
		local channel = ns.Comm:Channel()
		if not channel then return "none" end
		local rank = UnitIsGroupLeader("player") and "leader"
			or UnitIsGroupAssistant("player") and "assistant" or "member"
		return ("%s of %d, %s"):format(channel:lower(), GetNumGroupMembers(), rank)
	end)
	add(lines, "sync", function()
		local parts = { ns.Comm:CanPublish() and "can publish" or "cannot publish" }
		if ns.db.profile.pauseSync then parts[#parts + 1] = "paused" end
		if ns.Comm.pendingManifest then parts[#parts + 1] = "an update waiting on Apply" end
		local update = ns.Comm.lastUpdate
		if update then
			parts[#parts + 1] = ("last update from %s %ds ago"):format(update.from, time() - update.time)
		end
		return table.concat(parts, ", ")
	end)
	add(lines, "windows", function()
		return ("editor %s, present mode %s"):format(state(RaidMapFrame), state(RaidMapPresentFrame))
	end)
	add(lines, "pack", function()
		local pack = ns:CurrentPack()
		return ("\"%s\" rev %d by %s, %d %s%s%s"):format(
			pack.title, pack.revision or 0, pack.author, #pack.boards, #pack.boards == 1 and "board" or "boards",
			pack.locked and ", locked" or "", pack.modified and ", edited since publish" or "")
	end)
	add(lines, "board", function()
		local pack, board = ns:CurrentPack(), ns:CurrentBoard()
		return ("%d of %d, \"%s\""):format(pack.currentBoard, #pack.boards, board.name)
	end)
	add(lines, "slide", function()
		local board = ns:CurrentBoard()
		local index = board.currentSlide or 1
		local slide = board.slides[index]
		return ("%d of %d, \"%s\", %s"):format(index, #board.slides, slide.name, tally(slide.elements))
	end)
	add(lines, "map", function()
		local board = ns:CurrentBoard()
		local key = board.slides[board.currentSlide or 1].mapKey
		local entry = ns.Catalog:Find(key)
		return ("%s (%s)"):format(key, entry and entry.name or "not one this client has")
	end)

	note = note:match("^%s*(.-)%s*$")
	lines[#lines + 1] = ""
	lines[#lines + 1] = "--- what went wrong ---"
	lines[#lines + 1] = note ~= "" and note or "(nothing written)"

	lines[#lines + 1] = ""
	lines[#lines + 1] = "--- recent messages ---"
	for _, line in ipairs(ns.log) do
		lines[#lines + 1] = line
	end
	if #ns.log == 0 then lines[#lines + 1] = "(none)" end

	return table.concat(lines, "\n")
end
ns.BuildBugReport = BuildReport

local frame

-- Written again on every keystroke in the note, so what is there to copy is
-- never a report from before the note was finished.
local function Refresh()
	local text = BuildReport(frame.note:GetText())
	frame.protected = text
	frame.edit:SetText(text)
end

local function CreateWindow()
	frame = ns.CreateTextFrame("RaidMapBugFrame", "Report a bug", false)
	frame:SetSize(560, 500)

	frame.hint:SetWidth(520)
	frame.hint:SetJustifyH("LEFT")
	frame.hint:SetText("Say what went wrong and what you were doing. Then press Select report,"
		.. " copy it with Ctrl+C, and paste it into an email to the address below.")

	local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", 0, -8)
	label:SetText("What went wrong:")

	local backdrop = CreateFrame("Frame", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
	backdrop:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
	backdrop:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
	backdrop:SetHeight(NOTE_HEIGHT)
	if backdrop.SetBackdrop then
		backdrop:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		backdrop:SetBackdropColor(0, 0, 0, 0.45)
		backdrop:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	end

	local noteScroll = CreateFrame("ScrollFrame", nil, backdrop, "UIPanelScrollFrameTemplate")
	noteScroll:SetPoint("TOPLEFT", 6, -6)
	noteScroll:SetPoint("BOTTOMRIGHT", -26, 6)

	local note = CreateFrame("EditBox", nil, noteScroll)
	note:SetMultiLine(true)
	note:SetAutoFocus(false)
	note:SetFontObject(ChatFontNormal)
	note:SetWidth(490)
	note:SetHeight(NOTE_HEIGHT - 12)
	note:SetTextInsets(2, 2, 2, 2)
	frame.note = note
	note:SetScript("OnEscapePressed", function() frame:Hide() end)
	note:SetScript("OnTextChanged", Refresh)
	noteScroll:SetScrollChild(note)

	-- Clicking anywhere in the box should start typing, not just on the text.
	backdrop:EnableMouse(true)
	backdrop:SetScript("OnMouseDown", function() note:SetFocus() end)

	-- The report, in the room left between the note and the bottom row.
	frame.scroll:ClearAllPoints()
	frame.scroll:SetPoint("TOPLEFT", backdrop, "BOTTOMLEFT", 2, -10)
	frame.scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 44)

	local address = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	address:SetPoint("BOTTOMLEFT", 16, 18)
	address:SetText("Email it to |cffffd100" .. EMAIL .. "|r")
	frame.address = address

	local selectReport = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	selectReport:SetSize(120, 22)
	selectReport:SetPoint("BOTTOMRIGHT", -16, 14)
	selectReport:SetText("Select report")
	selectReport:SetScript("OnClick", function()
		frame.edit:HighlightText()
		frame.edit:SetFocus()
	end)
	frame.selectReport = selectReport
end

function ns.ShowBugReport()
	if not frame then CreateWindow() end
	Refresh()
	frame:Show()
	frame.note:SetFocus()
end
