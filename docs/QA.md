# Wild Feast Islands: QA pass 3 (polish and autonomous QA)

This pass builds on PR #1 (MVP) and PR #2 (first QA pass). All earlier fixes and the save format (schema v2, store `WildFeastIslands_Profiles_v1`) are unchanged, so existing saves load as before.

## Evidence levels

| Level | Meaning |
|---|---|
| **Sim** | Offline simulation that runs the real scripts. The real server and client scripts from the built `.rbxl` run in `tests/sim` (Lune). It covers logic, ordering, timing and remote payloads. It does **not** cover Roblox physics, replication, rendering, the GUI layout engine or real DataStores. |
| **Unit** | Pure shared rules tested directly (`tests/run.luau`). |
| **Static** | `luau-lsp` strict type check against the Roblox API definitions, selene, StyLua, and `scripts/verify-place.luau`. |
| **Unverified** | Needs Roblox Studio, devices or live servers, none of which were available. These items were not run. |

No Roblox engine execution happened in this pass. Studio, devices, multi-client sessions and screenshots weren't available on the Linux build host. Reopening the place with Lune is not the same as opening it in Studio.

## Defects found and fixed (each has a regression that fails on the pre-fix build)

Every regression was confirmed failing against a build of the pre-fix sources (`/tmp/old.rbxl`) and passing on the new build. Each runs in the Sim unless noted.

| # | Area | Defect | Fix |
|---|---|---|---|
| 1 | Persistence | `UpdateAsync` may re-run its transform, and the flags from an earlier run leaked into the result. A load could then believe it owned a lock another server had taken, and a save could misreport a lost lock. | Flags are reset on every transform run. |
| 2 | Persistence | A corrupt top-level record (not a table) was replaced by a fresh profile at load. | The record is refused: the session runs Unsaved and the stored value is never written. |
| 3 | Persistence | Leaving mid-load and then quickly rejoining could race the lock-only release. The late release stripped the new session's lock and pushed it into unsaved mode. | The abort-path release is tracked in `releasing[key]`, and rejoins wait for it. |
| 4 | Persistence | A load still in flight at shutdown left a 5-minute lock behind, because BindToClose didn't wait for loads. | BindToClose waits for in-flight loads and their releases. No new loads start once closing. |
| 5 | Persistence | Remotes and feast payouts could still change a profile after `PlayerRemoving`, behind the final snapshot. | Sessions are marked `closing` at once and `getProfile` returns nil. |
| 6 | Persistence | A session that lost its lock mid-visit stopped saving without telling the player. | The player gets a notification, the HUD updates, and the `PersistenceMode` attribute changes. |
| 7 | Resources | `StateService.markDirty` from late callbacks kept departed `Player` references forever and iterated them every frame. | Departed or unloaded players are ignored, and `push` always clears the entry. |
| 8 | Exploit | A client-reported origin within 6 studs was accepted even through a wall, so a thrower could launch from the far side. | The server checks line of sight from its own head to the reported origin and to the spawn point. |
| 9 | Exploit | Animal and giant hits were tested before world geometry within a step. On a long frame, food could pass through a thin wall into a mouth. | Geometry is raycast first. Only targets whose closest point lies before the first surface can be hit. |
| 10 | Economy | A double tap (or a resent request) on Upgrade, Restore or Prepare bought two levels or batches. | Repeatable purchases carry `expect` (the level or stock the player saw), and stale requests are dropped. The client also debounces until the next state push. |
| 11 | Controls | A system-cancelled touch (`UserInputState.Cancel`) **threw** the food. The old test only checked that charging stopped, so it hid this. | A cancelled touch cancels the throw. The test now asserts that nothing was sent. |
| 12 | Controls | Losing window focus or opening the Roblox menu while holding left the throw charging, and the stale hold threw later. | Both cancel the hold. |
| 13 | Core loop | After the last stocked food, the selection stayed on the empty food and every throw just toasted "Out of …". | The server switches back to the free Sunberry and says so. |
| 14 | Feast | The goal was fixed at the start, so if teammates left, the one who stayed often couldn't finish. | The appetite only shrinks when players leave mid-event, and the event finishes if the new goal is already met. |
| 15 | Feast | A second contribution in the same frame as the completing one consumed the food with no credit. | The food is refunded. Rewards stay one per player per event. |
| 16 | UI | Every coin or trust change destroyed and rebuilt the food bar, which can swallow a tap. | The food bar has its own fingerprint (foods, stock, selection, input mode). |
| 17 | UI | Identical toasts stacked up (for example, spamming a locked button). | They merge into one toast with ×N and a refreshed timer, capped at 4. |
| 18 | UI | Balances near the caps (1e9) overflowed the resource pills. | Compact numbers (`987.65M`, `123.4K`). |
| 19 | Goals | Recipe and restoration goals had no progress bar, and "Keep restoring" didn't say which step or what it cost. | Every cost goal shows its next step, its cost and a progress bar. |
| 20 | Migration | A v2-shaped save that lost its `schemaVersion` would have had its discoveries wiped by the v1 migration. | The migration keeps dictionary-shaped discoveries and replaces a non-table restoration. |

Also changed: per-frame HUD writes now skip unchanged values, and the feast banner tolerates missing fields.

## Harness audit (does the simulator hide production defects?)

- **Cancelled-touch test:** it masked defect 11 by not asserting that nothing was thrown. It now does.
- **Shutdown model:** the simulator always ran 30 s after shutdown, so work that only finished because of that extra time looked fine. It now stops as soon as BindToClose returns, like Roblox (defect 4).
- **DataStore model:** requests used to commit only after their full latency, and the transform ran exactly once. Now half the latency is spent before the commit and half after, the transform can be re-run on a conflict, per-call latencies can be scripted (defect 3), and a worst-case per-key write throttle is available (it errors; real Roblox usually queues).
- **Remaining shims, documented in the harness:** `Position` is mirrored from `CFrame` for moving roots (Lune stores them separately). On the client, `X.Adornee = nil` is rewritten, because Lune can't assign nil to Ref properties. Neither shim touches the place file.
- **Layout tests:** these are arithmetic on offset sizes, and their jump-button rectangle uses the same documented fallback numbers as the HUD. They show internal consistency, not on-screen layout.

## QA matrix

Result: ✅ pass · ⚠ gap (not verifiable here). Method: S = Sim, U = Unit, St = Static, — = Unverified.

| Feature | Scenario | Expected | Method | Result | Evidence |
|---|---|---|---|---|---|
| Boot | Server starts from the `.rbxl` with no setup | No errors, world baked, 6 remotes | S, St | ✅ | integration "server boots…", verify-place |
| Lifecycle | Join, state push, save mode shown | Profile pushed, mode labelled | S | ✅ | "a joining player receives…" |
| Lifecycle | Leave mid-load, then quick rejoin | New session saves | S | ✅ | regression 3 |
| Lifecycle | Remotes after leave or during the final save | Ignored | S | ✅ | regression 5, fuzz |
| Lifecycle | Death and respawn while charging or throwing | Charge cancelled; dead characters can't throw | S | ✅ | "dead characters…", "respawning while charging…" |
| Feeding | Tutorial Puffhop catch | Perfect or Good, paid once | S | ✅ | "first toss…" |
| Feeding | Ground food, edge food, multiple animals | One animal eats it, once | S | ✅ | ground and edge tests, `claimedBy` |
| Feeding | Every food × species preference | Liked, favourite or disliked rewards per Config | U | ✅ | run.luau economy tests and progression simulation |
| Feeding | Through walls (origin or long step) | Blocked | S | ✅ | regressions 8 and 9 |
| Feeding | Locked island across the water | No pay | S | ✅ | "feeding a locked island's animal…" |
| Feeding | Out of stock | Falls back to free food | S | ✅ | regression 13 |
| Progression | Free-food-only run to the final goal, with every purchase reachable | No softlock | U | ✅ | "a player using only free food…" |
| Progression | Steps done out of order | Goal skips completed steps | U | ✅ | "goals recover…" |
| Purchases | Double tap, stale or missing `expect` | Exactly one purchase | S | ✅ | regression 10 (server and client), fuzz |
| Inputs | Keyboard F, mouse, touch, gamepad R2 | Throw sent with origin | S | ✅ | client tests |
| Inputs | Touch slide-off, cancel, multitouch | Correct release or cancel | S | ✅ | client tests and regression 11 |
| Inputs | Focus loss or Roblox menu | Hold cancelled | S | ✅ | regression 12 |
| Inputs | Gamepad Y/B menu focus | Tab selected; cleared on close | S | ✅ | "gamepad: Y opens…" |
| UI | Unchanged push or coin change | No rebuild of open or food buttons | S | ✅ | "an unchanged profile push…", regression 16 |
| UI | Toasts and large values | Merged, bounded, compact | S | ✅ | regressions 17 and 18 |
| UI | Layout on 667×375, 844×390, 1024×768 and 1366×768 | No overlap (arithmetic) | S | ⚠ | Arithmetic only; real layout, safe areas, fonts and wrapping are unverified |
| Feast | Solo, 3-player, timeout, repeated cycles | Paid once per cycle | S | ✅ | feast tests, "repeated feast cycles…" |
| Feast | Players leave mid-event | Appetite shrinks | S | ✅ | regression 14 |
| Feast | Simultaneous final contributions | One completion; late food refunded | S | ✅ | regression 15 |
| Persistence | Fresh, existing, v1 migration, newer schema, corrupt | Never overwrites unreadable or newer data | S, U | ✅ | persistence tests and regression 2 |
| Persistence | Foreign, stale or re-run locks; lock taken over | Never overwrites; player told | S | ✅ | regressions 1 and 6, stale-takeover test |
| Persistence | Outage, retry exhaustion, throttling, shutdown | Last good save kept; locks released | S | ✅ | outage, exhaustion, throttle and shutdown tests |
| Persistence | Studio without API access | Labelled memory mode | S | ✅ | "Studio without API access…" |
| Security | Hostile payloads on all 6 remotes (nil, NaN, inf, huge strings, nested tables, wrong types) | No error, no pay | S | ✅ | "hostile remote payloads…", fuzz |
| Resources | Projectiles, ground food, animals, workspace children, dirty map | Bounded | S | ✅ | fuzz invariants, spam test, regression 7 |
| Randomized | Seeded random sessions (joins, leaves, rejoins, deaths, teleports, throws, purchases, bells, DB failures) | All invariants hold; saved coins equal live coins; no locks left | S | ✅ | `tests/fuzz.luau`. Batch 1: 6 seeds clean. Batch 2: seed 1358208003 flagged a lock left after injected failures exhausted a leave-save; that is by design (the lock goes stale after 300 s), so the invariant was refined and the seed kept as a regression. Batch 3: 6 seeds clean after the refinement. That makes one clean batch after the last change, not two |
| Engine | Physics, collisions, gates opened locally, falling | — | — | ⚠ | Unverified (needs Studio) |
| Engine | Real touch jump-button position, gamepad selection visuals | — | — | ⚠ | Unverified |
| Engine | Two real clients over a network, real DataStore ordering and throttling | — | — | ⚠ | Unverified |
| Engine | Built-in `rbxasset://` sounds load; frame time; network cost | — | — | ⚠ | Unverified (no FPS numbers are claimed) |

## Resource audit (static plus Sim)

- **Bounded by caps:** animals (24), projectiles (4 per player, 64 total), ground food (6 per player, 60 total, 12 s lifetime), client effects (24), toasts (4), feast payout history (3 events).
- **Per-player tables** in Feeding, Action, Safety and State are cleared on `PlayerRemoving`. `StateService` no longer accepts departed players (regression 7).
- **Per-frame work:**
  - Animal AI runs at 15 Hz with the move step every frame.
  - The projectile step does one raycast per projectile per frame, plus mouth/body distance checks against animals within 25 studs.
  - The client preview does up to 22 raycasts per frame, and only while charging.
  - The HUD now writes properties only when they change.
- **Repeated full-profile pushes** are throttled to 4 per second per player, and the HUD skips identical pushes.
- **Not measured:** frame time, memory and network bandwidth. No figures are claimed.

## Known limitations

- The feast giant can only be fed by thrown food. There's no melee or alternative path (by design).
- The per-key write throttle model errors instead of queueing, which is stricter than Roblox.
- Animals move through decorative props (anchored CFrame movement, no pathfinding). Stuck recovery only covers lack of progress.
- The local gate-open state is client-side by design. The server enforces access by bouncing players out of locked islands.

## Expansion pass (PR #4): 1,000 content additions, then the four follow-up gaps

All checks below are **offline**: unit/content rules in Lune, plus the engine simulator running the
real scripts from the built place. Roblox Studio is not available on this Linux host, so nothing here
was rendered, physically simulated, networked for real, or played on a device.

| Gap | Implementation | Regressions |
|---|---|---|
| Decoration rendering | `DecorService` (server) builds placed pieces with `DecorFactory` into `Workspace.WildFeastDecor/Garden_<UserId>`, so all players see them (replicated like any Workspace part). Each player in the server gets one of `Config.Decor.Lanes` (6) interleaved plot rings per island. Models are diffed against the owner's saved `decorPlaced` (only changed plots are rebuilt) and destroyed when the owner leaves. Parts are anchored and have CanCollide, CanQuery and CanTouch off; ≤ 6 parts per model, ≤ 6 × 3 × 12 models in total. A player beyond the lane limit keeps the effects and is told their pieces aren't drawn. | integration: plot transform on its island, swap, hostile placement, another player can't remove it, cleanup on leave, rejoin rebuilds the saved garden, lane bound + notice; fuzz: model and folder bounds, ownership invariants |
| Food bar pinning | The HUD bar comes from `Economy.barFoods`: free food, selection, the **server-saved** `pinned` list, core foods, then every other stocked food, in pages. With more than 6 foods it shows 5 foods + ◀ ▶ (fits the original 780-px bar). Keys 1–6 pick visible slots; Q/L1/R1 cycle all bar foods and the page follows the selection; touch taps select. The Pantry has Pin/Unpin and Select. | client: pin via the Pantry (double tap sends once), 📌 marker, paging, key 2 = 2nd visible, R1 cycles and stays visible, tap selects, hostile pins refused; unit: bar bounds, pin cap |
| Menu search | One persistent `SearchBox` above the panel content (never rebuilt, so typing keeps focus; refreshes never overwrite its text). There is one query per tab, combined with that tab's category filter and paging, with an explicit empty-results row. It covers Pantry (156 foods), Kitchen (200), Quests (300), Decor (150), Upgrades (105) and Journal (106 species, with visitor lure buttons). Hotkeys ignore keys Roblox marks as processed (typing). | client: name/description matches, filter + search + paging, empty results, refresh during typing, per-tab queries, processed keys ignored |
| Efficient profile updates | `ProfileSync` (shared, pure). The server sends one full snapshot on join and on `RequestState`, then sequenced deltas per top-level section: whole replacement for scalars/arrays, a second-level `set` + `del` patch for maps (deletions travel as key lists because nil can't cross a remote). Unchanged pushes are skipped. A client that sees a gap ignores the delta and requests a snapshot. Each player has a private server-side copy, released on leave. | unit: 3,000-step seeded diff/apply fuzz through JSON (nested deletions, arrays), malformed deltas; integration: contiguous seqs, mirror == server, deletions, no cross-player state, skip/resync/cleanup; client: mirror == server, gap → resync, junk payloads; fuzz: no gaps, final mirror == server for every player |

**Payload measurements (JSON-encoded bytes in tests; not live network numbers):**
- Late-game profile (156 foods, 106 species, 300 quests claimed): full snapshot **18,635 B**. Typical deltas: one feed **180 B**, one cook **141 B**, placing a decoration **67 B**.
- Simulator (fresh profile, 14 mixed changes): full snapshot 634 B, largest delta 201 B.
- Worst-case maxed save: 38,166 B of JSON.

**Tooling this pass.**
- selene had no execute bit in the local mise install (`chmod +x`, not a repo change). It now runs: 0 errors, plus 6 style warnings, all in lines that predate the expansion.
- luau-lsp was run against the downloaded Roblox `globalTypes.d.luau`. It found ~190 strict-mode type errors in the expansion data and Config loader (mixed-type rows, the Lune-only string require). These are fixed and the result is now **0 errors**.

**Still not verified:** visual appearance and placement of decorations in a real renderer, actual replication timing, touch/gamepad feel of the paged bar, TextBox focus behaviour on real devices, real network byte counts.

## QA pass 4 (expansion follow-up audit)

Offline only (Lune unit/content suites plus the engine simulator on the built place). No Roblox Studio, renderer, device or real network is available on this Linux host.

**Defects found and fixed.** Each has a regression that was confirmed **failing on the pre-fix build** (built from the previous commit in a worktree) and passing after the fix.

| # | Defect (reproduced) | Fix | Regression |
|---|---|---|---|
| 1 | Any client could force a full snapshot (~18.6 KB late-game) on every `RequestState`, limited only by the action rate limiter: 30 requests in 3 s → 12 snapshots. | Snapshots answer resyncs at most every `Config.Remote.FullSnapshotInterval` (2 s). Ordinary deltas keep flowing while one waits, so joins aren't delayed. | integration: spam → ≤ 3 snapshots; changes still arrive promptly during the throttle window |
| 2 | Lost resync: after a real gap, the client asked once. If that request was lost (or throttled), every later delta was ignored forever and the mirror froze. | The client re-asks after 3 s while it is still out of sync. | client: one State delta and the RequestState are both dropped in transit → mirror recovers |
| 3 | A stale or duplicate full snapshot (seq ≤ last applied) replaced a newer mirror. | Snapshots are applied only when `seq > lastSeq`. | client: old seq-1 snapshot ignored |
| 4 | Decoration lanes: a 7th player waiting for a lane was never drawn when one freed up; they had to change a placement to be drawn. | Freeing a lane hands it to a waiting player (deferred out of PlayerRemoving). | integration: waiting player drawn when a lane frees; models stay bounded |
| 5 | `SelectFood` accepted an out-of-stock food (likelier with pins), so every throw then failed silently with `no_food`. | The server refuses with a notice and keeps the current selection. | integration: empty food refused + notice; stocked food selects |

**Probed with no defect found** (now covered by tests): unpinning the selected food; the last item thrown falling back to the free food with the bar following; ◀/▶ paging wrap; a 300-character query of Lua pattern characters (plain find, clamped to 40, empty-results row); Map (a non-search tab) hiding the box and restoring the per-tab query; bar and panel surviving respawn; the rejoin garden rebuild alongside lane hand-off.

**Six-player decoration limit (unchanged by design).** `Config.Decor.Lanes = 6` gardens are drawn per server.
- **Over the limit:** a 7th player's pieces keep every gameplay effect, and they are told they aren't drawn.
- **Handover:** they now get the next freed lane automatically.
- **Bounds:** models never exceed 6 × 3 × 12, with ≤ 6 inert parts each. Fuzz checks the model count, the garden folder count, ownership (never more placed than owned), islands and plot ranges.

**Simulator shims added:** `client.dropIncoming` / `client.dropOutgoing` drop server→client and client→server messages to test recovery. The delta tests compare against the real server profile (an independent oracle), not the harness's own merge.

**Fuzz reproducibility:** extra seeds came from `os.time()` and the base wasn't printed. One batch in this pass reported a failure whose seed was lost (only the summary line was kept). The base is now printed and accepted as the 4th argument. 21 seeds at fixed base 1763047000 and a further 10 at base 1794584187, all × 250 steps, passed. That one failure is **unresolved**: its seed is unknown and it could not be reproduced in the time available.

**Final evidence** (two consecutive clean full passes after the last source change): unit 34/34, content 20/20 (1,000 counts, cross-references, reachability, manifest sync, ProfileSync fuzz), server simulator 57/57, client simulator 28/28, fuzz 10 + 21 seeds, StyLua clean, selene 0 errors (6 pre-existing style warnings), luau-lsp strict 0 errors. `WildFeastIslands.rbxl` was rebuilt byte-identically twice and reopened by `verify-place` with source parity.
