#!/usr/bin/env python3
"""Run the addon's real catalog code against a build's real map data.

    ~/.venvs/lua/bin/python tools/test_catalog.py

Executes Data/Instances.lua, Core/Catalog.lua and Core/Census.lua under Lua 5.1
(via lupa) with C_Map and GetFileIDFromPath answered from wago.tools data for
that build -- so the zone list, instance floors, legacy keys and census output
are checked the way the client would compute them, without launching WoW.
When an in-game /rm census of the same build is on disk, the simulated client
is checked against it floor by floor. Needs `pip install lupa` in that venv.
"""

import collections
import os
import sys

from lupa import lua51

import mapdata
import wago

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures = []


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def build_world(build):
    """C_Map answers for one build: info, art layer, textures per uiMapID."""
    style = {r["ID"]: r["UiMapArtStyleID"] for r in wago.db2("UiMapArt", build)}
    layer = {r["UiMapArtStyleID"]: r for r in wago.db2("UiMapArtStyleLayer", build) if r["LayerIndex"] == "0"}
    tiles = collections.defaultdict(list)
    for r in wago.db2("UiMapArtTile", build):
        if r["LayerIndex"] == "0":
            tiles[r["UiMapArtID"]].append((int(r["RowIndex"]), int(r["ColIndex"]), int(r["FileDataID"])))
    art_of = {}
    for r in wago.db2("UiMapXMapArt", build):
        if r["PhaseID"] == "0" or r["UiMapID"] not in art_of:
            art_of[r["UiMapID"]] = r["UiMapArtID"]
    world = {}
    for r in wago.db2("UiMap", build):
        entry = {"name": r["Name_lang"], "mapType": int(r["Type"]), "parentMapID": int(r["ParentUiMapID"])}
        a = art_of.get(r["ID"])
        L = layer.get(style.get(a)) if a else None
        if L and tiles.get(a):
            entry["layer"] = {k: int(L[v]) for k, v in (("layerWidth", "LayerWidth"), ("layerHeight", "LayerHeight"),
                                                        ("tileWidth", "TileWidth"), ("tileHeight", "TileHeight"))}
            entry["textures"] = [f for _, _, f in sorted(tiles[a])]
        world[int(r["ID"])] = entry
    return world


def runtime(build, flavor, version):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    world = build_world(build)
    art = mapdata.loadable_art(build, wago.listfile("interface/worldmap/", build))
    files = {p.lower(): fid for fid, p in art.items()}

    def table(d):
        return lua.table_from(d)

    def get_map_info(id_):
        e = world.get(int(id_))
        return table({"name": e["name"], "mapType": e["mapType"], "parentMapID": e["parentMapID"]}) if e else None

    def get_layers(id_):
        e = world.get(int(id_))
        return table({1: table(e["layer"])}) if e and "layer" in e else None

    def get_textures(id_, _layer):
        e = world.get(int(id_))
        return table({i + 1: f for i, f in enumerate(e["textures"])}) if e and "textures" in e else None

    def file_id(path):
        return files.get(path.replace("\\", "/").lower() + ".blp")

    g = lua.globals()
    g.C_Map = table({"GetMapInfo": get_map_info, "GetMapArtLayers": get_layers,
                     "GetMapArtLayerTextures": get_textures})
    g.GetFileIDFromPath = file_id
    major = ".".join(version.split(".")[:3])
    lua.execute(f"""
        function GetBuildInfo() return "{major}", "{version.split('.')[-1]}", "", 0 end
        C_Timer = {{ After = function(_, fn) fn() end }}
        time = os.time
        printed = {{}}
        ns = {{ FLAVOR = "{flavor}", db = {{ global = {{}} }} }}
        function ns:Print(fmt, ...) printed[#printed + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
    """)
    loader = lua.eval("""function(path, src)
        local f = assert(loadstring(src, "@" .. path))
        return f("RaidMap", ns)
    end""")
    for rel in ("Data/Instances.lua", "Core/Catalog.lua", "Core/Census.lua"):
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            loader(rel, f.read())
    return lua, world


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t else []


def test_forever():
    build = wago.latest_build("wow_classic_beta")
    print(f"\nWoW Forever {build}")
    lua, world = runtime(build, "forever", build)
    C = lua.globals().ns.Catalog

    zones = lua_list(C.GetZoneMaps(C))
    names = [z.name for z in zones]
    with_art = [i for i, e in world.items() if "layer" in e]
    check(len(with_art) == 60, f"60 uiMaps with art in public data (got {len(with_art)})")
    check(len(names) == len(set(names)), "zone list has no duplicate names")
    check(len(zones) == 57, f"duplicates collapsed: 60 maps -> 57 entries (got {len(zones)})")
    zephras = [z for z in zones if z.name == "Zephras Isle"]
    check(len(zephras) == 1 and zephras[0].key == "uimap:2521", "Zephras Isle keeps the 12-tile map 2521, not 2665")
    for n in ("Mount Hyjal", "Riverglades", "Shen'dralas", "Darkspear Islands", "Alterac Valley"):
        check(n in names, f"zone list includes {n}")

    order, groups = C.GetZoneGroups(C)
    order = lua_list(order)
    check(order[0] == "World", f"World group first (order: {order})")
    bgs = sorted(e.name for e in lua_list(groups["Battlegrounds"]))
    check(bgs == ["Alterac Valley", "Arathi Basin", "Darkspear Islands", "Warsong Gulch"], f"battlegrounds group {bgs}")
    check("Mount Hyjal" in [e.name for e in lua_list(groups["Kalimdor"])], "Mount Hyjal grouped under Kalimdor")
    check("Riverglades" in [e.name for e in lua_list(groups["Eastern Kingdoms"])], "Riverglades under Eastern Kingdoms")

    raids = lua_list(C.GetInstancesOfKind(C, "raid"))
    raid_keys = [r.key for r in raids]
    check("moltencore" in raid_keys and "naxxramas" in raid_keys, "vanilla raids offered")
    check("karazhan" not in raid_keys, "TBC raids not offered on Forever")
    dungeons = [d.key for d in lua_list(C.GetInstancesOfKind(C, "dungeon"))]
    check(dungeons and dungeons[0] in ("dalaran", "ruinsoflordaeron"), f"Forever's own dungeons listed first ({dungeons[:3]})")

    sm = C.Find(C, "inst:scarletmonastery:1")
    check(sm is not None and sm.art.base.lower().endswith("scarletmonastery\\scarletmonastery1_"),
          "Scarlet Monastery opens the four classic wings")
    scholo = C.Find(C, "inst:scholomance:1")
    check(scholo is not None and "scholomanceold" in scholo.art.base, "Scholomance uses the classic 'old' art on Forever")
    bgs = [b.key for b in lua_list(C.GetInstancesOfKind(C, "bg"))]
    check("battleforgilneas" in bgs, f"Battle for Gilneas is loadable and offered ({bgs})")
    kara = C.Find(C, "inst:karazhan:3")
    check(kara is not None and kara.name == "Karazhan: The Banquet Hall", "Karazhan still opens from a shared pack")

    d = C.Resolve(C, C.Find(C, "uimap:1411").art)
    check(d is not None and d.cols == 4 and d.rows == 3 and len(lua_list(d.textures)) == 12, "Durotar resolves to 4x3 tiles")
    check(C.Find(C, "blacktemple") is not None, "legacy key 'blacktemple' resolves")
    check(C.DefaultKey(C) == "blank", "new slides default to the blank canvas on Forever")

    census = lua.globals().ns.Census
    census.Run(census)
    lines = lua_list(lua.globals().ns.db["global"].census[".".join(build.split(".")[:3])])
    check(lines[0].startswith("B|1.60.1|") and lines[0].split("|")[3] == "forever", f"census header {lines[0]}")
    check(sum(l.startswith("M|") for l in lines) == 60, "census records all 60 maps with art")
    floors = [l for l in lines if l.startswith("F|")]
    listed = sum(len(lua_list(alt.floors)) for inst in lua_list(lua.globals().ns.InstanceData)
                 for alt in lua_list(inst.alts))
    check(len(floors) == listed, f"census records every listed floor ({len(floors)} of {listed})")
    return lines


def test_anniversary():
    build = wago.latest_build("wow_anniversary")
    print(f"\nTBC Anniversary {build}")
    lua, world = runtime(build, "tbc", build)
    C = lua.globals().ns.Catalog

    zones = lua_list(C.GetZoneMaps(C))
    # 73 with art = 1 Cosmic (excluded) + 3 same-name copies (Outland's 1-tile 987, and
    # parentless twins of Kalimdor/Eastern Kingdoms) + 69 distinct maps.
    check(len(zones) == 69, f"73 maps with art -> 69 entries (got {len(zones)})")
    order, groups = C.GetZoneGroups(C)
    check("Outland" in lua_list(order), f"Outland group present ({lua_list(order)})")

    raids = [r.key for r in lua_list(C.GetInstancesOfKind(C, "raid"))]
    check(raids[:2] == ["karazhan", "gruulslair"], f"TBC raids first ({raids[:4]})")
    kara = [r for r in lua_list(C.GetInstancesOfKind(C, "raid")) if r.key == "karazhan"][0]
    check(len(lua_list(kara.floors)) == 17, "Karazhan has 17 floors")
    bt = [r for r in lua_list(C.GetInstancesOfKind(C, "raid")) if r.key == "blacktemple"][0]
    labels = [f.label for f in lua_list(bt.floors)]
    check(labels[0] == "Black Temple" and "Temple Summit" in labels, f"Black Temple courtyard + interiors ({labels[:3]}...)")
    scholo = C.Find(C, "inst:scholomance:1")
    check(scholo is not None and "scholomanceold" not in scholo.art.base, "Scholomance falls back to the art Anniversary ships")
    hs = C.Find(C, "inst:hyjalsummit:0")
    check(hs is not None and "cotmounthyjal" in hs.art.base, "Hyjal Summit uses the Caverns of Time raid art")

    for legacy, expect in (("blacktemple", "blacktemple\\blacktemple"), ("sunwell", "sunwellplateau"),
                           ("zulaman", "zulaman"), ("zulgurub", "zulgurub"), ("ruinsofaq", "ruinsofahnqiraj")):
        e = C.Find(C, legacy)
        check(e is not None and expect in e.art.base.lower(), f"legacy key '{legacy}' resolves")
    old = C.Find(C, "hyjal")
    check(old is not None, "legacy key 'hyjal' (Cataclysm zone page) still resolves")
    check(C.DefaultKey(C) == "blacktemple", "new slides still default to Black Temple on Anniversary")
    d = C.Resolve(C, C.Find(C, "blacktemple").art)
    check(lua_list(d.textures)[0].lower().endswith("blacktemple\\blacktemple1"), "Black Temple page tile path unchanged")


def test_census_roundtrip(lines):
    print("\nCensus -> mapdata.py --census parser")
    import tempfile
    body = "\nRaidMapDB = {\n[\"global\"] = {\n[\"census\"] = {\n[\"1.60.1\"] = {\n"
    body += "".join('"%s", -- [%d]\n' % (l.replace("\\", "\\\\").replace('"', '\\"'), i + 1) for i, l in enumerate(lines))
    body += "},\n},\n},\n}\n"
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(body)
    blocks = mapdata.parse_census(f.name)
    os.unlink(f.name)
    check(len(blocks) == 1 and len(blocks[0]["maps"]) == 60, "parser reads the census the addon wrote")
    present = sum(1 for *_, fid in blocks[0]["floors"] if fid)
    check(present > 100, f"{present} instance floors present per census")
    return blocks[0]


def test_real_census(sim):
    """GetFileIDFromPath is the one answer here that is modelled rather than
    read from a table, so hold it to what the real client said."""
    print("\nSimulated client vs the in-game census")
    path = mapdata.default_census_path()
    blocks = mapdata.parse_census(path) if path else []
    if not blocks:
        print("  skip  no census in SavedVariables (/rm census, then /reload)")
        return
    real = max(blocks, key=lambda b: b["time"])
    if (real["version"], real["build"]) != (sim["version"], sim["build"]):
        print(f"  skip  census is from build {real['build']}, the test ran {sim['build']}")
        return
    if {f[:3] for f in real["floors"]} != {f[:3] for f in sim["floors"]}:
        print("  skip  census was taken with other instance data (/reload, /rm census, /reload)")
        return
    wrong = sorted(set(real["floors"]) ^ set(sim["floors"]))
    check(not wrong, f"all {len(real['floors'])} floors resolve to the file the client reported {wrong[:4] or ''}")


if __name__ == "__main__":
    lines = test_forever()
    test_anniversary()
    test_real_census(test_census_roundtrip(lines))
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)
