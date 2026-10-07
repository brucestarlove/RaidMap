#!/usr/bin/env python3
"""Run the client-compatibility code paths under Lua 5.1 with stubbed WoW APIs.

    ~/.venvs/lua/bin/python tools/test_compat.py

Covers what differs between TBC Anniversary and WoW Forever: flavor detection,
event registration on clients that lack an event, secret-value guards, spec
detection, the chat-link code on both chat APIs, and the StaticPopup rename
dialogs. A fake "secret" value throws on any use, the way the real ones do, so
a missing guard fails loudly.
"""

import os
import sys

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []

COMMON = r"""
SECRET = setmetatable({}, {
    __index = function() error("secret value used", 2) end,
    __eq = function() error("secret value compared", 2) end,
    __concat = function() error("secret value concatenated", 2) end,
    __tostring = function() error("secret value stringified", 2) end,
})
function issecretvalue(v) return rawequal(v, SECRET) end

registered = {}
function CreateFrame()
    local f = {}
    function f:RegisterEvent(e)
        if e == "BOGUS_EVENT" then error("Attempt to register unknown event") end
        registered[e] = true
    end
    function f:UnregisterEvent() end
    function f:SetScript() end
    return f
end
time = os.time
hooks = {}
function hooksecurefunc(name, fn) hooks[name] = fn end
printed = {}
"""


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def runtime(setup, files):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(COMMON)
    lua.execute(setup)
    lua.execute("ns = {}")
    loader = lua.eval("""function(path, src)
        local f = assert(loadstring(src, "@" .. path))
        return f("RaidMap", ns)
    end""")
    for rel in files:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            loader(rel, f.read())
    lua.execute('function ns:Print(fmt, ...) printed[#printed + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end')
    return lua


def run(lua, code):
    """Execute Lua; return (ok, result-or-error)."""
    try:
        return True, lua.execute(code)
    except lua51.LuaError as e:
        return False, str(e)


FOREVER = """
WOW_PROJECT_MAINLINE, WOW_PROJECT_CLASSIC, WOW_PROJECT_CAMELOT = 1, 2, 18
WOW_PROJECT_ID = WOW_PROJECT_CAMELOT
function GetBuildInfo() return "1.60.1", "70205", "", 16001 end
C_EventUtils = { IsEventValid = function(e) return e ~= "CHARACTER_POINTS_CHANGED" end }
C_SpecializationInfo = {
    GetSpecialization = function() return 2 end,
    GetSpecializationInfo = function(i) return 65, "Holy", "", 135920, "HEALER" end,
}
"""

ANNIVERSARY = """
WOW_PROJECT_MAINLINE, WOW_PROJECT_CLASSIC = 1, 2
WOW_PROJECT_ID = 5
function GetBuildInfo() return "2.5.6", "69795", "", 20506 end
function GetNumTalentTabs() return 3 end
function GetTalentTabInfo(i)
    local tabs = { {"Holy", 135920, 11}, {"Protection", 135893, 0}, {"Retribution", 135873, 41} }
    return i, tabs[i][1], "", tabs[i][2], tabs[i][3]
end
C_SpecializationInfo = { GetSpecialization = function() return nil end, GetSpecializationInfo = function() end }
"""


def test_init():
    print("\nFlavor detection and helpers (Core/Init.lua)")
    lua = runtime(FOREVER, ["Core/Init.lua"])
    check(lua.eval("ns.FLAVOR") == "forever", "Forever (project 18, interface 16001) -> forever")
    lua = runtime(ANNIVERSARY, ["Core/Init.lua"])
    check(lua.eval("ns.FLAVOR") == "tbc", "Anniversary (interface 20506) -> tbc")
    lua = runtime('function GetBuildInfo() return "1.15.9", "1", "", 11509 end', ["Core/Init.lua"])
    check(lua.eval("ns.FLAVOR") == "vanilla", "Classic Era (11509) -> vanilla")

    lua = runtime(FOREVER, ["Core/Init.lua"])
    ok, err = run(lua, 'ns.RegisterEvents(CreateFrame(), "GROUP_ROSTER_UPDATE", "CHARACTER_POINTS_CHANGED", "TRAIT_CONFIG_UPDATED")')
    check(ok, f"RegisterEvents with C_EventUtils raises nothing {err or ''}")
    check(lua.eval("registered.GROUP_ROSTER_UPDATE and registered.TRAIT_CONFIG_UPDATED and not registered.CHARACTER_POINTS_CHANGED"),
          "invalid event skipped, valid ones registered")
    lua.execute("C_EventUtils = nil")
    ok, err = run(lua, 'ns.RegisterEvents(CreateFrame(), "BOGUS_EVENT", "PLAYER_ENTERING_WORLD")')
    check(ok and lua.eval("registered.PLAYER_ENTERING_WORLD"), "without C_EventUtils an unknown event is swallowed")

    check(lua.eval("ns.AnySecret(1, 'a', SECRET)") is True, "AnySecret spots a secret among plain values")
    check(lua.eval("ns.AnySecret(1, nil, 'a')") is False, "AnySecret passes plain values (and nil)")


ROSTER_STUBS = """
function IsInRaid() return raidMode end
function IsInGroup() return raidMode end
function GetNumGroupMembers() return 2 end
function GetRaidRosterInfo(i)
    if secretRoster then return SECRET, nil, 1, nil, nil, "PRIEST", nil, true, false end
    return ({"Alice", "Bob"})[i], nil, 1, nil, nil, ({"PRIEST", "MAGE"})[i], nil, true, false
end
function UnitName() return "Alice" end
function UnitClass() return "Priest", "PRIEST" end
"""


def test_roster():
    print("\nSpec detection and roster guards (Core/Roster.lua)")
    lua = runtime(FOREVER + ROSTER_STUBS, ["Core/Init.lua", "Core/Roster.lua"])
    name, icon = lua.eval("ns.Roster:GetPlayerSpec()")
    check((name, icon) == ("Holy", 135920), f"Forever: spec from C_SpecializationInfo ({name}, {icon})")
    check(lua.eval("registered.PLAYER_SPECIALIZATION_CHANGED and registered.TRAIT_CONFIG_UPDATED"),
          "Forever: spec events registered")

    lua.execute("raidMode = true")
    ok, err = run(lua, "ns.Roster:Build()")
    check(ok and lua.eval("#ns.Roster.entries") == 2, f"raid roster builds normally {err or ''}")
    lua.execute("secretRoster = true")
    ok, err = run(lua, "ns.Roster:Build()")
    check(ok, f"secret roster identity does not throw {err or ''}")
    check(lua.eval("#ns.Roster.entries == 2 and ns.Roster.entries[1].name == 'Alice'"),
          "secret roster keeps the last good entries")

    lua = runtime(ANNIVERSARY + ROSTER_STUBS, ["Core/Init.lua", "Core/Roster.lua"])
    name, icon = lua.eval("ns.Roster:GetPlayerSpec()")
    check((name, icon) == ("Retribution", 135873), f"Anniversary: spec still from talent tabs ({name})")
    check(lua.eval("registered.CHARACTER_POINTS_CHANGED"), "Anniversary: talent event registered")


TRANSFER_STUBS = """
filters = {}
inserted = {}
editBox = { Insert = function(self, text) inserted[#inserted + 1] = text end }
DEFAULT_CHAT_FRAME = { editBox = editBox }
"""
MODERN_CHAT = """
ChatFrameUtil = {
    AddMessageEventFilter = function(event, fn) filters[event] = fn end,
    GetActiveWindow = function() return nil end,
    ChooseBoxForSend = function() return editBox end,
    ActivateChat = function(box) activated = box end,
}
"""
OLD_CHAT = """
function ChatFrame_AddMessageEventFilter(event, fn) filters[event] = fn end
function ChatEdit_GetActiveWindow() return editBox end
"""
PACK = """
function ns:CurrentPack() return { title = "Kara Week 1" } end
ns.Pack = { AuthorName = function() return "Lavitz" end, WhisperName = function() return "Lavitz" end }
"""


def test_transfer():
    print("\nChat links (UI/Transfer.lua)")
    for label, setup in (("Forever (ChatFrameUtil)", FOREVER + MODERN_CHAT), ("Anniversary (old globals)", ANNIVERSARY + OLD_CHAT)):
        lua = runtime(setup + TRANSFER_STUBS, ["Core/Init.lua", "UI/Transfer.lua"])
        lua.execute(PACK)
        check(lua.eval("filters.CHAT_MSG_RAID ~= nil"), f"{label}: chat filter registered")
        ok, err = run(lua, "ns.LinkPackInChat()")
        check(ok and lua.eval("inserted[1]") == "[RaidMap: Kara Week 1 from Lavitz]", f"{label}: link text inserted {err or ''}")

        result = lua.eval('{ filters.CHAT_MSG_RAID(nil, "CHAT_MSG_RAID", "see [RaidMap: Kara Week 1 from Lavitz] pls", "Lavitz") }')
        check(result[1] is False and "|Hgarrmission:raidmap|h" in (result[2] or ""), f"{label}: plain text rewritten to a link")
        ok, err = run(lua, 'filtered = { filters.CHAT_MSG_RAID(nil, "CHAT_MSG_RAID", SECRET, "x") }')
        check(ok and lua.eval("filtered[1] == false and filtered[2] == nil"), f"{label}: secret chat text passed through untouched {err or ''}")
        ok, err = run(lua, 'hooks.SetItemRef(SECRET, SECRET)')
        check(ok, f"{label}: SetItemRef hook ignores secret arguments {err or ''}")

        lua.execute("ns.Comm = { RequestLinkedPack = function(_, author, title) requested = { author, title } end }")
        lua.execute('ns.Pack.WhisperName = function() return "Someone" end')
        link = result[2]
        ok, err = run(lua, f'hooks.SetItemRef("garrmission:raidmap", {lua.eval("string.format")("%q", link)})')
        check(ok and lua.eval("requested and requested[1] == 'Lavitz' and requested[2] == 'Kara Week 1'"),
              f"{label}: clicking the link asks the author for the pack {err or ''}")


DIALOG_STUBS = """
StaticPopupDialogs = {}
function LibStub() return {} end
"""
DIALOG_WORLD = """
board = { name = "Illidan", currentSlide = 1, slides = { { name = "P1" } } }
pack = { title = "BT guild", currentBoard = 1, boards = { board } }
function ns:CurrentPack() return pack end
function ns:CurrentBoard() return board end
ns.Pack = {
    New = function(_, name) return { title = name, uid = name } end,
    Add = function(_, p) added = p; return p end,
    Select = function() end,
    Rename = function(_, p, name) p.title = name end,
    RenameBoard = function(_, p, index, name) p.boards[index].name = name end,
}
ns.Model = { RenameSlide = function(_, b, index, name) b.slides[index].name = name end }

-- A StaticPopup as the client hands it to a dialog's callbacks. "GameDialog"
-- is the frame both clients ship (Blizzard_StaticPopup_Game/GameDialog.xml:
-- parentKey="EditBox", GameDialogMixin:GetEditBox); it has no .editBox.
-- data is StaticPopup_Show's fourth argument, which it keeps at dialog.data
-- and passes to OnShow and OnAccept after the dialog.
function popup(shape, data)
    local dialog = { data = data, Hide = function(self) self.hidden = true end }
    local box = { text = "" }
    function box:SetText(t) self.text = t end
    function box:GetText() return self.text end
    function box:HighlightText() end
    function box:SetFocus() self.focused = true end
    function box:GetParent() return dialog end
    if shape == "GameDialog" then
        dialog.EditBox = box
        function dialog:GetEditBox() return self.EditBox end
    else
        dialog.editBox = box
    end
    return dialog, box
end
"""
# Name, what the box is prefilled with, where the new text lands, and the data
# the dialog is shown with.
DIALOGS = (
    ("RAIDMAP_RENAME_BOARD", "Illidan", "board.name", "nil"),
    ("RAIDMAP_RENAME_PACK", "BT guild", "pack.title", "nil"),
    ("RAIDMAP_RENAME_SLIDE", "P1", "board.slides[1].name", "board.slides[1]"),
    ("RAIDMAP_NEW_PACK", "", "added.title", "nil"),
)


def test_dialogs():
    print("\nRename dialogs (UI/Library.lua, UI/Filmstrip.lua)")
    for label, shape in (("both clients (GameDialog)", "GameDialog"), ("pre-GameDialog UI", "legacy")):
        for name, initial, result, data in DIALOGS:
            lua = runtime(FOREVER + DIALOG_STUBS, ["Core/Init.lua", "UI/Library.lua", "UI/Filmstrip.lua"])
            lua.execute(DIALOG_WORLD)
            ok, err = run(lua, f"""
                info = StaticPopupDialogs.{name}
                dialog, box = popup("{shape}", {data})
                info.OnShow(dialog, dialog.data)
                shown, focused = box.text, box.focused
                box:SetText("Via button")
                info.OnAccept(dialog, dialog.data)
            """)
            check(ok and lua.eval("shown") == initial and lua.eval("focused") and lua.eval(result) == "Via button",
                  f"{label}: {name} prefills '{initial}', Accept applies the text {err or ''}")
            ok, err = run(lua, f"""
                dialog, box = popup("{shape}", {data})
                info.OnShow(dialog, dialog.data)
                box:SetText("Via enter")
                info.EditBoxOnEnterPressed(box)
                entered = dialog.hidden
                dialog, box = popup("{shape}", {data})
                info.EditBoxOnEscapePressed(box)
            """)
            check(ok and lua.eval(result) == "Via enter" and lua.eval("entered and dialog.hidden"),
                  f"{label}: {name} Enter applies and closes, Escape closes {err or ''}")


if __name__ == "__main__":
    test_init()
    test_roster()
    test_transfer()
    test_dialogs()
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)
