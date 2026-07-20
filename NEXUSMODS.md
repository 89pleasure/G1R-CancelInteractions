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

- Cancels an accidental interaction before the hero reaches the target
- Cancels a player-initiated conversation before its UI opens
- Works with regular interaction objects as well as benches and ladders
- Uses the game's own approach and arrival events for a focused, lightweight
  runtime
- Supports configurable keyboard and mouse cancel keys
- Cancellation for benches and ladders, early conversations, and WASD input
  can each be changed independently from the game's native Mods settings page
- Mining can always be cancelled during the verified approach; the native
  mining option only decides whether cancelling still gives you ore
- Clears tracked state across interaction completion and map changes
- Uses single-use tracked state to avoid repeated calls on stale game objects
- Quiet by default, with optional debug logging

The current runtime does not provide controller or EnhancedInput cancellation.

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

The four native options appear in the game under:

```text
Settings (Einstellungen) -> Mods -> G1R Cancel Interaction
```

Changes made there take effect immediately. PleasureLib 0.5.1 or newer saves
each change back to `G1R_CancelInteraction.ini`.

The INI remains available as a manual fallback and stores the default
configuration:

```ini
Debug=false
EnableBenchAndLadderCancellation=true
EnableConversationCancellation=true
EnableWASDCancellation=true
KeepOreOnMiningCancellation=false
CancelKeys=F,R,ESCAPE,A,W,S,D,RIGHT_MOUSE_BUTTON
```

- `EnableBenchAndLadderCancellation=false` disables cancellation while
  approaching benches and ladders. It also applies to any other interaction
  spot the game handles in the same way.
- `EnableConversationCancellation=false` disables early cancellation of
  player-started conversations.
- `EnableWASDCancellation=false` prevents `A`, `W`, `S`, and `D` from triggering
  cancellation, even when they remain in `CancelKeys`. Other configured keys
  continue to work.
- `KeepOreOnMiningCancellation` only controls the reward when mining is
  cancelled. With `true` / On, you still get the ore and its notification.
  With `false` / Off (default), you get no ore and no ore notification. Mining
  itself can be cancelled in both states.
- `CancelKeys` and `Debug` remain INI-only options and do not appear on the
  native Mods settings page.
- `CancelKeys` accepts comma-separated UE4SS keyboard and mouse key names. Use
  `RIGHT_MOUSE_BUTTON` for right mouse click.
- Set `Debug=true` only when you need additional interaction diagnostics.

Controller buttons are not supported by this version.

## How It Works

For most objects, the mod remembers the interaction while the hero is walking
toward its target. Benches and ladders behave differently internally, so their
approach is handled separately too.

In both cases, a configured key ends the accidental action before the object
animation begins. Successful arrival closes the cancel window immediately,
leaving normal bench, ladder, object, and menu controls untouched. A short
input edge covers either ordering of a WASD press and the game's arrival event.

Player-started conversations can also be ended during the approach. Once the
conversation UI appears, normal conversation controls take over.

Mining can always be cancelled during the verified standard approach. A
normal mining cancel uses `m_ApplyCooldown=false` plus `K2_CancelAbility`. If
WASD already cancelled the mining movement before the mod's key callback, the
mod accepts that lifecycle result instead of issuing a duplicate K2 call.
Mining never uses `Server_OnCloseRequested` or a reflected task-cancel call. When
`KeepOreOnMiningCancellation=false`, the mod captures the authoritative
player, game-state, trader-manager, and ore baseline before cancellation. It
then removes only a positive ore delta observed immediately or during a short,
bounded series of rechecks. The exact `ItMi_Orenugget` notification for that
single cancelled reward is suppressed through the tracked player inventory;
other item notifications and normal mining remain unchanged. With the setting
enabled, the game's ore credit and notification are left unchanged.

If authority, the baseline, or a required reflected rollback function is
unavailable, mining cancellation still works and only reward rollback is
skipped. The UE4SS log reports that safe fallback. Mining through the separate
FreePoint path is never ended with the bench-and-ladder quick-end call, and an
ownerless FreePoint task does not clear an already verified mining record.

## Manual Mining Check

Before relying on the reward option in a save, test both `F` and an enabled
WASD key with `KeepOreOnMiningCancellation=false`, and compare the exact ore
count before and after each cancellation. Confirm that no ore reward
notification appears for the rolled-back reward. Repeat with the setting
enabled to confirm that both the reward and its notification remain. After
every variant, mine the same spot normally and check that its reward
notification, remaining amount, and visual/state behavior are unchanged.

## Updating From Earlier Versions

Version 0.7.0 replaces the previous broad movement and input implementation
with a smaller event-based runtime.

Version 0.7.2 adds the separate approach flow used by benches and ladders, so
WASD can also cancel while the hero approaches them.

Version 0.8.0 adds independent native Mods settings for bench and ladder
cancellation, early conversation cancellation, and WASD cancellation. Changes
take effect immediately and PleasureLib persists them to the INI.

Version 0.8.1 adds the disabled-by-default
`Cancel mining and receive ore` opt-in and keeps the verified mining cancel
window open while the game's overlapping approach task initializes.

Version 0.8.2 makes mining cancellation always available and changes the
native mining option so it only controls whether ore is retained.

Version 0.8.3 preserves verified mining records while overlapping FreePoint
tasks are still ownerless.

Version 0.8.4 restores reliable functional mining cancellation in both reward
modes. Normal cancellation uses `m_ApplyCooldown=false` plus
`K2_CancelAbility`, while an already-cancelled WASD movement is not cancelled
a second time. When ore
retention is disabled, it captures a safe ore baseline and rolls back only a
positive delta observed during bounded rechecks. Missing rollback prerequisites
never block cancellation, and verified mining records continue to survive
ownerless FreePoint tasks.

Version 0.8.5 suppresses the misleading ore reward notification when a
cancelled mining reward is routed through the rollback path. The one-shot HUD
hook is limited to the tracked player inventory and the exact ore item; normal
mining, unrelated items, and the reward-retention mode keep their
notifications.

Version 0.8.6 replaces the technical mining reward setting description with
simple On/Off wording. Gameplay behavior is unchanged.

Replace `Scripts/main.lua`, `Scripts/cancel_core.lua`, and
`Scripts/pleasure_lib_loader.lua`. Delete the obsolete installed files
`Scripts/mod_runtime.lua` and `Scripts/player_asc.lua`. Replace the INI, or add
the new feature settings to your existing file.

Missing bench-and-ladder, conversation, and WASD settings default to `true`.
The mining ore setting defaults to `false`, so mining still uses the verified
blocking cancellation lifecycle and the mod attempts safe ore-delta rollback. If
`KeepOreOnMiningCancellation` is missing, the legacy
`EnableMiningCancellation` value is used as a fallback (`true` keeps ore and
`false` requests rollback). The new key takes precedence and only the new key
is persisted by Native Settings.

The old `DiscoveryMode`, `ControllerCancelEnabled`, `ControllerCancelKeys`, and
`CooldownMs` settings are no longer used. Savegames do not require migration.

## Current Version

`0.8.6`
````
