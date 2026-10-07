# RaidMap — Implementation Plan

Working name. Folder name is baked into texture paths, so rename before Phase 1
art lands or not at all.

A raid strategy board for WoW: zone/raid maps, drag-and-drop player tokens,
multi-slide phase sequences, notes, live sharing to the raid, and importable
"packs" in the WeakAuras mould.

---

## 0. Environment (verified, not assumed)

One source tree serves two clients. The repo lives at
`C:\Users\bruce\git\RaidMap` (`/mnt/c/Users/bruce/git/RaidMap`); each
client's `Interface\AddOns\RaidMap` is a Windows **directory junction** to it,
so a launcher repair or uninstall cannot take the repo with it.

| Fact | TBC Anniversary | WoW Forever beta |
|---|---|---|
| Folder | `_anniversary_` | `_classic_beta_` |
| Build | 2.5.6 (69795) | 1.60.1 (70205) |
| Interface | 20506 | **16001** (classic-range number, retail UI) |
| `WOW_PROJECT_ID` | 5 (C-defined) | `WOW_PROJECT_CAMELOT` = 18 — codename **Camelot** |
| TOC | `## Interface: 20506, 16001` (one TOC; Forever's own suffix would be `_Camelot.toc`) | |
| SavedVariables | `WTF/Account/PEANUTBOY13/SavedVariables/` | `WTF/Account/1128289#4/SavedVariables/` |
| UI source | `Gethe/wow-ui-source` branch `classic_anniversary` | same repo, branch **`forever`** |

`ns.FLAVOR` (`Core/Init.lua`) is `tbc` / `forever` / `vanilla`. It decides
**content only** (which instances the menu offers, the default map). API
differences are always feature-detected at the call site.

### WoW Forever (`_classic_beta_`): what changed

Forever is the **retail Midnight (12.x) UI codebase carrying classic content**.
Verified against the `forever` branch of `Gethe/wow-ui-source` at the exact
installed build, diffed against `classic_anniversary`:

| Area | Finding | Handled in |
|---|---|---|
| `C_Map` | Unchanged for everything we call. `GetFileIDFromPath`, `SetResizeBounds`, `BackdropTemplate`, `UIPanel*Template`, `StaticPopup`, `RAID_CLASS_COLORS`, `CLASS_ICON_TCOORDS` all present | — |
| Talents | No `GetNumTalentTabs`; specs via `C_SpecializationInfo.GetSpecialization/GetSpecializationInfo` (Anniversary has that API too, so tabs stay first) | `Core/Roster.lua` |
| Spec events | `PLAYER_SPECIALIZATION_CHANGED`, `TRAIT_CONFIG_UPDATED`. Registering an unknown event is a hard error, so `ns.RegisterEvents` checks `C_EventUtils.IsEventValid` | `Core/Init.lua` |
| Chat | `ChatFrame_AddMessageEventFilter`, `ChatEdit_*` exist only as shims in `Blizzard_DeprecatedChatInfo`, loaded only while the `loadDeprecationFallbacks` CVar is on. Real names: `ChatFrameUtil.AddMessageEventFilter/GetActiveWindow/ChooseBoxForSend/ActivateChat` | `UI/Transfer.lua` |
| **Secret values** | Midnight's restriction system is live. Chat text is secret during chat lockdown; `UnitClass`, `UnitIsGroupAssistant`, … are `SecretWhenUnitIdentityRestricted`. Secrets throw when compared, indexed with, or passed to string functions. `ns.AnySecret` guards them | `Init.lua`, `Roster.lua`, `Transfer.lua` |
| Dropdowns | `LibUIDropDownMenu` picks its code path by interface number: 16001 < 20000 → "ClassicEra" on a retail UI. **Local patch** decides by `WOW_PROJECT_ID` first. Re-apply if the lib is ever updated. Fallback if menus misbehave: Blizzard's `MenuUtil` (`Blizzard_Menu` ships in both clients) | `Libs/LibUIDropDownMenu/LibUIDropDownMenu.lua:31` |
| **Names** | A character is a **first name and a surname**, unique across the region, with no realm in its identity (`RegionalUniqueNamesEnabled()`; the WTF folder is `Lavitz-Starlove`). `UnitName` and `UnitNameUnmodified` return the surname where other clients return a realm (`Blizzard_FrameXMLUtil/Camelot/NameUtil.lua`). `GetRealmName` still answers, but `Name-Realm` is nobody's address: a chat link built that way was never answered (2026-10-06, first two-player test). The chat box accepts `First-Surname` and `First Surname` as whisper targets (`ChatFrameEditBox.lua`, `ExtractTellTarget`). **Only Forever.** TBC Anniversary, and any other version supported later, still needs `Name-Realm`, so the surname form is used only when `RegionalUniqueNamesEnabled()` exists and says yes, never by flavor; `test_sync.py` runs both kinds of world. So `Pack.WhisperName` gives `First-Surname` there, replies go to the sender exactly as the client reported it, and "is this me" compares full names, since two raiders can share a first name. **From the UI source; the working link is not yet confirmed in game.** `Pack.AuthorName` is `First Surname` there as well (2026-10-07), so the pack list reads right and the lock tells namesakes apart; a pack this character made under `Name-Realm` is rewritten at login, and `Pack.DisplayName` drops the realm from anyone else's. Still by short name: specs | `Model/Pack.lua`, `Core/Comm.lua` |
| Addon comms | `C_ChatInfo.InChatMessagingLockdown()`, `Enum.AddOnRestrictionType` {Combat, Encounter, ChallengeMode, PvPMatch, Map, Chat}, event `ADDON_RESTRICTION_STATE_CHANGED`. Sends return `AddOnMessageLockdown`. See Phase 4 | deferred |

### Verified APIs (all confirmed present in this client)

- `C_Map.GetMapArtLayers(mapID)` / `C_Map.GetMapArtLayerTextures(mapID, layer)`
  — used by `MRT/VisNote.lua:765`, which loads on Classic per `MRT-Classic.toc`.
- `C_ChatInfo.SendAddonMessage` / `RegisterAddonMessagePrefix` — `MRT/core.lua:942`.
- `GetFileIDFromPath(path)` — returns nil for absent files. Used as an existence
  check by `AtlasLootClassic/Loader.lua:277`.
- Chat hyperlinks via `|Hgarrmission:<addon>|h` + `hooksecurefunc("SetItemRef", ...)`
  survive server-side link filtering — `WeakAuras/Transmission.lua:161,231`.
- Modern map canvas mixins (`MapCanvasDataProviderMixin`) exist — GatherMate2,
  Leatrix_Maps. Not needed if we render tiles ourselves (we do).

### ⚠️ Removed globals in this client

Anniversary runs a modern engine, so a batch of long-standing globals are **gone**
even though the content is TBC. Confirmed the hard way:

| Gone | Use instead | Notes |
|---|---|---|
| `GetAddOnMetadata` | `C_AddOns.GetAddOnMetadata` | Killed `Init.lua` at load, which cascaded into every later file seeing a half-built namespace |
| `UIDropDownMenu_*`, `UIDropDownMenuTemplate` | `LibStub("LibUIDropDownMenu-4.0")` | 5 addons here vendor this lib; none call the globals |
| `dialog.editBox` on a StaticPopup | `ns.PopupEditBox(dialog)` | Gone in **both** clients, see below |

Still present (verified in use by Classic addons here): `UIPanelCloseButton`,
`UIPanelButtonTemplate`, `UISpecialFrames`, `BackdropTemplate`. Both
`SetMinResize` and `SetResizeBounds` appear in the wild — guard for both.
`SetClipsChildren` has near-zero usage in Classic addons; it is guarded, and if
it turns out to be absent the fallback is to parent tiles to a ScrollFrame.

**Lesson:** when something is missing, grep the 76 installed addons for what
they use instead. It is faster and more reliable than reasoning about which
patch removed what.

**A StaticPopup's edit box is `dialog:GetEditBox()`, not `dialog.editBox`.**
Both clients build their dialogs from `GameDialogMixin`
(`Blizzard_StaticPopup_Game/GameDialog.xml`, same in the `classic_anniversary`
and `forever` branches), which keeps the edit box at `dialog.EditBox`. The
lowercase field is nil, so indexing it throws inside `OnShow` / `OnAccept` —
that is what broke every rename dialog, on both clients. Use
`ns.PopupEditBox(dialog)`; `tools/test_compat.py` runs all four dialogs against
a dialog shaped like the real one.

This replaces an earlier diagnosis here, that entries built or mutated just
before `StaticPopup_Show` do not take. Anniversary's `!BugGrabber` log from
that day (2026-07-27) shows the pre-refactor code failing with this same
`editBox` error. Registering statically and reading state inside `OnShow` /
`OnAccept` is still the pattern, because it is simpler, not because the other
way is known to fail.

### ✅ Correction (2026-10-02): instance interiors DO ship, in both clients

The spike below concluded Karazhan, SSC, TK, Gruul and Magtheridon were absent.
**That was wrong. The probe used the wrong filename.** Blizzard names floor
tiles `Interface\WorldMap\<folder>\<stem><floor>_<tile>` (e.g. `Karazhan3_7`).
The spike only tried `<Name><tile>`, which matches the single-page "overview"
maps (`BlackTemple1..12`) and nothing else.

Checked per build against wago.tools' build-filtered listfile (validated: 345
of 345 agreed with per-file CASC probes). Present in **both** clients: Karazhan
(17 floors), Black Temple (overview + 7 interiors), Gruul, Magtheridon, SSC
(`coilfangreservoir`), Tempest Keep, **Hyjal Summit (`cotmounthyjal` — the
real CoT raid, not the Cataclysm zone)**, Sunwell, ZA, all vanilla raids and
dungeons, and every TBC 5-man. Forever also ships the classic-layout
`scholomanceold`; Anniversary has only the Mists rebuild of Scholomance.

Floor names come from retail, which binds these same files to named uiMaps.
All of this is generated into `Data/Instances.lua` — see §7. An entry in
`tools/instances.json` may give a `stem` when folder and file stem differ.

**Shipping is not enough: the client must also be able to name the file
(2026-10-03, first `/rm census` on Forever).** `GetFileIDFromPath`, and so
`SetTexture` with a path, only knows files in the build's
`ManifestInterfaceData` table. The census found 132 of the 139 floors the
listfile predicted; manifest membership predicts all 139, file IDs included.
In Forever 70205, 5,400 worldmap files ship without a manifest row. The seven
misses were three such sets, and looking at the tiles showed none was what its
name suggested:

- `thedeadmines/deadmines*` and `scarletmonasteryold/*` are **Korean-text
  copies** of the Deadmines and Scarlet Monastery maps, not older layouts. The
  loadable `thedeadmines/thedeadmines*` and `scarletmonastery/*` are the right
  art (same Deadmines layout; the four classic SM wings), and the addon was
  already falling back to them.
- `battleforgilneas` is a Gilneas City page. The battleground is
  `gilneasbattleground2` (retail uiMap 275), which is loadable.

`tools/mapdata.py` now counts art as present only with a manifest row
(`loadable_art`), and reports a curated alt that ships but cannot be loaded.

The census numbers below remain correct. The "conclusively absent" list and
the custom-art backlog in §4 do not.

### Map art findings (spike `RCMapCensus`, run 2026-07-27)

**Census** (`/mapcensus`): 186 valid `uiMapID`s, **73 with art. Zero interiors.**
Only world zones, continents, cities, and 4 battlegrounds. Retail `uiMapID`s for
TBC raids (e.g. "Black Temple = 339") **do not exist in this client** — that is
retail map data and any plan citing it is wrong.

**Path probe** (`/mapprobe`, pass 1): interior art *does* ship on disk, just
unbound to any `uiMapID`. Controls passed (`Interface\WorldMap\Azeroth\Azeroth1`
→ `270454`), so misses are real absences, not probe failure.

Art present, 12 tiles each at `Interface\WorldMap\<Name>\<Name>1..12`:

- **BlackTemple**, **SunwellPlateau**, **ZulAman**, **ZulGurub**,
  **RuinsOfAhnQiraj**, **Hyjal** (pass 2)

**Pass 2** probed 32 alternate folder names with BlackTemple as a positive
control (it re-hit, so the misses are real). Result: `Hyjal` hits under exactly
that plain name. Conclusively absent across all spellings tried: **Karazhan**
(5), **Serpentshrine** (5), **Tempest Keep** (5), **Gruul's** (4),
**Magtheridon's** (5). Stop guessing names for these — they need custom art.

### 🚨 Art that exists may be the WRONG ERA

**The client is a modern engine, so its art is the modern version of each map.**
A path resolving proves art exists — it says nothing about which expansion's
layout you get.

Confirmed by visual inspection:

| Map | Verdict |
|---|---|
| **BlackTemple** | ✅ Correct TBC layout, renders beautifully. **But 12 tiles = one page**, showing only the Illidari Training Grounds courtyard. Good for Najentus/Supremus; Teron, Gurtogg, Council, Illidan are interior rooms not on it. |
| **Hyjal** | ❌ **Cataclysm** Mount Hyjal zone. Wrong geometry entirely — unusable for the TBC CoT raid. ~~Needs custom art.~~ The raid's own art is `cotmounthyjal` (catalog key `inst:hyjalsummit:0`); the old `hyjal` key still resolves for saved packs but is no longer offered. |
| SunwellPlateau | Unverified — probably fine, unchanged since TBC |
| ZulAman | Unverified — Cata revamped it; geometry may still match |
| ZulGurub | Unverified — Cata revamped it heavily; **suspect wrong layout** |
| RuinsOfAhnQiraj | Unverified — probably fine, unchanged |

**Verify every map visually before trusting it.** `GetFileIDFromPath` answers
"does a file exist", which is a strictly weaker claim than "is this the map I
need".

The rule for *existence*: instances given real world maps in original
vanilla/TBC have art; those that never had one don't.

**Consequence:** no interior is reachable via `uiMapID`, so we render tiles
ourselves regardless. Shipped art and custom art therefore use the *same code
path*; "custom art" is a catalog entry, not a second renderer.

---

## 1. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Art source | Client art where it exists, ship custom for gaps | Probe results above |
| Sync model | Publish button + lightweight live slide focus | 800 B/s ceiling makes live drag streaming infeasible |
| Audience | Guild-first | Skip locale scaffolding; **keep** pack schema versioning |
| MVP raids | **Black Temple** (art free) + **Hyjal** (art needed) | User priority |
| Conflict resolution | Last-write-wins + author stamp + local pause toggle | Anything smarter is a rabbit hole for a guild tool |

### Bandwidth reality (drives the whole sync design)

- ~255 bytes per addon message including prefix; AceComm chunks at 251.
- ~800 bytes/sec sustained (ChatThrottleLib default `MAX_CPS`).
- A 5-slide / 40-token pack ≈ 5–10 s to broadcast. Acceptable for a button,
  fatal for live dragging.
- Broadcasting to `RAID` is **one** transmission for all 25 recipients — cheap.
  On-demand fetch (send hash, only those missing it whisper-request payload) is
  the WeakAuras model and keeps it cheaper.
- Live slide focus is a *separate opcode*, ~20 bytes, lead/assist only,
  throttled ~1/sec, on its own code path so it never queues behind a pack.

---

## 2. Architecture

**Libs** (all already vendored in addons present on this machine, copy from there):
AceAddon-3.0, AceDB-3.0, AceComm-3.0 (chunking + throttling free),
LibSerialize, LibDeflate.

**Strict layering** — the top two must never call down into UI:

```
Model/    Pack -> Board -> Slide -> Element.  Pure data + mutations.
Net/      publish, hash-dedupe, chunked transfer, permissions, slide focus.
Serialize/ pack <-> string.  Schema version + migrations.
Render/   map canvas widget, tile loader, element widgets.
UI/       main frame, roster panel, filmstrip, notes, toolbar.
```

**Model shape:**

- One generic `Element` with variants: `player`, `role`, `marker`, `arrow`,
  `text`, `shape`. Arrows are two-anchor elements. Keeps serializer, undo, and
  hit-testing single-implementation.
- Positions are **normalized `{x, y}` in [0,1]** against the map layer, so zoom,
  resize, and differing client resolutions are free.
- Art refs are polymorphic from day one:
  `{kind="tiles", base="Interface\\WorldMap\\BlackTemple\\BlackTemple", count=12}`
  or `{kind="tiles", base="Interface\\AddOns\\RaidMap\\art\\hyjal\\hyjal", count=12}`
  or `{kind="uimap", id=1948}` or `{kind="blank"}`.

**Two things to build early because they are cheap now and expensive later:**

1. **Command-pattern undo stack** on the model.
2. **Model/Net/Serialize as pure Lua, testable outside WoW** under Lua 5.1 with
   a stubbed API. In-game iteration costs a `/reload` per change; shell-testable
   serialization and sync logic is a large multiplier.

**Pack schema versioning is non-negotiable** even guild-first: packs outlive the
code that wrote them, and someone will import a pack next tier that was authored
today. Every pack carries a schema version and a migration path.

---

## 3. Phases

### Phase 0 — Spike ✅ mostly done
- [x] Map census (`/mapcensus`) — 73 maps, no interiors
- [x] Path probe pass 1 (`/mapprobe`) — 5 raids with shipped art
- [x] Path probe pass 2 — `Hyjal` found; Kara/SSC/TK/Gruul/Mag conclusively absent
- [ ] **Visually confirm** BT and Hyjal tiles render *and are usable* (path
      resolution ≠ good strategy backdrop; first task of the canvas anyway)

### Phase 1 — Local editor (the core; no networking)

**Status: increments 1-2 verified working in game. Increment 3 awaiting test.**

Built so far:
- **Increment 1 ✅** — canvas renders Black Temple correctly, tiles seamless
- **Increment 2 ✅** — markers, drag, undo/redo/clear all confirmed working
- **Increment 3 (untested)** — roster panel, player tokens, display modes

- `RaidMap.toc`, `Core/Init.lua` (namespace, event emitter, AceDB, `/rm`)
- `Core/Catalog.lua` — art-ref resolver; 6 shipped raid maps + blank + all
  client zone maps (lazily scanned, cached)
- `Render/MapCanvas.lua` — tile renderer, edge-tile cropping, zoom-to-cursor,
  right-drag pan, normalized coordinate API (`NormalizedToOffset`,
  `CursorToNormalized`)
- `UI/MainFrame.lua` — movable/resizable window, map picker, live coord readout

Libs vendored from Questie (Classic-safe versions): LibStub, CallbackHandler-1.0,
AceDB-3.0. AceComm/LibSerialize/LibDeflate get vendored at Phase 4/5.

There is no system Lua and no sudo to install one, but **`lupa` (pip) embeds a
real Lua 5.1** — the same version as WoW — so code that doesn't need frames can
now *run* offline:

	~/.venvs/lua/bin/python ~/.venvs/lua/check.py         # parse every source file
	~/.venvs/lua/bin/python ~/.venvs/lua/ns.py            # ns.* used but never defined
	~/.venvs/lua/bin/python tools/test_catalog.py         # catalog + census vs real build data
	~/.venvs/lua/bin/python tools/test_compat.py          # flavor/spec/chat/secret code paths
	~/.venvs/lua/bin/python tools/test_sync.py            # packs and sharing between simulated clients
	~/.venvs/lua/bin/python tools/test_ui.py              # whole addon on stub frames: toolbar, roster, toggles

Set up with `python3 -m venv ~/.venvs/lua && ~/.venvs/lua/bin/pip install
luaparser lupa`. The parser catches typos that otherwise cost a `/reload`; the
`ns.*` pass catches calls to functions no file defines.

- `test_catalog.py` runs `Data/Instances.lua`, `Core/Catalog.lua` and
  `Core/Census.lua` with `C_Map` and `GetFileIDFromPath` answered from wago.tools
  data for the actual Forever and Anniversary builds. When an in-game census of
  the same build and instance data is on disk, it also checks that every floor
  resolves to the file the real client reported.
- `test_compat.py` stubs both clients' APIs, including a StaticPopup shaped
  like the real one for the rename dialogs. Its fake secret value throws on
  any use, so a missing guard fails loudly. Its first run caught a live bug:
  the chat-link filter used `find("%[...", 1, true)`, whose plain mode makes
  `%` literal, so links were never rewritten.

- `test_sync.py` runs several clients at once, each its own Lua runtime on the
  real Model, Serialize, Comm and Transfer code and the real LibSerialize and
  LibDeflate. A message bus stands in for AceComm and the clock only moves when
  the test moves it. It checks what every client ends up holding: publish,
  per-board deltas, re-announce, pause/apply, rollback, lock, duplicate, export
  strings, chat links. Not covered: chunking and throttling, the UI, and
  whatever the server does to a message. Its first run failed 11 checks; see
  Phase 5.
- `test_ui.py` loads every file in the TOC, in TOC order, once as each client,
  against frames that are tables remembering their size, scripts, text and
  state. It then clicks and drags the toolbar's marker and role buttons, scrolls
  a full demo raid, drags a name out of the list and cycles the token toggles,
  checking the model and the widgets' state after each. It proves the wiring and
  that nothing trips over a nil. It cannot say what anything looks like, or in
  what order the client reports a mouse-up after a drag.

None of them runs real frames. In-game errors still come through `!BugGrabber` (read
`WTF/Account/<acct>/SavedVariables/!BugGrabber.lua` after a run) or
`/console scriptErrors 1`.

Remaining in Phase 1:

- Addon skeleton, TOC, AceDB, slash commands
- Tile-loading map canvas widget (4×3 × 256×256 grid; copy layer math from
  `MRT/VisNote.lua:748-800`)
- Map catalog: BT + Hyjal + blank grid + the 73 client zone maps
- Element model + drag-and-drop tokens + hit testing
- Undo stack
- Persistence + schema v1
- **Exit criterion:** author a Black Temple board with tokens, `/reload`, it
  comes back intact.

### Phase 2 — Roster
- [x] Class colors, group headers, recycled-row list with a scrollbar (wheel
      or drag; a full raid is 48 rows and 24 fit at the default size)
- [x] Drag-from-roster onto canvas creates a player token
- [x] Raid markers and role icons drag from the toolbar the same way
      (`UI/PlaceDrag.lua`); a click still adds one at the centre of the view.
      A dragged role shows the number it will get and is numbered on release
- [x] Token display modes: icon / name / both, stacked V or H (board-level;
      per-token override still to come). The two toggles sit under the roster
- [x] Demo roster toggle — 39 fake raiders filling the eight groups around
      whoever is really there, because a roster panel cannot be tested solo
      otherwise
- [x] Own spec via `GetTalentTabInfo` (tab with most points; its icon is the
      spec icon). Signature: `id, name, description, icon, pointsSpent`
- [x] **Other players' specs** — by comm self-report (Phase 4). Players without
      the addon fall back to class icon, which is never wrong, just less
      informative
- [ ] Bench/standby section
- [ ] Drop-back-to-roster removes; shift-drag copies

### Phase 3 — Slides, notes, presentation
- [x] Slide strip with add / duplicate / delete / rename (right-click a tab)
- [x] The strip stays inside its row however many slides there are: tabs
      narrow to fit, then page between `<` `>` (or the wheel) without
      changing slide, and `+` / Copy / Delete never leave the row
- [x] Per-slide map, framing and elements; switching restores all three
- [x] `+` opens the new slide on the map of the slide in view, not the default
- [x] Copy-slide-forward — the fast path for authoring movement
- [x] Notes panel, two scopes (per-slide and per-board), collapsible
- [ ] Slide reordering (drag tabs)
- [x] Presentation mode: compact read-only overlay for raiders, next/prev
      (`UI/Presentation.lua`, `/rm present` or the Present Mode button)

**Presentation mode is a second *view*, never a second copy of the state.** Its
next/prev call the same `ns.SwitchSlide` the editor does, so one path serves
both directions: a lead presenting from it drives the raid through the existing
focus opcode, and a raider's window tracks the lead with no second mechanism to
keep in step. `ns.SwitchSlide` now fires `SLIDE_SHOWN` so a view that is not the
editor can hear about it.

Read-only is structural, not a matter of leaving the buttons out:

- read-only tokens have their mouse disabled entirely, so they cannot be
  dragged or right-click deleted — and right-drag panning works over the top of
  them instead of being swallowed;
- pan/zoom is local, because MainFrame writes `slide.view` for *its own* canvas
  only (`if moved ~= canvas then return end`). Framing a room mid-pull cannot
  dirty the pack or bump a revision;
- notes render as a FontString, not an edit box. **An edit box that takes focus
  eats the movement keys** — a bad thing to hand somebody during a fight. Same
  reason there is no arrow-key binding.

**Focus now carries the board id as well as the slide index.** A bare index
lands on whatever board the receiver happened to be looking at, which is wrong
the moment the lead moves to the next boss; presentation mode made it visible
because the raider is now actually watching. Old clients send a bare index and
`strsplit` returns it unchanged, so they still read correctly. The focus
throttle was also loosened to drop only *repeats of the same target*, because a
blanket 1/sec swallowed the board change that immediately followed a slide
change — exactly the sequence "next boss" produces.

`Model:MoveElement` now fires `ELEMENTS_CHANGED` on drag stop (once per drag,
not per frame), or a presentation window open beside the editor would never see
a token move.

Note edits deliberately stay out of the undo stack — undo is for spatial edits,
and threading keystrokes through it would bury a token move under fifty
one-character entries.

**A slide's framing is saved from the user's own pan or zoom and from nothing
else** (`CANVAS_VIEW_MOVED`: a wheel notch, or letting go of a right-drag). It
used to be saved on every `CANVAS_VIEW_CHANGED`, which every layout fires,
including the ones that happen while a slide, board or pack is loading; so
switching board, or receiving a publish, stamped the editor's last view onto
the slide being opened. Saving it is also an edit (`Model:Touch`), or a publish
left the framing behind. Undo/redo fires `SLIDES_CHANGED` as well as
`ELEMENTS_CHANGED` so the view resyncs when an undone slide vanishes.

`Model:Touch` fires `PACK_MODIFIED` on the first edit since a publish, which is
what puts the `~` on the pack's name without waiting for something else to
redraw the dropdown.

### Phase 4 — Sync

**Status: ✅ VERIFIED on two clients (two subscriptions). Board publish, slide
focus, and live spec updates all confirmed working across accounts.**

- [x] `Core/Serialize.lua` — LibSerialize + LibDeflate, schema-stamped, two
      encodings (addon channel / print) off the same compressed bytes
- [x] `Core/Comm.lua` — one prefix, three opcodes: `B` board, `F` slide focus,
      `S` spec self-report
- [x] Publish gated to leader/assist in raid, anyone in a 5-man
- [x] Content-hash dedupe (Adler32), pause toggle + Apply for held updates
- [x] Replaced boards saved to `backupBoard`, recoverable with `/rm restore`
- [x] Spec self-report closes the Phase 2 gap — no inspecting needed
- [x] Verified against a second client
- [x] On-demand payload fetch — the Phase 5 manifest: receivers ask for what
      they lack

#### Sync on WoW Forever — constraints to design for (not yet built)

Forever enforces Midnight's addon restrictions. None of this is handled yet:

- **Chat lockdown blocks sends.** While `C_ChatInfo.InChatMessagingLockdown()`
  is true (instanced encounters at least; `Enum.AddOnRestrictionType` also has
  Combat, ChallengeMode, PvPMatch, Map, Chat), `SendAddonMessage` returns
  `Enum.SendAddonMessageResult.AddOnMessageLockdown`.
- **ChatThrottleLib v31 silently drops** a chunk that comes back as lockdown
  (dequeues it, `didSend = false`). A multi-chunk AceComm transfer started just
  before a pull arrives half-built, and the receiver gives up after
  `INCOMING_TIMEOUT`.
- Needed:
  - Gate every send on `InChatMessagingLockdown()`.
  - Queue the one pending publish and flush it on `ADDON_RESTRICTION_STATE_CHANGED`.
  - Never start a multi-chunk transfer that could straddle a pull.
  - Show "sharing paused — encounter in progress" in the sync status.
  - Check whether a newer Ace3 / ChatThrottleLib treats lockdown like a throttle.
- **Live slide focus (`F`) cannot work mid-encounter.** Presentation mode still
  works; raiders navigate locally. Lead-driven focus is pre-pull / between
  pulls only.
- Receiving is fine: `CHAT_MSG_ADDON` is not flagged secret in the docs.

`/rm selftest` proves the serialize round trip and prints real payload size and
broadcast time — the part verifiable without a second account.

Key sizing facts baked into the design: ~255 B per message, ~800 B/s sustained,
and a RAID broadcast is one transmission for all 25 recipients — so publishing
is cheap and *streaming* is what is impossible.

### Phase 5 — Packs

Full design in **`PACKS.md`** — read that first, it records the decisions and
why.

- [x] Pack model, immutable uid, revision, fork, author lock
- [x] Schema v1 -> v2 migration (bare board becomes a one-board pack)
- [x] Pack + board dropdowns; new/rename/duplicate/delete for both
- [x] Sync moved from boards to packs, revision decides staleness
- [x] `/rm restore` republishes at a higher revision (a restore at the old
      number would be ignored as stale by everyone holding the bad one)
- [x] **Role tokens** — Tank/Healer/DPS, auto-numbered per slide (T1, T2, T3).
      The portable primitive: names mean nothing to an importer, roles do.
- [x] Manifest + per-board deltas — publish sends a manifest of
      `{boardID, rev}`; receivers request only what they are behind on
- [x] Revision history (10 snapshots) + restore, under Pack > Revision history
- [x] Automatic propagation on roster change (throttled 10s, 3s delay so a
      joiner's addon is listening)

Delta sync compares a **per-board version, not a content hash**. LibSerialize
walks tables with `pairs()`, whose order varies between clients, so two clients
holding identical content can serialize to different bytes and every hash
comparison would miss.

The version is `(rev, stamp)`: a counter plus a random number set on every
edit, compared for **equality**. The first design was the counter alone with
"request if mine is lower", and `tools/test_sync.py` showed that only works
with one writer: a raider who drags a token five times is "ahead" of the
lead's next edit and never receives it, and a rollback is "behind" what
everyone holds and never propagates. Anything that changes a board must call
`Model:Touch` or it will not travel — a map change, a board rename and the
token display toggles did not.

Fixed in the same pass (2026-10-03), each with a check in `test_sync.py`:

- a second manifest for a transfer already running restarted it (roster churn
  re-announces every 10s, so a slow transfer could never finish);
- `/rm restore` numbered the restored pack from its own old revision, which
  loses to an offending pack two or more revisions ahead;
- a duplicated or forked pack kept the source's history, and restoring from it
  overwrote the source pack;
- the author lock never left the author's client, so it stopped nobody. It now
  travels in the manifest, and only the author is offered the menu item;
- the roster-change announce pushed whatever pack was selected, including one
  never published, so everyone's untouched "My Pack" was traded on grouping up;
- a chat link named its author with the display realm, which is not a valid
  whisper target when the realm has spaces ("Classic Beta PvP 2").

Decided in `PACKS.md`, **not built yet**:

- [ ] Accept / Not now / Never prompt for a pack you have never seen. Today any
      pack announced by anyone in your group is stored without asking.
- [ ] Payload size cap.
- [ ] Take update / Keep mine / Fork when an update would overwrite local
      edits. Today the update wins and `/rm restore` holds one backup.
- [ ] Receivers checking that the sender is leader or assist.
- [ ] Confirmation on Delete pack / Delete board (immediate, and not undoable).
- [ ] Framing-only changes (pan/zoom, nothing else) do not sync: the view is
      saved without `Touch`, deliberately for now, since a raider panning
      their own copy would otherwise count as an edit.

`ns.applyingRemote` guards the touch path: applying a received pack fires the
same events a local edit does, and without the guard every receiver would bump
its board revisions and drift a revision ahead of the sender.

Send heuristic: 3+ requesters gets one broadcast of the union; 1-2 gets each
person whispered only the boards they asked for.
- [x] Export/import strings (Pack menu), read-only export box, import validates
      and preserves local-only state (history, lock)
- [x] Chat links

**Chat links send PLAIN TEXT, not a hyperlink.** `[RaidMap: Title from
Author]` goes over chat; each recipient's own addon rewrites it into a clickable
`|Hgarrmission:raidmap|h` link locally through a
`ChatFrame_AddMessageEventFilter`. The server strips hyperlink types it does not
recognise, so an actual link inserted into the edit box would not survive the
trip. WeakAuras does exactly this — `WeakAuras/Transmission.lua:146-170` is the
reference. Bonus: people without the addon see readable plain text rather than
broken markup.

Clicking a link whispers the author, who replies with a manifest — so a link
click lands in the same delta machinery as a publish and only fetches boards the
clicker lacks.

### Deferred (explicitly out of MVP)
Freehand drawing, arrow animation, timeline/reminders, DBM/BigWigs-triggered
auto-advance, WeakAuras-style companion app.

---

## 4. Art backlog (custom, priority order)

Spec: 12 tiles, 256×256 each, 4 cols × 3 rows = 1024×768 layer. `.blp` or
uncompressed/RLE 32-bit `.tga`. Power-of-two dimensions required.
Same convention as Blizzard's, so the renderer needs no special case.

~~Revised after visual verification. Client art covers **less than the probe
suggested** — only Black Temple's courtyard is confirmed usable.~~

**Superseded 2026-10-02:** every item that used to be on this list (Hyjal
Summit, Black Temple interiors, Gruul, Magtheridon, SSC, TK, Karazhan) ships
in the client under the floor naming in §0. The backlog is now **visual
verification**, not drawing: open each floor and confirm it is the right era.
Mark it in `tools/instances.json` → `verified`.

Custom art is still the answer for instances whose art turns out to be the
wrong era. Known candidates: Zul'Gurub and Zul'Aman (only the Cataclysm 5-man
page exists), Scholomance on Anniversary (only the Mists rebuild ships there),
and Forever's new dungeons if Blizzard ships no art for them.

Looked at outside the game on 2026-10-03, from the build's own tiles (§7 step
4): Deadmines, the four Scarlet Monastery wings, classic Scholomance
(`scholomanceold`) and the Battle for Gilneas battleground all show the
expected layout. None is marked `verified` yet; that still means someone
compared it in the instance.

**This does not block feature work.** Tokens, roster, slides, sync, and packs
all build against the BT courtyard and the blank grid canvas. Art production
runs in parallel and drops in as catalog entries.

Recommended style: **stylized/traced floor plans**, not composited screenshots.
Cleaner for strategy communication (a literal top-down of BT is visually busy
in exactly the way a diagram shouldn't be), faster to produce, and it reads as
a deliberate look rather than an apology.

---

## 5. Prior art to study (all installed locally)

- **`MRT/VisNote.lua`** (3,839 lines) — the incumbent. Map-backed visual note
  with sync + popup, loads on Classic. Its map catalog is hardcoded to *retail*
  raids, UX is dense/functional, no roster integration, no spec icons, no
  multi-slide phases, no import/export. **That gap is the wedge.** Read
  `SetBackground` at :748 for tile layer math and `:3505 UnpackString` for its
  sync format.
- **`WeakAuras/Transmission.lua`** — export strings, chat links, `SetItemRef`.
- **`MRT/core.lua:1090-1190`** — addon message throttling wrapper.
- **`MRT/Inspect.lua`**, **TacoTip** — talent/spec scanning on TBC.
- **`PallyPower`** — long-lived simple raid-wide assignment sync.

---

## 6. Open questions

- Final addon name (folder name is baked into custom art paths).
- ~~Do BT's and Hyjal's shipped tiles look usable?~~ BT confirmed; Hyjal Summit
  now uses the real raid art (`cotmounthyjal`). Still to eyeball: the rest of
  the instance floors (§4).
- Forever's announced-but-unseen instances (Drown City, Barrow Deeps, Hyjal
  Summit raid, Onyxia 40 changes): do they get map art at all? The weekly
  report (§7) will show when they appear. Census of 70205 (2026-10-03): the
  client sees the same 60 maps public data has, so nothing is unlocked yet.
- Forever's guessed art (City of Dalaran → `dalarancity`, Ruins of Lordaeron →
  BfA scenario art, Battle for Gilneas → Cataclysm BG `gilneasbattleground2`)
  — confirm or drop once someone has stood in them.

---

## 7. Weekly map refresh (WoW Forever beta → launch)

Zone maps need **no work**: the catalog reads `C_Map` live, so a new zone in a
beta build appears on next login. Only instance interiors (path-only art)
need curation. One pass per beta build, ~10 minutes:

1. `python3 tools/mapdata.py` — picks the newest `wow_classic_beta` build on
   wago.tools, regenerates `Data/Instances.lua`, writes
   `tools/reports/<product>-<build>.md`:
   - new / removed / renamed zone maps vs the previous build's snapshot
   - new instances in the `Map` table
   - **art folders new in this build**: candidates for new dungeons
   - per-instance status in Forever and Anniversary, plus problems
2. For each new instance with art: add an entry to `tools/instances.json`
   (folder, stem, flavors, notes) and re-run step 1. Floor names fill in from
   retail where retail knows the art; otherwise name them in `floorNames`.
3. In game on the beta: `/reload` (to pick up the regenerated data),
   `/rm census`, `/reload` again, then `python3 tools/mapdata.py --census`.
   This lists maps the **client** sees but public data doesn't: encrypted beta
   content (Drown City, Barrow Deeps, Hyjal Summit are absent from public data
   as of 70205), plus any floor the tool predicted wrong. Floors are matched
   by alt number, so a census taken before `instances.json` changed is
   reported as not comparable rather than as a list of false misses. The
   census only probes uiMaps and curated floors; a new dungeon whose art sits
   in an unknown folder shows up in step 1's new-folder list instead.
4. Eyeball new floors; add the flavor to `verified` in `instances.json`. A
   first look needs no game: `https://wago.tools/api/casc/<fileDataID>?download&version=<build>`
   returns the tile as a BLP (Pillow opens BLP2), 12 tiles row-major per floor.
   Do this for any art whose name is a guess — names lie (§0).
5. Run both test scripts (§3 Phase 1), commit (`Data/`, `tools/instances.json`,
   `tools/snapshots/`, `tools/reports/`).

After launch (Nov 4), the product name will change: `python3 tools/mapdata.py
--products` lists every wago product carrying 1.60.x builds; pass the new one
with `--product`. Cache: `tools/cache/` (gitignored; per-build data never
expires).
