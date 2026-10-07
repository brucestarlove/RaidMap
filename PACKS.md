# Packs — agreed design

Settled 2026-07-27. Read alongside `PLAN.md`.

## Hierarchy

	Pack -> Board -> Slide -> Element

A **pack** is the shareable unit ("BT guild"). A **board** is one boss. A
**slide** is one phase. Schema v1 (a single bare board) migrates to a one-board
pack.

## Identity

	uid       immutable, generated once: author-realm + timestamp + salt
	title     display, mutable ("BT guild")
	author    display, mutable ("Starlove-Whitemane")
	revision  integer, bumped on publish

**Dedupe, versioning and update-matching all key on `uid`, never on
title+author.** Title-based identity breaks the moment someone retitles a pack
(every subscriber sees a new pack) and collides when two guilds both make
"BT guild".

Higher revision wins; equal revision is ignored. Revision is per-pack, so
updating BT never touches Sunwell.

## Co-editing (decided)

Anyone with publish rights may push an update to a shared pack. It keeps the
original `uid` and `author`, and records `lastPublishedBy`. This matches how
co-leads actually work.

Safety net, because trust is not enforcement:

- **Per-pack revision history** — the last ~10 revisions kept as their already
  compressed transport blobs (near-free: ~4KB each). Shows who published each.
- **Restore republishes as a new higher revision** (restoring v6 publishes v9).
  Never reuse an old number or the restore is ignored as stale.
- **Author lock** — per-pack "only I can publish", a targeted remedy short of
  stripping assist.

⚠️ **Not a security boundary.** Addon messages cannot be authenticated; a
modified client can claim to be anyone. These are guardrails against accidents
and casual mischief — which is what almost every real incident is. Against a
determined bad actor the remedy is removing their assist.

## Forking

Importers editing someone else's pack need an explicit escape. Editing is
allowed and badged "modified from Starlove's v7". When an incoming update would
clobber local changes, prompt: **Take update / Keep mine / Fork**. Forking mints
a new uid, sets the forker as author, and records `origin`.

Never silently destroy local edits — that is the one moment where doing nothing
loses work.

## Sync: manifest + per-board deltas

Publishing the whole pack does not scale. 8 boards at ~2-4KB is ~20KB, and at
~800 B/s that is **~25 seconds** for a one-boss change.

Instead:

1. Publish broadcasts a **manifest**: `uid, revision, title, author,
   {boardID -> hash}` — a few hundred bytes.
2. Clients compare and request only boards whose hash they lack.
3. Sender heuristic: **3+ requesters -> broadcast once; 1-2 -> whisper them.**
   A RAID broadcast is one transmission for all 25, so it is often cheaper than
   three whispers.

Change one boss, only that boss moves: ~3s instead of ~25s. This subsumes the
hash-first optimization left over from Phase 4.

## Propagation (decided: automatic on join)

The lead's client announces the manifest on roster change, throttled. Clients
pull what they lack. No lead action needed — a substitute joins and is current
within seconds. Silent when everyone is up to date, which is most of the time.

**Acceptance splits by familiarity:**
- Update to a pack you already hold -> applies silently. That is the point.
- Pack you have never seen -> prompt: *"Starlove-Whitemane shared 'BT guild'
  (8 boards). [Accept] [Not now] [Never from this player]"*

Plus a payload size cap so nobody can spam a 500KB pack.

## Roster in packs (decided: tokens only)

Packs carry no roster snapshot. Names live on the tokens that were placed.
Simpler, never goes stale, travels better.

## Why role tokens come BEFORE export/import

An imported pack arrives full of names that mean nothing to the importer.
"Cotank tanks the left add" is useless to a stranger who pulled the pack off a
website.

**Role tokens are the portable primitive; named player tokens are not.** A pack
authored with "Tank 1 / Healer 2 / Melee A" travels intact. This makes the role
icons a prerequisite for shareable packs, not a nice-to-have.

A later import-time "map these names to your raiders" step can help the rest.

## The three archetypes

| Archetype | What they need |
|---|---|
| **PUG lead**, assignments on the fly | Fast path: scratch pack, place tokens, publish. No pack admin required. |
| **Regular team lead**, 1+ boss/week | Per-board deltas so weekly updates are instant; revision history; auto-propagation to subs. |
| **Importer**, adopts others' packs | Import string, chat link, explicit fork, role tokens so the content means something. |

## Build order

1. Pack model + schema v2 migration + board library UI
2. **Role tokens** (prerequisite for meaningful sharing)
3. Manifest sync, per-board deltas, revision history, propagation
4. Export/import strings + chat links (`|Hgarrmission:raidmap|h` +
   `SetItemRef`, proven working in this client by WeakAuras)
