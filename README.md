# Wild Feast Islands

An original, cooperative Roblox feeding game (bounded MVP). Toss food in an arc to befriend six animal species across three connected low-poly islands, discover what each one loves, restore their habitats, and team up (or go solo) to feed a giant friendly visitor at Feast Cove.

**Download:** [`WildFeastIslands.rbxl`](WildFeastIslands.rbxl). It's a genuine binary place file built by Rojo, with the islands baked into Workspace by Lune. Open it in Roblox Studio and press Play. No Command Bar setup is needed.

## Gameplay

| | |
|---|---|
| Habitats | Sunpetal Meadow (start), Mistfern Grove, Coralglass Lagoon, joined by bridges. Locked islands are opened in the **Map** tab. |
| Animals | Puffhop, Waddlebill (meadow) · Mossback, Glimmerfox (grove) · Bubblefin, Pinchpearl (lagoon). States: Idle → Approach → Anticipate → Eat → Happy (plus Refuse), with stuck recovery. |
| Foods | Sunberry (free and unlimited), Clover Bun, Honey Drop, Fern Roll, Kelp Bundle, Starfruit. Each species has one favourite, one dislike, and likes the rest. |
| Skill | Hold to charge, release to throw. A trajectory preview and landing ring show where it will go, and **◎ CATCH!** (with larger dots) appears when the arc meets a mouth. Mouth catch = Perfect ×2, body hit = Good ×1.35, food on the ground = ×1. Anticipating animals have bigger mouths. |
| Progression | Coins (spent) and Research (a knowledge threshold, never spent) come from feeding, discoveries and trust levels. Throw upgrades: Strong Arm, Quick Hands, Steady Aim. Prep upgrades: Big Batches, Fresh Recipes. Each habitat has 3 restoration steps that change its visuals and give a coin bonus there. |
| Journal | Species, trust level, every food preference you've discovered (icon + word), hints, and stats. |
| Grand Feast | A repeatable cooperative event. Ring the pier bell (or wait for the auto-start). Appetite = 16 + 12 per extra player, so one player can finish it. Every contributor gets a participation reward plus a capped share of the pool, paid once per event. |
| Onboarding | A tutorial Puffhop waits 16 studs in front of the spawn, so the first feeding takes seconds. A goal card always shows the next step, and contextual hints plus a world marker can be switched off. |

There are no purchases, trading, paid randomness, prestige or forced waits. Free food never runs out.

**Controls.** Mouse: hold LMB (or F), release to throw; 1–6 / Q select food; X cancels; P/U/M/J/O open tabs. Touch: hold the round THROW button and aim with the camera. Gamepad: R2 throws, L1/R1 select food, Y opens the menu, B closes it.

## Architecture

```
src/shared   (ReplicatedStorage.Shared)  Config (central economy), Economy, Validation, Trajectory,
                                          SaveSchema, FeastRules, RateLimiter, Rng, Guard. Pure Luau, unit tested
src/server   (ServerScriptService.Server) Main + Services: Data, State, Animal, Feeding, Feast, Action, Safety;
                                          World/WorldBuilder + AnimalFactory (procedural parts, no assets)
src/client   (StarterPlayerScripts.Client) Store, ThrowController, Effects, WorldVisuals, Hud, Ui
```

- **Server-authoritative.** The client sends only `(foodId, unitDirection, power)` and small action tables. The server checks types, string lengths, NaN/inf, unit length, pitch range, food ownership/unlocks, the cooldown (plus a token bucket), whether the character is alive, the origin, and per-player/global projectile caps. It launches from the character's own head and simulates the arc itself. It decides mouth/body/ground hits, the max range, and whether the habitat is unlocked before paying a reward. Clients only render the broadcast arc.
- **Bounded resources.** At most 24 animals, 4 projectiles per player and 64 in total, 6 ground foods per player and 60 in total (12 s lifetime), and 24 client effects. Saves are capped and sanitised.
- **Persistence.** Profiles are versioned (schema v2 with a v1 migration). Loads use `UpdateAsync` session locks inside pcall, with bounded retries and backoff. If a load fails, the profile is locked elsewhere, or the save comes from a newer schema, the session runs in *Unsaved* mode: the player is told, and their data is never overwritten. Saves autosave every 120 s and save + release on leave and on `BindToClose`. In Studio without API access, the game uses an explicitly labelled **Studio memory** mode (banner shown). Live servers never fall back to memory.
- **Per-player world.** Gates and restoration visuals are applied locally from each player's own profile. The server still enforces access: anyone found inside a locked island is moved back, and players who fall into the sea are rescued.
- No HTTP, `loadstring`, external `require(assetId)`, model scripts or uploaded assets. The sounds are built-in `rbxasset://` engine sounds.

## Building and checking

Tools are pinned in `mise.toml` (Rojo 7.7.1, Lune 0.11.1, luau-lsp, selene, StyLua).

```sh
./scripts/build.sh               # rojo build -> lune bake world -> lune reopen & verify WildFeastIslands.rbxl
lune run tests/run.luau          # 28 unit tests: rules, validation, persistence schema, feast, builders
lune run tests/integration.luau  # 27 server scenarios run from the built place file in the simulator
lune run tests/client.luau       # 15 client+server scenarios (input, menus, layout arithmetic)
rojo sourcemap -o sourcemap.json && luau-lsp analyze --definitions=<roblox globalTypes.d.luau> --sourcemap=sourcemap.json src
selene src && stylua --check src tests scripts
```

For live development, run `rojo serve`. The server rebuilds the world when the baked folder is missing.

### The offline engine simulator

`tests/sim/Engine.luau` and `tests/sim/Client.luau` load the **real scripts from the built `.rbxl`** and run them against hand-written stand-ins: a virtual clock and `task` scheduler, fake `Players`/`RunService`/`DataStoreService` (with latency and failure injection, shared between "servers"), RemoteEvents that copy arguments and add latency, a ray-vs-part `Raycast`, `ProximityPrompt`/button signals and fake input objects. **It is not Roblox.** Physics, replication, rendering, the GUI layout engine, the default touch controls, real networking and real DataStore behaviour are not simulated. The layout checks are arithmetic on the HUD's own offset sizes, so they are not screenshots. Two harness-only shims exist because Lune differs from the engine: `Position` is mirrored from `CFrame` for moving parts, and client `X.Adornee = nil` assignments are rewritten (the place file is untouched).

## Verification status

**Performed (offline, outside Roblox Studio):**
- `luau-lsp analyze` in `--!strict` against the Roblox API definitions: 0 errors. selene: 0 errors. StyLua check passes.
- 28 unit tests, 27 server integration scenarios and 15 client scenarios pass. The scenarios cover:
  - Boot from the place file, join and state push.
  - Tutorial catch, ground feeding and edge-of-island feeding.
  - Gates, origin tolerance, spam caps, death/respawn/leave cleanup.
  - Stuck recovery, model rebuild, long-run island bounds.
  - Solo, three-player and timed-out feasts with single payment.
  - Save/rejoin, a quick rejoin during a retried save, foreign locks, newer schemas, an outage at join, shutdown and Studio memory mode.
  - Hostile payloads, sea rescue and locked-island bounce.
  - On the client: every tab with new and advanced profiles, keyboard/touch/gamepad throws, slide-off and cancelled touches, respawn while charging, the pantry prompt, buying through the UI, no rebuild on identical pushes, the bell button, and HUD overlap at 667×375, 844×390, 1024×768 and 1366×768.
- `WildFeastIslands.rbxl` was rebuilt and reopened with Lune. It has the binary `<roblox!` header, script sources that match the repo, 6 remotes and 678 baked world parts.

**Not verified (needs Roblox Studio / devices / live servers, which weren't available here):**
- Real Studio playtests and play sessions.
- Real physics and character movement (gates opened locally, bridge and pier collisions, falling).
- Actual on-screen layout with the top-bar safe insets and text wrapping.
- The real touch jump-button position (the HUD reads it when present and falls back to PlayerModule's documented numbers).
- Gamepad selection and navigation behaviour.
- Two real clients and reconnects over a real network.
- DataStore throttling and real `UpdateAsync` ordering.
- Whether the built-in sound paths load.
- Frame time and network cost.

Please playtest in Studio before publishing. The game has not been published, and no purchases are configured.

The game is original and only broadly inspired by casual feeding games. The reference video was not inspected, and no branding, assets or UI were copied.
