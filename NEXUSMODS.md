# Nexus Mods Description

## Image Upload Order

Use these PNG files for the Nexus Mods image gallery:

1. `nexusmods/images/00-header.png` - Nexus Mods header image, 1300x372
2. `nexusmods/images/01-cover.png` - main gallery cover/thumbnail image
3. `nexusmods/images/02-feature-flow.png` - explains the accidental-click cancel flow
4. `nexusmods/images/03-supported-interactions.png` - lists supported interaction types
5. `nexusmods/images/04-installation.png` - shows the manual installation layout

The editable SVG sources are in `nexusmods/images/source/`.

## Short Description

```text
Cancel accidental interactions in Gothic 1 Remake with ESC, right mouse button, controller B/Circle, or movement keys before the hero reaches the object.
```

## Main Description

```markdown
# G1R Cancel Interaction

G1R Cancel Interaction is a small UE4SS Lua mod for Gothic 1 Remake that lets you cancel accidental interaction movement with `ESC`, right mouse button, controller B/Circle, or the movement keys `A`, `W`, `S`, and `D`.

It is meant for those moments where you accidentally click a cooking pan, bench, chair, bed, chest, or other interactable object and the hero starts walking toward it. Instead of waiting for the interaction to finish, press a cancel key and get back in control before the object animation or UI phase starts.

## Features

- Cancel interaction movement with `ESC`, right mouse button, controller B/Circle, `A`, `W`, `S`, or `D`
- Supports common ambient interactions such as sitting, benches, chairs, beds, cooking spots, workstations, and containers/chests
- Movement-key cancellation for accidental clicks while the hero is still walking to the target
- Uses a generic movement-task path instead of per-object cancel branches
- Keeps normal game menu behavior intact
- Does not try to force-cancel during unsafe states such as menus, pause, dialogue, cutscenes, combat, airborne states, or unsafe transitions
- Configurable cancel keys and cooldown
- Quiet by default, with optional debug and discovery logging for troubleshooting

## Requirements

- Gothic 1 Remake
- UE4SS installed and working for the game

## Installation

Create this folder in your UE4SS mods directory:

```text
<GameDir>/G1R/Binaries/Win64/ue4ss/Mods/G1R_CancelInteraction/
```

Copy the mod files into that folder.

The installed folder should contain:

```text
enabled.txt
G1R_CancelInteraction.ini
Scripts/main.lua
Scripts/cancel_core.lua
Scripts/mod_runtime.lua
```

Start the game with UE4SS enabled. The mod loads automatically.

## Configuration

Edit `G1R_CancelInteraction.ini` if you want to change the defaults.

Default cancel keys:

```ini
DiscoveryMode=false
Debug=false
CancelKeys=ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
ControllerCancelEnabled=true
ControllerCancelKeys=CONTROLLER_FACE_RIGHT
CooldownMs=250
```

`CONTROLLER_FACE_RIGHT` is controller B/Circle. Do not use `CONTROLLER_FACE_BOTTOM`
as the default cancel button here. In Gothic 1 Remake that button is the normal
interact/confirm input and would cancel immediately after starting an interaction.

For troubleshooting, you can enable:

```ini
Debug=true
DiscoveryMode=true
```

Leave those disabled during normal play unless you need verbose UE4SS logs.

## Notes

This mod focuses on cancelling the movement toward an interaction target. It does
not replace the game's normal menu handling, and it intentionally avoids
cancelling in situations where doing so could interfere with gameplay state.

Game updates may change internal interaction hooks, so if something stops working
after an update, enable discovery logging and report the affected interaction.
```
