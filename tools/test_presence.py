#!/usr/bin/env python3
"""Exercise group status between real addon runtimes, including old clients."""

import test_sync as sync


def roster(world, members=None):
    members = members if members is not None else world.clients
    for client in world.clients:
        g = client.lua.globals()
        g.members = client.lua.table_from({
            i + 1: client.lua.table_from({"name": c.name, "suffix": c.surname or c.realm.replace(" ", "").replace("-", "")})
            for i, c in enumerate(members)
        })
        client.do("""
            function GetNumGroupMembers() return #members end
            function UnitFullName(unit)
                if unit == 'player' then return NAME, SURNAME or REALM end
                local index = tonumber(unit:match('raid(%d+)'))
                local member = index and members[index]
                if member then return member.name, member.suffix end
            end
            function UnitIsConnected() return true end
            if SURNAME then UnitNameUnmodified = UnitFullName end
        """)


def status(client, name):
    return client.lua.eval("""function(name)
        for _, row in ipairs(ns.Comm:GetGroupStatus()) do
            if row.name == name then return row end
        end
    end""")(name)


def test_presence():
    print("Group versions, viewers and old clients")
    w = sync.World()
    a = w.join("Aly", raid=True, leader=True)
    b = w.join("Bek", raid=True)
    c = w.join("Cid", raid=True)
    roster(w)
    for client, version in ((a, "1.2.0"), (b, "v1.10.0"), (c, "1.0.0")):
        client.lua.globals().ns.VERSION = version
        client.do("function ns.IsPresentationShown() return showing or false end")
    c.do("function ns.Comm:BroadcastPresence() end")  # a client without the new status opcode
    a.do("ns.Comm:PublishPack()")
    w.run()
    uid = a.get("ns:CurrentPack().uid")
    b.do(f'ns.Pack:Select("{uid}") showing = true ns.Comm:BroadcastPresence(true)')
    c.do("ns.Comm:BroadcastSpec()")
    w.run()
    rows = a.get("ns.Comm:GetGroupStatus()")
    assert rows[1:] == (1, 3, 1, 2, "v1.10.0"), rows[1:]
    assert status(a, "Aly-Dreamscythe").outdated
    assert not status(a, "Bek-Dreamscythe").outdated
    assert status(a, "Cid-Dreamscythe").state == "Unknown"
    print("  ok  numeric version comparison, current-pack viewers and a legacy client's unknown state")

    b.do("local pack = ns.Pack:Add(ns.Pack:New('Other pack')) ns.Pack:Select(pack.uid)")
    w.run(3)
    assert a.get("ns.Comm:GetGroupStatus()")[1:4] == (1, 3, 0)
    assert status(a, "Bek-Dreamscythe").state == "Other pack"
    b.do("showing = false ns.Comm:BroadcastPresence()")
    w.run(3)
    assert a.get("ns.Comm:ViewerCount()") == (0, 3, 0)
    assert status(a, "Bek-Dreamscythe").state == "Closed"
    print("  ok  switching packs and closing Present are reflected immediately")

    # Private whispers and messages from someone outside the roster cannot add viewers.
    a.do("""
        local message = 'P' .. string.char(1) .. '99.0.0' .. string.char(2) .. '1' .. string.char(2) .. 'fake'
        ns.Comm:OnCommReceived('RaidMap', message, 'RAID', 'Stranger-Dreamscythe')
        ns.Comm:OnCommReceived('RaidMap', message, 'WHISPER', 'Cid-Dreamscythe')
        ns.Comm:OnCommReceived('RaidMap', 'P' .. string.char(1) .. 'bad', 'RAID', 'Cid')
    """)
    assert a.get("ns.Comm:ViewerCount()") == (0, 3, 0)
    assert a.get("ns.Comm:GetGroupStatus()")[5] == "v1.10.0"
    print("  ok  strangers, private packets and malformed status do not change group status")

    b.do("showing = true ns.Comm:BroadcastPresence()")
    w.run(3)
    b.do("function ns.Comm:BroadcastPresence() end")
    w.run(95)
    assert a.get("ns.Comm:ViewerCount()") == (0, 3, 0)
    assert status(a, "Bek-Dreamscythe").state == "Unknown"
    print("  ok  a missing heartbeat expires an open viewer rather than leaving a permanent count")

    roster(w, [a, c])
    a.do("fire('GROUP_ROSTER_UPDATE')")
    assert a.get("ns.Comm:ViewerCount()") == (0, 2, 0)
    assert a.get("ns.Comm:GetGroupStatus()")[5] == "1.2.0"
    roster(w)
    a.do("fire('GROUP_ROSTER_UPDATE')")
    assert status(a, "Bek-Dreamscythe").state == "No reply"
    print("  ok  leaving removes the player and their version; rejoining has no stale state")

    a.do("group.raid = false group.party = false fire('GROUP_ROSTER_UPDATE')")
    assert a.get("ns.Comm:ViewerCount()") == (0, 0, 0)
    print("  ok  solo mode and demo roster entries do not count as raid viewers")


def test_surnames():
    print("Forever names")
    w = sync.World(realm="Classic Beta PvP 2", sender_sep=" ")
    a = w.join("Aeva", surname="Starlove", raid=True, leader=True)
    b = w.join("Aeva", surname="Other", raid=True)
    roster(w)
    for client in (a, b):
        client.do("ns.VERSION = '1.2.0' function ns.IsPresentationShown() return true end ns.Comm:BroadcastPresence(true)")
    w.run()
    assert a.get("ns.Comm:ViewerCount()") == (2, 2, 1)
    assert status(a, "Aeva-Other").version == "1.2.0"
    assert status(a, "Aeva-Starlove").mine
    print("  ok  characters sharing a first name stay distinct; space-form senders match their surnames")


def test_versions():
    w = sync.World()
    a = w.join("Aly")
    compare = a.get("ns.Comm.CompareVersions")
    for left, right, expected in [
        ("v1.2.0", "1.2.0", 0), ("1.10.0", "1.9.9", 1),
        ("1.2.0-beta.2", "1.2.0-rc.1", -1), ("1.2.0-rc.1", "1.2.0", -1),
        ("1.2.0-alpha.10", "1.2.0-alpha.2", 1), ("dev", "1.2.0", None),
        ("1.2.0", None, None),
    ]:
        assert compare(left, right) == expected, (left, right)
    print("  ok  release tags, prereleases, development labels and unknown versions compare correctly")


if __name__ == "__main__":
    test_presence()
    test_surnames()
    test_versions()
    print("\n0 failure(s)")
