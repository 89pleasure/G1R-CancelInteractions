# Controller Back Cancel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a B/Circle controller cancel trigger that feeds the existing `ESCAPE` cancel path.

**Architecture:** Keep all cancellation policy in `Scripts/cancel_core.lua` and keep `Scripts/main.lua` responsible only for runtime input registration. Register controller back aliases when UE4SS exposes matching `Key[...]` values; if those keys are missing, install G1R/CommonUI fallback hooks and a player-widget tick poll that delegates to the existing `ESCAPE` path while preserving keyboard/mouse behavior.

**Tech Stack:** UE4SS Lua, pure Lua core tests in `tests/g1r_cancel_interaction_core.test.lua`.

---

### Task 1: Add Controller Back Config And Aliases

**Files:**
- Modify: `Scripts/cancel_core.lua`
- Test: `tests/g1r_cancel_interaction_core.test.lua`

- [ ] **Step 1: Write the failing test**

Add assertions that default config enables controller cancel and returns aliases for Xbox B / PlayStation Circle:

```lua
local defaults = core.config_from_ini({})
assert_true(defaults.controller_cancel_enabled, "default controller cancel enabled")
assert_equal(defaults.controller_cancel_key, "CONTROLLER_BACK", "default controller cancel semantic key")

local controller_back_candidates = core.cancel_key_lookup_candidates("CONTROLLER_BACK")
assert_true(contains_value(controller_back_candidates, "GAMEPAD_FACE_BUTTON_RIGHT"),
    "controller back includes Unreal right face button")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/g1r_cancel_interaction_core.test.lua`
Expected: FAIL because `controller_cancel_enabled` and the controller aliases do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add `CONTROLLER_BACK` aliases in `cancel_core.lua`, parse `ControllerCancelEnabled`, and expose a default semantic key of `CONTROLLER_BACK`.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/g1r_cancel_interaction_core.test.lua`
Expected: PASS.

### Task 2: Register Controller Back Into Existing Hotkey Path

**Files:**
- Modify: `Scripts/main.lua`
- Test: `tests/g1r_cancel_interaction_core.test.lua`

- [ ] **Step 1: Write the failing test**

Add source-level assertions that `main.lua` registers controller cancel aliases and calls `on_cancel_hotkey("ESCAPE")`.

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/g1r_cancel_interaction_core.test.lua`
Expected: FAIL because the runtime registration helper is missing.

- [ ] **Step 3: Write minimal implementation**

Add `install_controller_cancel_hotkeys()` after `install_cancel_hotkeys()`. It should use `key_value_from_name(config.controller_cancel_key)` and register a callback that calls `on_cancel_hotkey("ESCAPE")`.

### Task 2b: Register Controller Back Fallback Hooks

**Files:**
- Modify: `Scripts/cancel_core.lua`
- Modify: `Scripts/main.lua`
- Test: `tests/g1r_cancel_interaction_core.test.lua`

- [ ] **Step 1: Write the failing test**

Assert that `core.controller_cancel_fallback_hook_candidates()` includes `/Script/G1R.GameplayAbilityCallInteractFunction:HandleLeaveInput` and `/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction`, and assert that `main.lua` installs those hooks only when direct keybind registration fails.

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/g1r_cancel_interaction_core.test.lua`
Expected: FAIL because the fallback hook list and installer are missing.

- [ ] **Step 3: Write minimal implementation**

Add the fallback hook list to `cancel_core.lua`. Add `install_controller_cancel_fallback_hooks()` to `main.lua`; each hook should debug-log `[controller-cancel-fallback]` and call `on_cancel_hotkey("ESCAPE")`.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/g1r_cancel_interaction_core.test.lua`
Expected: PASS.

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/g1r_cancel_interaction_core.test.lua`
Expected: PASS.

### Task 3: Keep Defaults Documented

**Files:**
- Modify: `G1R_CancelInteraction.ini`
- Modify: `README.md`

- [ ] **Step 1: Update config defaults**

Add:

```ini
ControllerCancelEnabled=true
ControllerCancelKey=CONTROLLER_BACK
```

- [ ] **Step 2: Update README configuration**

Document that `ControllerCancelKey=CONTROLLER_BACK` maps to the controller east face button when UE4SS exposes that key.

- [ ] **Step 3: Verify all checks**

Run:

```bash
lua tests/g1r_cancel_interaction_core.test.lua
luac -p Scripts/main.lua
luac -p Scripts/cancel_core.lua
luac -p Scripts/runtime_diagnostics.lua
```

Expected: all commands exit 0.

### Task 4: Add Runtime Controller Polling

**Reason:** Runtime testing showed `Controller cancel fallback hooks registered: 8`, but pressing controller buttons did not trigger those hooks. UE4SS `RegisterKeyBind` is keyboard-focused, so controller support needs a lower-level runtime path.

**Files:**
- Modify: `Scripts/cancel_core.lua`
- Modify: `Scripts/main.lua`
- Modify: `G1R_CancelInteraction.ini`
- Modify: `README.md`
- Test: `tests/g1r_cancel_interaction_core.test.lua`

- [x] **Step 1: Add poll config and defaults**

Add `ControllerCancelPollEnabled=true` and default poll keys beginning with `Gamepad_FaceButton_Right`.

- [x] **Step 2: Add constrained tick hooks**

Use player UI ticks (`Player_Widget`, `W_HealthBar`, `W_ManaBar`) and a filtered
`/Script/UMG.UserWidget:Tick` fallback rather than global actor tick.

- [x] **Step 3: Poll PlayerController input**

Call `WasInputKeyJustPressed` with an `FKey`-shaped table: `{ KeyName = <controller key> }`. On a true result, call `on_cancel_hotkey("ESCAPE")`.

- [x] **Step 4: Add EnhancedInput discovery hooks**

When `Debug=true` or `DiscoveryMode=true`, register known pause/map/inventory EnhancedInput Blueprint event hooks to capture runtime evidence.

- [x] **Step 5: Verify**

Run:

```bash
lua tests/g1r_cancel_interaction_core.test.lua
luac -p Scripts/main.lua
luac -p Scripts/cancel_core.lua
luac -p Scripts/runtime_diagnostics.lua
```

Observed: all commands exit 0.
