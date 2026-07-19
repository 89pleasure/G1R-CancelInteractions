# Agent Instructions

These instructions apply to this repository.

## Project Scope

This repository contains a standalone UE4SS Lua mod for Gothic 1 Remake. The
mod lets the player cancel an accidental blocking interaction while the game is
still moving the hero toward its target. It also lets the player end a
player-initiated conversation before the conversation UI appears.

Version 0.7.2 uses the game's interaction lifecycle directly:

- Track a player-owned `GameplayAbilityBlockingInteraction` from
  `SetMoveToTask` until its matching `OnMoveToTaskEnded`.
- Preserve a cancelled move-to result for one short directional-input edge so
  WASD can cancel approaches whose native task-end callback runs first.
- Track the exact player-owned `AbilityTask_MoveIntoPositionForInteraction`
  and its `GameplayAbilityInteractFreePoint` owner for benches, ladders, and
  equivalent FreePoint approaches.
- End a tracked FreePoint approach only with `OnRequestEndQuick`, before
  `bIsReadyToStartAnimation` or successful alignment hands control to the
  object's animation.
- Cancel the tracked ability with `K2_CancelAbility` after disabling the
  cancellation cooldown through `m_ApplyCooldown`.
- Track a player-initiated `ConversationGroup` only until
  `ClientShowConversationUI`.
- Never cancel mining interactions. Cancelling mining through this path can
  award ore incorrectly.

The supported inputs are keyboard and mouse keys configured through
`CancelKeys`. Controller and EnhancedInput handling are outside the scope of
this lean runtime.

The user-facing defaults are:

```ini
Debug=false
CancelKeys=F,R,ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
```

Keep this repository focused on the standalone mod. Do not add files from the
G1R Optimizer app, local game installs, crash dumps, logs, or exploratory
`examples/` folders. Curated FModel exports that are intentionally used as
development references belong under `reference/g1r-config/`.

## Repository Layout

- `Scripts/main.lua` contains UE4SS hooks, tracked runtime state, key binds,
  game-thread cancellation, and core logging.
- `Scripts/cancel_core.lua` contains pure Lua config, key, identity, and
  lifecycle policy that can be tested without the game.
- `Scripts/pleasure_lib_loader.lua` loads the required neighboring PleasureLib
  mod without relying on `mods.txt` load order.
- `reference/g1r-config/` contains FModel-exported Gothic 1 Remake config and
  gameplay tag files used as development references.
- `.luarc.json` configures LuaLS to read UE4SS-generated types from the local
  `Mods/shared` directory.
- `G1R_CancelInteraction.ini` defines user-facing defaults.
- `enabled.txt` enables the UE4SS mod.
- `tests/g1r_cancel_interaction_core.test.lua` covers pure policy and mocked
  runtime behavior.
- `README.md` documents installation and manual game testing.

## Implementation Rules

- Keep game-facing code defensive. Wrap UObject access, property writes,
  reflected calls, hook registration, and scheduled callbacks in `pcall` or
  PleasureLib safety helpers when an object may be missing, stale, or invalid.
- Use PleasureLib 0.5.1 or newer for generic logging, config/file/string
  helpers, object validation and lookup, safe calls, hook registration, and
  delayed game-thread work where its API fits.
- Keep decision logic in `cancel_core.lua` when it can be expressed without
  UE4SS APIs. This makes ownership, mining exclusion, key parsing, and lifecycle
  regressions testable outside the game.
- Keep config defaults aligned across `cancel_core.lua`,
  `G1R_CancelInteraction.ini`, `README.md`, `NEXUSMODS.md`, and tests.
- Track both the UObject and a stable full-name identity. Clear lifecycle state
  only for the matching ability or conversation.
- FreePoint tracking uses the factory post-hook as its primary source and a
  delayed `NotifyOnNewObject` callback as fallback. Dedupe by exact task and
  retain a finished-task tombstone so delayed discovery cannot reopen a
  completed window.
- A FreePoint record supersedes an overlapping blocking record. One key press
  must invoke either `OnRequestEndQuick` or `K2_CancelAbility`, never both.
- Treat `EGenericTaskResult::Cancelled` as a directional-input race only for
  `A`, `W`, `S`, and `D`. Do not extend the edge to successful, failed, unknown,
  or non-directional task endings.
- Treat tracked state as single-use. Copy and clear it before scheduling a
  cancellation so repeated key presses cannot call cancel methods on the same
  stale object.
- Guard delayed and game-thread callbacks with a runtime generation token.
  Increment the generation and clear all tracked state before a map load.
- Revalidate every captured UObject inside the game-thread callback.
- Set `m_ApplyCooldown=false` immediately before cancelling a valid tracked
  blocking ability. Do not change cooldown behavior for untracked or excluded
  abilities.
- Preserve the mining exclusion unless a replacement is proven safe in-game
  without granting ore or other rewards.
- Conversation tracking must be player-owned. Allow the new object enough time
  to initialize, validate its `Initiator`, and stop offering mod cancellation
  as soon as `ClientShowConversationUI` runs.
- Keep cancellation scoped to the lifecycle hooks. Do not reintroduce
  AbilitySystem scans, generic movement-task cancellation, locomotion mutation,
  movement-state heuristics, object-specific interaction branches, global
  object scans, or high-frequency input hooks.
- Use `RegisterKeyBind` only for configured keyboard and mouse keys. Do not add
  controller aliases, AbilityInput hooks, EnhancedInput hooks, polling, or
  controller discovery to the 0.7 runtime.
- Keep runtime logging quiet by default. Normal mode should log startup and
  capability failures. Cancellation and detailed lifecycle state belong behind
  `Debug=true`.
- Do not add third-party dependencies unless there is a clear need and they
  work in the UE4SS Lua runtime.
- Do not `require` generated UE4SS binding/type files from Lua scripts. They are
  editor-only LuaLS input and can override runtime globals when loaded.
- Prefer ASCII in source and docs unless a file already has a clear reason to
  use non-ASCII text.

## Interaction Lifecycle

The normal ability path is intentionally narrow:

1. `GameplayAbilityBlockingInteraction:SetMoveToTask` identifies the active
   player-owned interaction.
2. A configured key consumes that tracked state and schedules
   `K2_CancelAbility` on the game thread.
3. `GameplayAbilityBlockingInteraction:OnMoveToTaskEnded` closes the cancel
   window when the hero reaches the target. A cancelled result retains one
   short edge for a matching directional key because some interactions report
   task cancellation before UE4SS dispatches that key bind.

The FreePoint path is also lifecycle-bounded:

1. The `BP_TaskMoveIntoPositionForInteraction` factory post-hook, with delayed
   object notification as fallback, identifies the exact player-owned task.
2. A configured key consumes that record and schedules
   `OnRequestEndQuick` for its `GameplayAbilityInteractFreePoint` owner.
3. `HandleAlignmentFinished` closes the window on successful alignment and
   preserves only a short directional edge for a cancelled result.
4. `OnInteractionTaskEnded` provides exact ability/root-task cleanup.

The conversation path is similarly bounded:

1. `NotifyOnNewObject("/Script/G1R.ConversationGroup")` observes a new group.
2. After initialization, the group is retained only when its `Initiator`
   belongs to the player.
3. A configured key requests `RequestEndConversation` while the approach is
   still pending.
4. `GameplayAbilityConversationV2WithUI:ClientShowConversationUI` closes the
   mod's conversation cancel window.

Do not broaden any cancel window without direct game evidence and regression
tests.

## UE4SS Type And Object Reference Workflow

- When developing `Scripts/*.lua`, use the LuaLS/UE4SS type information exposed
  through `.luarc.json` before guessing classes, properties, functions, or
  signatures. Treat generated types as editor hints, not runtime guarantees.
- An UE4SS Object Dumper snapshot is optional development input and is not
  stored at a fixed repository path. If a local snapshot is available, search
  its actual supplied path with targeted `rg` queries. Do not make the runtime
  depend on it and do not document a machine-specific path as part of the mod.
- Absence from a local dump does not prove that a class or object cannot exist
  in another save, map, menu state, or load session.
- Treat addresses and pointer-like fields as session-specific diagnostics only.
  Never hard-code them.
- UE4SS Object Dumper documentation:
  `https://docs.ue4ss.com/dev/feature-overview/dumpers.html#object-dumper`.

## Game Config Reference Workflow

- Use `reference/g1r-config/` before guessing G1R config defaults, gameplay tag
  names, or interaction semantics.
- Treat these files as development-only reference data. Do not load them from
  the mod at runtime and do not copy local game-install paths into Lua code.
- For relevant lifecycle and safety research, start with
  `reference/g1r-config/DefaultGameplayTags.ini` and its split tag files.
- If the FModel export is refreshed, replace `reference/g1r-config/` as a whole
  and keep `reference/g1r-config/README.md` aligned with the source export.

## Verification

Run these checks before committing Lua changes:

```bash
lua tests/g1r_cancel_interaction_core.test.lua
luac -p Scripts/main.lua
luac -p Scripts/cancel_core.lua
luac -p Scripts/pleasure_lib_loader.lua
```

For game-facing behavior changes, copy the mod into the UE4SS mod directory only
when explicitly asked, restart the game, and manually test:

1. cancelling a player blocking interaction immediately, halfway to the target,
   and just before arrival,
2. cancelling bench and ladder approaches with `A`, `W`, `S`, and `D` before
   arrival,
3. that cancellation no longer occurs after successful arrival or after the
   target animation/UI phase starts, including normal bench and ladder controls,
4. `F`, `R`, `ESC`, right mouse button, `A`, `W`, `S`, and `D`,
5. that the initial interaction press does not cancel itself,
6. a player-initiated conversation before and after its UI appears,
7. that NPC conversations and NPC interactions remain untouched,
8. that mining cannot be cancelled by the mod and never grants ore on cancel,
9. repeated cancel presses, consecutive interactions, map loads, save changes,
   death, and respawn,
10. that cancelled interactions can be started again and normally completed
   interactions keep their expected cooldown and rewards.

## Git Hygiene

- Commit only files that belong to this standalone mod repository.
- Do not commit `examples/`, crash folders, minidumps, generated logs, local
  dumps, or local game-install copies.
- Keep commits small and describe the player-visible behavior or safety fix.
