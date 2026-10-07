local ADDON, ns = ...

--[[
/rm census -- what map art does THIS client actually have?

tools/mapdata.py works from public data, which cannot see encrypted beta
content; the client can, once Blizzard ships the keys. The census records
every uiMap with art plus every instance floor in Data/Instances.lua, as flat
"|"-separated strings that `tools/mapdata.py --census` parses without needing
a Lua interpreter. /reload afterwards so SavedVariables hit the disk.

	B|version|build|flavor|unixtime                 (first line of a census)
	M|uiMapID|mapType|parentID|name|cols|rows|layerW|layerH|numTextures
	F|instanceKey|alt|floor|fileID                   (fileID 0 = not in client)
]]

local Census = {}
ns.Census = Census

local MAX_MAP_ID = 5000
local CHUNK = 250   -- map IDs per frame; the whole scan takes ~20 frames

local function clean(s)
	return (tostring(s or ""):gsub("|", "/"))
end

local function FileID(path)
	if not GetFileIDFromPath then return 0 end
	return GetFileIDFromPath(path) or 0
end

local function ScanMaps(lines, first, last)
	local found = 0
	for id = first, last do
		local info = C_Map.GetMapInfo(id)
		local layers = info and C_Map.GetMapArtLayers(id)
		local layer = layers and layers[1]
		if layer then
			local textures = C_Map.GetMapArtLayerTextures(id, 1)
			lines[#lines + 1] = ("M|%d|%d|%d|%s|%d|%d|%d|%d|%d"):format(
				id, info.mapType or -1, info.parentMapID or 0, clean(info.name),
				math.ceil(layer.layerWidth / layer.tileWidth),
				math.ceil(layer.layerHeight / layer.tileHeight),
				layer.layerWidth, layer.layerHeight, textures and #textures or 0)
			found = found + 1
		end
	end
	return found
end

-- Every floor of every alt, present or not, so the report can say which art
-- set this client actually ships.
local function ScanFloors(lines)
	local present = 0
	for _, inst in ipairs(ns.InstanceData or {}) do
		for altIndex, alt in ipairs(inst.alts) do
			for _, f in ipairs(alt.floors) do
				local n = f[1]
				local base = n == 0 and alt.path or (alt.path .. n .. "_")
				local id = FileID(base .. "1")
				lines[#lines + 1] = ("F|%s|%d|%d|%d"):format(inst.key, altIndex, n, id)
				if id ~= 0 then present = present + 1 end
			end
		end
	end
	return present
end

function Census:Run()
	if self.running then
		ns:Print("Census already running.")
		return
	end
	self.running = true

	local version, build = GetBuildInfo()
	local lines = { ("B|%s|%s|%s|%d"):format(version, build, ns.FLAVOR, time()) }
	local nextID, maps = 1, 0

	ns:Print("Census running...")

	local function step()
		local last = math.min(nextID + CHUNK - 1, MAX_MAP_ID)
		maps = maps + ScanMaps(lines, nextID, last)
		nextID = last + 1
		if nextID <= MAX_MAP_ID then
			C_Timer.After(0, step)
			return
		end

		local floors = ScanFloors(lines)
		ns.db.global.census = ns.db.global.census or {}
		ns.db.global.census[version] = lines
		self.running = false

		ns:Print("Census of %s (%s): %d maps with art, %d instance floors present.",
			version, ns.FLAVOR, maps, floors)
		ns:Print("/reload to save it, then run: python3 tools/mapdata.py --census")
	end

	step()
end
