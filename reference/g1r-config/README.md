# G1R Config Reference

This directory contains FModel-exported Gothic 1 Remake config files used as
development references for this UE4SS mod.

Source export path:

```text
/gaming/SteamLibrary/steamapps/common/Gothic 1 Remake/Output/Exports/G1R/Config/
```

These files are reference inputs only. The mod must not load them at runtime.

Useful entry points:

- `DefaultInput.ini`: input subsystem setup, `EnhancedPlayerInput`,
  `GothicInputComponent`, and raw gamepad axis names.
- `DefaultGame.ini`: CommonInput platform support and controller data assets for
  Xbox, PlayStation, Switch, and mouse/keyboard.
- `DefaultGameplayTags.ini`: broad gameplay ability, action, input context, and
  state tags.
- `Tags/DefaultGameplayActions.ini`: split gameplay action tag list.
- `Tags/DefaultGameplayEvents.ini`: split gameplay event tag list.

Gameplay tags describe semantics, not physical controller button mappings. For
controller support, cross-check these files with the UE4SS object dump and
in-game `DiscoveryMode=true` logs before choosing defaults.
