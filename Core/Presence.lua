local ADDON, ns = ...

-- Small, independent status packets. Old clients ignore these opcodes and
-- still exchange packs normally. Never infer "not installed" from silence.
local Comm = ns.Comm
local SEP, FIELD = "\1", "\2"
local STALE = 90
local peers = {}

local function canonical(name)
	return name:gsub(" ", "-"):lower()
end

local function address(unit)
	local surnames = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
	local getName = surnames and (UnitNameUnmodified or UnitName) or (UnitFullName or UnitName)
	local name, suffix = getName(unit)
	if ns.AnySecret(name, suffix) or not name or name == "" then return nil end
	if name:find("-", 1, true) then return name end
	if surnames then
		return suffix and suffix ~= "" and (name .. "-" .. suffix) or name
	end
	if not suffix or suffix == "" then
		suffix = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
	end
	return name .. "-" .. (suffix or ""):gsub("[%s%-]", "")
end

function Comm:GroupMembers()
	local members, seen = {}, {}
	local function add(unit)
		local name = address(unit)
		if not name then return end
		local key = canonical(name)
		if seen[key] then return end
		seen[key] = true
		local online = UnitIsConnected and UnitIsConnected(unit)
		if ns.AnySecret(online) then online = nil end
		members[#members + 1] = {
			key = key, name = name, mine = key == canonical(ns.Pack.WhisperName()),
			online = online ~= false,
		}
	end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do add("raid" .. i) end
	elseif IsInGroup() then
		add("player")
		for i = 1, GetNumGroupMembers() - 1 do add("party" .. i) end
	end
	return members
end

local function memberKey(self, sender)
	local key = canonical(sender)
	-- On Classic a same-realm sender can arrive without its realm suffix.
	local bare = not sender:find("-", 1, true) and not sender:find(" ", 1, true)
	if bare and not (RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()) then
		local realm = GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
		key = canonical(sender .. "-" .. (realm or ""):gsub("[%s%-]", ""))
	end
	for _, member in ipairs(self:GroupMembers()) do
		if member.key == key then return key end
	end
end

-- Compare release tags, including alpha/beta/rc tags; development labels
-- have no ordering and must not mark a released client as out of date.
local function versionParts(version)
	if type(version) ~= "string" then return nil end
	local major, minor, patch, suffix = version:match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
	if not major then return nil end
	local rank, serial = 4, 0
	if suffix ~= "" and suffix:sub(1, 1) ~= "+" then
		local tag, n = suffix:match("^%-([%a]+)[%.%-]?(%d*)")
		rank = ({ alpha = 1, beta = 2, rc = 3 })[tag]
		if not rank then return nil end
		serial = tonumber(n) or 0
	end
	return { tonumber(major), tonumber(minor), tonumber(patch), rank, serial }
end

function Comm.CompareVersions(a, b)
	a, b = versionParts(a), versionParts(b)
	if not a or not b then return nil end
	for i = 1, #a do
		if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
	end
	return 0
end

function Comm:NotePeer(sender, version)
	local key = memberKey(self, sender)
	if not key then return end
	local peer = peers[key] or {}
	peers[key], peer.seen = peer, GetTime()
	if type(version) == "string" and #version <= 48 and version:match("^[%w%.%+%-]+$") then
		peer.version = version
	end
	ns.Events:Fire("GROUP_STATUS")
	return peer
end

function Comm:ReceivePresence(data, sender, distribution)
	if distribution ~= self:Channel() or #data > 240 then return end
	local version, shown, uid = strsplit(FIELD, data)
	if (shown ~= "0" and shown ~= "1") or not uid then return end
	local peer = self:NotePeer(sender, version)
	if not peer then return end
	peer.shown, peer.uid, peer.presenceAt = shown == "1", uid, GetTime()
	ns.Events:Fire("GROUP_STATUS")
end

function Comm:BroadcastPresence(force)
	local channel = self:Channel()
	if not channel or not ns.db then return end
	local pack = ns:CurrentPack()
	local shown = ns.IsPresentationShown and ns.IsPresentationShown()
	local payload = table.concat({ ns.VERSION, shown and "1" or "0", pack and pack.uid or "" }, FIELD)
	local now = GetTime()
	if not force and payload == self.lastPresence and now - (self.lastPresenceAt or 0) < 25 then return end
	self.lastPresence, self.lastPresenceAt = payload, now
	self:SendCommMessage("RaidMap", "P" .. SEP .. payload, channel, nil, "NORMAL")
	ns.Events:Fire("GROUP_STATUS")
end

function Comm:SchedulePresence()
	if self.presencePending then return end
	self.presencePending = true
	C_Timer.After(0.5 + math.random() * 2, function()
		self.presencePending = nil
		self:BroadcastPresence(true)
	end)
end

function Comm:RequestGroupStatus()
	local channel = self:Channel()
	if not channel then return end
	local now = GetTime()
	if self.lastStatusRequest and now - self.lastStatusRequest < 15 then return end
	self.lastStatusRequest = now
	self:SendCommMessage("RaidMap", "Q" .. SEP, channel, nil, "NORMAL")
end

function Comm:GetGroupStatus()
	local rows, latest, now = self:GroupMembers(), ns.VERSION, GetTime()
	local pack = ns:CurrentPack()
	for _, row in ipairs(rows) do
		local peer = peers[row.key]
		if row.mine then
			row.version = ns.VERSION
			row.shown = ns.IsPresentationShown and ns.IsPresentationShown() or false
			row.uid = pack and pack.uid
			row.known = true
		elseif peer then
			row.version, row.known = peer.version, true
			if peer.presenceAt and now - peer.presenceAt < STALE then
				row.shown, row.uid = peer.shown, peer.uid
			end
		end
		if row.version and (not versionParts(latest) or self.CompareVersions(row.version, latest) == 1) then
			latest = row.version
		end
	end
	local watching, thisPack, outdated = 0, 0, 0
	for _, row in ipairs(rows) do
		row.outdated = self.CompareVersions(row.version, latest) == -1
		if row.outdated then outdated = outdated + 1 end
		if not row.online then row.state = "Offline"
		elseif row.shown then
			watching = watching + 1
			if pack and row.uid == pack.uid then
				row.state, thisPack = "This pack", thisPack + 1
			else row.state = "Other pack" end
		elseif row.shown == false then row.state = "Closed"
		else row.state = row.known and "Unknown" or "No reply" end
	end
	return rows, watching, #rows, thisPack, outdated, latest
end

function Comm:ViewerCount()
	local _, watching, total, thisPack = self:GetGroupStatus()
	return watching, total, thisPack
end

local function rosterChanged()
	if not ns.db then return end
	local keep = {}
	for _, member in ipairs(Comm:GroupMembers()) do keep[member.key] = true end
	for key in pairs(peers) do if not keep[key] then peers[key] = nil end end
	if not Comm:Channel() then
		Comm.lastPresence, Comm.lastPresenceAt, Comm.lastStatusRequest = nil, nil, nil
	end
	Comm:SchedulePresence()
	Comm:RequestGroupStatus()
	ns.Events:Fire("GROUP_STATUS")
end

local watcher = CreateFrame("Frame")
ns.RegisterEvents(watcher, "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", rosterChanged)
ns.Events:On("PACK_CHANGED", function() Comm:BroadcastPresence() end)
ns.Events:On("READY", function()
	rosterChanged()
	C_Timer.NewTicker(30, function()
		Comm:BroadcastPresence()
		ns.Events:Fire("GROUP_STATUS")
	end)
end)
