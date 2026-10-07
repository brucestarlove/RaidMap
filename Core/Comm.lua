local ADDON, ns = ...

local AceComm = LibStub("AceComm-3.0")

--[[
Sync. See PACKS.md for the design and why.

Bandwidth is the constraint: ~255 bytes per addon message, ~800 bytes/sec
sustained under ChatThrottleLib. Publishing a whole 8-board pack is ~20KB, or
about 25 seconds -- unacceptable for the weekly "I changed one boss" update.

So publishing sends a MANIFEST (a few hundred bytes) listing each board and its
revision. Receivers compare against what they hold and request only the boards
they are behind on. Change one boss, only that boss moves.

Opcodes on one prefix:
	M  manifest         -- small, broadcast, the thing publishing actually sends
	R  request          -- whispered back: "send me these board ids"
	D  board payload    -- one board, broadcast or whispered per the heuristic
	B  whole pack       -- legacy/import path, still accepted
	F  focus            -- board + slide, ~40 bytes, ALERT priority
	S  spec self-report

Focus rides its own opcode so a mid-fight "look at slide 3" never queues behind
a board transfer.
]]

local PREFIX = "RaidMap"

local OP_MANIFEST = "M"
local OP_REQUEST  = "R"
local OP_DATA     = "D"
local OP_BOARD    = "B"
local OP_FOCUS    = "F"
local OP_SPEC     = "S"
local OP_SPEC_REQ = "?"
local OP_LINK_REQ = "L"

local SEP = "\1"
local FIELD = "\2"

-- Requests are collected briefly so we can tell "one straggler" from "everyone
-- needs this", then answered in whichever way moves fewer bytes.
local REQUEST_WINDOW = 1.5
local BROADCAST_THRESHOLD = 3
local INCOMING_TIMEOUT = 45

local Comm = {}
ns.Comm = Comm
AceComm:Embed(Comm)

Comm.incoming = {}   -- uid -> assembling state
Comm.requests = {}   -- uid -> pending requests we must answer

local function shortName(name)
	if not name then return nil end
	return (name:match("^[^-]+")) or name
end

local function me()
	return shortName(UnitName("player"))
end

function Comm:Channel()
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
	return nil
end

-- In a raid, publishing is leader/assist only: a strategy board everyone can
-- overwrite is worse than no board. A 5-man has no assist concept.
function Comm:CanPublish()
	if not self:Channel() then return false end
	if not IsInRaid() then return true end
	return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function send(self, opcode, payload, distribution, target, priority)
	self:SendCommMessage(PREFIX, opcode .. SEP .. (payload or ""),
		distribution, target, priority or "NORMAL")
end

------------------------------------------------------------------- publishing

function Comm:BuildManifest(pack)
	local boards = {}
	for i, board in ipairs(pack.boards) do
		boards[i] = { id = board.id, rev = board.rev or 1, stamp = board.stamp, name = board.name }
	end

	return {
		uid = pack.uid,
		revision = pack.revision,
		title = pack.title,
		author = pack.author,
		locked = pack.locked,
		lastPublishedBy = pack.lastPublishedBy,
		currentBoard = pack.currentBoard,
		boards = boards,
	}
end

function Comm:AnnounceManifest(pack, distribution, target)
	local channel = distribution or self:Channel()
	if not channel then return end

	local manifest = ns.Serialize:PackForComm(self:BuildManifest(pack), "manifest")
	send(self, OP_MANIFEST, manifest, channel, target, "ALERT")
end

function Comm:PublishPack()
	local channel = self:Channel()
	if not channel then
		ns:Print("You are not in a group.")
		return
	end
	if not self:CanPublish() then
		ns:Print("Only the raid leader or an assistant can publish.")
		return
	end

	local pack = ns:CurrentPack()

	if pack.locked and pack.author ~= ns.Pack.AuthorName() then
		ns:Print("\"%s\" is locked by %s.", pack.title, pack.author)
		return
	end

	pack.revision = (pack.revision or 1) + 1
	pack.lastPublishedBy = ns.Pack.AuthorName()
	pack.lastPublishedAt = time()
	pack.modified = nil

	ns.Pack:PushHistory(pack)

	self.lastUpdate = { from = me(), time = time() }
	self:AnnounceManifest(pack, channel)

	ns:Print("Published \"%s\" rev %d. Sending only what each person is missing.",
		pack.title or "pack", pack.revision)
	ns.Events:Fire("SYNC_STATUS")
	ns.Events:Fire("PACK_CHANGED")
end

--[[
Focus carries the board as well as the slide. A bare index lands on whichever
board the receiver happened to be looking at, which is wrong the moment the lead
moves from one boss to the next -- and presentation mode makes that visible,
because the raider is now actually watching.

Older clients send a bare index; strsplit returns it unchanged, so they still
read as "this slide, whatever board you are on".
]]
function Comm:PublishFocus(index, board)
	local channel = self:Channel()
	if not channel or not self:CanPublish() then return end

	board = board or ns:CurrentBoard()
	local payload = tostring(index) .. FIELD .. (board and board.id or "")

	-- Throttled against repeats of the same target only. A blanket 1/sec would
	-- swallow a board change that immediately followed a slide change, which is
	-- exactly the sequence "next boss" produces.
	local now = GetTime()
	if self.lastFocusPayload == payload and (now - (self.lastFocusSent or 0)) < 1 then
		return
	end
	self.lastFocusSent, self.lastFocusPayload = now, payload

	send(self, OP_FOCUS, payload, channel, nil, "ALERT")
end

--------------------------------------------------------- answering requests

function Comm:FlushRequests(uid)
	local pending = self.requests[uid]
	self.requests[uid] = nil
	if not pending then return end

	local pack = ns.db.profile.packs[uid]
	if not pack then return end

	local requesterCount = 0
	for _ in pairs(pending.requesters) do requesterCount = requesterCount + 1 end
	if requesterCount == 0 then return end

	local byID = {}
	for _, board in ipairs(pack.boards) do byID[board.id] = board end

	-- Serialize each board once, however many people end up receiving it.
	local payloads = {}
	for boardID in pairs(pending.boards) do
		local board = byID[boardID]
		if board then
			payloads[boardID] = ns.Serialize:PackForComm({
				uid = uid,
				revision = pack.revision,
				board = board,
			}, "boarddata")
		end
	end

	-- A RAID broadcast is one transmission for all 25, so once enough people
	-- need boards, broadcasting the union beats whispering each of them.
	local broadcast = requesterCount >= BROADCAST_THRESHOLD
	local channel = self:Channel()

	local sent = 0
	if broadcast and channel then
		for _, payload in pairs(payloads) do
			send(self, OP_DATA, payload, channel, nil, "BULK")
			sent = sent + 1
		end
	else
		-- Whisper each requester only the boards they actually asked for; two
		-- people missing different boards should not each receive both.
		for requester, wanted in pairs(pending.requesters) do
			for _, boardID in ipairs(wanted) do
				local payload = payloads[boardID]
				if payload then
					send(self, OP_DATA, payload, "WHISPER", requester, "BULK")
					sent = sent + 1
				end
			end
		end
	end

	ns:Print("Sent %d board%s to %d %s (%s).",
		sent, sent == 1 and "" or "s",
		requesterCount, requesterCount == 1 and "person" or "people",
		broadcast and "broadcast" or "whisper")
end

function Comm:ReceiveRequest(data, from)
	local request = ns.Serialize:UnpackFromComm(data)
	if not request or not request.uid then return end

	local pack = ns.db.profile.packs[request.uid]
	if not pack then return end

	local pending = self.requests[request.uid]
	if not pending then
		pending = { requesters = {}, boards = {} }
		self.requests[request.uid] = pending

		C_Timer.After(REQUEST_WINDOW, function() self:FlushRequests(request.uid) end)
	end

	pending.requesters[from] = request.boards or {}
	for _, boardID in ipairs(request.boards or {}) do
		pending.boards[boardID] = true
	end
end

--------------------------------------------------------------- receiving

function Comm:NeededBoards(manifest)
	local existing = ns.db.profile.packs[manifest.uid]
	local needed, list = {}, {}

	for _, info in ipairs(manifest.boards or {}) do
		-- Same version, not "at least as new": see Model:Touch.
		local have = false
		if existing then
			for _, board in ipairs(existing.boards) do
				if board.id == info.id and (board.rev or 1) == (info.rev or 1)
					and board.stamp == info.stamp then
					have = true
					break
				end
			end
		end
		if not have then
			needed[info.id] = true
			list[#list + 1] = info.id
		end
	end

	return needed, list
end

function Comm:ReceiveManifest(data, from)
	local manifest = ns.Serialize:UnpackFromComm(data)
	if not manifest or not manifest.uid then return end

	local existing = ns.db.profile.packs[manifest.uid]

	-- Revision, not arrival order, decides. A replayed or out-of-order publish
	-- must never clobber something newer.
	if existing and (existing.revision or 0) >= (manifest.revision or 0) then
		return
	end

	-- Already fetching exactly this. The lead re-announces on every roster
	-- change; starting over would drop the boards received so far and ask for
	-- all of them again, which never finishes while people keep joining.
	local running = self.incoming[manifest.uid]
	if running and (running.manifest.revision or 0) == (manifest.revision or 0) then
		return
	end

	if ns.db.profile.pauseSync then
		self.pendingManifest = { manifest = manifest, from = from }
		ns:Print("%s published \"%s\" rev %d -- sync is paused, click Apply to take it.",
			from, manifest.title, manifest.revision or 0)
		ns.Events:Fire("SYNC_STATUS")
		return
	end

	self:StartTransfer(manifest, from)
end

function Comm:StartTransfer(manifest, from)
	local needed, list = self:NeededBoards(manifest)

	local entry = {
		manifest = manifest,
		from = from,
		needed = needed,
		boards = {},
		started = GetTime(),
	}
	self.incoming[manifest.uid] = entry

	if #list == 0 then
		-- Metadata-only change (a retitle, or a board reordering). Nothing to
		-- fetch; assemble straight from what we already hold.
		self:Assemble(manifest.uid)
		return
	end

	send(self, OP_REQUEST, ns.Serialize:PackForComm({
		uid = manifest.uid,
		revision = manifest.revision,
		boards = list,
	}, "request"), "WHISPER", from, "ALERT")
end

function Comm:ReceiveData(data)
	local payload = ns.Serialize:UnpackFromComm(data)
	if not payload or not payload.uid or not payload.board then return end

	local entry = self.incoming[payload.uid]
	if not entry then return end
	if (payload.revision or 0) ~= (entry.manifest.revision or 0) then return end

	entry.boards[payload.board.id] = payload.board
	entry.needed[payload.board.id] = nil

	for _ in pairs(entry.needed) do return end -- still waiting on others
	self:Assemble(payload.uid)
end

function Comm:Assemble(uid)
	local entry = self.incoming[uid]
	if not entry then return end

	local manifest = entry.manifest
	local existing = ns.db.profile.packs[uid]

	local pack = {
		uid = uid,
		title = manifest.title,
		author = manifest.author,
		revision = manifest.revision,
		lastPublishedBy = manifest.lastPublishedBy,
		lastPublishedAt = time(),
		currentBoard = manifest.currentBoard or 1,
		boards = {},
		-- The author's lock has to reach everyone to mean anything.
		locked = manifest.locked or nil,
		-- Local-only state survives an update; it is ours, not the sender's.
		history = existing and existing.history or nil,
		origin = existing and existing.origin or nil,
	}

	for i, info in ipairs(manifest.boards) do
		local board = entry.boards[info.id]

		if not board and existing then
			for _, candidate in ipairs(existing.boards) do
				if candidate.id == info.id then
					board = candidate
					break
				end
			end
		end

		if not board then
			ns:Print("|cffff5555Transfer of \"%s\" incomplete; missing a board.|r", manifest.title)
			self.incoming[uid] = nil
			return
		end

		pack.boards[i] = board
	end

	self.incoming[uid] = nil
	self:ApplyPack(pack, entry.from, existing ~= nil)
end

function Comm:ApplyPack(pack, from, existed)
	local profile = ns.db.profile

	if existed then profile.backupPack = profile.packs[pack.uid] end

	local wasCurrent = (profile.currentPack == pack.uid)

	-- Applying fires the same events a local edit does; without this every
	-- receiver would bump its board revisions and drift ahead of the sender.
	ns.applyingRemote = true

	ns.Pack:Add(pack)
	pack.currentBoard = math.max(1, math.min(pack.currentBoard or 1, #pack.boards))

	self.lastUpdate = { from = from, time = time() }

	if wasCurrent or not existed and #profile.packOrder == 1 then
		ns.History:Clear()
		profile.currentPack = pack.uid
		ns.Events:Fire("BOARD_REPLACED")
		ns:Print("\"%s\" updated by %s (rev %d).", pack.title, from, pack.revision or 0)
	elseif existed then
		ns:Print("\"%s\" updated by %s (rev %d).", pack.title, from, pack.revision or 0)
	else
		-- Do not yank someone's view onto a pack they have never seen.
		ns:Print("%s shared \"%s\" (%d boards) -- pick it from the Pack menu.",
			from, pack.title, #pack.boards)
	end

	ns.Events:Fire("PACK_CHANGED")
	ns.Events:Fire("SLIDES_CHANGED")
	ns.Events:Fire("ELEMENTS_CHANGED")
	ns.Events:Fire("SYNC_STATUS")

	ns.applyingRemote = nil
end

function Comm:ApplyPending()
	local pending = self.pendingManifest
	if not pending then return end
	self.pendingManifest = nil
	self:StartTransfer(pending.manifest, pending.from)
end

-- Legacy whole-pack payload, from a client running the previous version.
function Comm:ReceiveBoard(data, from)
	local incoming, err, payload = ns.Serialize:UnpackFromComm(data)
	if not incoming then
		ns:Print("|cffff5555Could not read pack from %s: %s|r", from, err or "unknown")
		return
	end

	if payload and payload.kind == "board" then
		local wrapper = ns.Pack:New(("%s's board"):format(from))
		wrapper.boards = { incoming }
		wrapper.author = from
		incoming = wrapper
	end

	if not incoming.uid then incoming.uid = ("%s#legacy"):format(from) end

	local existing = ns.db.profile.packs[incoming.uid]
	if existing and (existing.revision or 0) >= (incoming.revision or 0) then return end

	self:ApplyPack(incoming, from, existing ~= nil)
end

function Comm:ReceiveFocus(data, from)
	if ns.db.profile.pauseSync then return end

	local indexText, boardID = strsplit(FIELD, data)
	local index = tonumber(indexText)
	if not index then return end

	-- Follow the board too, when we hold it. A boardID we do not recognise means
	-- the sender is on a pack we do not have; moving the slide anyway is the
	-- closest useful thing we can do.
	if boardID and boardID ~= "" then
		local pack = ns:CurrentPack()
		for i, board in ipairs(pack and pack.boards or {}) do
			if board.id == boardID then
				if pack.currentBoard ~= i then ns.Pack:SelectBoard(pack, i) end
				break
			end
		end
	end

	if ns.SwitchSlide then ns.SwitchSlide(index, true) end

	-- Announced rather than calling into the UI: somebody is actively driving,
	-- and a player with nothing open is missing it entirely. Presentation mode
	-- decides what, if anything, to say about that.
	ns.Events:Fire("REMOTE_FOCUS", from)
end

function Comm:ReceiveSpec(data, from)
	local class, specName, specIcon = strsplit(FIELD, data)
	if not class or class == "" then return end

	ns.Roster.specs[from] = {
		class = class,
		specName = (specName ~= "" and specName) or nil,
		specIcon = tonumber(specIcon) or (specIcon ~= "" and specIcon) or nil,
	}

	ns.Roster:Build()
end

function Comm:OnCommReceived(prefix, message, distribution, sender)
	if prefix ~= PREFIX then return end

	local from = shortName(sender)
	if from == me() then return end

	-- Fixed-width header rather than a pattern: the encoded payload can itself
	-- contain the separator byte.
	local op = message:sub(1, 1)
	if message:sub(2, 2) ~= SEP then return end
	local data = message:sub(3)

	if op == OP_MANIFEST then
		self:ReceiveManifest(data, from)
	elseif op == OP_REQUEST then
		self:ReceiveRequest(data, from)
	elseif op == OP_DATA then
		self:ReceiveData(data)
	elseif op == OP_BOARD then
		self:ReceiveBoard(data, from)
	elseif op == OP_FOCUS then
		self:ReceiveFocus(data, from)
	elseif op == OP_SPEC then
		self:ReceiveSpec(data, from)
	elseif op == OP_SPEC_REQ then
		self:ScheduleSpecBroadcast(0.5 + math.random() * 4)
	elseif op == OP_LINK_REQ then
		self:ReceiveLinkRequest(data, from)
	end
end

--------------------------------------------------------------- chat linking

--[[
A chat link carries no payload, so the click asks the linker directly. The
answer is an ordinary manifest whispered back, which drops the requester into
the same delta machinery as a normal publish -- including only fetching boards
they do not already have.
]]
function Comm:RequestLinkedPack(author, title)
	send(self, OP_LINK_REQ, title, "WHISPER", author, "ALERT")
end

function Comm:ReceiveLinkRequest(title, from)
	-- An empty title is the "I do not have that" reply, not a new request.
	-- Answering it with another empty request would ping-pong forever.
	if title == "" then
		ns:Print("|cffff5555%s no longer has that pack.|r", from)
		return
	end

	local match
	for _, pack in ipairs(ns.Pack:List()) do
		if pack.title == title then
			match = pack
			break
		end
	end

	if not match then
		send(self, OP_LINK_REQ, "", "WHISPER", from, "ALERT")
		return
	end

	ns:Print("%s asked for \"%s\"; sending it.", from, match.title)
	self:AnnounceManifest(match, "WHISPER", from)
end

-------------------------------------------------------------------------- spec

function Comm:BroadcastSpec()
	local channel = self:Channel()
	if not channel then return end

	local specName, specIcon = ns.Roster:GetPlayerSpec()
	local _, class = UnitClass("player")

	send(self, OP_SPEC, table.concat({
		class or "",
		specName or "",
		tostring(specIcon or ""),
	}, FIELD), channel)
end

function Comm:ScheduleSpecBroadcast(delay)
	if self.specPending then return end
	self.specPending = true
	C_Timer.After(delay or 2, function()
		self.specPending = false
		self:BroadcastSpec()
	end)
end

function Comm:RequestSpecs()
	local channel = self:Channel()
	if not channel then return end

	local now = GetTime()
	if self.lastSpecRequest and (now - self.lastSpecRequest) < 15 then return end
	self.lastSpecRequest = now

	send(self, OP_SPEC_REQ, "", channel)
end

------------------------------------------------------- propagation on join

--[[
"Controlled virus": the lead re-announces the manifest when the roster changes.
Anyone already current computes an empty needed-list and stays silent, so this
is nearly free; a substitute who just joined pulls exactly what they lack with
no action from the lead.
]]
function Comm:AnnounceOnRosterChange()
	if not self:CanPublish() then return end

	-- Only a pack that has been published. Without this, everyone's untouched
	-- "My Pack" is handed to everyone else the moment a group forms.
	local pack = ns:CurrentPack()
	if not pack or not pack.lastPublishedAt then return end

	local now = GetTime()
	if self.lastAnnounce and (now - self.lastAnnounce) < 10 then return end
	self.lastAnnounce = now

	self:AnnounceManifest(pack)
end

----------------------------------------------------------------------- wiring

-- Talent/spec events only change what we report about ourselves; roster
-- events also mean someone new may need the pack.
local SPEC_EVENTS = {
	CHARACTER_POINTS_CHANGED = true,       -- talent tabs (Anniversary)
	PLAYER_SPECIALIZATION_CHANGED = true,  -- specs (Forever)
	TRAIT_CONFIG_UPDATED = true,
}

local watcher = CreateFrame("Frame")
ns.RegisterEvents(watcher, "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD",
	"CHARACTER_POINTS_CHANGED", "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED")
watcher:SetScript("OnEvent", function(_, event)
	if not ns.db then return end

	Comm:ScheduleSpecBroadcast(2)

	if not SPEC_EVENTS[event] then
		Comm:RequestSpecs()
		-- Slight delay: a joiner's addon should be listening before we announce.
		C_Timer.After(3, function() Comm:AnnounceOnRosterChange() end)
	end
end)

ns.Events:On("READY", function()
	Comm:RegisterComm(PREFIX, "OnCommReceived")

	-- Abandon transfers whose sender went offline or zoned mid-send, so a
	-- stalled entry does not block the next manifest for that pack.
	C_Timer.NewTicker(15, function()
		local now = GetTime()
		for uid, entry in pairs(Comm.incoming) do
			if now - entry.started > INCOMING_TIMEOUT then
				Comm.incoming[uid] = nil
				ns:Print("|cffff5555Gave up receiving \"%s\" from %s.|r",
					entry.manifest.title or "pack", entry.from or "?")
			end
		end
	end)
end)
