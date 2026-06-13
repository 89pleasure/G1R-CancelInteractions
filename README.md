# G1R Cancel Interaction

G1R Cancel Interaction is a UE4SS Lua mod for Gothic 1 Remake that lets you
cancel accidental interaction movement and early interaction animations with
`F`, `ESC`, or the movement keys `A`, `W`, `S`, and `D`.

The mod is meant for situations where the hero starts walking toward an
unwanted interaction target, such as a cooking spot, workstation, bench, chair,
bed, chest, or other interactable object. Press a cancel key to stop the
interaction and regain control sooner.

## Features

- Cancel interaction movement with `F`, `ESC`, `A`, `W`, `S`, or `D`.
- Cancel accidental clicks while the hero is walking to an interaction target.
- Supports common ambient interactions such as benches, chairs, beds, cooking
  spots, workstations, containers, and chests.
- Keeps the game's normal menu handling intact.
- Avoids cancelling during unsafe states such as pause, open menus, dialogue,
  cutscenes, combat, airborne movement, or unsafe transitions.
- Configurable cancel keys and cooldown.
- Quiet by default, with optional debug and discovery logging for
  troubleshooting.

## Requirements

- Gothic 1 Remake
- UE4SS installed and enabled for the game

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
   ```

5. Start the game with UE4SS enabled. The mod loads automatically.

## Configuration

The default configuration is stored in `G1R_CancelInteraction.ini`:

```ini
DiscoveryMode=false
Debug=false
CancelKeys=F,ESCAPE,A,W,S,D
CooldownMs=250
AllowMontageFallback=false
RuntimeFunctionScan=false
RuntimeFunctionScanLimit=80
```

### Common Options

- `CancelKeys` controls which keys trigger cancellation.
- `CooldownMs` controls the delay between cancel attempts.
- `Debug=true` enables verbose logging.
- `DiscoveryMode=true` logs candidate interaction hooks for troubleshooting.

Leave debug and discovery mode disabled during normal play unless you need to
collect UE4SS log output for a bug report.

## Notes

This mod focuses on cancelling interaction movement and early interaction
animation phases. It does not replace the game's normal menu controls, and it
intentionally avoids cancelling once an interaction has reached states where the
game should handle it normally.

If a game update changes internal interaction hooks and a specific interaction
stops cancelling, enable `Debug=true` and `DiscoveryMode=true`, reproduce the
issue, and include the relevant UE4SS log output when reporting it.
