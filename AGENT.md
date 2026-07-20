# Agent Instructions

These instructions apply to this repository.

## Project Scope

This repository contains a standalone UE4SS Lua mod for Gothic 1 Remake. The
mod lets the player cancel an accidental blocking interaction while the game is
still moving the hero toward its target. It also lets the player end a
player-initiated conversation before the conversation UI appears.

Version 0.8.6 uses the game's interaction lifecycle directly:

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
- Cancel every valid tracked blocking interaction with `K2_CancelAbility`
  after setting `m_ApplyCooldown=false`. For a mining directional edge whose
  movement already ended as cancelled before the key callback, accept that
  lifecycle result and do not issue a duplicate K2 call.
- Capture an authoritative mining ore baseline before cancellation. When
  `KeepOreOnMiningCancellation=false`, remove only the positive ore delta
  observed after that cancellation during a short, bounded recheck window and
  suppress the matching one-shot `ItMi_Orenugget` HUD notification. When the
  setting is `true`, leave the game's ore reward and notification unchanged.
- Never use `GameplayAbilityMining:Server_OnCloseRequested` or movement-task
  cancellation for mining. Missing authority, avatar, game state, trader
  manager, ore baseline, or rollback functions must never prevent the
  functional K2 cancellation; they only disable reward rollback and produce a
  safe diagnostic.
- Track a player-initiated `ConversationGroup` only until
  `ClientShowConversationUI`.
- Let users independently disable bench and ladder cancellation, early
  conversation cancellation, and WASD cancellation, and independently choose
  whether a mining cancellation retains ore through PleasureLib's native Mods
  settings page.
- Keep verified player-owned blocking mining cancellation always available
  through the blocking lifecycle path. Mining through the FreePoint quick-end path
  always remains excluded, and an ownerless FreePoint task must not clear an
  already verified mining record.

The supported inputs are keyboard and mouse keys configured through
`CancelKeys`. Controller and EnhancedInput handling are outside the scope of
this lean runtime.

The user-facing defaults are:

```ini
Debug=false
EnableBenchAndLadderCancellation=true
EnableConversationCancellation=true
EnableWASDCancellation=true
KeepOreOnMiningCancellation=false
CancelKeys=F,R,ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
```

Register the four native Bool options under
`Settings (Einstellungen) -> Mods -> G1R Cancel Interaction`. Their changes
must take effect immediately and PleasureLib must persist them to the loaded
INI. The INI remains the manual fallback; `Debug` and `CancelKeys` stay
INI-only.

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
  helpers, object validation and lookup, safe calls, hook registration,
  delayed game-thread work, native Bool settings, and targeted INI persistence
  where its API fits.
- Keep decision logic in `cancel_core.lua` when it can be expressed without
  UE4SS APIs. This makes ownership, mining reward routing, key parsing, and
  lifecycle regressions testable outside the game.
- Keep config defaults aligned across `cancel_core.lua`,
  `G1R_CancelInteraction.ini`, `README.md`, `NEXUSMODS.md`, and tests.
- Missing or invalid bench-and-ladder, conversation, and WASD settings must
  preserve their documented `true` defaults. A missing or invalid
  `KeepOreOnMiningCancellation` setting must preserve its documented `false`
  default, which keeps mining cancellation available through the verified
  blocking lifecycle and requests safe ore-delta rollback.
  When the new key is missing, read legacy `EnableMiningCancellation` as a
  fallback (`true` keeps the game's ore reward and `false` requests rollback);
  the new key takes precedence.
- Register exactly the four native Bool options with PleasureLib's
  `register_game_bool_setting`, stable mod-namespaced IDs, the
  `G1R Cancel Interaction` section, user-facing names and descriptions, and
  their exact INI keys. Keep `Debug` and `CancelKeys` out of Native Settings.
- Keep the mining Native Setting names exactly
  `Keep ore when cancelling mining` and
  `Erz bei Abbruch behalten`. Keep its user-facing description simple and
  explicit: mining can always be cancelled; On keeps the ore and its
  notification; Off gives no ore and shows no ore notification; the default is
  Off. Keep rollback implementation details out of that short description.
- Native setting changes must update runtime behavior immediately and persist
  through PleasureLib without rewriting unrelated INI values or comments.
  Native Settings registration or persistence failures must not break the
  manual INI fallback or the gameplay runtime.
- Apply live setting changes idempotently. They must not duplicate hooks or key
  binds, reopen a completed cancel window, revive stale state, bypass runtime
  generation checks, weaken FreePoint precedence, extend directional race
  edges, disable mining cancellation, or reset a valid mining cancel window
  when only ore retention changes.
- Track both the UObject and a stable full-name identity. Clear lifecycle state
  only for the matching ability or conversation.
- FreePoint tracking uses the factory post-hook as its primary source and a
  delayed `NotifyOnNewObject` callback as fallback. Dedupe by exact task and
  retain a finished-task tombstone so delayed discovery cannot reopen a
  completed window.
- A FreePoint record supersedes an overlapping blocking record. One key press
  must invoke at most one cancellation API: `OnRequestEndQuick` for a verified
  FreePoint interaction or `K2_CancelAbility` for a verified blocking
  interaction. If a mining movement already ended as cancelled before a WASD
  key callback, do not invoke K2 again. A later mining `RemoveCharacterOre`
  call is reward rollback, not a second cancellation route.
- When `EnableBenchAndLadderCancellation=false`, keep enough FreePoint
  lifecycle observation to supersede an overlapping blocking record, but mark
  the FreePoint record as non-cancellable and never resolve or call
  `OnRequestEndQuick`.
- While a newly observed FreePoint task is still missing its owner, suppress
  normal blocking cancellation fail-closed. Such an ownerless task must never
  delete, suppress, or replace an already verified `GameplayAbilityMining`
  blocking record. Release normal suppression only after the task is
  classified, becomes invalid, the bounded initialization timeout closes the
  potential blocking fallback, or the runtime context resets.
- Treat `EGenericTaskResult::Cancelled` as a directional-input race only for
  `A`, `W`, `S`, and `D`. Do not extend the edge to successful, failed, unknown,
  or non-directional task endings.
- Treat tracked state as single-use. Copy and clear it before scheduling a
  cancellation so repeated key presses cannot call cancel methods on the same
  stale object.
- Guard delayed and game-thread callbacks with a runtime generation token.
  Increment the generation and clear all tracked state before a map load.
- Revalidate every captured UObject inside the game-thread callback.
- Set `m_ApplyCooldown=false` immediately before cancelling any valid tracked
  blocking ability through `K2_CancelAbility`. Do not change the cooldown for
  untracked or excluded abilities, or when a mining directional edge reports
  that movement was already cancelled before the key callback.
- Always track the verified player-owned `GameplayAbilityMining` blocking
  path. In both `KeepOreOnMiningCancellation` states, a normal cancel uses
  `m_ApplyCooldown=false` plus `K2_CancelAbility`; a directional edge whose
  movement already ended as cancelled must not receive a duplicate K2 call.
  Never dispatch `Server_OnCloseRequested` or directly cancel a movement task. With the setting
  `true`, leave the game's ore credit unchanged. With the setting `false`,
  prepare rollback in advance by validating `K2_HasAuthority`, resolving the
  avatar through `GetAvatarActorFromActorInfo`, resolving the game state and
  `m_TraderManager`, and reading the baseline with `GetCharacterOre`. After
  cancellation, compare against that baseline immediately and through bounded
  delayed rechecks, and call `RemoveCharacterOre` only for the temporally
  observed positive delta. Do not hard-code the mining reward amount. Resolve
  the exact player inventory through `GothicCharacter:GetInventory`; while a
  verified rollback cancellation is pending, suppress at most one positive
  `ItMi_Orenugget` notification for only that inventory by setting the
  `InventoryComponent:OnItemAddedForHUD` count parameter to zero. Bound that
  state by runtime generation and a short timeout, clear it on consumption,
  replacement, map load, failed cancellation, or enabling reward retention,
  and never suppress unrelated items, inventories, normal mining, or the
  `KeepOreOnMiningCancellation=true` path. Missing authority, baseline,
  inventory, HUD hook, or reflected rollback capability must leave K2
  cancellation functional; if rollback preparation is unavailable, retain
  the reward and notification as the safe fallback and log a useful
  diagnostic. If a notification was already suppressed before a later
  rollback failure, report that explicitly. Always exclude FreePoint mining from
  `OnRequestEndQuick`.
- Conversation tracking must be player-owned. Allow the new object enough time
  to initialize, validate its `Initiator`, and stop offering mod cancellation
  as soon as `ClientShowConversationUI` runs.
- When `EnableConversationCancellation=false`, do not track or cancel
  conversations. Any hook or notification installed to support immediate
  re-enabling must remain inert while disabled, and the notification must not
  become active unless the UI boundary hook succeeded.
- Keep cancellation scoped to the lifecycle hooks. Do not reintroduce
  AbilitySystem scans, generic movement-task cancellation, locomotion mutation,
  movement-state heuristics, object-specific interaction branches, global
  object scans, or high-frequency input hooks.
- Use `RegisterKeyBind` only for configured keyboard and mouse keys.
  `EnableWASDCancellation=false` must suppress `A`, `W`, `S`, and `D` even when
  they remain in `CancelKeys`, and it must not retain directional input edges.
  Do not add controller aliases, AbilityInput hooks, EnhancedInput hooks,
  polling, or controller discovery to the current runtime.
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
   player-owned interaction and captures the authoritative ore context and
   baseline when it is verified mining.
2. A configured key consumes that tracked state and schedules
   `m_ApplyCooldown=false` followed by `K2_CancelAbility` on the game thread.
   A mining WASD edge that observes the native cancelled result first does not
   issue a duplicate K2 call. If mining reward retention is disabled and a
   safe baseline exists, immediate and bounded delayed checks remove only the
   positive ore delta observed after cancellation, while the exact one-shot
   ore HUD notification for the tracked player inventory is suppressed.
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

After every completed game-facing update, copy the verified five-file runtime
into the UE4SS mod directory unless the user explicitly asks not to. Do not
copy before automated checks pass. If the game is running, report that a
restart is required; never terminate it unless explicitly asked. Then manually
test:

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
8. that verified blocking mining cancels with both `F` and each enabled WASD
   key in both `KeepOreOnMiningCancellation` states; record ore immediately
   before and after cancellation so `false` can be verified to remove only the
   observed positive delta and suppress only its matching ore notification,
   while `true` retains both the ore and notification; confirm both states use
   the blocking lifecycle path, FreePoint mining never receives
   `OnRequestEndQuick`, and an overlapping ownerless FreePoint task never
   deletes the verified mining record,
9. after each mining-cancellation variant, mine the same spot normally and
   verify its reward notification, remaining amount, and visual/state behavior
   so cancellation does not silently consume or corrupt the deposit,
10. repeated cancel presses, consecutive interactions, map loads, save changes,
   death, and respawn,
11. that cancelled interactions can be started again and normally completed
   interactions keep their expected cooldown and rewards,
12. each of the three cancellation switches disabled independently and the
    mining reward option disabled, including all four options set to `false`;
    mining must still cancel through the blocking lifecycle and attempt
    ore-delta rollback, other configured keys must still work when WASD is
    disabled, and benches and
    ladders must not fall back to normal interaction cancellation when their
    switch is disabled,
13. changing all four native options under
    `Settings (Einstellungen) -> Mods -> G1R Cancel Interaction`, including
    immediate runtime behavior, exact INI persistence, repeated toggles without
    duplicate hooks or key binds, and persistence after a restart,
14. the manual INI fallback, including that `Debug` and `CancelKeys` remain
    INI-only and configured non-WASD cancel keys continue to work.

## Git Hygiene

- Commit only files that belong to this standalone mod repository.
- Do not commit `examples/`, crash folders, minidumps, generated logs, local
  dumps, or local game-install copies.
- Keep commits small and describe the player-visible behavior or safety fix.
