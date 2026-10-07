#!/usr/bin/env python3
"""Run pack saving and sharing between simulated clients, without the game.

    ~/.venvs/lua/bin/python tools/test_sync.py

Each client is its own Lua 5.1 runtime running the addon's real Model,
Serialize, Comm and Transfer code on the real LibSerialize and LibDeflate.
What is faked: AceComm (a bus that hands whole messages from one runtime to
the others -- no chunking, no throttle), AceDB (a plain table), frames, and
the clock, which only moves when a test advances it.

So this covers the protocol and the data: who asks for what, what each client
ends up holding, what survives a rollback. It does not cover bandwidth, the
UI, or anything the server does to a message.
"""

import os
import sys

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []

STUBS = r"""
now = 0
function GetTime() return now end
function time() return 1791000000 + math.floor(now) end
function GetBuildInfo() return "2.5.6", "69795", "", 20506 end
printed = {}
function print(...) printed[#printed + 1] = tostring((...)) end

timers = {}
local function after(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end
C_Timer = {
    After = after,
    NewTicker = function(period, fn)
        local function tick() fn() after(period, tick) end
        after(period, tick)
    end,
}
function advance(dt)
    local target = now + dt
    while true do
        local best
        for i, t in ipairs(timers) do
            if t.at <= target and (not best or t.at < timers[best].at) then best = i end
        end
        if not best then break end
        local t = table.remove(timers, best)
        now = t.at
        t.fn()
    end
    now = target
end

-- Frames answer any method, remember scripts, events and text.
frames = {}
local function noop() end
local frameMT = { __index = function() return noop end }
function CreateFrame(kind, name)
    local f = setmetatable({ kind = kind, scripts = {}, events = {} }, frameMT)
    function f:SetScript(what, fn) self.scripts[what] = fn end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetText(t) self.text = t end
    function f:GetText() return rawget(self, "text") or "" end
    function f:CreateFontString() return CreateFrame("FontString") end
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end
function click(label)
    for _, f in ipairs(frames) do
        if f.kind == "Button" and rawget(f, "text") == label then return f.scripts.OnClick(f) end
    end
    error("no button labelled " .. label)
end

group = { raid = false, party = false, leader = false, assist = false }
function IsInRaid() return group.raid end
function IsInGroup() return group.raid or group.party end
function UnitIsGroupLeader() return group.leader end
function UnitIsGroupAssistant() return group.assist end
function UnitName() return NAME end
function UnitClass() return "Shaman", "SHAMAN" end
function GetRealmName() return REALM end
function GetNormalizedRealmName() return (REALM:gsub("[%s%-]", "")) end

function strsplit(sep, s)
    local out, pos = {}, 1
    while true do
        local i = s:find(sep, pos, true)
        if not i then out[#out + 1] = s:sub(pos) break end
        out[#out + 1] = s:sub(pos, i - 1)
        pos = i + 1
    end
    return unpack(out)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
UISpecialFrames, UIParent, SlashCmdList = {}, {}, {}

hooks, filters = {}, {}
function hooksecurefunc(name, fn) hooks[name] = fn end
function ChatFrame_AddMessageEventFilter(event, fn) filters[event] = fn end
chatBox = { Insert = function(self, text) typed = text end }
DEFAULT_CHAT_FRAME = { editBox = chatBox }
function ChatEdit_GetActiveWindow() return chatBox end
"""

# Registered through the real LibStub, after it has loaded.
FAKE_LIBS = r"""
local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end
local AceDB = LibStub:NewLibrary("AceDB-3.0", 1)
function AceDB:New(_, defaults) return { profile = copy(defaults.profile), global = {} } end

-- Payloads are binary; they cross between runtimes as hex.
local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function unhex(h) return (h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end)) end

local receive
local AceComm = LibStub:NewLibrary("AceComm-3.0", 1)
function AceComm:Embed(target)
    function target:RegisterComm(_, method) receive = function(...) return target[method](target, ...) end end
    function target:SendCommMessage(prefix, text, distribution, to) BUS(prefix, hex(text), distribution, to) end
end
function deliver(prefix, text, distribution, sender)
    if receive then receive(prefix, unhex(text), distribution, sender) end
end
"""

HELPERS = r"""
ns.Catalog = { DefaultKey = function() return "blank" end }
ns.Roster = { specs = {}, Build = function() end, GetPlayerSpec = function() end }
function ns.SwitchSlide(index) shownSlide = index end

function slideOf(boardIndex)
    local pack = ns:CurrentPack()
    pack.currentBoard = boardIndex or pack.currentBoard
    local board = ns:CurrentBoard()
    return board.slides[board.currentSlide or 1], board
end
function addMarker(boardIndex, x, y)
    local slide, board = slideOf(boardIndex)
    return ns.Model:AddElement(slide, ns.Model:NewElement(board, "marker", x or 0.5, y or 0.5, { index = 1 }))
end

-- Order-independent text of a value, so two clients' copies can be compared.
local function dump(v, skip)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do
        if not skip[k] then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for i, k in ipairs(keys) do keys[i] = tostring(k) .. "=" .. dump(v[k], skip) end
    return "{" .. table.concat(keys, ",") .. "}"
end
function boardsOf(uid)
    local pack = ns.db.profile.packs[uid]
    return pack and dump(pack.boards, { currentSlide = true }) or "no such pack"
end
function packCount()
    local n = 0
    for _ in pairs(ns.db.profile.packs) do n = n + 1 end
    return n
end
"""

FILES = ("Core/Init.lua", "Core/Serialize.lua", "Core/Comm.lua", "Model/Board.lua", "Model/Pack.lua",
         "UI/Transfer.lua")


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


class Client:
    def __init__(self, world, name, realm):
        self.world, self.name, self.realm = world, name, realm
        self.online = True
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.NAME, g.REALM = name, realm
        g.BUS = lambda prefix, text, dist, to: world.send(self, prefix, text, dist, to)
        # Every runtime starts from the same seed; ids must not collide by accident.
        self.lua.execute(f"math.randomseed({sum(name.encode()) * 7919})")
        self.lua.execute(STUBS)
        load = self.lua.eval("""function(path, src)
            local f = assert(loadstring(src, "@" .. path))
            return f("RaidMap", ns)
        end""")

        def run_file(rel):
            with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
                load(rel, f.read())

        self.lua.execute("ns = {}")
        for lib in ("Libs/LibStub/LibStub.lua", "Libs/LibSerialize/LibSerialize.lua", "Libs/LibDeflate/LibDeflate.lua"):
            run_file(lib)
        self.lua.execute(FAKE_LIBS)
        for rel in FILES:
            run_file(rel)
        self.lua.execute(HELPERS)
        self.lua.execute('fire("ADDON_LOADED", "RaidMap")')
        self.lua.execute("ns.Pack:Migrate()")   # MainFrame does this on READY

    def do(self, code):
        self.lua.execute(code)

    def get(self, expr):
        return self.lua.eval(expr)

    def group(self, **flags):
        for k, v in flags.items():
            self.lua.execute(f"group.{k} = {'true' if v else 'false'}")

    def whisper_names(self):
        return {self.name, self.name + "-" + self.realm.replace(" ", "").replace("-", "")}

    def said(self, text):
        return any(text in line for line in self.lua.eval("printed").values())


class World:
    def __init__(self, realm="Dreamscythe"):
        self.realm, self.clients, self.queue, self.log = realm, [], [], []

    def join(self, name, **flags):
        c = Client(self, name, self.realm)
        c.group(**flags)
        self.clients.append(c)
        return c

    def send(self, sender, prefix, text, dist, to):
        self.queue.append((sender, prefix, text, dist, to))

    def deliver(self):
        while self.queue:
            sender, prefix, text, dist, to = self.queue.pop(0)
            op = bytes.fromhex(text[:2]).decode()
            if dist == "WHISPER":
                got = [c for c in self.clients if c.online and to in c.whisper_names()]
            else:   # group broadcasts echo to the sender too, as in game
                got = [c for c in self.clients if c.online and c.get("IsInGroup()")]
            self.log.append({"from": sender.name, "op": op, "dist": dist, "to": to, "got": [c.name for c in got]})
            for c in got:
                c.lua.globals().deliver(prefix, text, dist, sender.name)

    def run(self, seconds=6):
        self.deliver()
        for _ in range(int(seconds / 0.25)):
            for c in self.clients:
                c.lua.globals().advance(0.25)
            self.deliver()

    def sent(self, since, op, **match):
        return [m for m in self.log[since:] if m["op"] == op and all(m[k] == v for k, v in match.items())]


def same(uid, *clients):
    first = clients[0].get(f'boardsOf("{uid}")')
    return first != "no such pack" and all(c.get(f'boardsOf("{uid}")') == first for c in clients[1:])


def test_raid():
    print("\nPublish and delta sync in a raid")
    w = World()
    a = w.join("Aly", raid=True, leader=True)
    b = w.join("Bek", raid=True, assist=True)
    c = w.join("Cid", raid=True)
    d = w.join("Dov", raid=True)

    a.do('ns.Pack:Rename(ns:CurrentPack(), "BT guild"); ns.Pack:AddBoard(ns:CurrentPack())')
    a.do("addMarker(1, 0.2, 0.2); addMarker(1, 0.3, 0.3); addMarker(2, 0.6, 0.6)")
    uid = a.get("ns:CurrentPack().uid")
    own = b.get("ns:CurrentPack().uid")

    a.do("ns.Comm:PublishPack()")
    w.run()
    check(same(uid, a, b, c, d), "first publish: all three raiders hold the leader's two boards")
    check(len(w.sent(0, "D", dist="RAID")) == 2 and not w.sent(0, "D", dist="WHISPER"),
          "three requesters -> each board broadcast once, no whispers")
    check(b.get("ns:CurrentPack().uid") == own, "a pack you have never seen does not take over your view")

    mark = len(w.log)
    a.do("addMarker(2, 0.7, 0.7); ns.Comm:PublishPack()")
    w.run()
    check(same(uid, a, b, c, d) and len(w.sent(mark, "D")) == 1, "editing one board moves one board")

    d.online = False
    mark = len(w.log)
    a.do("addMarker(1, 0.4, 0.4); ns.Comm:PublishPack()")
    w.run()
    check(len(w.sent(mark, "D", dist="WHISPER")) == 2 and not w.sent(mark, "D", dist="RAID"),
          "two requesters -> whispered, not broadcast")
    d.online = True
    mark = len(w.log)
    a.do("ns.Comm:AnnounceManifest(ns:CurrentPack())")
    w.run()
    check(same(uid, a, d) and len(w.sent(mark, "R")) == 1, "a re-announce catches up whoever missed it, and only them")

    mark = len(w.log)
    a.do('ns.Pack:Rename(ns:CurrentPack(), "BT guild v2"); ns.Comm:PublishPack()')
    w.run()
    check(b.get(f'ns.db.profile.packs["{uid}"].title') == "BT guild v2" and not w.sent(mark, "R"),
          "a retitle travels in the manifest; no board is fetched")

    a.do('ns.Pack:RenameBoard(ns:CurrentPack(), 1, "Najentus"); ns.Comm:PublishPack()')
    w.run()
    check(b.get(f'ns.db.profile.packs["{uid}"].boards[1].name') == "Najentus", "a board rename reaches the raid")

    # A raider fiddles with their copy, then the leader changes the same board.
    c.do(f'ns.Pack:Select("{uid}")')
    c.do("local s = slideOf(1); for i = 1, 5 do local e = s.elements[1]; ns.Model:MoveElement(e, e.x, e.y, i / 10, 0.9) end")
    a.do("addMarker(1, 0.8, 0.1); ns.Comm:PublishPack()")
    w.run()
    check(same(uid, a, c), "local edits on a raider's copy do not block the leader's next update")

    # The leader publishes a mistake, rolls back from history, publishes again.
    good = a.get(f'boardsOf("{uid}")')
    a.do("ns.Model:ClearSlide((slideOf(1))); ns.Comm:PublishPack()")
    w.run()
    a.do("ns.Pack:RestoreRevision(ns:CurrentPack(), 2); ns.Comm:PublishPack()")
    w.run()
    check(a.get(f'boardsOf("{uid}")') == good and same(uid, a, b, c, d), "restoring a revision and publishing rolls the raid back")

    # A second manifest for a transfer already in flight (roster churn does this).
    mark = len(w.log)
    a.do("addMarker(2, 0.1, 0.1); ns.Comm:PublishPack()")
    w.deliver()
    a.do("ns.Comm:AnnounceManifest(ns:CurrentPack())")
    w.run()
    check(len([m for m in w.sent(mark, "R") if m["from"] == "Bek"]) == 1 and same(uid, a, b),
          "a repeated manifest does not restart a transfer that is already running")

    # An assistant publishes twice while the leader is not listening, then the
    # leader takes the update, dislikes it, and restores what they had.
    before = a.get(f'boardsOf("{uid}")')
    a.do("ns.db.profile.pauseSync = true")
    b.do(f'ns.Pack:Select("{uid}"); ns.Model:ClearSlide((slideOf(1))); ns.Comm:PublishPack()')
    w.run()
    b.do("addMarker(1, 0.5, 0.5); ns.Comm:PublishPack()")
    w.run()
    check(a.get("ns.Comm.pendingManifest ~= nil") and a.get(f'boardsOf("{uid}")') == before, "paused: the update is held, not applied")
    a.do("ns.db.profile.pauseSync = nil; ns.Comm:ApplyPending()")
    w.run()
    check(same(uid, a, b), "Apply takes the held update")
    a.do('SlashCmdList.RAIDMAP("restore"); ns.Comm:PublishPack()')
    w.run()
    check(a.get(f'boardsOf("{uid}")') == before and same(uid, a, b, c, d), "/rm restore then publish wins over a pack two revisions ahead")

    # Author lock.
    a.do("ns:CurrentPack().locked = true; ns.Comm:PublishPack()")
    w.run()
    rev = b.get(f'ns.db.profile.packs["{uid}"].revision')
    b.do(f'ns.Pack:Select("{uid}"); addMarker(1, 0.5, 0.5); ns.Comm:PublishPack()')
    w.run()
    check(b.said("is locked by") and a.get(f'ns.db.profile.packs["{uid}"].revision') == rev,
          "an assistant cannot publish over a pack its author locked")

    # Sender disappears mid-transfer.
    a.do("ns:CurrentPack().locked = nil; addMarker(2, 0.2, 0.9); ns.Comm:PublishPack()")
    a.online = False
    w.run(65)   # 45s timeout, checked every 15s
    check(c.said("Gave up receiving"), "a transfer whose sender vanished is abandoned after the timeout")
    a.online = True
    a.do("ns.Comm:AnnounceManifest(ns:CurrentPack())")
    w.run()
    check(same(uid, a, b, c, d), "and completes on the next announce")


def test_duplicate():
    print("\nDuplicate and fork")
    w = World()
    a = w.join("Aly", party=True)
    a.do("addMarker(1); ns.Comm:PublishPack(); addMarker(1); ns.Comm:PublishPack()")
    uid = a.get("ns:CurrentPack().uid")
    rev = a.get("ns:CurrentPack().revision")
    a.do("copy = ns.Pack:Duplicate(ns:CurrentPack()); ns.Pack:Select(copy.uid)")
    check(a.get("copy.uid") != uid and a.get("boardsOf(copy.uid)") == a.get(f'boardsOf("{uid}")'), "a duplicate is a new pack with the same boards")
    a.do("ns.Pack:RestoreRevision(copy, 1)")
    check(a.get("ns.db.profile.currentPack == copy.uid") and a.get(f'ns.db.profile.packs["{uid}"].revision') == rev,
          "restoring inside a duplicate cannot reach back into the pack it was copied from")


def test_party():
    print("\nAutomatic propagation in a party")
    w = World()
    x = w.join("Xan", party=True)
    y = w.join("Yul", party=True)
    for c in (x, y):
        c.do('fire("GROUP_ROSTER_UPDATE")')
    w.run(8)
    check(y.get("packCount()") == 1 and x.get("packCount()") == 1, "packs nobody published are not traded just for grouping up")

    x.do("addMarker(1); ns.Comm:PublishPack()")
    w.run()
    uid = x.get("ns:CurrentPack().uid")
    check(same(uid, x, y), "anyone in a party can publish")

    z = w.join("Zed", party=True)
    w.run(11)   # past the announce throttle
    x.do('fire("GROUP_ROSTER_UPDATE")')
    w.run(8)
    check(same(uid, x, z), "someone who joins later is sent the published pack without anyone acting")


def test_strings_and_links(realm):
    print(f"\nExport, import and chat links on realm '{realm}'")
    w = World(realm)
    a = w.join("Aly")
    f = w.join("Fen")
    a.do('ns.Pack:Rename(ns:CurrentPack(), "Kara Week 1"); addMarker(1, 0.25, 0.75); ns.Pack:AddBoard(ns:CurrentPack())')
    uid = a.get("ns:CurrentPack().uid")

    a.do("ns.ShowExport()")
    text = a.get("RaidMapExportFrame.edit:GetText()")
    f.do("ns.ShowImport()")
    f.lua.globals().RaidMapImportFrame.edit.SetText(f.lua.globals().RaidMapImportFrame.edit, text)
    f.do('click("Import")')
    check(same(uid, a, f) and f.get("ns:CurrentPack().uid") == uid, f"export string ({len(text)} chars) imports to an identical pack and opens it")
    before = f.get("packCount()")
    f.do('click("Import")')
    check(f.get("packCount()") == before and f.said("You already have"), "importing the same string twice changes nothing")

    g = w.join("Gil")
    a.do("ns.LinkPackInChat()")
    line = a.get("typed")
    shown = g.lua.eval("function(line) return (select(2, filters.CHAT_MSG_GUILD(nil, 'CHAT_MSG_GUILD', line, 'Aly'))) end")(line)
    check(shown is not None and "|Hgarrmission:raidmap|h" in shown, f"chat text becomes a link: {line}")
    g.lua.globals().hooks.SetItemRef("garrmission:raidmap", shown)
    w.run()
    asked = w.sent(0, "L")
    check(bool(asked) and asked[0]["got"] == ["Aly"], f"clicking it reaches the author (whisper to '{asked[0]['to'] if asked else None}')")
    check(same(uid, a, g), "and the pack arrives")


if __name__ == "__main__":
    test_raid()
    test_duplicate()
    test_party()
    test_strings_and_links("Dreamscythe")
    test_strings_and_links("Classic Beta PvP 2")
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)
