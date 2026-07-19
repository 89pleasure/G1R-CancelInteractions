# Nexus Mods Description

## Image Upload Order

Use these PNG files for the Nexus Mods image gallery:

1. `nexusmods/images/00-header.png` - Nexus Mods header image, 1300x372
2. `nexusmods/images/01-cover.png` - main gallery cover/thumbnail image
3. `nexusmods/images/02-feature-flow.png` - explains the accidental-interaction
   cancel flow
4. `nexusmods/images/03-supported-interactions.png` - explains runtime scope
   and safety exclusions
5. `nexusmods/images/04-installation.png` - shows the manual installation layout

The editable SVG sources are in `nexusmods/images/source/`.

## Short Description

```text
Cancel accidental interactions and early conversations before the hero reaches the target. Configurable keyboard and mouse keys; requires PleasureLib.
```

## Main Description

````markdown
# G1R Cancel Interaction

G1R Cancel Interaction is a small UE4SS Lua mod for Gothic 1 Remake that lets
you cancel an accidental interaction while the hero is still moving toward its
target. It can also end a player-initiated conversation before the conversation
UI appears.

Press `F`, `R`, `ESC`, right mouse button, or one of the movement keys `A`, `W`,
`S`, and `D` during the early cancel window to regain control.

## Features

- Cancels the player's active blocking interaction before the hero reaches the
  target
- Cancels a player-initiated conversation before its UI opens
- Uses the game's exact blocking-interaction and FreePoint approach lifecycles
  instead of scanning the AbilitySystem, locomotion state, or global objects
- Supports the FreePoint approach used by benches and ladders
- Supports configurable keyboard and mouse cancel keys
- Excludes mining because cancelling that ability can incorrectly award ore
- Clears tracked state across interaction completion and map changes
- Uses single-use tracked state to avoid repeated calls on stale game objects
- Quiet by default, with optional debug logging

The 0.7 runtime does not provide controller or EnhancedInput cancellation.

## Requirements

- Gothic 1 Remake
- UE4SS 3.0.1 or a newer G1R-compatible experimental build installed and
  working for the game
- PleasureLib 0.5.1 or newer

## Installation

Install PleasureLib and G1R Cancel Interaction as neighboring folders in your
UE4SS mods directory:

```text
<GameDir>/G1R/Binaries/Win64/ue4ss/Mods/G1R_CancelInteraction/
<GameDir>/G1R/Binaries/Win64/ue4ss/Mods/PleasureLib/
```

The included loader can find PleasureLib from the neighboring folder even when
`mods.txt` does not define the load order.

The installed G1R Cancel Interaction folder should contain:

```text
enabled.txt
G1R_CancelInteraction.ini
Scripts/main.lua
Scripts/cancel_core.lua
Scripts/pleasure_lib_loader.lua
```

Start the game with UE4SS enabled. The mod loads automatically.

## Configuration

Edit `G1R_CancelInteraction.ini` if you want to change the defaults:

```ini
Debug=false
CancelKeys=F,R,ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
```

`CancelKeys` accepts comma-separated UE4SS keyboard and mouse key names. Use
`RIGHT_MOUSE_BUTTON` for right mouse click. Set `Debug=true` only when you need
additional lifecycle diagnostics.

Controller buttons are not supported by this version.

## How It Works

For blocking interactions, the mod tracks the player's blocking-interaction
ability while its move-to phase is active. A configured key cancels that
ability on the game thread. The cancel window closes when the move-to phase
ends, leaving the normal object animation or UI alone after the hero arrives.

Benches and ladders use a separate player-owned FreePoint approach task. The
mod tracks that exact task and calls `OnRequestEndQuick` before its animation
handoff. Successful alignment closes the window immediately, so normal bench
and ladder controls take over after arrival. A short edge covers either
ordering of the WASD input and the task-end event.

For conversations, the mod tracks only a group initiated by the player. It can
be ended during the approach, but the mod stops intervening as soon as the
conversation UI appears.

Mining is intentionally excluded. Cancelling the mining ability through this
path can incorrectly grant ore.

## Updating From 0.6.x

Version 0.7.0 replaces the previous movement-task, AbilitySystem, locomotion,
discovery, and EnhancedInput implementation with the smaller
blocking-interaction lifecycle.

Version 0.7.2 adds the missing narrow FreePoint lifecycle used by benches and
ladders, so WASD can also cancel while the hero approaches them. It does this
without restoring AbilitySystem scans or locomotion mutation.

Replace `Scripts/main.lua`, `Scripts/cancel_core.lua`, and
`Scripts/pleasure_lib_loader.lua`. Delete the obsolete installed files
`Scripts/mod_runtime.lua` and `Scripts/player_asc.lua`. Replace the INI, or
migrate your keyboard and mouse keys to `CancelKeys`.

The old `DiscoveryMode`, `ControllerCancelEnabled`, `ControllerCancelKeys`, and
`CooldownMs` settings are no longer used. Savegames do not require migration.

## Current Version

`0.7.2`
````
