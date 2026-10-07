local ADDON, ns = ...

--[[
Packs. See PACKS.md for the full design.

	Pack -> Board -> Slide -> Element

A pack is the shareable unit ("BT guild"), a board is one boss, a slide is one
phase.

Identity is an immutable uid, never title+author: retitling a pack would
otherwise make every subscriber see a brand new pack, and two guilds both
naming one "BT guild" would collide. Title and author are display metadata.
]]

local Pack = {}
ns.Pack = Pack

local function authorName()
	local name = UnitName("player") or "?"
	local realm = GetRealmName() or "?"
	return name .. "-" .. realm
end

Pack.AuthorName = authorName

--[[
The address another client whispers to reach this character. AuthorName keeps
the display realm instead, because uids and author fields already saved were
minted with it.

On most clients that is Name-Realm, the realm without its spaces.

WoW Forever has no realm in a character's identity. A name there is a first
name and a surname, unique across the region, and the name functions hand back
the surname in the slot where other clients hand back a realm. Name-Realm
reaches nobody. Blizzard's own chat box takes "First-Surname" or "First
Surname" as a whisper target (ChatFrameEditBox.lua, ExtractTellTarget); the
hyphen form is used here because it has no space to lose inside a chat link.
]]
function Pack.WhisperName()
	local name, surname = (UnitNameUnmodified or UnitName)("player")
	name = name or "?"

	if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
		local full = (surname and surname ~= "") and (name .. "-" .. surname) or name
		return (full:gsub(" ", "-"))
	end

	local realm = GetNormalizedRealmName and GetNormalizedRealmName()
	if not realm or realm == "" then
		realm = (GetRealmName() or "?"):gsub("[%s%-]", "")
	end
	return name .. "-" .. realm
end

local function newUID()
	return ("%s#%d#%04x"):format(authorName(), time(), math.random(0, 0xFFFF))
end

function Pack:New(title)
	local board = ns.Model:NewBoard("New Board")
	return {
		uid = newUID(),
		title = title or "New Pack",
		author = authorName(),
		revision = 1,
		boards = { board },
		currentBoard = 1,
	}
end

------------------------------------------------------------------- accessors

function ns:CurrentPack()
	local profile = ns.db.profile
	return profile.packs and profile.packs[profile.currentPack]
end

function ns:CurrentBoard()
	local pack = ns:CurrentPack()
	if not pack then return nil end
	local index = math.max(1, math.min(pack.currentBoard or 1, #pack.boards))
	pack.currentBoard = index
	return pack.boards[index]
end

function Pack:List()
	local profile = ns.db.profile
	local list = {}
	for _, uid in ipairs(profile.packOrder or {}) do
		local pack = profile.packs[uid]
		if pack then list[#list + 1] = pack end
	end
	return list
end

function Pack:Add(pack)
	local profile = ns.db.profile
	profile.packs[pack.uid] = pack
	-- Only append if it is genuinely new; re-adding an updated pack must not
	-- duplicate its entry in the ordering.
	for _, uid in ipairs(profile.packOrder) do
		if uid == pack.uid then return pack end
	end
	table.insert(profile.packOrder, pack.uid)
	return pack
end

function Pack:Select(uid)
	local profile = ns.db.profile
	if not profile.packs[uid] then return false end
	profile.currentPack = uid
	-- Undo entries close over the previous pack's tables.
	ns.History:Clear()
	ns.Events:Fire("PACK_CHANGED")
	return true
end

function Pack:Delete(uid)
	local profile = ns.db.profile
	if #profile.packOrder <= 1 then return false end

	profile.packs[uid] = nil
	for i, existing in ipairs(profile.packOrder) do
		if existing == uid then
			table.remove(profile.packOrder, i)
			break
		end
	end

	if profile.currentPack == uid then
		profile.currentPack = profile.packOrder[1]
		ns.History:Clear()
	end

	ns.Events:Fire("PACK_CHANGED")
	return true
end

function Pack:Rename(pack, title)
	if not pack or title == "" then return end
	pack.title = title
	ns.Events:Fire("PACK_CHANGED")
end

function Pack:Duplicate(pack)
	-- Round-tripping through the serializer is the cheapest correct deep copy,
	-- and it exercises the same path sharing uses.
	local encoded = ns.Serialize:PackForExport(pack)
	local copy = ns.Serialize:UnpackFromExport(encoded)
	if not copy then return nil end

	copy.uid = newUID()
	copy.title = (pack.title or "Pack") .. " (copy)"
	copy.author = authorName()
	copy.revision = 1
	copy.origin = nil
	copy.lastPublishedBy = nil
	copy.lastPublishedAt = nil
	copy.locked = nil
	copy.modified = nil
	-- The snapshots are of the source pack and carry its uid.
	copy.history = nil

	return self:Add(copy)
end

--[[
Forking: an importer who edits someone else's pack needs a way to stop being a
subscriber to it. Records where it came from so the badge can say so.
]]
function Pack:Fork(pack)
	local copy = self:Duplicate(pack)
	if not copy then return nil end

	copy.title = pack.title
	copy.origin = {
		uid = pack.uid,
		author = pack.author,
		revision = pack.revision,
	}
	copy.modified = nil

	ns.Events:Fire("PACK_CHANGED")
	return copy
end

----------------------------------------------------------------------- boards

function Pack:AddBoard(pack, copyFromIndex)
	local board

	if copyFromIndex and pack.boards[copyFromIndex] then
		local encoded = ns.Serialize:PackForExport(pack.boards[copyFromIndex])
		board = ns.Serialize:UnpackFromExport(encoded)
		if not board then return nil end
		board.id = ns.Model:NewBoardID()
		board.name = board.name .. " (copy)"
	else
		board = ns.Model:NewBoard("Board " .. (#pack.boards + 1))
	end

	table.insert(pack.boards, board)
	ns.Events:Fire("PACK_CHANGED")
	return #pack.boards
end

function Pack:RemoveBoard(pack, index)
	if #pack.boards <= 1 then return false end
	table.remove(pack.boards, index)
	pack.currentBoard = math.max(1, math.min(pack.currentBoard or 1, #pack.boards))
	ns.History:Clear()
	ns.Events:Fire("PACK_CHANGED")
	return true
end

function Pack:SelectBoard(pack, index)
	pack.currentBoard = math.max(1, math.min(index, #pack.boards))
	-- Undo entries reference the outgoing board's slides.
	ns.History:Clear()
	ns.Events:Fire("PACK_CHANGED")
end

function Pack:RenameBoard(pack, index, name)
	local board = pack.boards[index]
	if not board or name == "" then return end
	board.name = name
	-- The name lives on the board, so it only travels if the board does.
	ns.Model:Touch(board)
	ns.Events:Fire("PACK_CHANGED")
end

------------------------------------------------------------ revision history

local HISTORY_DEPTH = 10

--[[
Snapshots are the already-compressed transport blob, so keeping ten of them
costs about what one pack costs. This is the answer to "a malicious or confused
assistant published garbage": roll back and republish.
]]
function Pack:PushHistory(pack)
	pack.history = pack.history or {}

	-- The blob must not contain the history, or each snapshot would embed every
	-- snapshot before it and the pack would grow geometrically.
	local saved = pack.history
	pack.history = nil
	local blob = ns.Serialize:PackForExport(pack, "pack")
	pack.history = saved

	table.insert(pack.history, 1, {
		rev = pack.revision,
		by = pack.lastPublishedBy or pack.author,
		at = time(),
		blob = blob,
	})

	for i = #pack.history, HISTORY_DEPTH + 1, -1 do
		pack.history[i] = nil
	end
end

function Pack:RestoreRevision(pack, index)
	local entry = pack.history and pack.history[index]
	if not entry then return false end

	local restored = ns.Serialize:UnpackFromExport(entry.blob)
	if not restored then
		ns:Print("|cffff5555That snapshot could not be read.|r")
		return false
	end

	-- Restoring must produce a NEWER revision. Republishing at the old number
	-- would be ignored as stale by everyone already holding the bad version.
	restored.uid = pack.uid
	restored.history = pack.history
	restored.revision = (pack.revision or 1) + 1
	restored.lastPublishedBy = self.AuthorName()
	restored.locked = pack.locked
	restored.origin = pack.origin

	ns.db.profile.packs[restored.uid] = restored
	ns.db.profile.currentPack = restored.uid

	ns.History:Clear()
	ns.Events:Fire("PACK_CHANGED")
	ns.Events:Fire("BOARD_REPLACED")

	ns:Print("Restored \"%s\" to the state at rev %d, now rev %d. Publish to push it.",
		restored.title, entry.rev, restored.revision)
	return true
end

--------------------------------------------------------------------- migration

-- schema v1 stored one bare board at profile.board. Wrap it in a pack.
function Pack:Migrate()
	local profile = ns.db.profile

	profile.packs = profile.packs or {}
	profile.packOrder = profile.packOrder or {}

	if profile.board then
		local pack = self:New("My Pack")
		profile.board.id = profile.board.id or ns.Model:NewBoardID()
		profile.board.name = profile.board.name or "Board 1"
		pack.boards = { profile.board }
		pack.currentBoard = 1

		self:Add(pack)
		profile.currentPack = pack.uid
		profile.board = nil

		ns:Print("Upgraded your board into a pack (\"%s\").", pack.title)
	end

	if #profile.packOrder == 0 then
		local pack = self:New("My Pack")
		self:Add(pack)
		profile.currentPack = pack.uid
	end

	if not profile.packs[profile.currentPack] then
		profile.currentPack = profile.packOrder[1]
	end
end
