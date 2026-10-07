#!/usr/bin/env python3
"""Load the whole addon against stub frames and drive the editor's controls.

    ~/.venvs/lua/bin/python tools/test_ui.py

Every file in the TOC runs, in TOC order, on Lua 5.1, once as each client.
Frames are tables that remember their size, scripts, text and state and answer
anything else with nothing. So this proves the wiring -- what a click, a drag
or a scroll does to the model and to the widgets' state -- and that none of it
trips over a nil. It cannot say what anything looks like, or how the client
orders mouse events; that still needs the game.
"""

import os
import sys

from lupa import lua51

import test_compat
import test_sync

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []

REAL_LIBS = ("Libs/LibStub/LibStub.lua", "Libs/LibSerialize/LibSerialize.lua", "Libs/LibDeflate/LibDeflate.lua")

FRAMES = r"""
frames = {}
local function noop() end
local M = {}
-- Widget methods are capitalised and the addon's own fields on a frame are
-- not, so an unset field still reads as nil the way it does in the game.
local frameMT = { __index = function(_, k)
    if M[k] then return M[k] end
    if type(k) == "string" and k:find("^%u") then return noop end
end }

local function new(kind, name, parent)
    local f = setmetatable({ kind = kind, parent = parent, scripts = {}, events = {}, _shown = true, _enabled = true },
        frameMT)
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
function CreateFrame(kind, name, parent) return new(kind, name, parent) end

function M:SetScript(what, fn) self.scripts[what] = fn end
function M:GetScript(what) return self.scripts[what] end
function M:HookScript(what, fn)
    local old = self.scripts[what]
    self.scripts[what] = old and function(...) old(...) fn(...) end or fn
end
function M:RegisterEvent(e) self.events[e] = true end
function M:UnregisterEvent(e) self.events[e] = nil end
function M:CreateTexture() return new("Texture", nil, self) end
function M:CreateFontString() return new("FontString", nil, self) end
function M:GetParent() return self.parent end

local function resized(self)
    if self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self, self._w or 0, self._h or 0) end
end
function M:SetSize(w, h) self._w, self._h = w, h resized(self) end
function M:SetWidth(w) self._w = w resized(self) end
function M:SetHeight(h) self._h = h resized(self) end
function M:GetWidth() return self._w or 0 end
function M:GetHeight() return self._h or 0 end
function M:GetSize() return self._w or 0, self._h or 0 end
function M:GetLeft() return self._left or 0 end
function M:GetTop() return self._top or 0 end
function M:GetEffectiveScale() return 1 end
function M:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function M:IsMouseOver() return self._mouseOver and true or false end

function M:Show() self._shown = true if self.scripts.OnShow then self.scripts.OnShow(self) end end
function M:Hide() self._shown = false if self.scripts.OnHide then self.scripts.OnHide(self) end end
function M:SetShown(shown) if shown then self:Show() else self:Hide() end end
function M:IsShown() return self._shown end
function M:SetEnabled(enabled) self._enabled = enabled and true or false end
function M:IsEnabled() return self._enabled end

function M:SetText(t) self._text = t end
function M:GetText() return self._text or "" end
function M:GetFont() return "font", 10 end
function M:GetStringWidth() return 40 end
function M:SetChecked(c) self._checked = c and true or false end
function M:GetChecked() return self._checked end
function M:SetTexture(t) self._texture = t end
function M:SetNormalTexture(t) self._texture = t end
function M:SetTexCoord(...) self._coords = { ... } end

-- A Slider clamps to its range and reports every change of value, including
-- the ones it makes itself when the range moves.
local function setValue(self, v)
    v = math.max(self._min or 0, math.min(self._max or 0, v))
    if v ~= self._value then
        self._value = v
        if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
    end
end
function M:SetMinMaxValues(lo, hi) self._min, self._max = lo, hi setValue(self, self._value or lo) end
function M:GetMinMaxValues() return self._min, self._max end
function M:SetValue(v) setValue(self, v) end
function M:GetValue() return self._value end

function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

UIParent = new("Frame")
GameTooltip = new("GameTooltip")
StaticPopupDialogs = {}
function StaticPopup_Show() end
function GetCursorPosition() return cursorX or 0, cursorY or 0 end
function GetTexCoordsForRole(role) return 0, 0.25, 0, 0.25 end
RAID_TARGET_1, RAID_TARGET_8 = "Star", "Skull"
CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 } }
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
C_Map = { GetMapInfo = noop, GetMapArtLayers = noop, GetMapArtLayerTextures = noop }
function BUS() end
-- A handler that throws is a failed test, not a line in a log nobody reads.
function geterrorhandler() return function(msg) error(msg, 0) end end
"""

# The dropdown library only has to hand back frames and swallow everything else.
MORE_LIBS = r"""
local LibDD = LibStub:NewLibrary("LibUIDropDownMenu-4.0", 1)
setmetatable(LibDD, { __index = function(_, k)
    if k == "Create_UIDropDownMenu" then return function(_, name, parent) return CreateFrame("Frame", name, parent) end end
    if k == "UIDropDownMenu_CreateInfo" then return function() return {} end end
    return function() end
end })
"""

HELPERS = r"""
window = RaidMapFrame
canvas, roster = window.canvas, window.roster

-- Toolbar buttons that make tokens, in the order they were built: the eight
-- raid markers, then tank, healer, damage.
palette = {}
for _, f in ipairs(frames) do
    if f.kind == "Button" and f.scripts.OnClick and f.scripts.OnDragStart then palette[#palette + 1] = f end
end

function elements()
    local board = ns:CurrentBoard()
    return board.slides[board.currentSlide or 1].elements
end
function last() local e = elements() return e[#e] end

function cursorTo(nx, ny)
    cursorX = canvas._left + canvas.originX + nx * canvas.drawW
    cursorY = canvas._top - (canvas.originY + ny * canvas.drawH)
end

-- Press on a button, move, let go. `over` says what is under the cursor then.
function drag(button, over, nx, ny)
    button.scripts.OnDragStart(button)
    ghost = { shown = dragGhost():IsShown(), caption = dragGhost().caption:GetText(), texture = dragGhost().icon._texture }
    if nx then cursorTo(nx, ny) end
    canvas._mouseOver, button._mouseOver = over == "canvas", over == "button"
    button.scripts.OnDragStop(button)
    canvas._mouseOver, button._mouseOver = false, false
end
function dragGhost()
    for _, f in ipairs(frames) do
        if f.caption and f.icon and f.scripts.OnUpdate and f.parent == UIParent then return f end
    end
end
function click(button) button.scripts.OnClick(button, "LeftButton") end

function rowsShown()
    local n, first, lastText = 0
    for _, row in ipairs(roster.rows) do
        if row:IsShown() then
            n = n + 1
            first = first or row.label:GetText()
            lastText = row.label:GetText()
        end
    end
    return n, first, lastText
end
"""


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def toc_files():
    with open(os.path.join(ROOT, "RaidMap.toc"), encoding="utf-8") as f:
        lines = [line.strip().replace("\\", "/") for line in f]
    return [line for line in lines if line and not line.startswith("#")]


def client(flavor_setup):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.NAME, g.REALM = "Aeva", "Starlove"
    lua.execute(test_sync.STUBS)
    lua.execute(FRAMES)
    lua.execute(flavor_setup)
    lua.execute("ns = {}")
    load = lua.eval("""function(path, src)
        local f = assert(loadstring(src, "@" .. path))
        return f("RaidMap", ns)
    end""")

    def run_file(rel):
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            load(rel, f.read())

    for rel in REAL_LIBS:
        run_file(rel)
    lua.execute(test_sync.FAKE_LIBS)
    lua.execute(MORE_LIBS)
    for rel in toc_files():
        if not rel.startswith("Libs/"):
            run_file(rel)
    lua.execute('fire("ADDON_LOADED", "RaidMap")')
    return lua


def test_client(label, flavor_setup):
    print(f"\n{label}")
    try:
        lua = client(flavor_setup)
        lua.execute(HELPERS)
    except lua51.LuaError as e:
        check(False, f"every file in the TOC loads and the window builds: {e}")
        return
    check(True, f"every file in the TOC loads and the window builds ({len(toc_files())} entries)")
    ev = lua.eval

    # A blank map at a known size and place, so normalized points are exact.
    lua.execute("""
        local board = ns:CurrentBoard()
        board.slides[1].mapKey = "blank"
        canvas._left, canvas._top = 200, 600
        canvas:SetSize(600, 400)
        ns.SwitchSlide(1, true)
    """)
    check(ev("canvas.drawW") is not None, "canvas lays out the blank map")
    check(ev("#palette") == 11, f"toolbar has 8 marker and 3 role buttons that click and drag ({ev('#palette')})")

    print("  -- markers")
    lua.execute("click(palette[1])")
    e = ev("last()")
    check(ev("#elements()") == 1 and e.kind == "marker" and e.data.index == 1 and (e.x, e.y) == (0.5, 0.5),
          "click adds the marker at the centre of the view")
    lua.execute("drag(palette[8], 'canvas', 0.25, 0.75)")
    e = ev("last()")
    check(ev("#elements()") == 2 and e.data.index == 8 and abs(e.x - 0.25) < 1e-9 and abs(e.y - 0.75) < 1e-9,
          f"drag onto the map adds it under the cursor ({e.x:.3f}, {e.y:.3f})")
    check(ev("ghost.shown and ghost.caption == '' and ghost.texture:find('RaidTargetingIcon_8') ~= nil"),
          "the ghost shows that marker while dragging")
    check(ev("not dragGhost():IsShown()"), "and is gone once it is dropped")
    lua.execute("drag(palette[2], 'nowhere')")
    check(ev("#elements()") == 2, "drag released off the map adds nothing")
    lua.execute("drag(palette[2], 'button')")
    e = ev("last()")
    check(ev("#elements()") == 3 and e.data.index == 2 and (e.x, e.y) == (0.5, 0.5),
          "a drag that never left the button counts as a click")
    lua.execute("drag(palette[3], 'canvas', 0.1, 0.1) click(palette[3])")
    check(ev("#elements()") == 4, "a click reported in the frame a drag ended in is ignored")
    lua.execute("advance(0.1) click(palette[3])")
    check(ev("#elements()") == 5, "and the next real click works")

    print("  -- roles")
    lua.execute("ns.Model:ClearSlide(elements() and ns:CurrentBoard().slides[1])")
    lua.execute("advance(0.1) click(palette[9]) drag(palette[9], 'canvas', 0.6, 0.4)")
    e = ev("last()")
    check(ev("#elements()") == 2 and e.kind == "role" and e.data.role == "TANK" and e.data.index == 2
          and abs(e.x - 0.6) < 1e-9 and abs(e.y - 0.4) < 1e-9,
          f"clicked tank is T1, the tank dragged after it is T{e.data.index} and lands under the cursor")
    check(ev("ghost.caption:find('T2') ~= nil"), f"its ghost showed the number it would get ({ev('ghost.caption')})")
    lua.execute("advance(0.1) drag(palette[10], 'canvas', 0.5, 0.5)")
    e = ev("last()")
    check(e.data.role == "HEALER" and e.data.index == 1 and ev("ghost.caption:find('H1') ~= nil"),
          "each role keeps its own count: the first healer is H1")
    lua.execute("advance(0.1) drag(palette[9], 'nowhere') drag(palette[9], 'canvas', 0.2, 0.2)")
    check(ev("last().data.index") == 3, "a drag that was abandoned does not use up a number")
    lua.execute("ns.History:Undo()")
    check(ev("#elements()") == 3, "a dragged token undoes like any other")

    print("  -- roster")
    lua.execute("roster:SetHeight(498) ns.db.profile.demoRoster = true ns.Roster:Build()")
    sizes = lua.eval("""(function()
        local size, demo = {}, 0
        for _, entry in ipairs(ns.Roster.entries) do
            size[entry.subgroup] = (size[entry.subgroup] or 0) + 1
            if entry.isDemo then demo = demo + 1 end
        end
        local out = {}
        for g = 1, 8 do out[#out + 1] = size[g] or 0 end
        return table.concat(out, " ") .. " / " .. demo
    end)()""")
    check(ev("#ns.Roster.entries") == 40 and sizes == "5 5 5 5 5 5 5 5 / 39",
          f"demo fills eight groups of five around you: {sizes} demo")
    check(ev("#roster.items") == 48, "the list is 40 raiders under 8 group headers")
    shown, first, _ = ev("rowsShown()")
    check(shown == 24 and "Group 1" in first, f"24 rows fit a 498px column, starting at Group 1 ({shown})")
    check(ev("roster.scrollBar:IsShown()") and ev("select(2, roster.scrollBar:GetMinMaxValues())") == 24,
          "the scrollbar shows, with 24 rows of travel")
    lua.execute("roster.scripts.OnMouseWheel(roster, -1)")
    check(ev("roster.offset") == 3 and ev("roster.scrollBar:GetValue()") == 3, "one wheel notch down moves three rows and the bar follows")
    lua.execute("roster.scrollBar:SetValue(24)")
    _, _, final = ev("rowsShown()")
    check(ev("roster.offset") == 24 and ev("roster.items[48].entry.name") in final,
          "dragging the bar to the end shows the last raider of Group 8")
    lua.execute("for i = 1, 20 do roster.scripts.OnMouseWheel(roster, 1) end")
    check(ev("roster.offset") == 0, "wheeling up stops at the top")
    lua.execute("roster.scrollBar:SetValue(24) ns.db.profile.demoRoster = nil ns.Roster:Build()")
    shown, _, _ = ev("rowsShown()")
    check(ev("roster.offset") == 0 and not ev("roster.scrollBar:IsShown()") and shown == 2,
          "a roster that fits snaps back to the top and hides the bar")

    lua.execute("ns.db.profile.demoRoster = true ns.Roster:Build() before = #elements()")
    row = ev("roster.rows[3]")
    lua.execute("drag(roster.rows[3], 'canvas', 0.3, 0.3)")
    e = ev("last()")
    check(ev("#elements() == before + 1") and e.kind == "player" and e.data.name == row.entry.name
          and abs(e.x - 0.3) < 1e-9, f"a name still drags from the list onto the map ({e.data.name})")
    lua.execute("before = #elements() drag(roster.rows[1], 'canvas', 0.3, 0.3)")
    check(ev("#elements() == before"), "a group header does not")

    print("  -- token toggles")
    show, stack = ev("window.displayToggle"), ev("window.layoutToggle")
    check((show.GetText(show), stack.GetText(stack), stack.IsEnabled(stack)) == ("Show: Both", "Stack: Vert", True),
          "start as Show: Both / Stack: Vert")
    lua.execute("click(window.layoutToggle)")
    check(stack.GetText(stack) == "Stack: Horiz" and ev("ns:CurrentBoard().tokenLayout") == "horizontal",
          "Stack flips on the first click")
    lua.execute("click(window.displayToggle)")
    check(show.GetText(show) == "Show: Icon" and not stack.IsEnabled(stack), "Show: Icon greys out Stack")
    lua.execute("click(window.displayToggle) click(window.displayToggle)")
    check(show.GetText(show) == "Show: Both" and stack.IsEnabled(stack), "back round to Both, Stack live again")

    check(ev("SLASH_RAIDMAP1 == '/raidmap' and SLASH_RAIDMAP2 == '/rm' and SlashCmdList.RAIDMAP ~= nil"),
          "/raidmap and /rm are the slash commands")
    errors = [line for line in ev("printed").values() if "failed" in str(line).lower()]
    check(not errors, f"nothing reported a failure along the way {errors or ''}")


if __name__ == "__main__":
    test_client("Anniversary", test_compat.ANNIVERSARY)
    test_client("WoW Forever", test_compat.FOREVER)
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)
