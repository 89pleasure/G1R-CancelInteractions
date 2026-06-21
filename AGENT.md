# Agent Instructions

These instructions apply to this repository.

## Project Scope

This repository contains a UE4SS Lua mod for Gothic 1 Remake. The mod lets the
player cancel movement toward an interaction target with `F`, `ESC`, right mouse
button, controller back/east-face input when available, or movement keys.

Keep this repository focused on the standalone mod. Do not add files from the
G1R Optimizer app, local game installs, crash dumps, logs, or exploratory
`examples/` folders. Curated FModel exports that are intentionally used as
development references belong under `reference/g1r-config/`.

## Repository Layout

- `Scripts/main.lua` contains UE4SS runtime hooks, UE object access, key binds,
  core logging, and game-thread calls.
- `Scripts/cancel_core.lua` contains pure Lua policy and parsing logic that can
  be tested without the game.
- `Scripts/runtime_diagnostics.lua` contains snapshot and discovery logging
  helpers.
- `dumps/UE4SS_ObjectDump.txt` is a local UE4SS Object Dumper snapshot for
  development research.
- `reference/g1r-config/` contains FModel-exported Gothic 1 Remake config and
  gameplay tag files used as development references for input, controller,
  CommonInput, Enhanced Input, and gameplay tag research.
- `.luarc.json` configures LuaLS to read UE4SS-generated types from the local
  `Mods/shared` directory.
- `G1R_CancelInteraction.ini` defines user-facing defaults.
- `enabled.txt` enables the UE4SS mod.
- `tests/g1r_cancel_interaction_core.test.lua` covers the pure core behavior.
- `README.md` documents installation and manual game testing.

## Implementation Rules

- Keep game-facing code defensive. Wrap UE object access and reflected calls in
  `pcall` where an object may be missing, stale, or invalid.
- When developing `Scripts/*.lua`, use the LuaLS/UE4SS type information exposed
  through `.luarc.json` to inspect available UE classes, properties, functions,
  and helper APIs before guessing names or signatures. Treat generated types as
  editor hints, not runtime guarantees; keep defensive `pcall` guards around
  game-facing access.
- Keep decision logic in `cancel_core.lua` when it can be expressed without UE4SS
  APIs. This makes regressions testable outside the game.
- Keep config defaults aligned across `cancel_core.lua`,
  `G1R_CancelInteraction.ini`, `README.md`, and tests.
- Keep cancellation generic. Do not reintroduce object-specific cancel branches;
  the runtime should track and cancel only movement tasks that take the player
  toward an interaction target.
- Avoid repeated calls to task cancel methods on stale objects. Preserve the
  successful-cancel lockout unless a replacement is proven safe in-game.
- Keep runtime logging quiet by default. Verbose state and discovery logs should
  stay behind `Debug=true` or `DiscoveryMode=true`.
- Do not use UE4SS `RegisterKeyBind` as the controller-input solution. In this
  project it is reliable for keyboard and mouse, but controller cancellation
  must go through the game's own input systems.
- Treat controller cancel as an EnhancedInput-driven path. AbilityInput hooks can
  stay as a low-noise fallback and discovery signal, but they are not sufficient
  for physical controller cancel and must not be treated as the primary source.
- Keep the normal controller hot path narrow. Expensive `EnhancedActionMappings`,
  `ActionInstanceData`, `GothicInputConfig`, and trigger-property dumps belong
  behind `DiscoveryMode=true`, not in normal gameplay logging.
- `CONTROLLER_FACE_BOTTOM` is the controller interact/confirm input, equivalent
  to `F`. It is intentionally supported as a cancel button, but only through the
  mapped EnhancedInput action path and with an initial interact-press guard.
- Cache local controller context before using high-frequency hooks. Re-resolving
  `PlayerInput` or scanning broad object state on every `UpdateState` callback
  is a known source of avoidable hitching.
- If controller cancel regresses, verify the runtime log registers both
  `Controller cancel ability input hooks` and
  `Controller cancel EnhancedInput hooks`. EnhancedInput is the required path;
  ASC hooks alone are not sufficient.
- Do not add third-party dependencies unless there is a clear need and they work
  in the UE4SS Lua runtime.
- Do not `require` generated UE4SS binding/type files from Lua scripts. They are
  editor-only LuaLS input and can override runtime globals when loaded.
- Prefer ASCII in source and docs unless a file already has a clear reason to use
  non-ASCII text.

## Controller Input Findings

These findings come from live UE4SS testing and should be checked before
repeating broad input discovery:

- Use the game's mapped keys, not hard-coded UE4SS controller key binds. UE4SS
  `RegisterKeyBind` is reliable for keyboard and mouse in this project, but not
  the controller cancel source.
- Controller cancel currently depends on
  `EnhancedInput.InputTrigger:UpdateState` plus the local `EnhancedPlayerInput`.
  Keep this hook narrow: only press-like trigger classes, only local player
  input, and only configured mapped controller keys.
- Do not scan EnhancedInput action instances directly inside the UpdateState
  hook. Schedule the scan into the game thread and deduplicate pending scans.
  Direct or repeated scans from the hook were crash-prone.
- Check the UpdateState event parameter before doing any player-input lookup or
  action scan. In observed logs, `p1=0` is high-frequency non-press traffic,
  while `p1=1` or `p1=2` are press-like events. `p1=0` must return early.
- `InputTriggerReleased`, AbilityInput release hooks, `PlayerController`
  key-state probes such as `WasInputKeyJustReleased`, and raw
  `InputActionValue` fields did not provide a stable release signal in UE4SS.
  Do not reintroduce them without fresh evidence from logs.
- `FACE_BOTTOM` maps to interact/confirm and `FACE_RIGHT` maps to jump in the
  tested controller setup. Some game interactions already cancel with
  `FACE_RIGHT` by default, but the mod goal is to make the mapped interact button
  usable for cancel too.
- The interact button cancel is handled as a second press after interaction
  start, guarded by `INTERACT_START_PRESS_IGNORE_MS`. Do not replace this with
  broad release arming unless a reliable release signal has been proven in game.
- Keep AbilityInput logging quiet. It is useful only for confirming hook
  registration or discovering stable ability IDs; it did not explain the mapped
  controller button behavior.
- Heavy EnhancedInput diagnostics such as raw `InputActionValue`, trigger
  property dumps, `EnhancedActionMappings`, and broad GothicInputConfig summaries
  belong only in targeted discovery sessions. Remove or gate them once the
  current issue is understood.
- If a crash appears after keyboard input while an interaction is active, inspect
  whether EnhancedInput is still scheduling scans for non-press events. The known
  bad signature is repeated `params=p1=0` followed by `reason=schedule-press` or
  action-instance scanning.

## Object Dump Workflow

- Use `dumps/UE4SS_ObjectDump.txt` before guessing reflected class, function,
  property, hook, or `StaticFindObject` paths. Search it with targeted `rg`
  queries; it is large and should not be loaded by the mod at runtime.
- Cross-check discoveries from the dump against `.luarc.json` LuaLS bindings,
  `DiscoveryMode=true` logs, and in-game behavior before changing cancellation
  logic.
- Treat memory addresses and pointer-like bracket fields as session-specific
  diagnostics only. Do not hard-code them. Stable development inputs are the
  object kind, full object/function/property path, owner path, names, and
  property offsets when validating reflected field access.
- The dump contains loaded objects from the session that produced it. Absence
  from this file does not prove that a class, asset, or function cannot exist in
  another save, map, menu state, or after force-loading assets.
- UE4SS Object Dumper docs:
  `https://docs.ue4ss.com/dev/feature-overview/dumpers.html#object-dumper`.

## Game Config Reference Workflow

- Use `reference/g1r-config/` before guessing G1R config defaults, gameplay tag
  names, input subsystem classes, CommonInput controller support, or Enhanced
  Input setup.
- Treat these files as dev-only reference data. Do not load them from the mod at
  runtime and do not copy local game install paths into Lua code.
- For input/controller work, start with:
  - `reference/g1r-config/DefaultInput.ini` for input subsystem classes,
    `EnhancedPlayerInput`, `GothicInputComponent`, and raw gamepad axis names.
  - `reference/g1r-config/DefaultGame.ini` for CommonInput platform support and
    controller data assets for Xbox, PlayStation, Switch, and mouse/keyboard.
  - `reference/g1r-config/DefaultGameplayTags.ini` for player ability, action,
    input context, and state tags such as `State.Interact`,
    `State.LockMovement`, `State.NoInput.*`, and `Event.Ability.Cancel`.
  - `reference/g1r-config/Tags/DefaultGameplayActions.ini` and
    `reference/g1r-config/Tags/DefaultGameplayEvents.ini` for split action and
    event tag lists.
- Do not infer final controller button names from gameplay tags alone. The tag
  files describe gameplay semantics, not physical controller mappings.
- Cross-check controller support against `dumps/UE4SS_ObjectDump.txt`, especially
  `GothicInputConfig`, `GothicInputAction`, `EnhancedPlayerInput`, and
  `EnhancedActionKeyMapping`, then validate with `DiscoveryMode=true` logs in
  game before hard-coding or documenting any controller defaults.
- When debugging controller behavior, prefer player-owned dumps and properties
  rooted at `G1RPlayerState`, `GameplayAbilityInteractFreePoint`,
  `EnhancedPlayerInput`, and `GothicPlayerControllerBaseBP_C`. NPC-owned task
  instances appear in dumps and hook traffic and are not enough to identify the
  local-player path safely.
- If the FModel export is refreshed, replace `reference/g1r-config/` as a whole
  and keep `reference/g1r-config/README.md` aligned with the source export.

## Verification

Run these checks before committing Lua changes:

```bash
lua tests/g1r_cancel_interaction_core.test.lua
luac -p Scripts/main.lua
luac -p Scripts/cancel_core.lua
luac -p Scripts/runtime_diagnostics.lua
```

For game-facing behavior changes, also copy the mod into the UE4SS mod directory
only when explicitly asked, restart the game, and manually test:

1. accidental interaction clicks while the hero walks to a target,
2. cancelling before the target object's animation or UI phase starts,
3. `F`, `ESC`, right mouse button, controller cancel input, `A`, `W`, `S`, and
   `D`,
4. that the game's normal object animation and menu handling continue once the
   movement phase has ended.

## Git Hygiene

- Commit only files that belong to this standalone mod repository.
- Do not commit `examples/`, crash folders, minidumps, generated logs, or local
  game-install copies.
- Keep commits small and describe the player-visible behavior or safety fix.
