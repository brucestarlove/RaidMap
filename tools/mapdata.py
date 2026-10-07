#!/usr/bin/env python3
"""Weekly map-data refresh for RaidMap.

    python3 tools/mapdata.py                  # newest WoW Forever beta build
    python3 tools/mapdata.py --products       # which wago products carry 1.60.x
    python3 tools/mapdata.py --census         # also diff the in-game /rm census

What it does:
  1. Pulls the build's UiMap/Map tables from wago.tools and diffs them against
     the previous snapshot -> new zones, new instances (tools/reports/).
     Zones need no action: the addon reads them live via C_Map.
  2. Resolves every instance in tools/instances.json to the art files the
     build's client can load by path (and Anniversary's), names each floor
     from retail's map tables, and writes Data/Instances.lua.
  3. Lists art folders that newly appear in the build -- candidates to add to
     instances.json when Forever's new dungeons get their maps.

Only the standard library is used. Downloads are cached in tools/cache/.
"""

import argparse
import collections
import glob
import json
import math
import os
import re
import sys
import time

import wago

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
CURATED = os.path.join(TOOLS, "instances.json")
OUTPUT = os.path.join(ROOT, "Data", "Instances.lua")
SNAPSHOTS = os.path.join(TOOLS, "snapshots")
REPORTS = os.path.join(TOOLS, "reports")
WOW_DIR = "/mnt/c/Program Files (x86)/World of Warcraft"

MAP_TYPES = {0: "Cosmic", 1: "World", 2: "Continent", 3: "Zone", 4: "Dungeon", 5: "Micro", 6: "Orphan"}
INSTANCE_TYPES = {"1": "party", "2": "raid", "3": "pvp", "4": "arena", "5": "scenario"}

# Classic map art: 4x3 tiles of 256px holding a 1002x668 image. The addon
# assumes this unless an instance says otherwise.
DEFAULT_DIMS = (4, 3, 256, 256, 1002, 668)

# Art folders whose newest file predates this are old content. Used only to
# bound the candidate search on the very first run, when there is no snapshot.
FIRST_RUN_MIN_FDID = 7_000_000


def version_key(v):
    return tuple(int(p) for p in v.split("."))


# ---------------------------------------------------------------- map tables

def load_uimaps(build):
    """{uiMapID: {name, type, parent, tiles}} for maps that have tiled art."""
    tiles = collections.Counter(r["UiMapArtID"] for r in wago.db2("UiMapArtTile", build)
                                if r["LayerIndex"] == "0")
    arts = collections.defaultdict(list)
    for r in wago.db2("UiMapXMapArt", build):
        arts[r["UiMapID"]].append(r["UiMapArtID"])
    out = {}
    for r in wago.db2("UiMap", build):
        n = max((tiles[a] for a in arts.get(r["ID"], [])), default=0)
        out[r["ID"]] = {"name": r["Name_lang"], "type": int(r["Type"]),
                        "parent": r["ParentUiMapID"], "tiles": n}
    return out


def load_instances(build):
    """{mapID: {name, type}} for dungeon/raid/pvp maps in the Map table."""
    return {r["ID"]: {"name": r["MapName_lang"], "type": INSTANCE_TYPES[r["InstanceType"]]}
            for r in wago.db2("Map", build) if r["InstanceType"] in INSTANCE_TYPES}


class Retail:
    """Names and grid sizes for art files, taken from retail, where nearly
    every instance map is bound to a uiMap and its floors are named."""

    def __init__(self, build):
        self.build = build
        uimap = {r["ID"]: r for r in wago.db2("UiMap", build)}
        floor_name = {r["UiMapID"]: r["Name_lang"] for r in wago.db2("UiMapGroupMember", build)}
        maps_by_art = collections.defaultdict(list)
        for r in wago.db2("UiMapXMapArt", build):
            maps_by_art[r["UiMapArtID"]].append(r["UiMapID"])
        style_by_art = {r["ID"]: r["UiMapArtStyleID"] for r in wago.db2("UiMapArt", build)}
        layer = {r["UiMapArtStyleID"]: r for r in wago.db2("UiMapArtStyleLayer", build)
                 if r["LayerIndex"] == "0"}

        self.art_by_fdid = {}
        for r in wago.db2("UiMapArtTile", build):
            if r["LayerIndex"] == "0" and r["RowIndex"] == "0" and r["ColIndex"] == "0":
                self.art_by_fdid[int(r["FileDataID"])] = r["UiMapArtID"]

        self.names, self.dims = {}, {}
        for art, maps in maps_by_art.items():
            m = maps[0]
            self.names[art] = (floor_name.get(m) or "", uimap[m]["Name_lang"] if m in uimap else "")
            L = layer.get(style_by_art.get(art))
            if L:
                w, h = int(L["LayerWidth"]), int(L["LayerHeight"])
                tw, th = int(L["TileWidth"]), int(L["TileHeight"])
                self.dims[art] = (math.ceil(w / tw), math.ceil(h / th), tw, th, w, h)

    def describe(self, first_tile_fdid):
        """(floorName, uiMapName, dims) or (None, None, None) if unknown."""
        art = self.art_by_fdid.get(first_tile_fdid)
        if not art:
            return None, None, None
        floor, mapname = self.names.get(art, ("", ""))
        return floor, mapname, self.dims.get(art)


# ------------------------------------------------------------------ art files

def loadable_art(build, shipped):
    """The part of a build's shipped map art that its client can load by path.

    GetFileIDFromPath, and so SetTexture with a path, only knows the files in
    the client's own ManifestInterfaceData table. The listfile holds more:
    5,400 worldmap files ship in Forever 70205 with no manifest row (Korean-text
    copies of dungeon maps, leftover revisions). Checked against an in-game
    /rm census: manifest membership matched the client on 139 of 139 floors,
    listfile membership alone on 132."""
    named = {int(r["ID"]) for r in wago.db2("ManifestInterfaceData", build)}
    return {fdid: path for fdid, path in shipped.items() if fdid in named}


def index_art(listfile):
    """{folder: {filename_without_ext: fdid}} for interface/worldmap/*/*.blp"""
    out = collections.defaultdict(dict)
    for fdid, path in listfile.items():
        m = re.match(r"interface/worldmap/([^/]+)/([^/]+)\.blp$", path)
        if m:
            out[m.group(1)][m.group(2)] = fdid
    return out


def floors_of(files, stem):
    """{floor: {tile: fdid}} for one folder+stem. Floor 0 is the single page
    named <stem><tile>; floors n >= 1 are <stem><n>_<tile>."""
    page = re.compile(re.escape(stem) + r"(\d+)$")
    floor = re.compile(re.escape(stem) + r"(\d+)_(\d+)$")
    out = collections.defaultdict(dict)
    for name, fdid in files.items():
        m = floor.match(name)
        if m:
            out[int(m.group(1))][int(m.group(2))] = fdid
            continue
        m = page.match(name)
        if m:
            out[0][int(m.group(1))] = fdid
    return out


def resolve_curated(curated, art, retail, present, shipped_art):
    """Attach the floors that at least one checked client can load to every alt.
    present: {product: set of fileDataIDs its client can load by path}.
    shipped_art: index of everything that ships, loadable or not, to tell a
    wrong name from art no client can reach.
    Returns (problems, notes) for the report."""
    problems, notes = [], []
    for inst in curated:
        for alt in inst["alts"]:
            alt.setdefault("stem", alt["folder"])
            alt["_floors"] = floors_of(art.get(alt["folder"], {}), alt["stem"])

    for inst in curated:
        # product -> {(alt, floor)}. alt counts only alts that reach the Lua
        # file, so it is the index the addon and its census use.
        inst["_present"] = collections.defaultdict(set)
        ai = 0
        for alt in inst["alts"]:
            if not alt["_floors"]:
                if floors_of(shipped_art.get(alt["folder"], {}), alt["stem"]):
                    problems.append(f"`{inst['key']}`: `{alt['folder']}/{alt['stem']}*` ships, but no client can "
                                    "load it by path (no ManifestInterfaceData row) -- drop the alt")
                else:
                    problems.append(f"`{inst['key']}`: no files named `{alt['stem']}*` in folder `{alt['folder']}`")
            out = []
            for n in sorted(alt["_floors"]):
                tiles = alt["_floors"][n]
                first = tiles.get(1)
                if not first:
                    continue
                where = [p for p in present if first in present[p]]
                if not where:
                    continue
                floor_name, map_name, dims = retail.describe(first)
                out.append({"n": n, "where": where, "known": map_name is not None, "tiles": len(tiles),
                            "name": floor_name or (map_name if map_name and map_name != inst["name"] else ""),
                            "dims": dims})

            # Retail binds every floor it still uses to a map. When some floors
            # of this art set are bound, the unbound ones are leftovers (old
            # revisions, scenario variants) and would only clutter the menu.
            # Wholly unbound sets -- the classic-only "old" folders -- stay.
            named = inst.get("floorNames", {})
            if any(f["known"] for f in out):
                dropped = [f["n"] for f in out if not f["known"] and str(f["n"]) not in named]
                if dropped:
                    notes.append(f"`{inst['key']}`: skipped floors {dropped} of `{alt['folder']}` "
                                    "(not used by retail; name them in floorNames to keep)")
                out = [f for f in out if f["known"] or str(f["n"]) in named]

            for f in out:
                for p in f["where"]:
                    inst["_present"][p].add((ai, f["n"]))
                if f["tiles"] != 12 and not f["dims"]:
                    problems.append(f"`{inst['key']}` floor {f['n']}: {f['tiles']} tiles but no grid size known")
            alt["_out"] = out
            ai += bool(out)
        if not any(alt["_out"] for alt in inst["alts"]):
            problems.append(f"`{inst['key']}`: art not present in any checked build")
    return problems, notes


# ------------------------------------------------------------------ Lua output

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_lua(curated, sources):
    lines = [
        "-- GENERATED by tools/mapdata.py from tools/instances.json -- do not edit by hand.",
        "-- " + "; ".join(f"{k}: {v}" for k, v in sources.items()),
        "--",
        "-- Each alt is a candidate art set; Catalog uses the first whose art exists in",
        "-- the running client. Floor 0 is a single page (<path><tile>), floors 1+ are",
        "-- <path><floor>_<tile>. dims = cols, rows, tileW, tileH, contentW, contentH",
        "-- when they differ from the classic 4, 3, 256, 256, 1002, 668.",
        "",
        "local ADDON, ns = ...",
        "",
        "ns.InstanceData = {",
    ]
    for inst in curated:
        alts = [a for a in inst["alts"] if a["_out"]]
        if not alts:
            continue
        flavors = ", ".join(f"{f} = true" for f in inst["flavors"])
        verified = ", ".join(f"{f} = true" for f in inst.get("verified", []))
        lines.append("\t{")
        lines.append(f"\t\tkey = {lua_str(inst['key'])}, name = {lua_str(inst['name'])}, "
                     f"kind = {lua_str(inst['kind'])}, era = {lua_str(inst['era'])},")
        lines.append(f"\t\tflavors = {{ {flavors} }},")
        if verified:
            lines.append(f"\t\tverified = {{ {verified} }},")
        lines.append("\t\talts = {")
        overrides = inst.get("floorNames", {})
        for alt in alts:
            path = "Interface\\WorldMap\\" + alt["folder"] + "\\" + alt["stem"]
            lines.append(f"\t\t\t{{ path = {lua_str(path)}, floors = {{")
            for f in alt["_out"]:
                name = overrides.get(str(f["n"]), f["name"])
                if f["n"] == 0 and not name and len(alt["_out"]) > 1:
                    name = "Overview"
                parts = [str(f["n"]), lua_str(name)]
                if f["dims"] and tuple(f["dims"]) != DEFAULT_DIMS:
                    parts.append("dims = { " + ", ".join(str(d) for d in f["dims"]) + " }")
                lines.append("\t\t\t\t{ " + ", ".join(parts) + " },")
            lines.append("\t\t\t} },")
        lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


# ------------------------------------------------------------ census (in-game)

def default_census_path():
    hits = glob.glob(os.path.join(WOW_DIR, "_classic_beta_", "WTF", "Account", "*",
                                  "SavedVariables", "RaidMap.lua"))
    return max(hits, key=os.path.getmtime) if hits else None


def parse_census(path):
    """Census blocks from the SavedVariables file: [{header, maps, floors}]"""
    text = open(path, encoding="utf-8", errors="replace").read()
    blocks = []
    for s in re.findall(r'"((?:[BMF])\|(?:[^"\\]|\\.)*)"', text):
        s = s.replace('\\"', '"').replace("\\\\", "\\")
        kind, _, rest = s.partition("|")
        if kind == "B":
            v, build, flavor, at = rest.split("|")
            blocks.append({"version": v, "build": build, "flavor": flavor, "time": int(at),
                           "maps": {}, "floors": []})
        elif blocks and kind == "M":
            id_, type_, parent, name, cols, rows, w, h, ntex = rest.split("|")
            blocks[-1]["maps"][id_] = {"name": name, "type": int(type_), "parent": parent,
                                       "cols": int(cols), "rows": int(rows), "ntex": int(ntex)}
        elif blocks and kind == "F":
            key, alt, floor, fileid = rest.split("|")
            blocks[-1]["floors"].append((key, int(alt) - 1, int(floor), int(fileid)))
    return blocks


# ---------------------------------------------------------------------- report

def latest_snapshot(product, before):
    paths = glob.glob(os.path.join(SNAPSHOTS, f"{product}-*.json"))
    older = [p for p in paths
             if version_key(os.path.basename(p)[len(product) + 1:-5]) < version_key(before)]
    if not older:
        return None
    path = max(older, key=lambda p: version_key(os.path.basename(p)[len(product) + 1:-5]))
    with open(path) as f:
        return json.load(f)


def diff_named(old, new):
    added = sorted(set(new) - set(old), key=int)
    removed = sorted(set(old) - set(new), key=int)
    renamed = sorted((k for k in set(old) & set(new) if old[k]["name"] != new[k]["name"]), key=int)
    return added, removed, renamed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--product", default="wow_classic_beta")
    ap.add_argument("--build", help="exact build (default: newest for --product)")
    ap.add_argument("--also", default="wow_anniversary",
                    help="comma list of other products whose builds count as 'art present'")
    ap.add_argument("--retail", help="retail build for floor names (default: newest 'wow')")
    ap.add_argument("--census", nargs="?", const="auto", help="diff an in-game /rm census (SavedVariables path)")
    ap.add_argument("--products", action="store_true", help="list products carrying 1.60.x builds and exit")
    args = ap.parse_args()

    if args.products:
        for product, entries in sorted(wago.builds().items()):
            vs = sorted({e["version"] for e in entries if e["version"].startswith("1.60.")}, key=version_key)
            if vs:
                print(f"{product:22} {len(vs):3} builds, newest {vs[-1]}")
        return

    build = args.build or wago.latest_build(args.product)
    retail_build = args.retail or wago.latest_build("wow")
    also = {p: wago.latest_build(p) for p in filter(None, args.also.split(","))}
    print(f"target {args.product} {build}; also {also}; names from retail {retail_build}")

    uimaps = load_uimaps(build)
    instances = load_instances(build)
    retail = Retail(retail_build)

    # Per-build listfiles say what ships; only what the client can also load
    # by path counts as present.
    builds = {args.product: build, **also}
    shipped = {p: wago.listfile("interface/worldmap/", b) for p, b in builds.items()}
    listing = {p: loadable_art(b, shipped[p]) for p, b in builds.items()}
    present = {p: set(files) for p, files in listing.items()}
    art = index_art({fdid: path for files in listing.values() for fdid, path in files.items()})
    shipped_art = index_art({fdid: path for files in shipped.values() for fdid, path in files.items()})
    target_art = index_art(listing[args.product])

    with open(CURATED) as f:
        curated = json.load(f)["instances"]
    problems, notes = resolve_curated(curated, art, retail, present, shipped_art)

    sources = {**builds, "names": f"wow {retail_build}"}
    write_lua(curated, sources)

    # Candidate art: folders this build ships that we have never seen before.
    prev = latest_snapshot(args.product, build)
    curated_folders = {a["folder"] for i in curated for a in i["alts"]}
    if prev:
        seen = set(prev["folders"])
        candidates = [f for f in target_art if f not in seen]
    else:
        candidates = [f for f in target_art if max(target_art[f].values()) >= FIRST_RUN_MIN_FDID]
    candidates = sorted(f for f in candidates if f not in curated_folders)

    snapshot = {
        "product": args.product, "build": build, "created": time.strftime("%Y-%m-%d"),
        "uimaps": uimaps, "instances": instances, "folders": sorted(target_art),
        "curated": {i["key"]: {p: sorted(map(list, s)) for p, s in i["_present"].items()} for i in curated},
    }
    os.makedirs(SNAPSHOTS, exist_ok=True)
    with open(os.path.join(SNAPSHOTS, f"{args.product}-{build}.json"), "w") as f:
        json.dump(snapshot, f, indent=1, sort_keys=True)

    # ---------------------------------------------------------------- report
    R = [f"# Map report: {args.product} {build}", "",
         f"Generated {snapshot['created']}. Compared against: "
         f"{prev['build'] if prev else 'nothing (first run)'}.", ""]

    with_art = {k: v for k, v in uimaps.items() if v["tiles"]}
    by_type = collections.Counter(MAP_TYPES.get(v["type"], v["type"]) for v in with_art.values())
    R += [f"## Zone maps ({len(with_art)} with art)", "",
          ", ".join(f"{n} {t}" for t, n in sorted(by_type.items())) + ".",
          "These appear in the addon automatically; nothing to do unless one is missing in game.", ""]
    if prev:
        added, removed, renamed = diff_named({k: v for k, v in prev["uimaps"].items() if v["tiles"]}, with_art)
        for title, ids, src in (("New", added, with_art), ("Removed", removed, prev["uimaps"])):
            if ids:
                R.append(f"**{title}:**")
                R += [f"- {i} {src[i]['name']} ({MAP_TYPES.get(src[i]['type'])}, parent {src[i]['parent']})" for i in ids]
                R.append("")
        if renamed:
            R.append("**Renamed:**")
            R += [f"- {i}: {prev['uimaps'][i]['name']} -> {with_art[i]['name']}" for i in renamed]
            R.append("")
        if not (added or removed or renamed):
            R += ["No changes.", ""]

    R += ["## Instances in the Map table", ""]
    if prev:
        added, removed, renamed = diff_named(prev["instances"], instances)
        if added:
            R += ["**New** (find their art, then add to `tools/instances.json`):"]
            R += [f"- {i} {instances[i]['name']} ({instances[i]['type']})" for i in added]
        if removed:
            R += ["**Removed:**"] + [f"- {i} {prev['instances'][i]['name']}" for i in removed]
        if renamed:
            R += ["**Renamed:**"] + [f"- {i}: {prev['instances'][i]['name']} -> {instances[i]['name']}" for i in renamed]
        if not (added or removed or renamed):
            R.append("No changes.")
    else:
        R += [f"- {i} {v['name']} ({v['type']})" for i, v in sorted(instances.items(), key=lambda kv: int(kv[0]))]
    R += ["", "Instances announced but absent above (Drown City, Barrow Deeps, Hyjal Summit, ...) are most",
          "likely encrypted until Blizzard ships their keys; `--census` shows what the client itself sees.", ""]

    R += [f"## Art folders new in this build ({len(candidates)})", "",
          "Shipped in this build, not yet in `tools/instances.json`. Most are retail content the Forever",
          "client carries along; look for names matching new instances above.", ""]
    for f in candidates:
        floors = collections.Counter()
        for n in target_art[f]:
            m = re.search(r"(\d+)_\d+$", n)
            floors[m.group(1) if m else "page"] += 1
        R.append(f"- `{f}`: {len(target_art[f])} files, floors {dict(sorted(floors.items()))}")
    R.append("")

    R += ["## Curated instances", "", "| key | " + " | ".join(listing) + " | floors | note |",
          "|---|" + "---|" * len(listing) + "---|---|"]
    for inst in curated:
        cells = []
        for p in listing:
            got = inst["_present"].get(p, set())
            alts = sorted({a for a, _ in got})
            cells.append(f"alt {alts[0] + 1}, {len([1 for a, _ in got if a == alts[0]])} fl" if alts else "**missing**")
        best = next((a["_out"] for a in inst["alts"] if a["_out"]), [])
        names = ", ".join(f"{f['n']}:{f['name'] or '?'}" for f in best)
        R.append(f"| {inst['key']} | " + " | ".join(cells) + f" | {names} | {inst.get('note', '')} |")
    R.append("")
    if problems:
        R += ["## Problems", ""] + [f"- {p}" for p in problems] + [""]
    if notes:
        R += ["## Notes", ""] + [f"- {n}" for n in notes] + [""]

    if args.census:
        path = default_census_path() if args.census == "auto" else args.census
        R += ["## In-game census", ""]
        blocks = parse_census(path) if path and os.path.exists(path) else []
        if not blocks:
            R += [f"No census found ({path}). In game: `/rm census`, then `/reload`.", ""]
        else:
            c = max(blocks, key=lambda b: b["time"])
            client = {k: v for k, v in c["maps"].items()}
            only_client = sorted(set(client) - set(with_art), key=int)
            only_wago = sorted(set(with_art) - set(client), key=int)
            seen = {(k, a, n) for k, a, n, fid in c["floors"] if fid}
            R += [f"Census of {c['version']} ({c['flavor']}), {time.strftime('%Y-%m-%d %H:%M', time.localtime(c['time']))}: "
                  f"{len(client)} maps with art, {len(seen)} of {len(c['floors'])} instance floors present.", ""]
            if only_client:
                R += ["**Client sees, public data does not** (encrypted content now unlocked):"]
                R += [f"- {i} {client[i]['name']} ({MAP_TYPES.get(client[i]['type'])})" for i in only_client]
            if only_wago:
                R += ["**Public data has, client does not:**"]
                R += [f"- {i} {with_art[i]['name']}" for i in only_wago]
            # Instance floors: does the client agree with what the tool predicted?
            # Only meaningful if the census probed the floors listed now; alt
            # numbers shift whenever instances.json gains or loses an alt.
            predicted = {(i["key"], a, n) for i in curated for a, n in i["_present"].get(args.product, set())}
            listed = {(i["key"], a, f["n"]) for i in curated
                      for a, alt in enumerate(x for x in i["alts"] if x["_out"]) for f in alt["_out"]}
            probed = {(k, a, n) for k, a, n, _ in c["floors"]}
            stale = probed != listed
            missing = sorted(predicted - seen)
            extra = sorted(seen - predicted)
            if stale:
                missing = extra = []
                R += [f"**Instance floors not compared:** the census probed {len(probed)} floors and "
                      f"`Data/Instances.lua` now lists {len(listed)} ({len(probed ^ listed)} differ), so it was taken "
                      "with other instance data. In game: `/reload`, `/rm census`, `/reload`, then re-run."]
            if missing:
                R += ["**Floors predicted present but missing in client** (alt and floor are 1-based / 0 = page):"]
                R += [f"- {k} alt {a + 1} floor {n}" for k, a, n in missing]
            if extra:
                R += ["**Floors present in client but not predicted:**"]
                R += [f"- {k} alt {a + 1} floor {n}" for k, a, n in extra]
            if not (only_client or only_wago or missing or extra or stale):
                R.append("Client and public data agree.")
            census_build = f"{c['version']}.{c['build']}"
            if census_build != build:
                R += ["", f"Note: census is from {census_build}, report is for {build}."]
            R.append("")

    os.makedirs(REPORTS, exist_ok=True)
    report_path = os.path.join(REPORTS, f"{args.product}-{build}.md")
    with open(report_path, "w", newline="\n") as f:
        f.write("\n".join(R))

    print(f"wrote {os.path.relpath(OUTPUT, ROOT)}, {os.path.relpath(report_path, ROOT)}")
    print(f"{len(with_art)} zone maps with art; {len(candidates)} new art folders; {len(problems)} problems")
    for p in problems:
        print("  problem:", p)


if __name__ == "__main__":
    sys.exit(main())
