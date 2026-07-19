# G1R Cancel Interaction

G1R Cancel Interaction is a UE4SS Lua mod for Gothic 1 Remake that lets you
cancel accidental interaction movement with `ESC`, right mouse button,
controller B/Circle, controller Interact after start, or the movement keys
`A`, `W`, `S`, and `D`.

The mod is meant for situations where the hero starts walking toward an
unwanted interaction target. Press a cancel key to stop the walk before the
object animation or UI phase starts.

## Features

- Cancel interaction movement with `ESC`, right mouse button, controller
  B/Circle, controller Interact after start, `A`, `W`, `S`, or `D`.
- Cancel accidental clicks while the hero is walking to an interaction target.
- Uses the same generic movement-task path for interactable objects instead of
  per-object cancel branches.
- Keeps the game's normal menu handling intact.
- Avoids cancelling during unsafe states such as pause, open menus, dialogue,
  cutscenes, combat, airborne movement, or unsafe transitions.
- Configurable cancel keys and cooldown.
- Quiet by default, with optional debug and discovery logging for
  troubleshooting.

## Requirements

- Gothic 1 Remake
- UE4SS 3.0.1 or a newer G1R-compatible experimental build, installed and
  enabled for the game
- PleasureLib 0.5.1 or newer

## Development Setup

This repository includes `.luarc.json` for LuaLS/VS Code IntelliSense with
UE4SS-generated bindings. The local setup expects generated bindings here:

```text
/gaming/SteamLibrary/steamapps/common/Gothic 1 Remake/G1R/Binaries/Win64/ue4ss/Mods/shared/
```

If the bindings are missing, open the UE4SS GUI console, go to the Dumpers tab,
and click `Dump Lua Bindings`. UE4SS writes the generated files into
`Mods/shared/types`.

Do not `require` or otherwise include generated binding files in mod scripts.
They are editor-only type information and can override UE4SS runtime globals if
loaded by Lua.

## Installation

1. Install UE4SS for Gothic 1 Remake if it is not already installed.
2. Install PleasureLib into the same UE4SS mods directory:

   ```text
   <GameDir>/G1R/Binaries/Win64/ue4ss/Mods/PleasureLib/
   ```

3. Create this folder for the mod:

   ```text
   <GameDir>/G1R/Binaries/Win64/ue4ss/Mods/G1R_CancelInteraction/
   ```

4. Copy the mod files into that folder.
5. Make sure the installed folder contains these files:

   ```text
   enabled.txt
   G1R_CancelInteraction.ini
   Scripts/main.lua
   Scripts/cancel_core.lua
   Scripts/mod_runtime.lua
   Scripts/player_asc.lua
   Scripts/pleasure_lib_loader.lua
   ```

6. Start the game with UE4SS enabled. The mod loads automatically.

The included loader can find PleasureLib in the neighboring mod folder even
when `mods.txt` does not define the load order.

## Configuration

The default configuration is stored in `G1R_CancelInteraction.ini`:

```ini
DiscoveryMode=false
Debug=false
CancelKeys=ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
ControllerCancelEnabled=true
ControllerCancelKeys=CONTROLLER_FACE_RIGHT,CONTROLLER_FACE_BOTTOM
CooldownMs=250
```

### Common Options

- `CancelKeys` controls which keys trigger cancellation. Use
  `RIGHT_MOUSE_BUTTON` for right mouse click.
- `ControllerCancelEnabled=true` enables controller cancellation.
- `ControllerCancelKeys` keeps the semantic controller button names used by the
  mapped EnhancedInput controller matching.
  `CONTROLLER_FACE_RIGHT` is B/Circle.
- `CONTROLLER_FACE_BOTTOM` is Interact/Confirm. The initial interact press is
  ignored for a short guard window, then a later press can cancel.
- `CONTROLLER_FACE_LEFT` is available for future testing if you want Xbox
  X/PlayStation Square.
- UE4SS `RegisterKeyBind` is not the controller solution here. Normal
  controller cancellation uses a narrow EnhancedInput check for the configured
  controller buttons. AbilitySystem input remains a quiet fallback.
- Every controller path delegates to the existing `ESCAPE` cancel path.
- `CooldownMs` controls the delay between cancel attempts.
- `Debug=true` enables lightweight runtime logging.
- `DiscoveryMode=true` logs targeted hook diagnostics for troubleshooting.

Leave debug and discovery mode disabled during normal play unless you need to
collect UE4SS log output for a bug report.

## Notes

This mod focuses on cancelling the movement toward an interaction target. It
does not cancel object animations or replace the game's normal menu controls,
and it intentionally avoids cancelling once an interaction has reached states
where the game should handle it normally.

For controller input the stable implementation is EnhancedInput-driven:

- AbilitySystem cancel hooks are useful as a quiet fallback, but not sufficient
  on their own.
- A narrow `EnhancedInput.InputTrigger:UpdateState` hook filtered to press-like
  events on the local `EnhancedPlayerInput` is required for mapped controller
  cancellation.
- The normal hot path keeps controller scans throttled, cached, and deferred
  outside the `UpdateState` callback to avoid the instability seen with broad
  trigger or mapping diagnostics.

If a game update changes internal interaction hooks and a specific interaction
stops cancelling, enable `DiscoveryMode=true`, reproduce the issue, and include
the relevant UE4SS log output when reporting it.

For controller regressions, first confirm these lines appear after reload:

- `Controller cancel ability input hooks registered: 4`
- `Controller cancel EnhancedInput hooks registered: 1`

## Updating to 0.6.0

PleasureLib is now a required neighboring mod. Install PleasureLib 0.5.1 or
newer and replace the existing G1R_CancelInteraction files. Configuration and
savegames do not require migration.

## Current Version

`0.6.0`
