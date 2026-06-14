# Agent Instructions

These instructions apply to this repository.

## Project Scope

This repository contains a UE4SS Lua mod for Gothic 1 Remake. The mod lets the
player cancel selected interaction movement and animation phases with `F`, `ESC`,
or movement keys.

Keep this repository focused on the standalone mod. Do not add files from the
G1R Optimizer app, local game installs, crash dumps, logs, or exploratory
`examples/` folders.

## Repository Layout

- `Scripts/main.lua` contains UE4SS runtime hooks, UE object access, key binds,
  core logging, and game-thread calls.
- `Scripts/cancel_core.lua` contains pure Lua policy and parsing logic that can
  be tested without the game.
- `Scripts/runtime_diagnostics.lua` contains verbose runtime scan and discovery
  logging helpers.
- `dumps/UE4SS_ObjectDump.txt` is a local UE4SS Object Dumper snapshot for
  development research.
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
- Do not cancel crafting after the menu/action phase has started. Crafting
  cancellation should remain limited to the movement phase where
  `movementAction == 7`.
- Avoid repeated calls to game ability cancel methods on stale objects. Preserve
  the successful-cancel lockout unless a replacement is proven safe in-game.
- Keep runtime logging quiet by default. Verbose state and discovery logs should
  stay behind `Debug=true`, `DiscoveryMode=true`, or `RuntimeFunctionScan=true`.
- Do not add third-party dependencies unless there is a clear need and they work
  in the UE4SS Lua runtime.
- Do not `require` generated UE4SS binding/type files from Lua scripts. They are
  editor-only LuaLS input and can override runtime globals when loaded.
- Prefer ASCII in source and docs unless a file already has a clear reason to use
  non-ASCII text.

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

1. accidental interaction clicks while the hero walks to the target,
2. cooking pan interactions,
3. bench interactions,
4. `F`, `ESC`, `A`, `W`, `S`, and `D`,
5. that open crafting menus are not closed by movement-key cancellation logic.

## Git Hygiene

- Commit only files that belong to this standalone mod repository.
- Do not commit `examples/`, crash folders, minidumps, generated logs, or local
  game-install copies.
- Keep commits small and describe the player-visible behavior or safety fix.
