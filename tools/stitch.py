#!/usr/bin/env python3
"""Stitch a dungeon's interior minimap into images the addon ships.

    ~/.venvs/lua/bin/python tools/stitch.py          (needs `pip install pillow`)

Forever's City of Dalaran has no drawn map, and its sewers are not on the
terrain minimap either. The client draws interiors from small textures, a few
per room of the building model (WMO). This lays a model's rooms out where they
stand and writes Art/<name>.tga with north up; tools/instances.json lists the
result under "images".

How the pieces fit, checked by laying the street-level rooms over the terrain
minimap of map 2959:
  * A room's textures are 2 pixels to the yard and at most 256 across. They
    tile from the corner of its bounding box with the lowest x and y, x to the
    right and y upward; a short one is padded on its right and top.
  * A build also ships textures a room's bounding box has no use for, left
    over from older revisions of the model. Those are skipped.
  * The model's own frame becomes north-up when turned by its placement's yaw
    minus 90 degrees.
"""

import io
import math
import os
import re
import struct

from PIL import Image

import wago

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRODUCT = "wow_classic_beta"
PPY = 2       # texture pixels per yard
TILE = 256

# name: the model's file, what the paths of its interior minimap textures start
# with, its placement's yaw, and the rooms to draw. Rooms on different levels
# overlap, so each level is its own image. A room's number is its index in the
# model, and will move if Blizzard rebuilds it.
DALARAN = (7116370, "world/minimaps/wmo/autogen-names/dalaran/18950_", 75)
IMAGES = {
    "DalaranUnderbelly": (*DALARAN, [54, 55, 56, 61, 62, 63, 64, 65, 66, 77]),
    "DalaranUnderbellyLower": (*DALARAN, [60, 75]),
}


def bounds(wmo, build):
    """(min x, y, z, max x, y, z) of every room of a model."""
    data, pos, chunks = wago.file(wmo, build), 0, {}
    while pos + 8 <= len(data):
        size = struct.unpack_from("<I", data, pos + 4)[0]
        chunks[data[pos:pos + 4][::-1]] = data[pos + 8:pos + 8 + size]
        pos += 8 + size
    count = struct.unpack_from("<I", chunks[b"MOHD"], 4)[0]
    return [struct.unpack_from("<6f", chunks[b"MOGI"], i * 32 + 4) for i in range(count)]


def stitch(wmo, prefix, yaw, rooms, build):
    boxes = bounds(wmo, build)
    tiles = {}   # (room, column, row): file
    for fdid, path in wago.listfile(prefix, build).items():
        m = re.fullmatch(re.escape(prefix) + r"(\d+)_(\d+)_(\d+)\.blp", path)
        if m:
            tiles[tuple(int(v) for v in m.groups())] = fdid

    x0 = min(boxes[r][0] for r in rooms)
    y1 = max(boxes[r][4] for r in rooms)
    width = max(boxes[r][3] for r in rooms) - x0
    height = y1 - min(boxes[r][1] for r in rooms)
    # A tile's width of spare room all round, for the padding of edge tiles.
    sheet = Image.new("RGBA", (math.ceil(width * PPY) + 2 * TILE, math.ceil(height * PPY) + 2 * TILE))
    # Deepest first, so where two rooms overlap the upper one shows.
    for r in sorted(rooms, key=lambda r: boxes[r][2]):
        bx0, by0, _, bx1, by1, _ = boxes[r]
        for a in range(math.ceil((bx1 - bx0) * PPY / TILE)):
            for b in range(math.ceil((by1 - by0) * PPY / TILE)):
                if (r, a, b) in tiles:
                    tile = Image.open(io.BytesIO(wago.file(tiles[(r, a, b)], build))).convert("RGBA")
                    left = TILE + round((bx0 - x0) * PPY) + a * TILE
                    bottom = TILE + round((y1 - by0) * PPY) - b * TILE
                    sheet.alpha_composite(tile, (left, bottom - tile.height))
    sheet = sheet.rotate(yaw - 90, expand=True, resample=Image.BICUBIC)
    return sheet.crop(sheet.getbbox())


def save(image, name):
    # The client wants power-of-two sides; the map sits in the top left corner
    # and instances.json says how much of the square it fills.
    side = 1 << (max(image.size) - 1).bit_length()
    canvas = Image.new("RGB", (side, side))
    canvas.paste(image, (0, 0), image)
    os.makedirs(os.path.join(ROOT, "Art"), exist_ok=True)
    canvas.save(os.path.join(ROOT, "Art", name + ".tga"))
    print(f"Art/{name}.tga: size {side}, content [{image.width}, {image.height}]")


def main():
    build = wago.latest_build(PRODUCT)
    print(f"{PRODUCT} {build}")
    for name, (wmo, prefix, yaw, rooms) in IMAGES.items():
        save(stitch(wmo, prefix, yaw, rooms, build), name)


if __name__ == "__main__":
    main()
