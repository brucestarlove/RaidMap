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
-- A line remembers where it runs and in what colour.
function M:CreateLine() return new("Line", nil, self) end
function M:SetStartPoint(_, _, x, y) self._from = { x, y } end
function M:SetEndPoint(_, _, x, y) self._to = { x, y } end
function M:SetColorTexture(r, g, b) self._color = { r, g, b } end
function M:SetFrameLevel(level) self._level = level end
function M:GetFrameLevel() return self._level or 1 end
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
function M:SetPoint(...) self._points = self._points or {} self._points[#self._points + 1] = { ... } end
function M:ClearAllPoints() self._points = nil end
function M:IsMouseOver() return self._mouseOver and true or false end

function M:Show() self._shown = true if self.scripts.OnShow then self.scripts.OnShow(self) end end
function M:Hide() self._shown = false if self.scripts.OnHide then self.scripts.OnHide(self) end end
function M:SetShown(shown) if shown then self:Show() else self:Hide() end end
function M:IsShown() return self._shown end
function M:SetEnabled(enabled) self._enabled = enabled and true or false end
function M:IsEnabled() return self._enabled end

function M:SetText(t) self._text = t end
function M:GetText() return self._text or "" end
function M:GetFontString()
    self._fontString = self._fontString or new("FontString", nil, self)
    return self._fontString
end
function M:GetFont() return "font", 10 end
function M:GetStringWidth() return 40 end
function M:GetStringHeight() return 12 end
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
-- Enough of a dialog to drive a popup's own callbacks: like the game's, it
-- holds the data it was shown with and an edit box, and runs OnShow.
function StaticPopup_Show(which, _, _, data)
    local dialog = new("Frame")
    dialog.which, dialog.data = which, data
    dialog.EditBox = new("EditBox", nil, dialog)
    function dialog:GetEditBox() return self.EditBox end
    popup = dialog
    local info = StaticPopupDialogs[which]
    if info.OnShow then info.OnShow(dialog, data) end
    return dialog
end
function GetCursorPosition() return cursorX or 0, cursorY or 0 end
function GetLocale() return "enUS" end
function GetPhysicalScreenSize() return 2560, 1440 end
function UnitLevel() return 70 end
function GetRealZoneText() return "Black Temple" end
function IsInInstance() return true, "raid" end
function GetNumGroupMembers() return 25 end
function GetTexCoordsForRole(role) return 0, 0.25, 0, 0.25 end
RAID_TARGET_1, RAID_TARGET_8 = "Star", "Skull"
CLASS_ICON_TCOORDS = { WARRIOR = { 0, 0.25, 0, 0.25 } }
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
C_Map = { GetMapInfo = noop, GetMapArtLayers = noop, GetMapArtLayerTextures = noop }
function BUS() end
-- The Settings window, as far as taking a page for its AddOns list.
addonPages = {}
Settings = {
    RegisterCanvasLayoutCategory = function(panel, name) return { panel = panel, name = name } end,
    RegisterAddOnCategory = function(category) addonPages[#addonPages + 1] = category end,
}
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
-- Except what a dropdown shows and what its menu lists, which are kept so they
-- can be read back.
function LibDD:UIDropDownMenu_SetText(dropdown, text) dropdown._text = text end
function LibDD:UIDropDownMenu_Initialize(dropdown, build) dropdown.build = build end
function LibDD:UIDropDownMenu_AddButton(info) menu[#menu + 1] = info.text picks[info.text] = info.func end
function menuOf(dropdown)
    menu, picks = {}, {}
    dropdown.build(dropdown, 1)
    return table.concat(menu, " / ")
end
-- Choosing an entry of a dropdown's menu, by what it says.
function pick(dropdown, text)
    menuOf(dropdown)
    picks[text]()
end
-- A menu put up in one go is kept whole, with where and how it was put up.
function LibDD:EasyMenu(list, frame, anchor, x, y, mode) easyMenu = { list = list, frame = frame, anchor = anchor, mode = mode } end

-- The broker hands an object back as it was given, and the icon library
-- remembers what it was registered with and whether it is showing.
local LDB = LibStub:NewLibrary("LibDataBroker-1.1", 1)
function LDB:NewDataObject(_, object) return object end
local LibDBIcon = LibStub:NewLibrary("LibDBIcon-1.0", 1)
LibDBIcon.tooltip = CreateFrame("GameTooltip")
minimapIcons = {}
function LibDBIcon:Register(name, object, db) minimapIcons[name] = { object = object, db = db, shown = not db.hide } end
function LibDBIcon:Show(name) minimapIcons[name].shown = true end
function LibDBIcon:Hide(name) minimapIcons[name].shown = false end
"""

# WoW Forever as it names people: a first name and a surname, on a realm that
# is in nobody's name.
FOREVER = test_compat.FOREVER + 'SURNAME, REALM = "Starlove", "Classic Beta PvP 2"\n' + test_sync.SURNAME_STUBS

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

-- The slide strip: which slides have a tab showing, how wide those tabs are,
-- and where the row ends, which is the right edge of Delete.
strip = window.filmstrip
function tabsShown()
    local out, width = {}
    for _, tab in ipairs(strip.tabs) do
        if tab:IsShown() then
            out[#out + 1] = tab.index
            width = tab:GetWidth()
        end
    end
    return table.concat(out, " "), width
end
function tabFor(index)
    for _, tab in ipairs(strip.tabs) do
        if tab:IsShown() and tab.index == index then return tab end
    end
end
function stripEnd()
    return strip.addButton._points[1][4] + strip.addButton:GetWidth()
        + 3 + strip.copyButton:GetWidth() + 3 + strip.deleteButton:GetWidth()
end
function slideCount(n)
    local board = ns:CurrentBoard()
    while #board.slides < n do click(strip.addButton) end
    while #board.slides > n do click(strip.deleteButton) end
end
function arrows()
    return (strip.prevButton:IsShown() and (strip.prevButton:IsEnabled() and "<" or "(<)") or "")
        .. (strip.nextButton:IsShown() and (strip.nextButton:IsEnabled() and ">" or "(>)") or "")
end

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


def near(x, y, wantX, wantY):
    """A point that went out through the cursor and came back is only nearly itself."""
    return abs(x - wantX) < 1e-9 and abs(y - wantY) < 1e-9


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


def test_client(label, flavor_setup, author):
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
        ns.SwitchSlide(1)
    """)
    check(ev("canvas.drawW") is not None, "canvas lays out the blank map")
    lua.execute("""
        canvas:SetArt({ kind = "tiles", files = { 11, 12, 21, 22 }, cols = 2, rows = 2, tileW = 512, tileH = 512,
                        contentW = 600, contentH = 400, offsetX = 100, offsetY = 300 })
        function shown(i)
            local c = canvas.tiles[i]._coords
            return ("%d-%d %d-%d"):format(c[1] * 512, c[2] * 512, c[3] * 512, c[4] * 512)
        end
    """)
    check((ev("shown(1)"), ev("shown(4)")) == ("100-512 300-512", "0-188 0-188"),
          f"a map that starts partway into its tiles shows only the part of each inside it ({ev('shown(1)')}, {ev('shown(4)')})")
    lua.execute("ns.SwitchSlide(1)")
    check(ev("#palette") == 11, f"toolbar has 8 marker and 3 role buttons that click and drag ({ev('#palette')})")
    captions = ev("""(function()
        local out = {}
        for _, caption in ipairs(window.captions) do
            local point, anchor, relative = unpack(caption._points[1])
            local name
            for _, global in ipairs({ "RaidMapPackDropDown", "RaidMapBoardDropDown", "RaidMapMapDropDown" }) do
                if _G[global] == anchor then name = global end
            end
            for _, field in ipairs({ "displayToggle", "filmstrip" }) do
                if window[field] == anchor then name = field end
            end
            out[#out + 1] = caption:GetText() .. " " .. point .. ">" .. relative .. " " .. tostring(name)
        end
        return table.concat(out, ", ")
    end)()""")
    check(captions == "Packs BOTTOMLEFT>TOPLEFT RaidMapPackDropDown, Boards BOTTOMLEFT>TOPLEFT RaidMapBoardDropDown, "
          "Maps BOTTOMLEFT>TOPLEFT RaidMapMapDropDown, Display Names & Icons BOTTOMLEFT>TOPLEFT displayToggle, "
          "Slides BOTTOMLEFT>TOPLEFT filmstrip",
          f"each dropdown, the token toggles and the slide strip have a caption sitting on top ({captions})")
    packs = ev("menuOf(RaidMapPackDropDown)")
    check(f"My Pack |cff888888({author}, rev 1)|r" in packs, f"the pack list names the author as {author} ({packs.split(' / ')[1]})")

    print("  -- view buttons")
    lua.execute("""
        byText = {}
        for _, f in ipairs(frames) do
            if f.kind == "Button" and f.parent == window then byText[f:GetText()] = f end
        end
        notesButton, presentButton = byText["Display Notes"], byText["Present Mode"]
    """)
    check(ev("notesButton ~= nil and presentButton ~= nil and byText['Reset view'] == nil"),
          "Present Mode and Display Notes are there, Reset view is not")
    check(ev("notesButton._points[1][2] == window and presentButton._points[1][2] == notesButton"),
          "Display Notes hangs off the window's corner and Present Mode off Display Notes")
    lua.execute("before = window.notes:IsShown() click(notesButton)")
    check(ev("window.notes:IsShown() ~= before"), "Display Notes shows and hides the notes panel")
    lua.execute("click(notesButton)")
    check(ev("window.notes:IsShown() == before"), "and a second click puts it back")

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

    print("  -- slide strip")
    current = "ns:CurrentBoard().currentSlide"
    lua.execute("slideCount(3)")
    maps = ev("(function() local s = ns:CurrentBoard().slides return s[1].mapKey .. ' ' .. s[2].mapKey .. ' ' .. s[3].mapKey end)()")
    check(maps == "blank blank blank", f"+ opens the new slide on the map of the one it was pressed from ({maps})")
    shown, width = ev("tabsShown()")
    check((shown, width, ev("arrows()")) == ("1 2 3", 104, "") and ev("strip.addButton._points[1][4]") == 321,
          "before the strip is measured, tabs are full width with + straight after the last")
    lua.execute("strip:SetWidth(630)")
    shown, width = ev("tabsShown()")
    check((shown, width, ev("arrows()")) == ("1 2 3", 104, ""), "three slides in a 630px strip look the same")
    lua.execute("slideCount(7)")
    shown, width = ev("tabsShown()")
    check((shown, ev("arrows()")) == ("1 2 3 4 5 6 7", "") and 64 <= width < 104 and ev("stripEnd()") <= 630,
          f"seven all show, narrowed to fit with Delete inside the strip ({width}px tabs, row ends at {ev('stripEnd()')})")
    check(ev("tabFor(7):GetFontString():GetWidth()") < width, "a tab's label is held narrower than the tab")
    check(ev("tabFor(7):GetText()") == "|cffffffff7. Slide 7|r" and ev("tabFor(6):GetText()") == "6. Slide 6",
          "only the current slide's tab is marked")

    lua.execute("slideCount(12)")
    shown, width = ev("tabsShown()")
    check((shown, ev("arrows()")) == ("7 8 9 10 11 12", "<(>)") and width >= 64 and ev("stripEnd()") <= 630,
          f"twelve do not fit: a run ending at the new slide shows between arrows ({shown}; row ends at {ev('stripEnd()')})")
    lua.execute("strip.scripts.OnMouseWheel(strip, 1)")
    check((ev("tabsShown()")[0], ev(current)) == ("6 7 8 9 10 11", 12),
          "a wheel notch up moves the run one tab and leaves the board on slide 12")
    lua.execute("click(strip.prevButton)")
    check((ev("tabsShown()")[0], ev("arrows()"), ev(current)) == ("1 2 3 4 5 6", "(<)>", 12),
          "the left arrow pages back to the start, where it greys out")
    lua.execute("click(tabFor(2))")
    check((ev("tabsShown()")[0], ev(current)) == ("1 2 3 4 5 6", 2), "clicking a tab in the scrolled run switches to that slide")
    lua.execute("click(strip.nextButton) ns.SwitchSlide(9)")
    check(ev("tabsShown()")[0] == "7 8 9 10 11 12", "a slide change arriving for a tab already showing does not move the run")
    lua.execute("ns.SwitchSlide(3)")
    check(ev("tabsShown()")[0] == "3 4 5 6 7 8", "one for a tab out of sight scrolls just far enough to show it")
    lua.execute("ns.SwitchSlide(12) strip:SetWidth(412)")
    shown, width = ev("tabsShown()")
    check(shown == "10 11 12" and ev("stripEnd()") <= 412,
          f"a narrower strip (notes opened) keeps the current slide in the shorter run ({shown})")
    lua.execute("strip:SetWidth(630) slideCount(3)")
    shown, width = ev("tabsShown()")
    check((shown, width, ev("arrows()")) == ("1 2 3", 104, ""), "deleting back down to three restores full-width tabs and drops the arrows")
    lua.execute("ns.History:Undo()")
    check(ev("tabsShown()")[0] == "1 2 3 4" and ev("#strip.tabs") <= 7, "undoing a delete brings its tab back")

    names = """(function()
        local out = {}
        for i, slide in ipairs(ns:CurrentBoard().slides) do out[i] = slide.name end
        return table.concat(out, ", ")
    end)()"""
    first = ev("ns:CurrentBoard().slides[1].name")
    lua.execute("ns.SwitchSlide(1) before = #elements()")
    lua.execute("tabFor(3).scripts.OnClick(tabFor(3), 'RightButton')")
    check((ev("popup.which"), ev("popup.EditBox:GetText()"), ev(current)) == ("RAIDMAP_RENAME_SLIDE", "Slide 3", 1),
          "right-clicking another slide's tab offers that slide's name and leaves the board on slide 1")
    lua.execute("advance(0.1) click(palette[1])")
    check(ev("#ns:CurrentBoard().slides[1].elements == before + 1 and #ns:CurrentBoard().slides[3].elements == 0"),
          "with the rename abandoned, the next token lands on the slide in view")
    lua.execute("popup.EditBox:SetText('P2 stack') StaticPopupDialogs[popup.which].OnAccept(popup, popup.data)")
    check((ev(names), ev(current), ev("tabFor(3):GetText()")) == (f"{first}, Slide 2, P2 stack, Slide 4", 1, "3. P2 stack"),
          f"accepting renames the tab that was right-clicked, still on slide 1 ({ev(names)})")
    lua.execute("tabFor(3).scripts.OnClick(tabFor(3), 'RightButton') ns.Model:RemoveSlide(ns:CurrentBoard(), 2)")
    lua.execute("popup.EditBox:SetText('P3') StaticPopupDialogs[popup.which].EditBoxOnEnterPressed(popup.EditBox)")
    check(ev(names) == f"{first}, P3, Slide 4", f"Enter renames the same slide even after it has moved up a place ({ev(names)})")
    lua.execute("tabFor(2).scripts.OnClick(tabFor(2), 'RightButton') ns.Model:RemoveSlide(ns:CurrentBoard(), 2)")
    lua.execute("popup.EditBox:SetText('gone') StaticPopupDialogs[popup.which].OnAccept(popup, popup.data)")
    check(ev(names) == f"{first}, Slide 4", "and a slide deleted while its popup was open renames nothing")

    print("  -- drawing")
    lua.execute("""
        arrowTool, pathTool, swatch = window.drawTools.arrow, window.drawTools.path, window.drawSwatch
        layer = ns.TokenLayer

        -- Left button down at the first point, the pointer through the rest,
        -- and up where it ends.
        function stroke(...)
            local points = { ... }
            cursorTo(points[1], points[2])
            canvas.scripts.OnMouseDown(canvas, "LeftButton")
            for i = 3, #points, 2 do
                cursorTo(points[i], points[i + 1])
                canvas.scripts.OnUpdate(canvas)
            end
            previewed = layer.pool.preview ~= nil and layer.pool.preview:IsShown()
            canvas.scripts.OnMouseUp(canvas, "LeftButton")
        end
        function tokenOf(element, of)
            for _, token in ipairs((of or layer).pool) do
                if token:IsShown() and token.element == element then return token end
            end
        end
        function linesShown(token)
            local n = 0
            for _, line in ipairs(token.lines) do if line:IsShown() then n = n + 1 end end
            return n
        end
        function ends(line) return ("%.0f %.0f > %.0f %.0f"):format(line._from[1], line._from[2], line._to[1], line._to[2]) end
        function span(ax, ay, bx, by)
            local x1, y1 = canvas:NormalizedToOffset(ax, ay)
            local x2, y2 = canvas:NormalizedToOffset(bx, by)
            return ("%.0f %.0f > %.0f %.0f"):format(x1, y1, x2, y2)
        end
        function lengthOf(line) return math.sqrt((line._to[1] - line._from[1]) ^ 2 + (line._to[2] - line._from[2]) ^ 2) end
        function pts(element) return table.concat(element.data.pts, " ") end

        ns.Model:ClearSlide(elements() and ns:CurrentBoard().slides[ns:CurrentBoard().currentSlide])
        stroke(0.2, 0.3, 0.6, 0.5)
    """)
    check(ev("#elements()") == 0, "with no tool armed, a left-drag on the map draws nothing")

    lua.execute("click(arrowTool) stroke(0.2, 0.3, 0.4, 0.45, 0.6, 0.5)")
    e = ev("last()")
    check(ev("#elements()") == 1 and e.kind == "path" and near(e.x, e.y, 0.6, 0.5) and ev("pts(last())") == "-1600 -800",
          f"Arrow draws one straight from the press to the release, kept as its end and the offset back to its start ({ev('pts(last())')})")
    check(ev("previewed and not layer.pool.preview:IsShown()"), "it is on screen while it is being dragged out, and the preview goes when it lands")
    check(ev("arrowTool:GetText()") == "|cffffffffArrow|r" and ev("ns.Draw.tool") == "arrow", "the tool is lit and stays armed for the next one")
    lua.execute("arrow = last() token = tokenOf(arrow)")
    check(ev("linesShown(token)") == 3 and ev("ends(token.lines[1])") == ev("span(0.2, 0.3, 0.6, 0.5)"),
          f"it is drawn as a shaft from start to end ({ev('ends(token.lines[1])')})")
    head = ev("""(function()
        local tipX, tipY = canvas:NormalizedToOffset(0.6, 0.5)
        local out = {}
        for i = 2, 3 do
            local line = token.lines[i]
            out[#out + 1] = (line._from[1] == tipX and line._from[2] == tipY and line._to[1] < tipX) and ("%.0f"):format(lengthOf(line)) or "wrong"
        end
        return table.concat(out, " ") .. (ends(token.lines[2]) ~= ends(token.lines[3]) and " apart" or " same")
    end)()""")
    check(head == "12 12 apart", f"and two barbs swept back from the end, the same size at any zoom ({head})")
    check(ev("token:GetFrameLevel() == canvas:GetFrameLevel() + 1"), "a path lies under the tokens, not over them")

    lua.execute("stroke(0.3, 0.3, 0.3, 0.3)")
    check(ev("#elements()") == 1, "a click that goes nowhere is not an arrow")

    lua.execute("click(pathTool) stroke(0.1, 0.1, 0.2, 0.15, 0.3, 0.1, 0.4, 0.15, 0.5, 0.1)")
    e = ev("last()")
    check(ev("ns.Draw.tool") == "path" and ev("arrowTool:GetText()") == "Arrow", "choosing Path puts Arrow away")
    check(ev("#elements()") == 2 and near(e.x, e.y, 0.5, 0.1) and ev("pts(last())") == "-1600 0 -1200 200 -800 0 -400 200",
          f"Path follows the pointer, point by point ({ev('pts(last())')})")
    check(ev("linesShown(tokenOf(last()))") == 6, "drawn as a line a segment and the same two barbs")

    lua.execute("""
        cursorTo(0.05, 0.5)
        canvas.scripts.OnMouseDown(canvas, "LeftButton")
        for i = 1, 300 do
            cursorTo(0.05 + i * 0.003, 0.5 + (i % 2) * 0.03)
            canvas.scripts.OnUpdate(canvas)
        end
        canvas.scripts.OnMouseUp(canvas, "LeftButton")
        long = last()
    """)
    points = ev("#long.data.pts / 2")
    check(10 <= points <= 40 and ev("long.data.pts[1] == math.floor((0.05 - long.x) * 4000 + 0.5)"),
          f"a path of 300 pointer moves is thinned to a bounded number of points, from the same start ({points:.0f})")

    lua.execute("click(swatch) stroke(0.2, 0.8, 0.4, 0.8)")
    colour = ev("(function() local c = tokenOf(last()).lines[1]._color return ('%.2f %.2f %.2f'):format(c[1], c[2], c[3]) end)()")
    check((ev("last().data.color"), ev("arrow.data.color"), colour) == (2, 1, "1.00 0.82 0.00"),
          f"the swatch changes the colour of what is drawn next, and of nothing already drawn ({colour})")

    lua.execute("""
        token = tokenOf(arrow)
        token.scripts.OnDragStart(token)
        cursorTo(0.7, 0.7)
        token.scripts.OnUpdate(token)
        token.scripts.OnDragStop(token)
    """)
    check(near(ev("arrow.x"), ev("arrow.y"), 0.7, 0.7) and ev("pts(arrow)") == "-1600 -800"
          and ev("ends(token.lines[1])") == ev("span(0.3, 0.5, 0.7, 0.7)"),
          f"dragging its end moves the whole arrow ({ev('ends(token.lines[1])')})")
    lua.execute("ns.History:Undo()")
    check(near(ev("arrow.x"), ev("arrow.y"), 0.6, 0.5), "and undo puts it back")

    lua.execute("before = #elements() click(strip.copyButton)")
    check(ev("#elements() == before and elements()[1].data.pts ~= arrow.data.pts and pts(elements()[1]) == pts(arrow)"),
          "a copied slide has the same paths, with points of its own")
    lua.execute("click(strip.deleteButton) ns.SwitchSlide(1)")

    lua.execute("""
        ns.ShowPresentation()
        RaidMapPresentFrame.canvas:SetSize(400, 300)
        shownThere = tokenOf(arrow, RaidMapPresentFrame.tokens)
    """)
    check(ev("shownThere ~= nil and linesShown(shownThere) == 3"), "the present window draws them too")
    lua.execute("RaidMapPresentFrame:Hide()")

    lua.execute("token = tokenOf(arrow) token.scripts.OnClick(token, 'RightButton')")
    check(ev("#elements() == before - 1 and tokenOf(arrow) == nil"), "right-clicking its end deletes it")
    lua.execute("""
        local slide = ns:CurrentBoard().slides[ns:CurrentBoard().currentSlide]
        ns.Model:ClearSlide(slide)
        click(palette[1])
        marker = tokenOf(last())
        table.insert(slide.elements, { id = 999, kind = "hologram", x = 0.5, y = 0.5, data = {} })
        ns.Events:Fire("ELEMENTS_CHANGED")
    """)
    check(ev("linesShown(marker) == 0 and marker:GetFrameLevel() == canvas:GetFrameLevel() + 2"),
          "a token that was a path a moment ago keeps none of its lines")
    check(ev("layer.pool[2] ~= nil and not layer.pool[2]:IsShown()"), "an element of a kind this version does not know is left undrawn")
    lua.execute("table.remove(ns:CurrentBoard().slides[ns:CurrentBoard().currentSlide].elements) ns.Events:Fire('ELEMENTS_CHANGED')")

    lua.execute("click(pathTool) before = #elements() stroke(0.2, 0.3, 0.6, 0.5)")
    check(ev("ns.Draw.tool == nil and #elements() == before") and ev("pathTool:GetText()") == "Path", "clicking the armed tool puts it away")

    print("  -- text")
    lua.execute(r"""
        textTool = window.drawTools.text
        for _, f in ipairs(frames) do
            if f.kind == "EditBox" and f.parent == canvas then textBox = f end
        end
        mouseDown = {}
        function IsMouseButtonDown(button) return mouseDown[button] or false end

        -- A press and a release on the map, in one place or from one to another.
        function clickMap(x, y, toX, toY)
            cursorTo(x, y)
            canvas.scripts.OnMouseDown(canvas, "LeftButton")
            if toX then cursorTo(toX, toY) end
            canvas.scripts.OnMouseUp(canvas, "LeftButton")
        end
        function typeText(text)
            textBox:SetText(text)
            textBox.scripts.OnTextChanged(textBox, true)
        end
        function enter() textBox.scripts.OnEnterPressed(textBox) end
        function escape() textBox.scripts.OnEscapePressed(textBox) end
        -- The left button going down anywhere but the box, seen by the box.
        function pressElsewhere()
            mouseDown.LeftButton = true
            textBox.scripts.OnUpdate(textBox, 0)
            mouseDown.LeftButton = nil
        end
        function clickToken(token, button)
            token.scripts.OnMouseDown(token, button or "LeftButton")
            token.scripts.OnClick(token, button or "LeftButton")
        end
        function texts()
            local out = {}
            for _, e in ipairs(elements()) do
                if e.kind == "text" then out[#out + 1] = e.data.text end
            end
            return table.concat(out, " / ")
        end
        function steps() return ns.History.pos end

        ns.Model:ClearSlide(ns:CurrentBoard().slides[ns:CurrentBoard().currentSlide])
    """)

    cleaned = ev(r"""ns.Model:CleanText("  Tank|cffff0000 here\n\tnow  ") .. "/" .. ns.Model:CleanText(nil)""")
    check(cleaned == "Tankcffff0000 here  now/", f"text is cleaned to one line with no pipes in it ({cleaned!r})")
    capped = ev(r"""(function()
        local a = ns.Model:CleanText(string.rep("é", 60))
        local b = ns.Model:CleanText(string.rep("\240\159\152\128", 49) .. "ab")
        return #a .. " " .. #b .. " " .. b:sub(-1)
    end)()""")
    check(capped == "100 197 a", f"and capped at 50 letters, however many bytes each takes, never cutting one in half ({capped})")

    lua.execute("click(textTool)")
    check((ev("ns.Draw.tool"), ev("textTool:GetText()"), ev("arrowTool:GetText()")) == ("text", "|cffffffffText|r", "Arrow"),
          "Text is armed from the same row as Arrow and Path, and lit")
    lua.execute("advance(0.1) stroke(0.2, 0.3, 0.6, 0.5)")
    check(ev("#elements()") == 0 and not ev("textBox:IsShown()"), "with Text armed, a drag on the map draws nothing and opens nothing")

    lua.execute("advance(0.1) before = steps() clickMap(0.3, 0.4)")
    check(ev("textBox:IsShown()") and ev("#elements()") == 0 and ev("textBox:GetWidth()") > 0,
          "a click on the map opens a box there, wide enough for a letter, and nothing is on the slide yet")
    lua.execute("typeText('Stack here') enter()")
    e = ev("last()")
    check(ev("#elements()") == 1 and e.kind == "text" and e.data.text == "Stack here" and near(e.x, e.y, 0.3, 0.4)
          and e.data.color == ev("ns.Draw:Color()") and not ev("textBox:IsShown()"),
          "Enter puts it on the slide where the click was, in the swatch's colour")
    check(ev("steps() - before") == 1, "however many keys it took, it is one step to undo")
    lua.execute("label = last() token = tokenOf(label)")
    check(ev("token.text:GetText()") == "Stack here" and ev("token:GetFrameLevel() == canvas:GetFrameLevel() + 2"),
          "it is drawn, over the paths")

    lua.execute("advance(0.1) clickToken(token)")
    aligned = ev("""(function()
        local b, t = textBox._points[1], token._points[1]
        return b[1] == t[1] and b[4] == t[4] + token.text._points[1][2] and b[5] == t[5]
    end)()""")
    check(ev("textBox:IsShown() and textBox:GetText() == 'Stack here' and not token:IsShown()") and aligned,
          "clicking it opens the same box in its place, the first letter where the text's first letter was")

    lua.execute("before = steps() typeText('Stack here!') pressElsewhere()")
    check(ev("texts()") == "Stack here!" and not ev("textBox:IsShown()") and ev("tokenOf(label) ~= nil")
          and ev("steps() - before") == 1, "a press anywhere else keeps the change, as one step")
    lua.execute("ns.History:Undo()")
    undone = ev("texts()")
    lua.execute("ns.History:Redo()")
    check((undone, ev("texts()")) == ("Stack here", "Stack here!"), "which undoes and redoes")

    lua.execute("advance(0.1) before = steps() clickToken(tokenOf(label)) typeText('junk') escape()")
    check(ev("texts()") == "Stack here!" and ev("steps() == before") and ev("tokenOf(label) ~= nil"),
          "Escape drops what was typed and leaves the text as it was")

    lua.execute("advance(0.1) clickMap(0.5, 0.6) typeText('a|b')")
    check(ev("textBox:GetText()") == "ab", "a pipe is taken out as it is typed, so the box never shows a colour code")
    lua.execute("advance(0.1) clickMap(0.7, 0.2)")
    check(ev("texts()") == "Stack here! / ab" and not ev("textBox:IsShown()"),
          "a click on the map while typing keeps the text and opens no second box")
    lua.execute("advance(0.1) clickMap(0.5, 0.7) typeText('cd') pressElsewhere() clickMap(0.7, 0.2)")
    check(ev("texts()") == "Stack here! / ab / cd" and not ev("textBox:IsShown()"),
          "nor when the box saw the press first")

    lua.execute("advance(0.1) before = steps() clickMap(0.1, 0.1) enter()")
    check(ev("texts()") == "Stack here! / ab / cd" and ev("steps() == before"), "a box left empty adds nothing")
    lua.execute("advance(0.1) n = #elements() clickToken(tokenOf(last())) typeText('   ') enter()")
    check(ev("#elements() == n - 1") and ev("texts()") == "Stack here! / ab", "text typed away to nothing is deleted")
    lua.execute("ns.History:Undo()")
    check(ev("texts()") == "Stack here! / ab / cd", "and undo brings it back")

    lua.execute("""
        advance(0.1)
        token = tokenOf(label)
        token.scripts.OnMouseDown(token, "LeftButton")
        token.scripts.OnDragStart(token)
        cursorTo(0.6, 0.65)
        token.scripts.OnUpdate(token)
        token.scripts.OnDragStop(token)
        token.scripts.OnClick(token, "LeftButton")
    """)
    check(near(ev("label.x"), ev("label.y"), 0.6, 0.65) and not ev("textBox:IsShown()"),
          "dragging text moves it, and letting go is not taken for a click that opens it")
    lua.execute("advance(0.1) clickToken(token)")
    check(ev("textBox:IsShown()"), "the next plain click does")
    lua.execute("canvas:SetView(0.5, 0.5, 2)")
    moved = ev("""(function()
        local x, y = canvas:NormalizedToOffset(label.x, label.y)
        return textBox._points[1][4] == x and textBox._points[1][5] == y
    end)()""")
    check(moved, "an open box stays on its text through a zoom")
    lua.execute("escape() canvas:SetView(0.5, 0.5, 1)")

    lua.execute("""
        advance(0.1)
        clickMap(0.1, 0.9) typeText('Temp') enter()
        advance(0.1)
        clickToken(tokenOf(last())) typeText('Temp, edited')
        ns.History:Undo()
    """)
    check(ev("texts()") == "Stack here! / ab / cd" and not ev("textBox:IsShown()"),
          "undoing the text under an open box closes the box and keeps nothing")
    lua.execute("ns.History:Redo()")
    check(ev("texts()") == "Stack here! / ab / cd / Temp", "redo brings back the text as it was before the box opened")

    lua.execute("""
        advance(0.1)
        slideCount(2)
        ns.SwitchSlide(1)
        clickMap(0.2, 0.2) typeText('Phase one')
        ns.SwitchSlide(2)
        textBox.scripts.OnUpdate(textBox, 0)
        onSecond = #ns:CurrentBoard().slides[2].elements
        ns.SwitchSlide(1)
    """)
    check(ev("texts()").endswith("Phase one") and ev("onSecond") == 0 and not ev("textBox:IsShown()"),
          "changing slide while typing keeps the text, on the slide it was typed on")

    lua.execute("""
        before = #elements()
        click(strip.copyButton)
        copied = last()
    """)
    check(ev("#elements() == before and copied.kind == 'text' and copied.data.text == 'Phase one' and copied.data ~= label.data"),
          "a copied slide has the same text, in data of its own")
    lua.execute("click(strip.deleteButton) ns.SwitchSlide(1)")

    lua.execute("""
        ns.ShowPresentation()
        RaidMapPresentFrame.canvas:SetSize(400, 300)
        shownThere = tokenOf(label, RaidMapPresentFrame.tokens)
    """)
    check(ev("shownThere ~= nil and shownThere.text:GetText() == 'Stack here!'"), "the present window draws it too")
    lua.execute("RaidMapPresentFrame:Hide()")

    lua.execute("n = #elements() token = tokenOf(label) clickToken(token, 'RightButton')")
    check(ev("#elements() == n - 1 and tokenOf(label) == nil") and not ev("textBox:IsShown()"),
          "right-clicking it deletes it, and opens nothing")

    # Hiding a window hides what is in it, which the stubs leave to the test.
    lua.execute("advance(0.1) clickMap(0.4, 0.4) typeText('kept') window:Hide() canvas.scripts.OnHide(canvas) window:Show()")
    check(ev("texts()").endswith("kept") and not ev("textBox:IsShown()"), "closing the window keeps what was being typed")

    lua.execute("click(textTool) advance(0.1) n = #elements() clickMap(0.4, 0.4)")
    check(ev("ns.Draw.tool == nil and textTool:GetText() == 'Text'") and not ev("textBox:IsShown()") and ev("#elements() == n"),
          "clicking Text again puts it away, and a click on the map opens nothing")
    lua.execute("ns.Model:ClearSlide(ns:CurrentBoard().slides[ns:CurrentBoard().currentSlide])")

    print("  -- framing")
    lua.execute("""
        function framing(slide)
            local board = ns:CurrentBoard()
            local v = (slide or board.slides[board.currentSlide]).view
            return ("%.2f %.2f x%.2f"):format(v.cx, v.cy, v.zoom)
        end
        function showing() return ("%.2f %.2f x%.2f"):format(canvas:GetView()) end
        function wheel(delta) canvas.scripts.OnMouseWheel(canvas, delta) end
        function pan(dx, dy)
            canvas.scripts.OnMouseDown(canvas, "RightButton")
            cursorX, cursorY = cursorX + dx, cursorY + dy
            canvas.scripts.OnUpdate(canvas)
            canvas.scripts.OnMouseUp(canvas, "RightButton")
        end
        function mark() return RaidMapPackDropDown:GetText():find("~", 1, true) ~= nil end

        local v = ns:CurrentBoard().slides[1].view
        v.cx, v.cy, v.zoom = 0.5, 0.5, 1
        ns:CurrentPack().modified = nil
        ns.Events:Fire("PACK_CHANGED")
        cursorTo(0.5, 0.5)
    """)
    rev = "ns:CurrentBoard().rev"
    check(not ev("mark()"), "a pack with nothing unpublished has no mark on its name")
    before = ev(rev)
    lua.execute("wheel(1)")
    check((ev("framing()"), ev("showing()")) == ("0.50 0.50 x1.20", "0.50 0.50 x1.20") and ev(rev) != before,
          f"a wheel notch is saved as the slide's framing, and is an edit to the board ({ev('framing()')})")
    check(ev("mark()"), "which puts the unpublished mark on the pack's name straight away")
    lua.execute("wheel(1) wheel(1)")
    before = ev(rev)
    lua.execute("pan(60, 0)")
    check(ev("framing() == showing() and ns:CurrentBoard().slides[1].view.cx < 0.5") and ev(rev) != before,
          f"so is a right-drag, once it is let go ({ev('framing()')})")
    before, saved = ev(rev), ev("framing()")
    lua.execute("pan(0, 0)")
    check(ev(rev) == before, "a right-click that goes nowhere is not an edit")
    lua.execute("canvas:SetSize(300, 400)")
    check((ev(rev), ev("framing()")) == (before, saved), "nor is resizing the map")
    lua.execute("canvas:SetSize(600, 400)")

    lua.execute("""
        local pack = ns:CurrentPack()
        second = ns.Pack:AddBoard(pack)
        other = pack.boards[second].slides[1]
        other.mapKey = "blank"
        other.view.cx, other.view.cy, other.view.zoom = 0.30, 0.60, 3
        ns.Pack:SelectBoard(pack, second)
    """)
    check((ev("framing(other)"), ev("showing()")) == ("0.30 0.60 x3.00", "0.30 0.60 x3.00"),
          f"a board opens framed the way it was saved, not the way the last one was left ({ev('framing(other)')})")
    lua.execute("ns.Pack:SelectBoard(ns:CurrentPack(), 1)")
    check((ev("framing()"), ev("showing()")) == (saved, saved), "and going back finds the first board's framing where it was")

    lua.execute("""
        incoming = ns.Serialize:UnpackFromExport(ns.Serialize:PackForExport(ns:CurrentPack()))
        incoming.revision = (incoming.revision or 1) + 1
        incoming.modified = nil
        local v = incoming.boards[1].slides[1].view
        v.cx, v.cy, v.zoom = 0.25, 0.25, 4
        sentRev = incoming.boards[1].rev
        ns.Comm:ApplyPack(incoming, "Lead", true)
    """)
    check((ev("framing()"), ev("showing()")) == ("0.25 0.25 x4.00", "0.25 0.25 x4.00"),
          f"a received publish shows the framing its sender saved ({ev('framing()')})")
    check(ev(rev) == ev("sentRev") and not ev("mark()"), "and loading it is not an edit of the receiver's own")

    print("  -- presenting")
    lua.execute("""
        present = RaidMapPresentFrame
        pack = ns:CurrentPack()
        first, other = pack.boards[1], pack.boards[2]
        ns.Pack:SelectBoard(pack, 1)
        slideCount(3)
        ns.SwitchSlide(3)

        function editing() return pack.currentBoard .. "/" .. ns:CurrentBoard().currentSlide end
        function presenting() return present.boardButton:GetText() .. " " .. present.slideButton:GetText():match("^%d+/%d+") end
        function hinted()
            local n = 0
            for _, line in ipairs(printed) do
                if line:find("is presenting", 1, true) then n = n + 1 end
            end
            return n
        end

        -- Every focus that goes out, as "slide board".
        focusSent = {}
        function BUS(_, text)
            local message = text:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end)
            if message:sub(1, 1) == "F" then focusSent[#focusSent + 1] = (message:sub(3):gsub(string.char(2), " ")) end
        end
        -- And one coming in, from somebody else who is presenting.
        function hear(index, board)
            local message = "F" .. string.char(1) .. index .. string.char(2) .. board.id
            deliver("RaidMap", (message:gsub(".", function(c) return ("%02x"):format(c:byte()) end)), "PARTY", "Gil-Marsh")
        end

        group.party = true
        present:Show()
        was = presenting()
        click(tabFor(2))
    """)
    check((ev("editing()"), ev("#focusSent"), ev("presenting() == was")) == ("1/2", 0, True),
          f"changing slide in the editor tells nobody, and leaves the present window where it was ({ev('was')})")
    lua.execute("pick(RaidMapBoardDropDown, other.name)")
    check((ev("editing()"), ev("#focusSent"), ev("presenting() == was")) == ("2/1", 0, True), "so does changing board there")
    lua.execute("pick(RaidMapBoardDropDown, first.name) ns.SwitchSlide(2) advance(0.1) click(palette[1])")

    lua.execute("pick(RaidMapPresentSlideMenu, '1. ' .. first.slides[1].name) click(present.next)")
    check((ev("presenting()"), ev("editing()")) == ("New Board 2/3", "1/2")
          and ev("#focusSent == 2 and focusSent[1] == '1 ' .. first.id and focusSent[2] == '2 ' .. first.id"),
          f"the present window's slide menu and arrows move it, and tell the group where it went ({ev('focusSent[2]')})")
    lua.execute("pick(RaidMapPresentBoardMenu, other.name)")
    check((ev("presenting()"), ev("editing()"), ev("focusSent[3] == '1 ' .. other.id")) == ("Board 2 1/1", "1/2", True)
          and ev("present.tokens.slide == other.slides[1] and present.tokens.board == other"),
          "its board menu takes the group to another board's first slide, and the editor stays on its own")

    lua.execute("hear(3, first)")
    check((ev("presenting()"), ev("editing()"), ev("#focusSent"), ev("ns.History:CanUndo()")) == ("New Board 3/3", "1/2", 3, True),
          "somebody else presenting moves the present window, and neither the editor nor its undo history")
    lua.execute("hear(1, other)")
    check((ev("presenting()"), ev("editing()"), ev("ns.History:CanUndo()"), ev("hinted()")) == ("Board 2 1/1", "1/2", True, 0),
          "to another board as well, which the editor does not follow them to")

    lua.execute("present:Hide() window:Show() hear(2, first)")
    check(ev("hinted()") == 1, "with the present window shut they are told somebody is presenting, editor open or not")
    lua.execute("hear(3, first)")
    check(ev("hinted()") == 1, "once")
    lua.execute("present:Show()")
    check((ev("presenting()"), ev("editing()")) == ("New Board 3/3", "1/2"), "and opening it lands where the presenter is")

    lua.execute("group.party, group.raid = false, true click(present.prev)")
    check((ev("presenting()"), ev("#focusSent")) == ("New Board 2/3", 3),
          "a raider who is not an assistant can page through it, and moves nobody else")
    lua.execute("group.raid = false present:Hide() window:Hide() function BUS() end")

    print("  -- bug report")
    lua.execute("""
        bug = window.bugButton
        function report() return RaidMapBugFrame.edit:GetText() end
        function has(text) return report():find(text, 1, true) ~= nil end
        function typeNote(text)
            local note = RaidMapBugFrame.note
            note:SetText(text)
            note.scripts.OnTextChanged(note, true)
        end
    """)
    check(ev("bug:GetText() == 'Report a bug' and bug.parent ~= window and bug._points[1][3] == 'LEFT'")
          and ev("RaidMapBugFrame == nil"),
          "Report a bug sits in the title bar beside the close button, and its window is not built until asked for")
    lua.execute("group.raid, group.leader = true, true click(bug)")
    check(ev("RaidMapBugFrame:IsShown()"), "clicking it opens the report window")
    first = ev("report():match('^[^\\n]*')")
    check(first == "=== RaidMap bug report, for lavitzstarlove@pm.me ===" and ev("RaidMapBugFrame.address:GetText()")
          == "Email it to |cffffd100lavitzstarlove@pm.me|r",
          f"the report opens with where to send it, and so does the window ({first})")
    client_line = ev("('client: %s (%s), interface %d, %s'):format(GetBuildInfo(), select(2, GetBuildInfo()), "
                     "select(4, GetBuildInfo()), ns.FLAVOR)")
    check(ev("has('version: dev')") and ev(f"has({client_line!r})") and ev("has('locale: enUS')")
          and ev("has('screen: 2560x1440, UI scale 1.00')"),
          f"it says which addon version and which client ({client_line})")
    check(ev(f"has('character: {author}, SHAMAN level 70')") and ev("has('zone: Black Temple (raid instance)')")
          and ev("has('group: raid of 25, leader')") and ev("has('sync: can publish')"),
          "who is reporting, where they are and what they may do in the group")
    lua.execute("""
        local pack, board = ns:CurrentPack(), ns:CurrentBoard()
        packLine = ('pack: "%s" rev %d by %s, %d boards'):format(pack.title, pack.revision, pack.author, #pack.boards)
        boardLine = ('board: %d of %d, "%s"'):format(pack.currentBoard, #pack.boards, board.name)
    """)
    check(ev("has(packLine) and has(boardLine)") and ev("has('map: blank (Blank Canvas)')"),
          f"and what they had up: the pack, the board and the slide's map ({ev('packLine')})")
    check(ev("has('windows: editor closed, present mode closed')"), "with the editor shut, it says so")
    lua.execute("window:Show() click(bug) window:Hide()")
    check(ev("has('windows: editor open at 1060x660, present mode closed')"), "and open, how big it is")
    lua.execute("""
        ns.Model:ClearSlide(elements() and ns:CurrentBoard().slides[ns:CurrentBoard().currentSlide or 1])
        advance(0.1) click(palette[1]) click(palette[2]) click(palette[9])
        click(bug)
    """)
    check(ev("has('2 marker, 1 role')"), "the slide's line counts what is on it by kind")
    check(ev("has('--- what went wrong ---\\n(nothing written)')"), "with no note yet, it says so")
    lua.execute("typeNote('  the map went blank after a publish  ')")
    check(ev("has('--- what went wrong ---\\nthe map went blank after a publish\\n')")
          and ev("RaidMapBugFrame.protected == report()"),
          "a note goes into the report as it is typed")
    lua.execute("""
        local edit = RaidMapBugFrame.edit
        kept = report()
        edit:SetText("mangled")
        edit.scripts.OnTextChanged(edit, true)
    """)
    check(ev("report() == kept"), "typing over the report itself puts it back")
    lua.execute("ns:Print('|cffff5555Unknown map \\'%s\\'.|r', 'nowhere') click(bug)")
    check(ev("report():find(\"%-%-%- recent messages %-%-%-\\n.*%d%d:%d%d:%d%d  Unknown map 'nowhere'%.\") ~= nil"),
          "what the addon said lately is quoted, without its colour codes")
    check(ev("has('the map went blank after a publish')"), "and reopening the window keeps the note")
    lua.execute("""
        local real = GetRealZoneText
        GetRealZoneText = nil
        click(bug)
        GetRealZoneText = real
    """)
    check(ev("has('zone: (could not read: ')") and ev("has('version: dev')") and ev("has('map: blank (')"),
          "something the client will not answer costs its own line, not the report")
    lua.execute("RaidMapBugFrame:Hide() SlashCmdList.RAIDMAP('bug') group.raid, group.leader = false, false")
    check(ev("RaidMapBugFrame:IsShown()") and ev("has('zone: Black Temple')"), "/rm bug opens it too")
    lua.execute("RaidMapBugFrame:Hide()")

    print("  -- minimap button and options page")
    lua.execute("""
        icon = minimapIcons.RaidMap
        tip = { lines = {} }
        function tip:AddLine(text, r, g, b) self.lines[#self.lines + 1] = { text, r, g, b } end
        function minimapClick(mouse) icon.object.OnClick(nil, mouse) end
        function said(text)
            for _, line in ipairs(printed) do
                if line:find(text, 1, true) then return true end
            end
            return false
        end
        window:Hide()
    """)
    check(ev("icon ~= nil and icon.db == ns.db.profile.minimap and icon.shown")
          and ev("icon.object.icon") == "Interface\\AddOns\\RaidMap\\Art\\Icon" and ev("icon.object.type") == "launcher",
          "the minimap button is registered on the profile's own table, showing, with the addon's icon")
    lua.execute("icon.object.OnTooltipShow(tip)")
    check(ev("#tip.lines") == 3 and ev("tip.lines[1][1] == 'RaidMap' and tip.lines[1][2] == 1 and tip.lines[1][4] == 1")
          and ev("tip.lines[2][1]") == "|cffcfcfcfleft click|r: open or close the editor"
          and ev("tip.lines[3][1]") == "|cffcfcfcfright click|r: quick menu",
          f"hovering names the addon in white and says what each click does ({ev('tip.lines[2][1]')})")
    lua.execute("minimapClick('LeftButton')")
    opened = ev("window:IsShown()")
    lua.execute("minimapClick('LeftButton')")
    check(opened and not ev("window:IsShown()") and ev("easyMenu == nil"),
          "a left click opens the editor and the next one closes it, with no menu")
    lua.execute("LibStub('LibDBIcon-1.0').tooltip:Show() minimapClick('RightButton')")
    check(ev("easyMenu ~= nil and easyMenu.mode == 'MENU' and easyMenu.anchor == 'cursor'")
          and ev("easyMenu.frame == RaidMapMinimapMenu") and not ev("window:IsShown()")
          and not ev("LibStub('LibDBIcon-1.0').tooltip:IsShown()"),
          "a right click puts a menu up at the cursor, takes the tooltip down and leaves the editor shut")
    check(ev("#easyMenu.list") == 2 and ev("easyMenu.list[1].text == 'RaidMap' and easyMenu.list[1].isTitle == true")
          and ev("easyMenu.list[2].text") == "Hide Minimap Icon" and ev("easyMenu.list[2].notCheckable == true"),
          "the menu is the addon's name over one entry, Hide Minimap Icon")
    lua.execute("easyMenu.list[2].func()")
    check(ev("ns.db.profile.minimap.hide == true") and not ev("icon.shown")
          and ev("said('Minimap icon hidden. /rm minimap brings it back')"),
          "picking it hides the icon, remembers that, and says in chat how to get it back")
    lua.execute("SlashCmdList.RAIDMAP('minimap')")
    check(ev("ns.db.profile.minimap.hide == false") and ev("icon.shown") and ev("said('Minimap icon shown.')"),
          "/rm minimap brings it back")
    lua.execute("SlashCmdList.RAIDMAP(' MiniMap ')")
    check(ev("ns.db.profile.minimap.hide == true") and not ev("icon.shown"), "and hides it again, however it is typed")

    check(ev("#addonPages") == 1 and ev("addonPages[1].name") == "RaidMap" and ev("addonPages[1].panel == ns.optionsPanel")
          and not ev("ns.optionsPanel:IsShown()"),
          "Options > AddOns has one RaidMap page, which stays hidden until it is opened there")
    lua.execute("""
        page, tick = ns.optionsPanel, ns.optionsPanel.minimapToggle
        function pageTexts()
            local out = {}
            for _, f in ipairs(frames) do
                if f.kind == "FontString" and f.parent == page then out[#out + 1] = f:GetText() end
            end
            return table.concat(out, " | ")
        end
        page:Show()
    """)
    texts = ev("pageTexts()")
    check(texts == "RaidMap | Minimap | Show minimap icon",
          f"the page is a title, one section heading and one labelled tick, and nothing else ({texts})")
    check(ev("tick:GetChecked() == false"), "opened with the icon hidden, the tick is clear")
    lua.execute("tick:SetChecked(true) tick.scripts.OnClick(tick)")
    check(ev("ns.db.profile.minimap.hide == false") and ev("icon.shown"), "ticking it shows the icon")
    lua.execute("tick:SetChecked(false) tick.scripts.OnClick(tick)")
    check(ev("ns.db.profile.minimap.hide == true") and not ev("icon.shown"), "and unticking hides it")
    lua.execute("page:Hide() SlashCmdList.RAIDMAP('minimap') page:Show()")
    check(ev("tick:GetChecked() == true"), "a change made while the page was shut shows when it is opened again")
    lua.execute("page:Hide()")

    check(ev("SLASH_RAIDMAP1 == '/raidmap' and SLASH_RAIDMAP2 == '/rm' and SlashCmdList.RAIDMAP ~= nil"),
          "/raidmap and /rm are the slash commands")
    errors = [line for line in ev("printed").values() if "failed" in str(line).lower()]
    check(not errors, f"nothing reported a failure along the way {errors or ''}")


if __name__ == "__main__":
    test_client("Anniversary", test_compat.ANNIVERSARY, "Aeva-Starlove")
    test_client("WoW Forever", FOREVER, "Aeva Starlove")
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)
