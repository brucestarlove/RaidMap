local ADDON, ns = ...

local Catalog = {}
ns.Catalog = Catalog

--[[
Art references are polymorphic. Every map -- Blizzard's or ours -- resolves to
the same descriptor, so the renderer has exactly one implementation:

	{ kind = "tiles",  base = "Interface\\WorldMap\\karazhan\\karazhan3_" }
	{ kind = "uimap",  id = 1948 }
	{ kind = "blank" }

Three sources feed the catalog:

  * Zone maps come live from the client's map DB (C_Map), so new zones in a
    beta build appear with no code change.
  * Instance interiors are NOT bound to any uiMapID in the classic clients, but
    their art ships on disk as Interface\WorldMap\<folder>\<stem><floor>_<tile>.
    Data/Instances.lua lists them; it is generated weekly by tools/mapdata.py.
  * Blank canvas, plus the keys boards were saved with before instance data.
]]

-- Classic world map art convention: 12 tiles in a 4x3 grid of 256px squares,
-- with the meaningful image occupying 1002x668 of the padded 1024x768 area.
local CLASSIC = {
	cols = 4, rows = 3,
	tileW = 256, tileH = 256,
	contentW = 1002, contentH = 668,
}

local BLANK = { key = "blank", name = "Blank Canvas", art = { kind = "blank" } }

-- Keys saved by earlier versions. Packs outlive code, so these must resolve
-- forever; they point at the same art the old hardcoded list used.
local LEGACY = {
	blacktemple = "inst:blacktemple:0",
	sunwell     = "inst:sunwellplateau:0",
	zulaman     = "inst:zulaman:0",
	zulgurub    = "inst:zulgurub:0",
	ruinsofaq   = "inst:ruinsofahnqiraj:0",
}

-- Resolvable for old packs, never offered: this is the Cataclysm zone, not the
-- Hyjal Summit raid (which is inst:hyjalsummit:0).
local HIDDEN = {
	hyjal = { key = "hyjal", name = "Mount Hyjal (Cataclysm zone art)",
		art = { kind = "tiles", base = "Interface\\WorldMap\\Hyjal\\Hyjal" } },
	blank = BLANK,
}

Catalog.blank = BLANK

function Catalog:DefaultKey()
	return ns.FLAVOR == "tbc" and "blacktemple" or "blank"
end

---------------------------------------------------------------- instances

-- GetFileIDFromPath answers "does this file ship in this client". Cached,
-- because the menu asks about the same few hundred paths every time it opens.
local hasArt = {}
local function HasArt(base)
	if hasArt[base] == nil then
		if not GetFileIDFromPath then
			hasArt[base] = true
		else
			local id = GetFileIDFromPath(base .. "1")
			hasArt[base] = id ~= nil and id ~= 0
		end
	end
	return hasArt[base]
end

local function TileArt(base, dims)
	if not dims then return { kind = "tiles", base = base } end
	return {
		kind = "tiles", base = base,
		cols = dims[1], rows = dims[2],
		tileW = dims[3], tileH = dims[4],
		contentW = dims[5], contentH = dims[6],
	}
end

local function FloorLabel(inst, floor, count)
	if floor.name and floor.name ~= "" then return floor.name end
	if count == 1 then return inst.name end
	if floor.n == 0 then return "Overview" end
	return "Floor " .. floor.n
end

local instances, floorsByKey

-- Every instance whose art exists in this client, whatever the flavor: a
-- pack shared from the other client must still open. The menu filters.
function Catalog:GetInstances()
	if instances then return instances end
	instances, floorsByKey = {}, {}

	for _, inst in ipairs(ns.InstanceData or {}) do
		-- First art set that actually ships here wins; later alts are
		-- fallbacks for clients that lack the preferred one.
		for _, alt in ipairs(inst.alts) do
			local found = {}
			for _, f in ipairs(alt.floors) do
				local n = f[1]
				local base = n == 0 and alt.path or (alt.path .. n .. "_")
				if HasArt(base) then
					found[#found + 1] = { n = n, name = f[2], art = TileArt(base, f.dims) }
				end
			end

			if #found > 0 then
				local entry = {
					key = inst.key, name = inst.name, kind = inst.kind, era = inst.era,
					flavors = inst.flavors, floors = found,
				}
				for _, floor in ipairs(found) do
					floor.key = ("inst:%s:%d"):format(inst.key, floor.n)
					floor.label = FloorLabel(inst, floor, #found)
					floor.name = #found == 1 and inst.name or (inst.name .. ": " .. floor.label)
					floorsByKey[floor.key] = floor
				end
				instances[#instances + 1] = entry
				break
			end
		end
	end

	return instances
end

-- Current era first: an Anniversary raider wants Karazhan above Molten Core.
local ERA_ORDER = {
	tbc     = { tbc = 1, vanilla = 2 },
	forever = { forever = 1, vanilla = 2 },
}

-- Instances of one kind ("raid", "dungeon", "bg") offered on this client.
function Catalog:GetInstancesOfKind(kind)
	local order = ERA_ORDER[ns.FLAVOR] or {}
	local list = {}
	for i, inst in ipairs(self:GetInstances()) do
		local offered = inst.flavors[ns.FLAVOR] or ns.FLAVOR == "retail"
		if inst.kind == kind and offered then
			list[#list + 1] = { inst = inst, rank = order[inst.era] or 9, index = i }
		end
	end
	table.sort(list, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.index < b.index
	end)
	for i, item in ipairs(list) do list[i] = item.inst end
	return list
end

---------------------------------------------------------------- zone maps

-- Highest uiMapID scanned. The Forever beta is at 2665 and every new zone
-- takes a fresh ID, so leave plenty of headroom.
local MAX_MAP_ID = 5000

local MAP_TYPE_WORLD, MAP_TYPE_CONTINENT, MAP_TYPE_ORPHAN = 1, 2, 6

local function ContinentOf(info)
	local hops = 0
	while info and hops < 10 do
		if info.mapType == MAP_TYPE_CONTINENT then return info.name end
		if not info.parentMapID or info.parentMapID == 0 then return nil end
		info = C_Map.GetMapInfo(info.parentMapID)
		hops = hops + 1
	end
end

local zoneCache

--[[
Every uiMap with art: world, continents, zones, cities, battlegrounds, and any
dungeon/micro maps a client binds. Each entry carries a menu `group`.

Some clients carry a second, single-texture copy of a map under the same name
(Forever: Eastern Kingdoms 1415/1463, Zephras Isle 2521/2665). Only the one
with the most texture survives.
]]
function Catalog:GetZoneMaps()
	if zoneCache then return zoneCache end

	local byName = {}
	for id = 1, MAX_MAP_ID do
		local info = C_Map.GetMapInfo(id)
		if info and info.mapType and info.mapType >= MAP_TYPE_WORLD then
			local layers = C_Map.GetMapArtLayers(id)
			local layer = layers and layers[1]
			if layer then
				local textures = C_Map.GetMapArtLayerTextures(id, 1)
				local score = layer.layerWidth * layer.layerHeight * 1000 + (textures and #textures or 0)
				local prev = byName[info.name]
				if not prev or score > prev.score then
					local group
					if info.mapType <= MAP_TYPE_CONTINENT then
						group = "World"
					elseif info.mapType == MAP_TYPE_ORPHAN then
						group = "Battlegrounds"
					else
						group = ContinentOf(info) or "Other"
					end
					byName[info.name] = {
						key = "uimap:" .. id,
						name = info.name,
						mapType = info.mapType,
						group = group,
						score = score,
						art = { kind = "uimap", id = id },
					}
				end
			end
		end
	end

	zoneCache = {}
	for _, entry in pairs(byName) do
		zoneCache[#zoneCache + 1] = entry
	end
	table.sort(zoneCache, function(a, b) return a.name < b.name end)
	return zoneCache
end

-- Group names in menu order, and {groupName = {entries}}.
function Catalog:GetZoneGroups()
	local groups, order = {}, {}
	for _, entry in ipairs(self:GetZoneMaps()) do
		if not groups[entry.group] then
			groups[entry.group] = {}
			order[#order + 1] = entry.group
		end
		table.insert(groups[entry.group], entry)
	end

	local rank = { World = 1, Battlegrounds = 8, Other = 9 }
	table.sort(order, function(a, b)
		local ra, rb = rank[a] or 5, rank[b] or 5
		if ra ~= rb then return ra < rb end
		return a < b
	end)
	return order, groups
end

---------------------------------------------------------------- lookup

function Catalog:Find(key)
	key = tostring(key)
	key = LEGACY[key] or key

	if HIDDEN[key] then return HIDDEN[key] end

	if key:match("^inst:") then
		self:GetInstances()
		return floorsByKey[key]
	end

	if key:match("^uimap:%d+$") then
		for _, entry in ipairs(self:GetZoneMaps()) do
			if entry.key == key then return entry end
		end
		-- Deduplication may have dropped this exact ID in favour of a
		-- same-named sibling; a pack that saved it should still open.
		local id = tonumber(key:match("%d+"))
		local info = C_Map.GetMapInfo(id)
		local layers = info and C_Map.GetMapArtLayers(id)
		if layers and layers[1] then
			return { key = key, name = info.name, art = { kind = "uimap", id = id } }
		end
	end

	return nil
end

--[[
Resolve an art ref into a flat descriptor the renderer consumes:

	{ textures = { <path or fileID>, ... },  -- row-major, nil for blank
	  cols, rows, tileW, tileH, contentW, contentH }
]]
function Catalog:Resolve(art)
	if not art then return nil end

	if art.kind == "blank" then
		return {
			blank = true,
			cols = CLASSIC.cols, rows = CLASSIC.rows,
			tileW = CLASSIC.tileW, tileH = CLASSIC.tileH,
			contentW = CLASSIC.contentW, contentH = CLASSIC.contentH,
		}
	end

	if art.kind == "tiles" then
		local cols = art.cols or CLASSIC.cols
		local rows = art.rows or CLASSIC.rows
		local textures = {}
		for i = 1, cols * rows do
			textures[i] = art.base .. i
		end
		return {
			textures = textures,
			cols = cols, rows = rows,
			tileW = art.tileW or CLASSIC.tileW,
			tileH = art.tileH or CLASSIC.tileH,
			contentW = art.contentW or CLASSIC.contentW,
			contentH = art.contentH or CLASSIC.contentH,
		}
	end

	if art.kind == "uimap" then
		local layers = C_Map.GetMapArtLayers(art.id)
		if not (layers and layers[1]) then return nil end

		local layer = layers[1]
		local textures = C_Map.GetMapArtLayerTextures(art.id, 1)
		if not textures then return nil end

		return {
			textures = textures,
			cols = math.ceil(layer.layerWidth / layer.tileWidth),
			rows = math.ceil(layer.layerHeight / layer.tileHeight),
			tileW = layer.tileWidth,
			tileH = layer.tileHeight,
			contentW = layer.layerWidth,
			contentH = layer.layerHeight,
		}
	end

	return nil
end
