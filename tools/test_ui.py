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
-- Except what a dropdown shows and what its menu lists, which are kept so they
-- can be read back.
function LibDD:UIDropDownMenu_SetText(dropdown, text) dropdown._text = text end
function LibDD:UIDropDownMenu_Initialize(dropdown, build) dropdown.build = build end
function LibDD:UIDropDownMenu_AddButton(info) menu[#menu + 1] = info.text end
function menuOf(dropdown)
    menu = {}
    dropdown.build(dropdown, 1)
    return table.concat(menu, " / ")
end
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
        ns.SwitchSlide(1, true)
    """)
    check(ev("canvas.drawW") is not None, "canvas lays out the blank map")
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
    lua.execute("click(strip.nextButton) ns.SwitchSlide(9, true)")
    check(ev("tabsShown()")[0] == "7 8 9 10 11 12", "a slide change arriving for a tab already showing does not move the run")
    lua.execute("ns.SwitchSlide(3, true)")
    check(ev("tabsShown()")[0] == "3 4 5 6 7 8", "one for a tab out of sight scrolls just far enough to show it")
    lua.execute("ns.SwitchSlide(12, true) strip:SetWidth(412)")
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
    lua.execute("ns.SwitchSlide(1, true) before = #elements()")
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
    lua.execute("click(strip.deleteButton) ns.SwitchSlide(1, true)")

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
        ns.SelectBoard(second)
    """)
    check((ev("framing(other)"), ev("showing()")) == ("0.30 0.60 x3.00", "0.30 0.60 x3.00"),
          f"a board opens framed the way it was saved, not the way the last one was left ({ev('framing(other)')})")
    lua.execute("ns.SelectBoard(1)")
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

    check(ev("SLASH_RAIDMAP1 == '/raidmap' and SLASH_RAIDMAP2 == '/rm' and SlashCmdList.RAIDMAP ~= nil"),
          "/raidmap and /rm are the slash commands")
    errors = [line for line in ev("printed").values() if "failed" in str(line).lower()]
    check(not errors, f"nothing reported a failure along the way {errors or ''}")


if __name__ == "__main__":
    test_client("Anniversary", test_compat.ANNIVERSARY, "Aeva-Starlove")
    test_client("WoW Forever", FOREVER, "Aeva Starlove")
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)
