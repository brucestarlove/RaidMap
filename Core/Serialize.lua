local ADDON, ns = ...

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

--[[
Board <-> string.

SCHEMA is stamped into every payload and checked on the way back in. Packs
outlive the code that wrote them -- someone will import next tier a board
authored today -- so there has to be a version to branch migrations off. This
is the one piece of "public release" rigor kept despite building guild-first,
because retrofitting it means breaking every saved board.

Two encodings off the same compressed bytes:
	addon channel -- for sync, avoids bytes the chat system mangles
	print         -- for export strings a human pastes into Discord
]]

local Serialize = {}
ns.Serialize = Serialize

-- v1 carried a bare board. v2 carries a pack, and tags what it holds so the
-- same encoder can deep-copy a single board.
Serialize.SCHEMA = 2

local function compress(data, kind)
	local payload = {
		schema = Serialize.SCHEMA,
		addonVersion = ns.VERSION,
		kind = kind or "pack",
		data = data,
	}
	local serialized = LibSerialize:Serialize(payload)
	return LibDeflate:CompressDeflate(serialized, { level = 9 })
end

local function decompress(raw)
	local decompressed = LibDeflate:DecompressDeflate(raw)
	if not decompressed then return nil, "decompression failed" end

	local ok, payload = LibSerialize:Deserialize(decompressed)
	if not ok then return nil, "deserialization failed" end

	if type(payload) ~= "table" then return nil, "malformed payload" end

	if (payload.schema or 0) > Serialize.SCHEMA then
		return nil, ("made by a newer RaidMap (schema %d, this client speaks %d)")
			:format(payload.schema or 0, Serialize.SCHEMA)
	end

	-- schema 1: a bare board under its own key, with no kind tag.
	if payload.schema == 1 and type(payload.board) == "table" then
		return payload.board, nil, { schema = 1, kind = "board" }
	end

	if type(payload.data) ~= "table" then return nil, "malformed payload" end

	return payload.data, nil, payload
end

function Serialize:PackForComm(data, kind)
	local compressed = compress(data, kind)
	return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

function Serialize:UnpackFromComm(str)
	local raw = LibDeflate:DecodeForWoWAddonChannel(str)
	if not raw then return nil, "decode failed" end
	return decompress(raw)
end

function Serialize:PackForExport(data, kind)
	local compressed = compress(data, kind)
	return LibDeflate:EncodeForPrint(compressed)
end

function Serialize:UnpackFromExport(str)
	local raw = LibDeflate:DecodeForPrint(str)
	if not raw then return nil, "that does not look like a RaidMap string" end
	return decompress(raw)
end

function Serialize:Hash(str)
	return LibDeflate:Adler32(str)
end

-- Solo-verifiable check: sync itself needs two clients, but the round trip and
-- the payload budget can be proven alone.
function Serialize:SelfTest(pack)
	local packed = Serialize:PackForComm(pack, "pack")
	local size = #packed

	local restored, err = Serialize:UnpackFromComm(packed)
	if not restored then
		ns:Print("|cffff5555Round trip FAILED: %s|r", err or "unknown")
		return false
	end

	local slides, elements = 0, 0
	for _, board in ipairs(restored.boards or {}) do
		slides = slides + #board.slides
		for _, slide in ipairs(board.slides) do
			elements = elements + #slide.elements
		end
	end
	ns:Print("Pack \"%s\" rev %d by %s -- %d boards",
		restored.title or "?", restored.revision or 0, restored.author or "?", #(restored.boards or {}))

	-- ~255 bytes per addon message, and ChatThrottleLib sustains ~800 B/s.
	local messages = math.ceil(size / 240)
	ns:Print("Round trip OK: %d slides, %d elements", slides, elements)
	ns:Print("Payload %d bytes -> ~%d messages, ~%.1fs to broadcast",
		size, messages, size / 800)
	return true
end
