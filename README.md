# G1R Cancel Interaction

G1R Cancel Interaction is a UE4SS Lua mod for Gothic 1 Remake that lets you
cancel accidental interaction movement with `ESC`, right mouse button,
controller B/Circle when detected at runtime, or the movement keys `A`, `W`,
`S`, and `D`.

The mod is meant for situations where the hero starts walking toward an
unwanted interaction target. Press a cancel key to stop the walk before the
object animation or UI phase starts.

## Features

- Cancel interaction movement with `ESC`, right mouse button, controller
  B/Circle when available, `A`, `W`, `S`, or `D`.
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
- UE4SS installed and enabled for the game

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
2. Create this folder in the game's UE4SS mods directory:

   ```text
   <GameDir>/G1R/Binaries/Win64/ue4ss/Mods/G1R_CancelInteraction/
   ```

3. Copy the mod files into that folder.
4. Make sure the installed folder contains these files:

   ```text
   enabled.txt
   G1R_CancelInteraction.ini
   Scripts/main.lua
   Scripts/cancel_core.lua
   Scripts/mod_runtime.lua
   ```

5. Start the game with UE4SS enabled. The mod loads automatically.

## Configuration

The default configuration is stored in `G1R_CancelInteraction.ini`:

```ini
DiscoveryMode=false
Debug=false
CancelKeys=ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
ControllerCancelEnabled=true
ControllerCancelKey=CONTROLLER_BACK
CooldownMs=250
```

### Common Options

- `CancelKeys` controls which keys trigger cancellation. Use
  `RIGHT_MOUSE_BUTTON` for right mouse click.
- `ControllerCancelEnabled=true` enables controller cancellation.
- `ControllerCancelKey=CONTROLLER_BACK` first tries controller east face button
  aliases through UE4SS `RegisterKeyBind`, which is keyboard-focused in
  upstream UE4SS.
- If the direct controller keybind is unavailable, the mod still installs
  G1R/CommonUI back/leave-input fallback hooks. Every controller path delegates
  to the existing `ESCAPE` cancel path.
- `CooldownMs` controls the delay between cancel attempts.
- `Debug=true` enables verbose logging.
- `DiscoveryMode=true` logs candidate interaction hooks for troubleshooting.

Leave debug and discovery mode disabled during normal play unless you need to
collect UE4SS log output for a bug report.

## Notes

This mod focuses on cancelling the movement toward an interaction target. It
does not cancel object animations or replace the game's normal menu controls,
and it intentionally avoids cancelling once an interaction has reached states
where the game should handle it normally.

If a game update changes internal interaction hooks and a specific interaction
stops cancelling, enable `Debug=true` and `DiscoveryMode=true`, reproduce the
issue, and include the relevant UE4SS log output when reporting it.
