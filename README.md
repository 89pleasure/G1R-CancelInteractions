# G1R Cancel Interaction

UE4SS Lua mod for cancelling Gothic 1 Remake interactions with `F`, `ESC`, or
the movement keys `A`, `W`, `S`, and `D`.

## Install

Create a `G1R_CancelInteraction` folder in the game's UE4SS mods folder and copy
the mod files from this repository into it:

```text
<GameDir>/G1R/Binaries/Win64/ue4ss/Mods/G1R_CancelInteraction/
```

The installed folder should contain:

```text
enabled.txt
G1R_CancelInteraction.ini
Scripts/main.lua
Scripts/cancel_core.lua
```

## Test

1. Start the game with UE4SS enabled.
2. Load a save near a cooking pan or workstation.
3. Press `F` when no interaction is active and confirm vanilla interaction still works.
4. Click/use the cooking pan.
5. Press `F` or a movement key while the hero is walking to the pan.
6. Repeat and press `F` or a movement key after the animation starts.
7. Repeat both cases with `ESC`.
8. Click/use a bench, chair, or similar ambient seat and press a movement key while
   the hero is walking to it or starting the sit animation.
9. Click/use a chest and press a movement key while the hero walks to it or starts
   the open animation.
10. Confirm movement-phase actions abort and the open cooking menu is only closed
    by the game's normal menu handling.

Set `DiscoveryMode=true` or `Debug=true` in `G1R_CancelInteraction.ini` when you need
verbose UE4SS log output for troubleshooting.
