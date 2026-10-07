local ADDON, ns = ...

--[[
Roster data. Kept free of frames so the panel is a pure view over it.

TBC has no GetSpecialization -- a "spec" is whichever talent tab holds the most
points, and that tab's icon is the spec icon. We can only read our OWN talents
locally; other people's specs need either inspection (range-limited, throttled)
or a self-report over the addon channel (Phase 4). Until then everyone else
falls back to their class icon, which is still useful and never wrong.
]]

local Roster = {}
ns.Roster = Roster

Roster.CLASS_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

Roster.entries = {}

-- Specs reported by other players' clients over the addon channel, keyed by
-- short name. This is how everyone else's spec arrives without inspecting.
Roster.specs = {}

-- Solo development would otherwise be impossible: you cannot test a roster
-- panel without 39 friends online. One short of a full raid, because you are
-- in it; Build tops each group up to five around whoever is really there.
local GROUPS, GROUP_SIZE = 8, 5

local DEMO = {
	{ name = "Mordreth",     class = "WARRIOR" },
	{ name = "Shockadin",    class = "PALADIN" },
	{ name = "Feathers",     class = "DRUID" },
	{ name = "Lightwell",    class = "PRIEST" },

	{ name = "Ironbrow",     class = "WARRIOR" },
	{ name = "Bruce",        class = "WARRIOR" },
	{ name = "Aldric",       class = "PALADIN" },
	{ name = "Kazgrim",      class = "SHAMAN" },
	{ name = "Toskk",        class = "ROGUE" },

	{ name = "Wyrmbane",     class = "WARRIOR" },
	{ name = "Fenwick",      class = "ROGUE" },
	{ name = "Mistfang",     class = "ROGUE" },
	{ name = "Yorrick",      class = "ROGUE" },
	{ name = "Emberlash",    class = "SHAMAN" },

	{ name = "Sylvara",      class = "HUNTER" },
	{ name = "Galewind",     class = "HUNTER" },
	{ name = "Jorvik",       class = "HUNTER" },
	{ name = "Stormcrow",    class = "HUNTER" },
	{ name = "Thunderhoofs", class = "SHAMAN" },   -- twelve letters, the longest a name gets

	{ name = "Illyria",      class = "MAGE" },
	{ name = "Cinderveil",   class = "MAGE" },
	{ name = "Kelthar",      class = "MAGE" },
	{ name = "Pyrelle",      class = "MAGE" },
	{ name = "Coldsnap",     class = "MAGE" },

	{ name = "Volkath",      class = "WARLOCK" },
	{ name = "Hexabelle",    class = "WARLOCK" },
	{ name = "Nethria",      class = "WARLOCK" },
	{ name = "Umbric",       class = "WARLOCK" },
	{ name = "Ashgrave",     class = "WARLOCK" },

	{ name = "Dawnsworn",    class = "PRIEST" },
	{ name = "Valeska",      class = "PRIEST" },
	{ name = "Xanthe",       class = "PRIEST" },
	{ name = "Zulmara",      class = "SHAMAN" },
	{ name = "Runehild",     class = "SHAMAN" },

	{ name = "Brambleclaw",  class = "DRUID" },
	{ name = "Lunessa",      class = "DRUID" },
	{ name = "Oakheart",     class = "DRUID" },
	{ name = "Quillon",      class = "PALADIN" },
	{ name = "Briarrose",    class = "PALADIN" },
}

-- WoW Forever has no talent tabs; it has real specs on the retail API. The
-- Anniversary client also exposes C_SpecializationInfo, so tabs stay first to
-- keep the behaviour that is already verified there.
local function GetModernSpec()
	local SpecInfo = C_SpecializationInfo
	if not (SpecInfo and SpecInfo.GetSpecialization and SpecInfo.GetSpecializationInfo) then
		return nil
	end

	local index = SpecInfo.GetSpecialization()
	if not index or index < 1 then return nil end

	-- specID, name, description, icon, role
	local _, name, _, icon = SpecInfo.GetSpecializationInfo(index)
	return name, icon
end

function Roster:GetPlayerSpec()
	if not GetNumTalentTabs or not GetTalentTabInfo then return GetModernSpec() end

	local numTabs = GetNumTalentTabs() or 0
	local bestName, bestIcon, bestPoints = nil, nil, -1

	for i = 1, numTabs do
		-- id, name, description, icon, pointsSpent
		local _, name, _, icon, points = GetTalentTabInfo(i)
		if points and points > bestPoints then
			bestName, bestIcon, bestPoints = name, icon, points
		end
	end

	-- A fresh character with no points spent has no meaningful spec.
	if bestPoints and bestPoints > 0 then
		return bestName, bestIcon
	end
end

local function classOf(unit)
	local _, token = UnitClass(unit)
	return token
end

function Roster:Build()
	local entries = {}

	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local name, _, subgroup, _, _, classToken, _, online, isDead = GetRaidRosterInfo(i)
			-- Identity can come back secret mid-encounter. The raid does not
			-- change shape mid-pull, so keep the last good roster and rebuild
			-- when the restriction lifts.
			if ns.AnySecret(name, classToken, subgroup) then return self.entries end
			if name then
				entries[#entries + 1] = {
					name = name,
					class = classToken,
					subgroup = subgroup,
					online = online,
					isDead = isDead,
				}
			end
		end
	elseif IsInGroup() then
		entries[#entries + 1] = {
			name = UnitName("player"), class = classOf("player"), subgroup = 1, online = true,
		}
		for i = 1, GetNumGroupMembers() - 1 do
			local unit = "party" .. i
			if UnitExists(unit) then
				if ns.AnySecret(UnitName(unit), classOf(unit)) then return self.entries end
				entries[#entries + 1] = {
					name = UnitName(unit),
					class = classOf(unit),
					subgroup = 1,
					online = UnitIsConnected(unit),
				}
			end
		end
	else
		entries[#entries + 1] = {
			name = UnitName("player"), class = classOf("player"), subgroup = 1, online = true,
		}
	end

	-- Our own spec is the one we can always resolve without comms or inspects.
	local playerName = UnitName("player")
	local specName, specIcon = self:GetPlayerSpec()

	for _, entry in ipairs(entries) do
		if entry.name == playerName then
			entry.specName, entry.specIcon = specName, specIcon
		else
			local reported = self.specs[entry.name]
			if reported then
				entry.specName, entry.specIcon = reported.specName, reported.specIcon
			end
		end
	end

	if ns.db and ns.db.profile.demoRoster then
		-- Fill the open slots group by group, so real members keep theirs and
		-- the result is a full raid whoever is actually here.
		local size = {}
		for _, entry in ipairs(entries) do
			local group = entry.subgroup or 1
			size[group] = (size[group] or 0) + 1
		end

		local group = 1
		for _, demo in ipairs(DEMO) do
			while group <= GROUPS and (size[group] or 0) >= GROUP_SIZE do
				group = group + 1
			end
			if group > GROUPS then break end

			size[group] = (size[group] or 0) + 1
			entries[#entries + 1] = {
				name = demo.name,
				class = demo.class,
				subgroup = group,
				online = true,
				isDemo = true,
			}
		end
	end

	table.sort(entries, function(a, b)
		if a.subgroup ~= b.subgroup then return (a.subgroup or 9) < (b.subgroup or 9) end
		return a.name < b.name
	end)

	self.entries = entries
	ns.Events:Fire("ROSTER_CHANGED")
	return entries
end

function Roster:ClassColor(classToken)
	local color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if color then return color.r, color.g, color.b end
	return 0.8, 0.8, 0.8
end

local watcher = CreateFrame("Frame")
ns.RegisterEvents(watcher,
	"GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD",
	"CHARACTER_POINTS_CHANGED",                                  -- talent tabs (Anniversary)
	"PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED",     -- specs (Forever)
	"ADDON_RESTRICTION_STATE_CHANGED")                           -- rebuild once secrets clear
watcher:SetScript("OnEvent", function()
	if ns.db then Roster:Build() end
end)
