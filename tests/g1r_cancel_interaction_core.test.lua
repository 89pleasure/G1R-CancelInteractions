package.path = "Scripts/?.lua;" .. package.path

local core = require("cancel_core")
local runtime_diagnostics = require("runtime_diagnostics")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s expected=%s actual=%s", label, tostring(expected), tostring(actual)))
    end
end

local function assert_true(value, label)
    if value ~= true then
        error(label .. " expected true")
    end
end

local function assert_false(value, label)
    if value ~= false then
        error(label .. " expected false")
    end
end

local function contains_value(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
end

local parsed = core.parse_ini([[
Debug=true
Timing=true
DiscoveryMode=false
CancelKeys=F, ESCAPE
CooldownMs=300
AllowMontageFallback=true
RuntimeFunctionScan=true
RuntimeFunctionScanLimit=12
]])

local config = core.config_from_ini(parsed)
assert_true(config.debug, "debug")
assert_true(config.timing, "timing")
assert_false(config.discovery_mode, "discovery")
assert_equal(config.cancel_keys[1], "F", "first cancel key")
assert_equal(config.cancel_keys[2], "ESCAPE", "second cancel key")
assert_equal(config.cooldown_ms, 300, "cooldown")
assert_true(config.allow_montage_fallback, "montage fallback")
assert_true(config.runtime_function_scan, "runtime function scan")
assert_equal(config.runtime_function_scan_limit, 12, "runtime function scan limit")
assert_false(core.startup_runtime_scan_allowed(config),
    "runtime scan alone does not allow startup scan")

local discovery_scan_config = core.config_from_ini(core.parse_ini([[
DiscoveryMode=true
RuntimeFunctionScan=true
]]))
assert_true(core.startup_runtime_scan_allowed(discovery_scan_config),
    "discovery plus runtime scan allows startup scan")

local defaults = core.config_from_ini({})
assert_false(defaults.debug, "default debug")
assert_false(defaults.timing, "default timing")
assert_false(defaults.discovery_mode, "default discovery")
assert_equal(defaults.cancel_keys[1], "F", "default first cancel key")
assert_equal(defaults.cancel_keys[2], "ESCAPE", "default second cancel key")
assert_equal(defaults.cancel_keys[3], "A", "default third cancel key")
assert_equal(defaults.cancel_keys[4], "W", "default fourth cancel key")
assert_equal(defaults.cancel_keys[5], "S", "default fifth cancel key")
assert_equal(defaults.cancel_keys[6], "D", "default sixth cancel key")
assert_equal(defaults.cooldown_ms, 250, "default cooldown")
assert_false(defaults.allow_montage_fallback, "default montage fallback")
assert_false(defaults.runtime_function_scan, "default runtime function scan")
assert_equal(defaults.runtime_function_scan_limit, 80, "default runtime function scan limit")

local unprintable = setmetatable({}, {
    __tostring = function()
        error("cannot stringify")
    end,
})
assert_equal(core.safe_to_string("ok"), "ok", "safe string preserves plain strings")
assert_equal(core.safe_to_string(unprintable), "<unprintable table>",
    "safe string handles tostring errors")

local snapshot_text = runtime_diagnostics.format_snapshot({
    rotation_mode = 1,
    movement_state = 2,
    movement_action = 7,
    requested_movement_action = nil,
    anim_is_in_combat = false,
    anim_is_alive = true,
    anim_is_conversation = false,
    anim_is_cinematic = false,
})
assert_true(string.find(snapshot_text, "rotationMode=1", 1, true) ~= nil,
    "diagnostic snapshot includes rotation mode")
assert_true(string.find(snapshot_text, "movementAction=7", 1, true) ~= nil,
    "diagnostic snapshot includes movement action")

local repeated_ready_hook_cache_update = core.classify_cached_hero_update({
    previous_identity = "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PlayerCharacterBP_C_1",
    next_identity = "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PlayerCharacterBP_C_1",
    source = "GothicCharacter:BP_IsGameplayReady",
})
assert_false(repeated_ready_hook_cache_update.changed,
    "same hero identity is not a cache change")
assert_false(repeated_ready_hook_cache_update.refresh_runtime_refs,
    "readiness poll does not refresh runtime refs for same hero")
assert_false(repeated_ready_hook_cache_update.should_log,
    "readiness poll does not log same hero")

local new_hero_cache_update = core.classify_cached_hero_update({
    previous_identity = "PlayerCharacterBP_C old",
    next_identity = "PlayerCharacterBP_C new",
    source = "GothicCharacter:BP_IsGameplayReady",
})
assert_true(new_hero_cache_update.changed, "new hero identity changes cache")
assert_true(new_hero_cache_update.refresh_runtime_refs,
    "new hero identity refreshes runtime refs")
assert_true(new_hero_cache_update.should_log, "new hero identity logs once")

local player_context_hooks = core.player_context_hook_candidates()
assert_false(contains_value(player_context_hooks,
        "/Script/G1R.GothicCharacter:BP_IsGameplayReady"),
    "player context hooks skip noisy readiness poll")
assert_true(contains_value(player_context_hooks,
        "/Script/G1R.GothicCharacter:GetInventory"),
    "player context hooks include inventory")
assert_true(contains_value(player_context_hooks,
        "/Script/G1R.GothicCharacter:GetCarryComponent"),
    "player context hooks include carry component")
assert_true(contains_value(player_context_hooks,
        "/Script/Engine.PlayerController:ClientRestart"),
    "player context hooks include client restart")

local flags = core.new_timed_flags()
flags:open("busy", 1000, 100)
assert_true(flags:active("busy", 500), "flag active")
assert_false(flags:active("busy", 1200), "flag expired")

local blocked = core.classify_cancel_safety({
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(blocked.allowed, "unsafe transition blocked")
assert_equal(blocked.reason, "unsafe transition", "unsafe reason")

local allowed = core.classify_cancel_safety({
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(allowed.allowed, "ambient interaction allowed")
assert_equal(allowed.reason, "ok", "allowed reason")

assert_true(core.is_movement_cancel_key("A"), "A is movement cancel key")
assert_true(core.is_movement_cancel_key("w"), "W is movement cancel key")
assert_true(core.is_movement_cancel_key("S"), "S is movement cancel key")
assert_true(core.is_movement_cancel_key("d"), "D is movement cancel key")
assert_true(core.is_movement_cancel_key("F"), "F is movement-phase cancel key")
assert_true(core.is_movement_cancel_key("ESCAPE"),
    "ESCAPE is movement-phase cancel key")
assert_false(core.cancel_hotkey_should_enter_game_thread({
        key_name = "W",
        interaction_active = false,
        movement_cancel_armed = false,
    }),
    "idle movement key does not enter game thread")
assert_true(core.cancel_hotkey_should_enter_game_thread({
        key_name = "W",
        interaction_active = false,
        movement_cancel_armed = true,
    }),
    "armed movement key enters game thread")
assert_true(core.cancel_hotkey_should_enter_game_thread({
        key_name = "A",
        interaction_active = true,
        movement_cancel_armed = false,
    }),
    "tracked interaction movement key enters game thread")
assert_true(core.cancel_hotkey_should_enter_game_thread({
        key_name = "F",
        interaction_active = false,
        movement_cancel_armed = false,
    }),
    "action key enters game thread and arms movement cancel")

local movement_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(movement_interaction_allowed.allowed,
    "movement key active interaction cancel allowed")
assert_equal(movement_interaction_allowed.reason, "movement interaction active",
    "movement interaction allowed reason")

local movement_action_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "D",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(movement_action_interaction_allowed.allowed,
    "movement action 7 cancel allowed without tracked interaction")
assert_equal(movement_action_interaction_allowed.reason, "movement action interaction active",
    "movement action interaction allowed reason")

local movement_action_interaction_enum_allowed = core.classify_movement_interaction_cancel({
    key_name = "A",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 8,
    requested_movement_action = 8,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(movement_action_interaction_enum_allowed.allowed,
    "movement action 8 cancel allowed without tracked interaction")
assert_equal(movement_action_interaction_enum_allowed.reason,
    "movement action interaction active",
    "movement action 8 interaction allowed reason")

local casting_spell_movement_blocked = core.classify_movement_interaction_cancel({
    key_name = "A",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 12,
    requested_movement_action = 12,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(casting_spell_movement_blocked.allowed,
    "movement action 12 casting spell does not cancel as interaction")
assert_equal(casting_spell_movement_blocked.reason,
    "movement action inactive",
    "movement action 12 blocked reason")

local launching_spell_movement_blocked = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 13,
    requested_movement_action = 13,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(launching_spell_movement_blocked.allowed,
    "movement action 13 launching spell does not cancel as interaction")
assert_equal(launching_spell_movement_blocked.reason, "movement action inactive",
    "movement action 13 blocked reason")

local sleep_movement_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    sleep_movement_active = true,
    movement_action = 0,
    requested_movement_action = 0,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(sleep_movement_interaction_allowed.allowed,
    "sleep movement interaction cancel allowed without movement action 7")
assert_equal(sleep_movement_interaction_allowed.reason, "sleep movement interaction active",
    "sleep movement interaction allowed reason")

local requested_only_interaction_blocked = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 0,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(requested_only_interaction_blocked.allowed,
    "requested-only movement interaction blocked")
assert_equal(requested_only_interaction_blocked.reason, "movement action inactive",
    "requested-only movement interaction blocked reason")

local action_key_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "F",
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(action_key_interaction_allowed.allowed,
    "action key movement interaction cancel allowed")
assert_equal(action_key_interaction_allowed.reason, "movement interaction active",
    "action key movement interaction allowed reason")

local action_key_movement_action_only_blocked = core.classify_movement_interaction_cancel({
    key_name = "F",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(action_key_movement_action_only_blocked.allowed,
    "action key does not cancel movement-only interaction start")
assert_equal(action_key_movement_action_only_blocked.reason,
    "action key movement-only start",
    "action key movement-only blocked reason")

local escape_key_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "ESCAPE",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(escape_key_interaction_allowed.allowed,
    "escape movement action cancel allowed")
assert_equal(escape_key_interaction_allowed.reason, "movement action interaction active",
    "escape movement action allowed reason")

local action_key_menu_open_blocked = core.classify_movement_interaction_cancel({
    key_name = "F",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = true,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(action_key_menu_open_blocked.allowed,
    "action key movement cancel blocked while menu is open")
assert_equal(action_key_menu_open_blocked.reason, "menu open",
    "action key menu-open blocked reason")

local movement_interaction_lockout = core.classify_movement_interaction_cancel({
    key_name = "A",
    player_ready = true,
    interaction_active = true,
    interaction_cancel_lockout = true,
    interaction_kind = "ambient",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(movement_interaction_lockout.allowed,
    "movement interaction lockout blocked")
assert_equal(movement_interaction_lockout.reason, "interaction cancel cooldown",
    "movement interaction lockout reason")

local crafting_allowed = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 0,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(crafting_allowed.allowed, "active crafting movement allowed")
assert_equal(crafting_allowed.reason, "crafting active", "crafting allowed reason")

local crafting_cancel_lockout = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_cancel_lockout = true,
    crafting_state = 0,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_cancel_lockout.allowed, "crafting cancel lockout blocked")
assert_equal(crafting_cancel_lockout.reason, "crafting cancel cooldown",
    "crafting cancel lockout reason")

local crafting_action_started = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 1,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_action_started.allowed, "started crafting action blocked")
assert_equal(crafting_action_started.reason, "crafting action started",
    "started crafting action reason")

local crafting_requested_only = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 0,
    movement_action = 0,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_requested_only.allowed, "requested-only crafting movement blocked")
assert_equal(crafting_requested_only.reason, "crafting idle",
    "requested-only crafting movement reason")

local crafting_idle = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 0,
    movement_action = 0,
    requested_movement_action = 0,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_idle.allowed, "idle crafting click blocked")
assert_equal(crafting_idle.reason, "crafting idle", "crafting idle reason")

local crafting_finished = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 8,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_finished.allowed, "finished crafting blocked")
assert_equal(crafting_finished.reason, "crafting finished", "crafting finished reason")

assert_true(core.crafting_hook_should_clear_tracking(
        "/Script/G1R.GameplayAbilityCrafting:ButtonCraftingMenuExit_Bind", 8),
    "crafting menu exit clears crafting tracking")
assert_true(core.crafting_hook_should_clear_tracking(
        "/Script/G1R.GameplayAbilityCrafting:OnCraftFinished", nil),
    "craft finished clears crafting tracking")
assert_true(core.crafting_hook_should_clear_tracking(
        "/Script/G1R.GameplayAbilityCrafting:Multicast_SetCraftingState", 6),
    "exit crafting state clears crafting tracking")
assert_false(core.crafting_hook_should_clear_tracking(
        "/Script/G1R.GameplayAbilityCrafting:Multicast_SetCraftingState", 2),
    "recipe selection state keeps crafting tracking")
assert_false(core.crafting_hook_should_track_after_cancel(2500, 1000, 10000),
    "crafting hooks are ignored shortly after cancel")
assert_true(core.crafting_hook_should_track_after_cancel(12000, 1000, 10000),
    "crafting hooks can track after post-cancel lockout")
assert_false(core.crafting_interaction_fallback_after_attempt({
        movement_action_active = true,
        crafting_cancelled = true,
        crafting_recent = true,
    }),
    "successful crafting cancel does not need interaction cleanup during movement")
assert_true(core.crafting_interaction_fallback_after_attempt({
        movement_action_active = true,
        crafting_cancelled = false,
        crafting_recent = true,
    }),
    "recent crafting does not block movement interaction fallback")
assert_false(core.crafting_interaction_fallback_after_attempt({
        movement_action_active = false,
        crafting_cancelled = true,
        crafting_recent = true,
    }),
    "crafting interaction cleanup requires active movement action")
assert_false(core.crafting_interaction_fallback_after_attempt({
        movement_action_active = true,
        crafting_cancelled = false,
        crafting_recent = false,
    }),
    "non-crafting movement follows the normal interaction path")

local crafting_cancel_methods = core.crafting_cancel_method_names()
assert_equal(crafting_cancel_methods[1], "CancelCrafting", "first crafting cancel method")
assert_equal(crafting_cancel_methods[2], "ButtonCraftingMenuExit_Bind",
    "second crafting cancel method")
assert_equal(#crafting_cancel_methods, 2,
    "crafting cancel avoids generic gameplay ability cancellation")

local crafting_move_task_properties = core.crafting_move_task_property_names()
assert_equal(crafting_move_task_properties[1], "m_TaskMoveTo",
    "crafting move task uses dump property name")
local crafting_move_task_methods = core.crafting_move_task_cancel_method_names()
assert_equal(crafting_move_task_methods[1], "EndTaskAsCancelled",
    "crafting move task prefers cancelled result")
assert_equal(crafting_move_task_methods[2], "EndTaskWithResult",
    "crafting move task can pass EGenericTaskResult::Cancelled")
assert_false(core.crafting_task_finished_check_required({
        property_name = "m_TaskMoveTo",
    }),
    "crafting move task skips expensive BP_IsFinished checks")
assert_false(core.crafting_task_finished_check_required({
        property_name = "TaskMoveTo",
    }),
    "crafting move task alias skips expensive BP_IsFinished checks")
assert_true(core.crafting_task_finished_check_required({
        property_name = "m_CharMontageTask",
    }),
    "crafting montage task keeps the finished check")
local container_move_task_properties = core.container_move_task_property_names()
assert_equal(container_move_task_properties[1], "m_TaskLootContainer",
    "container cancel uses OpenContainer loot task dump property name")
assert_equal(container_move_task_properties[2], "TaskLootContainer",
    "container cancel accepts generated loot task alias")
assert_equal(container_move_task_properties[3], "m_TaskMoveTo",
    "container cancel keeps movement task compatibility")
assert_equal(container_move_task_properties[4], "TaskMoveTo",
    "container cancel accepts generated movement task alias")
local container_move_task_methods = core.container_move_task_cancel_method_names()
assert_equal(container_move_task_methods[1], "EndTaskAsCancelled",
    "container move task prefers cancelled result")
assert_true(contains_value(container_move_task_methods, "EndTask"),
    "container loot task can fall back to GameplayTask EndTask")
local root_interaction_task_properties =
    core.root_interaction_task_property_names()
assert_equal(root_interaction_task_properties[1], "m_RootInteractionTask",
    "free point root task supports generated property name")
assert_equal(root_interaction_task_properties[2], "RootInteractionTask",
    "free point root task supports dump property name")
local root_interaction_subtask_properties =
    core.root_interaction_subtask_property_names()
assert_equal(root_interaction_subtask_properties[1], "CurrentSubtask",
    "root interaction task checks current subtask first")
assert_true(contains_value(root_interaction_subtask_properties, "MoveTask"),
    "root interaction task descends into move task")
assert_true(contains_value(root_interaction_subtask_properties, "TurnTask"),
    "root interaction task descends into turn task")
assert_true(contains_value(root_interaction_subtask_properties, "AlignTask"),
    "root interaction task descends into align task")
local container_root_task_methods =
    core.container_root_interaction_task_cancel_method_names()
assert_equal(container_root_task_methods[1], "EndTaskAsCancelled",
    "container root task prefers cancelled result")
assert_true(contains_value(container_root_task_methods, "EndTaskWithResult"),
    "container root task can pass EGenericTaskResult::Cancelled")
assert_true(contains_value(container_root_task_methods, "BP_ExternalCancel"),
    "container root task can use generic external cancel")
local container_player_task_scan_classes =
    core.container_player_interaction_task_scan_classes()
assert_equal(container_player_task_scan_classes[1],
    "AbilityTask_MoveIntoPositionForInteraction",
    "container player task scan starts with measured chest cancel task")
assert_equal(container_player_task_scan_classes[2],
    "AbilityTask_MoveRotateToLocation",
    "container player task scan checks the low-level move task second")
assert_true(contains_value(container_player_task_scan_classes,
        "AbilityTask_GotoInteractionSpot"),
    "container player task scan includes goto interaction task")
assert_true(contains_value(container_player_task_scan_classes,
        "AbilityTask_InteractionSpot"),
    "container player task scan includes root interaction spot task")
assert_true(contains_value(container_player_task_scan_classes,
        "AbilityTask_MoveIntoPositionForInteraction"),
    "container player task scan includes move-into-position task")
assert_true(contains_value(container_player_task_scan_classes,
        "AbilityTask_MoveRotateToLocation"),
    "container player task scan includes low-level move/rotate task")
assert_false(core.container_player_interaction_task_finished_check_required({
        scan_class_name = "AbilityTask_MoveIntoPositionForInteraction",
    }),
    "scanned player interaction tasks skip expensive BP_IsFinished checks")
assert_true(core.container_player_interaction_task_finished_check_required({
        scan_class_name = "tracked",
    }),
    "tracked player interaction tasks keep the finished check")
local loot_widget_methods = core.loot_container_widget_cancel_method_names()
assert_equal(#loot_widget_methods, 0,
    "loot container widget cancel does not call UI functions directly")
assert_false(contains_value(loot_widget_methods, "CloseWidget"),
    "loot container widget cancel does not call CloseWidget directly")
assert_false(contains_value(loot_widget_methods,
        "BndEvt__W_LootContainer_Chest_Button_Close_K2Node_ComponentBoundEvent_2_ClickedEventBP__DelegateSignature"),
    "loot container widget cancel does not call the close button event directly")
assert_false(contains_value(loot_widget_methods, "BP_OnHandleBackAction"),
    "loot container widget cancel does not call CommonUI back handling directly")
assert_false(contains_value(loot_widget_methods, "RequestClose"),
    "loot container widget cancel does not call RequestClose directly")
assert_false(core.loot_container_widget_cancel_call_succeeded(
        "BndEvt__W_LootContainer_Chest_Button_Close_K2Node_ComponentBoundEvent_2_ClickedEventBP__DelegateSignature",
        nil),
    "loot container close button event is not called by the mod")
assert_false(core.loot_container_widget_cancel_call_succeeded(
        "CloseWidget", nil),
    "loot container CloseWidget alone is not terminal")
assert_false(core.loot_container_widget_cancel_call_succeeded(
        "BP_OnHandleBackAction", true),
    "loot container widget back action true result is not terminal")
assert_false(core.loot_container_widget_cancel_call_succeeded(
        "BP_OnHandleBackAction", false),
    "loot container widget back action false result is not terminal")
assert_false(core.loot_container_widget_cancel_call_succeeded(
        "RequestClose", nil),
    "loot container RequestClose call alone is not terminal")
assert_false(core.container_task_active_check_required({
        property_name = "m_TaskLootContainer",
        task_name = "AbilityTask_LootWorldContainer /Engine/Transient.Task",
    }),
    "loot container task does not depend on BP_IsActive")
local container_loot_task_methods = core.container_task_cancel_method_names({
    property_name = "m_TaskLootContainer",
    task_name = "AbilityTask_LootWorldContainer /Engine/Transient.Task",
})
assert_equal(container_loot_task_methods[1], "EndTask",
    "loot container task uses stable GameplayTask EndTask")
assert_equal(#container_loot_task_methods, 1,
    "loot container task avoids AbilityTaskGeneric cancel methods")
assert_false(core.container_task_cancel_call_is_terminal({
        property_name = "m_TaskLootContainer",
        task_name = "AbilityTask_LootWorldContainer /Engine/Transient.Task",
    }, "EndTask", nil),
    "loot container EndTask call alone is not terminal")
assert_true(core.container_task_cancel_call_is_terminal({
        property_name = "m_TaskMoveTo",
        task_name = "AbilityTask_MoveIntoPositionForInteraction",
    }, "EndTaskAsCancelled", nil),
    "container movement task cancelled result remains terminal")
local container_close_methods = core.open_container_close_method_names()
assert_equal(container_close_methods[1], "OnLocalCloseRequested",
    "open container close starts with local close request")
assert_true(contains_value(container_close_methods, "OnCloseRequested"),
    "open container close can use base close request")
assert_true(contains_value(container_close_methods, "Server_OnCloseRequested"),
    "open container close can use server close request")
local loot_ability_close_methods = core.loot_ability_close_method_names()
assert_equal(loot_ability_close_methods[1], "CloseLootContainer",
    "loot ability close starts with the dump-backed close method")
assert_true(contains_value(loot_ability_close_methods,
        "Server_OnCloseRequested"),
    "loot ability close can use its server close request")
local container_close_observation_hooks =
    core.container_close_observation_hook_candidates()
assert_true(contains_value(container_close_observation_hooks,
        "/Script/G1R.GothicCommonActivatableWidget:CloseWidget"),
    "container close observation watches the common widget close path")
assert_true(contains_value(container_close_observation_hooks,
        "/Script/CommonUI.CommonActivatableWidget:DeactivateWidget"),
    "container close observation watches CommonUI deactivation")
assert_true(contains_value(container_close_observation_hooks,
        "/Game/UI/LootContainers/W_LootContainer_Chest.W_LootContainer_Chest_C:BP_OnDeactivated"),
    "container close observation watches chest widget deactivation")
assert_true(contains_value(container_close_observation_hooks,
        "/Script/G1R.GameplayAbilityLoot:TaskFinished"),
    "container close observation watches Loot ability task completion")
assert_true(contains_value(container_close_observation_hooks,
        "/Script/G1R.GameplayAbilityOpenContainer:ActivateAbility"),
    "container lifecycle observation watches OpenContainer activation")
assert_true(contains_value(container_close_observation_hooks,
        "/Script/G1R.GameplayAbilityOpenContainer:K2_OnEndAbility"),
    "container lifecycle observation watches OpenContainer end")
assert_true(core.text_is_container_close_observation_context(
        "/Script/G1R.GothicCommonActivatableWidget:CloseWidget",
        "W_LootContainer_Chest_C /Engine/Transient.Widget"),
    "container close observation accepts chest widgets on broad hooks")
assert_false(core.text_is_container_close_observation_context(
        "/Script/G1R.GothicCommonActivatableWidget:CloseWidget",
        "W_Crafting_InProgress_C /Engine/Transient.Widget"),
    "container close observation ignores non-container widgets on broad hooks")
assert_true(core.container_task_active_check_required({
        property_name = "m_TaskMoveTo",
        task_name = "AbilityTask_MoveIntoPositionForInteraction",
    }),
    "container movement task still requires BP_IsActive")
local crafting_montage_task_properties = core.crafting_montage_task_property_names()
assert_equal(crafting_montage_task_properties[1], "m_CharMontageTask",
    "crafting montage task uses dump property name")
local crafting_montage_task_methods = core.crafting_montage_task_cancel_method_names()
assert_equal(crafting_montage_task_methods[1], "StopPlayingMontage",
    "crafting montage task stops the dedicated montage")

local crafting_menu_exit_states = core.crafting_menu_exit_state_candidates()
assert_equal(crafting_menu_exit_states[1], 8,
    "first crafting menu exit state is ExitDefault")
assert_equal(crafting_menu_exit_states[2], 9,
    "second crafting menu exit state is ExitInProgress")

local reflected_modes = core.reflected_call_modes(nil)
assert_equal(reflected_modes[1], "call", "first reflected call mode")
assert_equal(reflected_modes[2], "self", "second reflected call mode")
assert_equal(#reflected_modes, 2, "reflected call modes skip bare calls")

local interaction_cancel_methods = core.interaction_cancel_method_names()
assert_equal(interaction_cancel_methods[1], "OnRequestEndQuick",
    "first interaction cancel method")
assert_equal(interaction_cancel_methods[2], "OnRequestEndNormal",
    "second interaction cancel method")
assert_equal(interaction_cancel_methods[3], "K2_CancelAbility",
    "third interaction cancel method")
assert_equal(interaction_cancel_methods[4], "K2_EndAbility",
    "fourth interaction cancel method")
assert_equal(interaction_cancel_methods[#interaction_cancel_methods],
    "BP_ExternalCancel", "last interaction cancel method")

local movement_action_cancel_methods = core.movement_action_cancel_method_names()
assert_equal(movement_action_cancel_methods[1], "OnRequestEndQuick",
    "first movement action cancel method")
assert_equal(movement_action_cancel_methods[2], "OnRequestEndNormal",
    "second movement action cancel method")
assert_equal(movement_action_cancel_methods[3], "K2_CancelAbility",
    "third movement action cancel method cancels the free point ability")
assert_equal(movement_action_cancel_methods[4], "K2_EndAbility",
    "fourth movement action cancel method ends the free point ability")
assert_equal(movement_action_cancel_methods[#movement_action_cancel_methods],
    "K2_EndAbility", "last movement action cancel method")

assert_equal(#core.movement_action_task_cancel_method_names(), 0,
    "movement-only cancel does not call task cancel methods without player context")
assert_equal(#core.movement_action_task_class_names(), 0,
    "movement-only cancel does not scan global interaction tasks")

local player_state_identity =
    "G1RPlayerState /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_1"
local player_ability_name =
    "GameplayAbilityInteractFreePoint "
    .. "/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel."
    .. "G1RPlayerState_1.GameplayAbilityInteractFreePoint_2"
local player_sleep_ability_name =
    "GA_Human_Sleep_Bed_Low "
    .. "/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel."
    .. "G1RPlayerState_1.GA_Human_Sleep_Bed_Low_4"
local player_gameplay_sleep_ability_name =
    "GameplayAbilitySleep "
    .. "/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel."
    .. "G1RPlayerState_1.GameplayAbilitySleep_4"
local sleep_task_name =
    "AbilityTask_Interaction_Human_Sleep_Seated /Engine/Transient.AbilityTask_Interaction_Human_Sleep_Seated_1"
local player_sleep_task_name =
    "AbilityTask_Interaction_Player_SitAndSleep /Engine/Transient.AbilityTask_Interaction_Player_SitAndSleep_1"
local player_container_ability_name =
    "GA_Human_OpenContainer "
    .. "/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel."
    .. "G1RPlayerState_1.GA_Human_OpenContainer_5"
local npc_ability_name =
    "GameplayAbilityInteractFreePoint "
    .. "/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel."
    .. "State_SC_NOV_Novice_1.GameplayAbilityInteractFreePoint_3"
assert_true(core.object_name_belongs_to_owner(player_ability_name, player_state_identity),
    "player ability belongs to player state")
assert_true(core.object_name_belongs_to_owner(player_sleep_ability_name, player_state_identity),
    "player sleep ability belongs to player state")
assert_false(core.object_name_belongs_to_owner(npc_ability_name, player_state_identity),
    "npc ability does not belong to player state")
assert_true(core.object_name_is_sleep_bed_ability(player_sleep_ability_name),
    "sleep bed ability name detected")
assert_false(core.object_name_is_sleep_bed_ability(player_ability_name),
    "free point ability is not sleep bed ability")
assert_true(core.object_name_is_sleep_ability(player_sleep_ability_name),
    "sleep bed ability is a sleep ability")
assert_true(core.object_name_is_sleep_ability(player_gameplay_sleep_ability_name),
    "GameplayAbilitySleep is a sleep ability")
assert_false(core.object_name_is_sleep_ability(player_ability_name),
    "free point ability is not a sleep ability")
assert_true(core.object_name_can_use_gameplay_ability_method(player_sleep_ability_name),
    "sleep ability can use gameplay ability reflected methods")
assert_true(core.object_name_can_use_gameplay_ability_method(player_ability_name),
    "free point ability can use gameplay ability reflected methods")
assert_false(core.object_name_can_use_gameplay_ability_method(
        "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PersistentLevel.PlayerCharacterBP_C_1"),
    "player character cannot use gameplay ability reflected methods")
assert_true(core.object_name_is_sleep_interaction_task(sleep_task_name),
    "sleep interaction task name detected")
assert_false(core.object_name_is_sleep_interaction_task(player_sleep_ability_name),
    "sleep bed ability is not sleep interaction task")
assert_true(core.object_name_is_player_sleep_interaction_task(player_sleep_task_name),
    "player sleep interaction task name detected")
assert_false(core.object_name_is_player_sleep_interaction_task(sleep_task_name),
    "human sleep interaction task is not the player sleep task")
assert_true(core.text_is_sleep_interaction_context(
        "m_InteractiveActor=Interactive_Sleep_Bed_Low_C_UAID_123"),
    "sleep bed actor text is sleep context")
assert_true(core.text_is_sleep_interaction_context(
        "AbilityTask_Interaction_Player_SitAndSleep"),
    "player sit and sleep task text is sleep context")
assert_false(core.text_is_sleep_interaction_context(
        "m_InteractiveActor=Interactive_Chair_WoodBench"),
    "bench actor text is not sleep context")
assert_true(core.object_name_is_container_ability(player_container_ability_name),
    "container ability name detected")
assert_false(core.object_name_is_container_ability(player_sleep_ability_name),
    "sleep bed ability is not container ability")
assert_true(core.text_is_container_interaction_context(
        "ActionFilter=Ability.Interact.Open.Container"),
    "open container action filter detected")
assert_true(core.text_is_container_interaction_context(
        "m_InteractiveActor=Interactive_Chest_C_UAID_123"),
    "interactive chest context detected")
assert_true(core.text_is_container_interaction_context(
        "m_DefaultInteraction=State.Interact.Container"),
    "state interact container context detected")
assert_true(core.text_is_container_interaction_context(
        "m_TaskLootContainer=AbilityTask_LootWorldContainer"),
    "loot world container task context detected")
assert_false(core.text_is_container_interaction_context(
        "ActionFilter=FGameplayTagContainer"),
    "generic gameplay tag container text is not container context")
assert_false(core.text_is_container_interaction_context(
        "m_InteractiveActor=Interactive_Chair_WoodBench"),
    "bench context is not container context")
assert_true(core.text_is_ladder_interaction_context(
        "m_InteractiveActor=Interactive_Ladder_Wooden_C_UAID_123"),
    "ladder actor detected")
assert_true(core.text_is_ladder_interaction_context(
        "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithNavLink"),
    "navlink traversal is treated as unsafe ladder context")
assert_true(core.text_is_ladder_interaction_context(
        "UAbilityTask_Interact_Ladder"),
    "ladder ability task is treated as unsafe ladder context")
assert_false(core.text_is_ladder_interaction_context(
        "m_InteractiveActor=LootContainer_Chest_C_UAID_123"),
    "chest context is not ladder context")
assert_false(core.text_is_ladder_interaction_context(
        "m_InteractiveActor=Interactive_Chair_WoodBench"),
    "bench context is not ladder context")
assert_true(core.text_is_seating_interaction_context(
        "AS_male_sit_bench_start"),
    "bench sit montage is seating context")
assert_true(core.text_is_seating_interaction_context(
        "Action.Interact.Sit.Chair"),
    "chair interaction tag is seating context")
assert_false(core.text_is_seating_interaction_context(
        "m_InteractiveActor=Interactive_Ladder_Wooden_C_UAID_123"),
    "ladder context is not seating context")
assert_true(core.seating_fast_path_context_can_cancel({
        free_point_context = "m_InteractiveActor=Interactive_Chair_ArtisanWoodBench_C",
        tracked_source = "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility",
        tracked_phase = "idle",
    }),
    "bench free point context can use seating fast path")
assert_true(core.seating_fast_path_context_can_cancel({
        tracked_target = "AS_male_sit_bench_start",
        tracked_phase = "animation",
    }),
    "bench montage context can use seating fast path")
assert_false(core.seating_fast_path_context_can_cancel({
        free_point_context = "m_InteractiveActor=Interactive_Sleep_Bed_Low_C",
        tracked_phase = "idle",
    }),
    "sleep bed does not use seating fast path")
assert_false(core.seating_fast_path_context_can_cancel({
        free_point_context = "m_InteractiveActor=Interactive_Ladder_Wooden_C",
        tracked_phase = "idle",
    }),
    "ladder does not use seating fast path")
assert_false(core.seating_fast_path_context_can_cancel({
        free_point_context = "m_InteractiveActor=Interactive_Chest_C",
        tracked_phase = "idle",
    }),
    "container does not use seating fast path")
assert_false(core.seating_fast_path_context_can_cancel({
        free_point_context = "m_InteractiveActor=Interactive_Chair_Stool_C",
        tracked_source = "seating-fast-cancelled",
        tracked_phase = "idle",
    }),
    "stale seating context after a bank cancel does not steal later interactions")
assert_false(core.seating_fast_path_context_can_cancel({
        free_point_context = "m_InteractiveActor=Interactive_Chair_Stool_C",
        tracked_source = "container-player-task-cancelled",
        tracked_phase = "idle",
    }),
    "stale seating context after a container cancel does not steal later interactions")
assert_false(core.ladder_free_point_context_should_be_read({
        tracked_target = "AS_male_sit_bench_start",
    }),
    "ladder free point context is not read during seating animations")
assert_true(core.ladder_free_point_context_should_be_read({
        tracked_target = "",
    }),
    "ladder free point context is read when no known non-ladder target is tracked")
assert_true(core.interaction_cancel_should_continue_after_success(player_sleep_ability_name),
    "sleep bed ability cancel success continues to next target")
assert_true(core.interaction_cancel_should_continue_after_success(sleep_task_name),
    "sleep task cancel success continues to next target")
assert_true(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        sleep_interaction_context = true,
    }),
    "free point success continues in sleep interaction context")
assert_false(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        sleep_interaction_context = true,
        sleep_task_cancelled = true,
    }),
    "free point success is terminal after sleep task cancel")
assert_false(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        container_interaction_context = true,
    }),
    "free point success does not continue in disabled container context")
assert_false(core.interaction_cancel_should_continue_after_success(player_ability_name),
    "free point ability cancel success is terminal")
assert_false(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        movement_action = 7,
    }),
    "free point movement action 7 success is terminal without interaction context")
assert_false(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        movement_action = 13,
    }),
    "free point seat movement action success remains terminal")

assert_false(core.interaction_success_should_trigger_container_secondary_cancel(
        player_ability_name, {
            movement_action = 7,
            container_ability_available = true,
        }),
    "free point movement action 7 alone does not trigger secondary container cancel")
assert_false(core.interaction_success_should_trigger_container_secondary_cancel(
        player_ability_name, {
            movement_action = 7,
            container_ability_available = true,
            container_interaction_context = true,
        }),
    "explicit container interaction context does not trigger secondary container cancel")
assert_false(core.interaction_success_should_trigger_container_secondary_cancel(
        player_ability_name, {
            movement_action = 7,
            container_ability_available = true,
            free_point_container_context = true,
        }),
    "current free point container context does not trigger secondary container cancel")
assert_false(core.interaction_success_should_trigger_container_secondary_cancel(
        player_ability_name, {
            movement_action = 13,
            container_ability_available = true,
        }),
    "seat movement action success does not trigger secondary container cancel")
assert_false(core.interaction_success_should_trigger_container_secondary_cancel(
        player_container_ability_name, {
            movement_action = 7,
            container_ability_available = true,
        }),
    "container ability success does not recursively trigger secondary container cancel")

assert_false(core.container_ability_fallback_allowed({
        container_task_count = 0,
        active_ability_is_container = true,
        tracked_object_is_container = false,
        tracked_animation_is_container = false,
    }),
    "container ability fallback requires current container context")
assert_false(core.container_ability_fallback_allowed({
        container_task_count = 1,
        active_ability_is_container = false,
        tracked_object_is_container = false,
        tracked_animation_is_container = false,
    }),
    "container task does not enable disabled container fallback")
assert_false(core.container_ability_fallback_allowed({
        container_task_count = 0,
        active_ability_is_container = false,
        tracked_object_is_container = false,
        tracked_animation_is_container = true,
    }),
    "tracked container animation does not enable disabled container fallback")

assert_false(core.container_ability_context_can_cancel({
        ability_available = true,
        ability_ended = false,
        context_text = "m_InteractiveActor=Interactive_Chest_C_UAID_123",
    }),
    "container ability context cannot cancel while container route is disabled")
assert_false(core.container_ability_context_can_cancel({
        ability_available = true,
        ability_ended = true,
        context_text = "m_InteractiveActor=Interactive_Chest_C_UAID_123",
    }),
    "ended container ability with stale chest target cannot cancel")

assert_false(core.sleep_interaction_task_should_cleanup_ability({
        explicit_sleep_context = false,
        task_name = player_sleep_task_name,
    }),
    "generic player SitAndSleep task does not cleanup sleep bed ability")
assert_true(core.sleep_interaction_task_should_cleanup_ability({
        explicit_sleep_context = true,
        task_name = player_sleep_task_name,
    }),
    "explicit sleep context can cleanup sleep bed ability")
assert_false(core.container_ability_context_can_cancel({
        ability_available = true,
        ability_ended = false,
        context_text = "m_InteractiveActor=Interactive_Chair_WoodBench",
    }),
    "active container ability without chest target cannot cancel")
assert_false(core.container_ability_context_can_cancel({
        ability_available = false,
        ability_ended = false,
        context_text = "m_InteractiveActor=Interactive_Chest_C_UAID_123",
    }),
    "missing container ability cannot cancel")
assert_true(core.interaction_container_context_should_block({
        tracked_source = "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility",
        free_point_context = "ActionFilter=Ability.Interact.Open.Container",
    }),
    "free point container context blocks generic interaction cancel")
assert_true(core.interaction_container_context_should_block({
        tracked_object = player_container_ability_name,
    }),
    "tracked container ability blocks generic interaction cancel")
assert_false(core.interaction_container_context_should_block({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
    }),
    "active container ability context alone does not block generic interaction cancel")
assert_true(core.container_free_point_movement_cancel_allowed({
        free_point_context = "ActionFilter=Ability.Interact.Open.Container",
        tracked_phase = "move",
        loot_ui_active = false,
    }),
    "container free point movement can cancel before loot UI exists")
assert_true(core.container_free_point_movement_cancel_allowed({
        free_point_context = "m_InteractiveActor=Interactive_Chest_C_UAID_123",
        tracked_phase = "ability",
        loot_ui_active = false,
    }),
    "container free point ability can cancel before loot UI exists")
assert_true(core.container_free_point_movement_cancel_allowed({
        free_point_context = "m_InteractiveActor=UObject: 00000000EE677178 "
            .. "ActionFilter=ScriptStruct /Script/GameplayTags.GameplayTagContainer",
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer "
            .. "m_InteractiveActor=Interactive_Chest_C_UAID_123",
        tracked_phase = "move",
        loot_ui_active = false,
    }),
    "generic free point movement can cancel when OpenContainer ability targets a chest")
assert_true(core.container_free_point_movement_cancel_allowed({
        free_point_context = "m_InteractiveActor=UObject: 000000006D9BE298 "
            .. "ActionFilter=ScriptStruct /Script/GameplayTags.GameplayTagContainer",
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer "
            .. "m_InteractiveActor=Interactive_Chest_C_UAID_123",
        tracked_phase = "idle",
        loot_ui_active = false,
    }),
    "idle tracking can still cancel when active OpenContainer ability targets a chest")
assert_false(core.container_free_point_movement_cancel_allowed({
        free_point_context = "ActionFilter=Ability.Interact.Open.Container",
        tracked_phase = "animation",
        loot_ui_active = false,
    }),
    "container free point cancel does not steal animation-phase handling")
assert_false(core.container_free_point_movement_cancel_allowed({
        free_point_context = "ActionFilter=Ability.Interact.Open.Container",
        tracked_phase = "move",
        loot_ui_active = true,
    }),
    "visible loot UI blocks free point movement cancel")
assert_false(core.container_free_point_movement_cancel_allowed({
        free_point_context = "m_InteractiveActor=Interactive_Chair_WoodBench",
        tracked_phase = "move",
        loot_ui_active = false,
    }),
    "non-container free point movement does not use container cancel")
assert_true(core.interaction_container_context_should_attempt_cancel({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
        widget_count = 1,
    }),
    "visible loot container widget allows container cancel")
assert_true(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 1,
        is_activated = true,
        is_visible = true,
    }),
    "activated visible loot widget skips container ability cancel")
assert_true(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 1,
        is_activated = true,
    }),
    "activated loot widget with unknown visibility preserves existing UI skip")
assert_true(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 1,
        is_visible = true,
    }),
    "visible loot widget skips container ability cancel")
assert_false(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 1,
        is_activated = true,
        is_visible = false,
    }),
    "activated invisible pre-UI loot widget does not skip container ability cancel")
assert_false(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 1,
        is_activated = false,
        is_visible = false,
    }),
    "inactive invisible stale loot widget does not skip container ability cancel")
assert_false(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 0,
        is_activated = true,
        is_visible = true,
    }),
    "missing loot widget does not skip container ability cancel")
assert_true(core.loot_container_widget_state_should_skip_cancel({
        widget_count = 1,
    }),
    "unknown loot widget runtime state preserves existing UI skip")
assert_true(core.interaction_container_context_should_attempt_cancel({
        task_count = 1,
        widget_count = 0,
    }),
    "active loot container task allows container cancel without widget")
assert_false(core.interaction_container_context_should_attempt_cancel({
        tracked_target = "AS_male_sit_bench_start",
        task_count = 1,
        widget_count = 0,
    }),
    "visible stale loot task does not steal seating cancel")
assert_false(core.interaction_container_context_should_attempt_cancel({
        tracked_target = "AS_male_sit_bench_start",
        widget_count = 1,
    }),
    "visible stale loot widget does not steal seating cancel")
assert_false(core.interaction_container_context_should_attempt_cancel({
        tracked_target = "Ability.Interact.Sleep.Bed",
        widget_count = 1,
    }),
    "visible stale loot widget does not steal sleep cancel")
assert_false(core.interaction_container_context_should_attempt_cancel({
        free_point_context = "ActionFilter=Ability.Interact.Climb.Ladder",
        widget_count = 1,
    }),
    "visible stale loot widget does not steal ladder cancel")
assert_false(core.interaction_container_context_should_attempt_cancel({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
        widget_count = 0,
    }),
    "stale container ability without current context does not allow container cancel")
assert_true(core.container_fast_path_context_can_cancel({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
        tracked_phase = "idle",
        loot_ui_active = false,
    }),
    "container fast path can use current OpenContainer ability context before broad scans")
assert_false(core.container_fast_path_context_can_cancel({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
        tracked_target = "Ability.Interact.Sleep.Bed",
        tracked_phase = "idle",
        loot_ui_active = false,
    }),
    "container fast path does not steal sleep movement")
assert_false(core.container_fast_path_context_can_cancel({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
        free_point_context = "ActionFilter=Ability.Interact.Climb.Ladder",
        tracked_phase = "idle",
        loot_ui_active = false,
    }),
    "container fast path does not steal ladder movement")
assert_false(core.container_fast_path_context_can_cancel({
        ability_context = "m_TaskLootContainer=AbilityTask_LootWorldContainer",
        tracked_phase = "idle",
        loot_ui_active = true,
    }),
    "container fast path does not run while the loot UI is active")
assert_true(core.player_interaction_task_fallback_should_scan({
        tracked_phase = "idle",
        free_point_ability_available = true,
    }),
    "player interaction task fallback can scan when chest context is not visible yet")
assert_true(core.player_interaction_task_fallback_should_scan({
        tracked_phase = "idle",
        free_point_context = "m_InteractiveActor=Interactive_Chair_Stool_C",
        free_point_ability_available = true,
    }),
    "player interaction task fallback ignores stale seating free point context")
assert_true(core.player_interaction_task_fallback_should_precede_sleep_probe({
        tracked_phase = "idle",
        free_point_context = "m_InteractiveActor=Interactive_Chair_Stool_C",
        free_point_ability_available = true,
    }),
    "player interaction task fallback can precede sleep probes for stale seating context")
assert_false(core.player_interaction_task_fallback_should_precede_sleep_probe({
        tracked_phase = "idle",
        free_point_context = "ActionFilter=Ability.Interact.Sleep.Bed",
        free_point_ability_available = true,
    }),
    "player interaction task fallback does not precede sleep probes for sleep context")
assert_false(core.player_interaction_task_fallback_should_precede_sleep_probe({
        tracked_phase = "idle",
        free_point_ability_available = true,
    }),
    "player interaction task fallback without context waits until sleep probes run")
assert_false(core.player_interaction_task_fallback_should_scan({
        tracked_target = "AS_male_sit_bench_start",
        tracked_phase = "move",
        free_point_ability_available = true,
    }),
    "player interaction task fallback does not steal tracked seating movement")
assert_false(core.player_interaction_task_fallback_should_scan({
        free_point_context = "ActionFilter=Ability.Interact.Climb.Ladder",
        tracked_phase = "move",
        free_point_ability_available = true,
    }),
    "player interaction task fallback does not scan ladder movement")
assert_false(core.player_interaction_task_fallback_should_scan({
        tracked_phase = "animation",
        free_point_ability_available = true,
    }),
    "player interaction task fallback skips animation-phase interactions")
assert_false(core.player_interaction_task_fallback_should_scan({
        tracked_phase = "idle",
        free_point_ability_available = false,
    }),
    "player interaction task fallback requires the player free point ability")
assert_false(core.interaction_container_context_should_block({
        tracked_source = "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility",
        free_point_context = "ActionFilter=Ability.Interact.Sit.Chair",
    }),
    "non-container free point context does not block generic interaction cancel")

local main_source = assert(io.open("Scripts/main.lua", "r")):read("*a")
local player_state_identity_position =
    string.find(main_source, "local function player_state_identity()", 1, true)
local mark_interaction_context_position =
    string.find(main_source, "local function mark_interaction_context", 1, true)
local try_cancel_crafting_position =
    string.find(main_source, "local function try_cancel_crafting", 1, true)
local pack_args_position =
    string.find(main_source, "local function pack_args", 1, true)
local call_method_with_arg_pack_position =
    string.find(main_source, "local function call_method_with_arg_pack", 1, true)
assert_true(player_state_identity_position ~= nil,
    "main defines player_state_identity as a local function")
assert_true(
    string.find(main_source, "controller_player_state = controller.PlayerState",
        1, true) ~= nil,
    "player_state_identity falls back to PlayerController.PlayerState")
assert_true(mark_interaction_context_position ~= nil,
    "main defines mark_interaction_context")
assert_true(player_state_identity_position < mark_interaction_context_position,
    "player_state_identity is local before interaction tracking uses it")
assert_true(pack_args_position ~= nil
        and try_cancel_crafting_position ~= nil
        and pack_args_position < try_cancel_crafting_position,
    "pack_args is local before crafting cancel uses it")
assert_true(call_method_with_arg_pack_position ~= nil
        and try_cancel_crafting_position ~= nil
        and call_method_with_arg_pack_position < try_cancel_crafting_position,
    "call_method_with_arg_pack is local before crafting cancel uses it")
assert_true(string.find(main_source, "try_cancel_movement_action_without_context", 1, true) == nil,
    "movement-only cancel avoids direct Character/Controller method fallback")
assert_true(string.find(main_source, "movement-task-cancel", 1, true) == nil,
    "movement-only cancel avoids global task EndTask fallback")
assert_true(string.find(main_source, "gameplay_ability_is_active", 1, true) == nil,
    "container fallback does not use unavailable IsActive")
assert_true(
    string.find(main_source, "secondaryContainer=", 1, true) == nil,
    "generic interaction cancel no longer attempts secondary container cleanup")
assert_true(
    string.find(main_source,
        "core.interaction_container_context_should_attempt_cancel", 1, true)
        ~= nil,
    "main gates container handling before generic interaction cancel")
assert_true(
    string.find(main_source, "count_player_container_interaction_task_candidates",
        1, true) ~= nil,
    "main can observe LootWorldContainer task candidates before enabling container cancel")
assert_true(
    string.find(main_source, "task_count = container_task_count", 1, true)
        ~= nil,
    "main passes LootWorldContainer task candidates into container cancel gating")
assert_true(
    string.find(main_source, "count_player_container_ability_candidates", 1, true)
        ~= nil,
    "main can observe OpenContainer ability candidates before enabling container cancel")
assert_true(
    string.find(main_source, "count_loot_container_widget_candidates", 1, true)
        ~= nil,
    "main can observe chest loot widgets before enabling container cancel")
assert_true(
    string.find(main_source, "try_cancel_container_move_task", 1, true) ~= nil,
    "main can cancel the OpenContainer move task without cancelling the ability")
assert_true(
    string.find(main_source, "try_cancel_container_free_point_movement", 1, true) ~= nil,
    "main can cancel container movement through InteractFreePoint before loot UI opens")
assert_true(
    string.find(main_source, "try_cancel_container_root_interaction_task", 1, true) ~= nil,
    "main can cancel the InteractFreePoint root interaction task before loot UI opens")
assert_true(
    string.find(main_source, "[container-root-task-attempt]", 1, true) ~= nil,
    "main logs root interaction task cancellation attempts")
assert_true(
    string.find(main_source, "try_cancel_container_player_interaction_tasks", 1, true) ~= nil,
    "main can cancel active player interaction tasks when root task is not reachable")
assert_true(
    string.find(main_source, "try_cleanup_player_interaction_free_point", 1, true)
        ~= nil,
    "main cleans up InteractFreePoint after a direct player task fallback")
assert_true(
    string.find(main_source, "timing_log", 1, true) ~= nil,
    "main defines timing logging helper")
assert_true(
    string.find(main_source, "[timing]", 1, true) ~= nil,
    "main emits dedicated timing log lines")
assert_true(
    string.find(main_source, "timed_find_all", 1, true) ~= nil,
    "main wraps FindAllOf calls for timing diagnostics")
assert_true(
    string.find(main_source, "Timing=", 1, true) ~= nil,
    "main logs whether timing diagnostics are enabled")
assert_true(
    string.find(main_source, "cancel-attempt-total", 1, true) ~= nil,
    "main logs total timing for each cancel attempt")
assert_true(
    string.find(main_source, "container-player-task-total", 1, true) ~= nil,
    "main logs total timing for scanned container task cancellation")
assert_true(
    string.find(main_source, "container-player-task-avatar", 1, true) ~= nil,
    "main logs timing for player task avatar matching")
assert_true(
    string.find(main_source, "container-root-task-method", 1, true) ~= nil,
    "main logs timing for each container task cancel method call")
assert_true(
    string.find(main_source, "container-root-task-target", 1, true) ~= nil,
    "main logs total timing for each container task cancel target")
assert_true(
    string.find(main_source, "skip_finished_check", 1, true) ~= nil,
    "main can skip the expensive finished check for scanned player tasks")
assert_true(
    string.find(main_source, "crafting-task-finished", 1, true) ~= nil,
    "main logs when crafting skips expensive finished checks")
assert_true(
    string.find(main_source, "crafting-task-method", 1, true) ~= nil,
    "main logs timing for crafting task cancel methods")
assert_true(
    string.find(main_source, "try_fast_cancel_container_movement", 1, true) ~= nil,
    "main has a container movement fast path before broad diagnostic scans")
assert_true(
    string.find(main_source, "try_fast_cancel_seating_movement", 1, true) ~= nil,
    "main has a seating movement fast path before broad sleep scans")
assert_true(
    string.find(main_source, "try_cancel_container_player_interaction_task_class", 1, true) ~= nil,
    "main cancels player interaction tasks class-by-class to avoid full scans")
assert_true(
    string.find(main_source, "[container-player-task-attempt]", 1, true) ~= nil,
    "main logs scanned player interaction task cancellation attempts")
assert_true(
    string.find(main_source, "task_avatar_matches_player", 1, true) ~= nil,
    "main filters scanned interaction tasks to the current player")
assert_true(
    string.find(main_source, "[container-freepoint-cancel]", 1, true) ~= nil,
    "main logs early container free point movement cancellation")
assert_true(
    string.find(main_source, "local any_success = false", 1, true) ~= nil
        and string.find(main_source, "[container-freepoint-attempt]", 1, true) ~= nil,
    "container free point cancel tries all movement end requests before returning")
assert_true(
    string.find(main_source, "container_task_active_check_required", 1, true)
        ~= nil,
    "main can bypass BP_IsActive for dump-backed loot container tasks")
assert_true(
    string.find(main_source, "container_task_cancel_method_names", 1, true)
        ~= nil,
    "main chooses the stable EndTask method for loot container tasks")
assert_true(
    string.find(main_source, "container_task_cancel_call_is_terminal", 1, true)
        ~= nil,
    "main does not treat loot EndTask as a proven visible close")
assert_true(
    string.find(main_source, "container_move_task_property_names", 1, true) ~= nil,
    "main uses dump-backed OpenContainer movement task properties")
assert_true(
    string.find(main_source, "should_handle_container", 1, true)
        ~= nil,
    "main gates container cancellation on current context")
assert_true(
    string.find(main_source, "try_close_loot_container_widget", 1, true)
        ~= nil,
    "main keeps the loot UI helper inert for safety")
assert_true(
    string.find(main_source,
        '"/Script/G1R.InventoryLootContainer:RequestClose"', 1, true) ~= nil,
    "main maps loot container UI RequestClose")
assert_true(
    string.find(main_source,
        '"/Script/G1R.GothicCommonActivatableWidget:CloseWidget"', 1, true)
        ~= nil,
    "main maps the observed normal loot container CloseWidget path")
assert_true(
    string.find(main_source,
        '"/Script/CommonUI.CommonActivatableWidget:IsActivated"', 1, true)
        ~= nil,
    "main maps passive CommonUI activation state reads")
assert_true(
    string.find(main_source, '"/Script/UMG.Widget:IsVisible"', 1, true)
        ~= nil,
    "main maps passive widget visibility state reads")
assert_true(
    string.find(main_source, '"/Script/UMG.Widget:GetVisibility"', 1, true)
        ~= nil,
    "main maps passive widget visibility enum reads")
assert_true(
    string.find(main_source,
        '"/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction"', 1, true)
        ~= nil,
    "main maps CommonUI back handling for loot container UI")
assert_true(
    string.find(main_source,
        '"/Game/UI/LootContainers/W_LootContainer_Chest.W_LootContainer_Chest_C:BndEvt__W_LootContainer_Chest_Button_Close_K2Node_ComponentBoundEvent_2_ClickedEventBP__DelegateSignature"',
        1, true) ~= nil,
    "main maps the loot container close button event")
assert_true(
    string.find(main_source, 'log("[container-ui-attempt] key=', 1, true) ~= nil,
    "main logs loot UI calls if active methods are reintroduced")
assert_true(
    string.find(main_source, 'log("[container-ui-skip] key=', 1, true) ~= nil,
    "main skips active cancellation when the loot UI is visible")
assert_true(
    string.find(main_source, "widget_state_context_text", 1, true) ~= nil,
    "main captures passive loot widget state for stale widget diagnosis")
assert_true(
    string.find(main_source, "loot_widget_runtime_state", 1, true) ~= nil,
    "main captures structured passive loot widget state")
assert_true(
    string.find(main_source, "is_activated", 1, true) ~= nil,
    "main tracks passive loot widget activation state")
assert_true(
    string.find(main_source, "is_visible", 1, true) ~= nil,
    "main tracks passive loot widget visibility state")
assert_true(
    string.find(main_source, "widgetState=", 1, true) ~= nil,
    "container context evidence includes passive widget state")
assert_true(
    string.find(main_source,
        '"/Script/G1R.GameplayAbilityOpenContainer:OnLocalCloseRequested"',
        1, true) ~= nil,
    "main maps OpenContainer local close request")
assert_true(
    string.find(main_source,
        '"/Script/G1R.GameplayAbilityOpen:OnCloseRequested"', 1, true) ~= nil,
    "main maps Open base close request")
assert_true(
    string.find(main_source,
        '"/Script/G1R.GameplayAbilityOpen:Server_OnCloseRequested"', 1, true)
        ~= nil,
    "main maps Open server close request")
assert_true(
    string.find(main_source,
        '"/Script/G1R.GameplayAbilityLoot:CloseLootContainer"', 1, true)
        ~= nil,
    "main maps Loot ability close container request")
assert_true(
    string.find(main_source,
        '"/Script/G1R.GameplayAbilityLoot:Server_OnCloseRequested"', 1, true)
        ~= nil,
    "main maps Loot ability server close request")
assert_true(
    string.find(main_source, "find_player_loot_ability", 1, true) ~= nil,
    "main can scan the player-owned Loot ability")
assert_true(
    string.find(main_source, "try_request_loot_ability_close", 1, true) ~= nil,
    "main can request a close on the Loot ability")
assert_true(
    string.find(main_source, "install_container_close_observation_hooks", 1, true)
        ~= nil,
    "main installs narrow container close observation hooks")
assert_true(
    string.find(main_source,
        "core.container_close_observation_hook_candidates()", 1, true)
        ~= nil,
    "main reads the container close observation hook list from core")
local container_close_observation_function =
    string.match(main_source,
        "local function install_container_close_observation_hooks%(.-%)(.-)local function install_player_hooks")
assert_true(container_close_observation_function ~= nil,
    "main defines container close observation hook installation")
assert_true(
    string.find(container_close_observation_function,
        "core.object_name_is_container_ability(object_text)", 1, true) ~= nil
        and string.find(container_close_observation_function,
            "cached_container_ability = object", 1, true) ~= nil,
    "container observation hooks cache OpenContainer ability before cancel hot path")
assert_true(
    string.find(main_source, 'log("[container-close-observe] hook=', 1, true)
        ~= nil,
    "main logs observed container close hook calls")
assert_true(
    string.find(main_source, 'log("[container-context] key=', 1, true) ~= nil,
    "main logs non-debug container context evidence")
assert_true(
    string.find(main_source, "widgets=", 1, true) ~= nil,
    "container context evidence includes chest widget count")
local container_fast_path_function =
    string.match(main_source,
        "local function try_fast_cancel_container_movement%(.-%)(.-)local function try_cancel_container_move_task")
assert_true(container_fast_path_function ~= nil,
    "main has a dedicated container fast path function")
local fast_path_free_point_guard_position =
    string.find(container_fast_path_function, "ability_context = \"\"", 1, true)
local fast_path_ability_scan_position =
    string.find(container_fast_path_function,
        "container_ability = active_container_ability()", 1, true)
assert_true(
    fast_path_free_point_guard_position ~= nil
        and fast_path_ability_scan_position ~= nil
        and fast_path_free_point_guard_position < fast_path_ability_scan_position,
    "container fast path checks free point context before scanning OpenContainer abilities")
local free_point_container_context_function =
    string.match(main_source,
        "local function free_point_container_context_text%(.-%)(.-)local function free_point_ladder_context_text")
assert_true(free_point_container_context_function ~= nil,
    "main has a dedicated container free point context reader")
assert_true(
    string.find(free_point_container_context_function, '"m_InteractiveActor"', 1, true)
        ~= nil,
    "container free point context reads the interactive actor")
assert_true(
    string.find(main_source, '"m_TaskLootContainer"', 1, true) ~= nil,
    "container ability context reads the OpenContainer loot task")
assert_true(string.find(main_source, "m_UICraftingProgress", 1, true) ~= nil,
    "main uses the crafting progress widget for graceful crafting cancel")
assert_true(string.find(main_source, "ButtonCraftingMenuExit_Bind", 1, true) ~= nil,
    "main falls back to the crafting menu exit binding")
assert_true(string.find(main_source, "crafting_move_task_property_names", 1, true) ~= nil,
    "main uses the crafting movement task before UI exit")
assert_true(string.find(main_source, "crafting_montage_task_property_names", 1, true) ~= nil,
    "main uses the crafting character montage task before UI exit")
assert_true(string.find(main_source, "EndTaskWithResult", 1, true) ~= nil,
    "main can cancel generic tasks with EGenericTaskResult")
assert_true(string.find(main_source, "StopPlayingMontage", 1, true) ~= nil,
    "main stops the dedicated crafting montage task")
assert_true(string.find(main_source, "uiCancel=", 1, true) ~= nil,
    "crafting menu exit logs whether UI cancel was attempted first")
assert_true(string.find(main_source, "local CRAFTING_RETRACK_LOCKOUT_MS = 1500", 1, true)
        ~= nil,
    "crafting retrack lockout stays short enough for repeated crafting attempts")
assert_true(
    string.find(main_source,
        "local sleep_interaction_cancelled = try_cancel_sleep_interaction", 1, true)
        ~= nil,
    "sleep interaction task cancel result is stored")
local sleep_interaction_return_position =
    string.find(main_source, "if sleep_interaction_cancelled then\n        return true\n    end",
        1, true)
local generic_interaction_objects_position =
    string.find(main_source, "local objects = interaction_cancel_objects()", 1, true)
assert_true(
    sleep_interaction_return_position ~= nil
        and generic_interaction_objects_position ~= nil
        and sleep_interaction_return_position < generic_interaction_objects_position,
    "sleep interaction task cancel returns before generic interaction fallback")
local sleep_context_position =
    string.find(main_source, "local free_point_sleep_text =", 1, true)
local container_fast_path_position =
    string.find(main_source,
        "try_fast_cancel_container_movement(key_name, interact_free_point_ability)",
        1, true)
local seating_fast_path_position =
    string.find(main_source,
        "try_fast_cancel_seating_movement(\n            key_name, interact_free_point_ability, free_point_sleep_text)",
        1, true)
local sleep_task_count_position =
    string.find(main_source,
        "local sleep_task_candidate_count =\n            count_player_sleep_interaction_task_candidates()",
        1, true)
local container_task_count_position =
    string.find(main_source,
        "container_task_count, container_task_sample =\n        count_player_container_interaction_task_candidates()",
        1, true)
local player_task_fallback_position =
    string.find(main_source,
        "try_player_task_fallback(\"post-sleep\")", 1, true)
local early_player_task_fallback_position =
    string.find(main_source,
        "try_player_task_fallback(\"pre-sleep\")", 1, true)
local player_task_fallback_helper_position =
    string.find(main_source, "local function try_player_task_fallback(stage)", 1, true)
local player_task_fallback_cleanup_position =
    string.find(main_source,
        "try_cleanup_player_interaction_free_point(",
        player_task_fallback_helper_position or 1, true)
local container_widget_count_position =
    string.find(main_source,
        "container_widget_count, container_widget_sample =\n        count_loot_container_widget_candidates()",
        1, true)
local container_move_cancel_position =
    string.find(main_source,
        "if try_cancel_container_move_task(key_name, container_ability) then",
        1, true)
local container_free_point_cancel_position =
    string.find(main_source,
        "local free_point_cancelled =",
        1, true)
local container_root_task_cancel_position =
    string.find(main_source,
        "if try_cancel_container_root_interaction_task(key_name, interact_free_point_ability) then",
        1, true)
local container_player_task_cancel_position =
    string.find(main_source,
        "if try_cancel_container_player_interaction_tasks(key_name) then",
        1, true)
local container_ability_close_position =
    string.find(main_source, "try_request_container_close(key_name, container_ability)",
        1, true)
local loot_ability_close_position =
    string.find(main_source,
        "try_request_loot_ability_close(key_name, loot_ability)",
        1, true)
local container_ui_return_position =
    string.find(main_source,
        "if try_close_loot_container_widget(key_name) then\n            return true\n        end",
        1, true)
local container_ui_skip_position =
    string.find(main_source,
        "if container_ui_visible then\n            log(\"[container-ui-skip] key=",
        1, true)
local container_ui_visibility_gate_position =
    string.find(main_source,
        "core.loot_container_widget_state_should_skip_cancel({",
        1, true)
local container_context_log_position =
    string.find(main_source, "log_container_context(key_name, {", 1, true)
local container_ability_count_position =
    string.find(main_source,
        "container_ability_count, container_ability_sample =",
        1, true)
assert_true(
    sleep_context_position ~= nil
        and container_move_cancel_position ~= nil
        and sleep_context_position < container_move_cancel_position,
    "sleep cancellation context is evaluated before container move task scan")
assert_true(
    container_fast_path_position ~= nil
        and sleep_task_count_position ~= nil
        and container_fast_path_position < sleep_task_count_position,
    "container fast path runs before broad sleep task scans")
assert_true(
    seating_fast_path_position ~= nil
        and sleep_task_count_position ~= nil
        and seating_fast_path_position < sleep_task_count_position,
    "seating fast path runs before broad sleep task scans")
assert_true(
    early_player_task_fallback_position ~= nil
        and sleep_task_count_position ~= nil
        and early_player_task_fallback_position < sleep_task_count_position,
    "known non-sleep player task fallback runs before broad sleep task scans")
assert_true(
    container_fast_path_position ~= nil
        and container_task_count_position ~= nil
        and container_fast_path_position < container_task_count_position,
    "container fast path runs before LootWorldContainer diagnostic scans")
assert_true(
    player_task_fallback_position ~= nil
        and container_task_count_position ~= nil
        and player_task_fallback_position < container_task_count_position,
    "player interaction task fallback runs before LootWorldContainer diagnostic scans")
assert_true(
    sleep_interaction_return_position ~= nil
        and player_task_fallback_position ~= nil
        and early_player_task_fallback_position ~= nil
        and early_player_task_fallback_position < sleep_interaction_return_position
        and sleep_interaction_return_position < player_task_fallback_position,
    "early player task fallback is guarded before sleep fallback keeps its return path")
assert_true(
    player_task_fallback_position ~= nil
        and generic_interaction_objects_position ~= nil
        and player_task_fallback_position < generic_interaction_objects_position,
    "player interaction task fallback runs before generic interaction fallback")
assert_true(
    player_task_fallback_helper_position ~= nil
        and player_task_fallback_cleanup_position ~= nil
        and player_task_fallback_helper_position < player_task_fallback_cleanup_position,
    "player interaction task fallback helper cleans up FreePoint before returning")
assert_true(
    player_task_fallback_cleanup_position ~= nil
        and container_task_count_position ~= nil
        and player_task_fallback_cleanup_position < container_task_count_position,
    "player task fallback cleanup runs before LootWorldContainer diagnostic scans")
assert_true(
    container_fast_path_position ~= nil
        and container_widget_count_position ~= nil
        and container_fast_path_position < container_widget_count_position,
    "container fast path runs before loot widget diagnostic scans")
assert_true(
    container_ui_skip_position ~= nil
        and container_ability_close_position ~= nil
        and container_ui_skip_position < container_ability_close_position,
    "visible loot UI skips before OpenContainer ability calls")
assert_true(
    container_ui_visibility_gate_position ~= nil
        and container_ui_skip_position ~= nil
        and container_ui_visibility_gate_position < container_ui_skip_position,
    "loot UI skip is gated by passive visibility state")
assert_true(
    container_free_point_cancel_position ~= nil
        and container_ability_close_position ~= nil
        and container_free_point_cancel_position < container_ability_close_position,
    "early container movement cancel is attempted before OpenContainer ability calls")
assert_true(
    container_root_task_cancel_position ~= nil
        and container_free_point_cancel_position ~= nil
        and container_root_task_cancel_position < container_free_point_cancel_position,
    "root interaction task cancel is attempted before FreePoint end requests")
assert_true(
    container_player_task_cancel_position ~= nil
        and container_free_point_cancel_position ~= nil
        and container_player_task_cancel_position < container_free_point_cancel_position,
    "scanned player interaction tasks run before FreePoint false-positive end requests")
assert_true(
    string.find(main_source,
        "local free_point_cancelled = try_cancel_container_free_point_movement",
        1, true) ~= nil,
    "container FreePoint cancellation is recorded instead of returned immediately")
assert_true(
    string.find(main_source,
        "debug_log(\"[container-freepoint-cancel] non-terminal",
        1, true) ~= nil,
    "container FreePoint success is explicitly treated as non-terminal")
assert_true(
    container_ui_skip_position ~= nil
        and container_ui_return_position ~= nil
        and container_ui_skip_position < container_ui_return_position,
    "visible loot UI skips before any active widget close helper")
assert_true(
    container_context_log_position ~= nil
        and container_ui_skip_position ~= nil
        and container_context_log_position < container_ui_skip_position,
    "container context is logged before visible UI skip")
assert_true(
    container_ability_count_position ~= nil
        and container_context_log_position ~= nil
        and container_ability_count_position < container_context_log_position,
    "container ability count is captured before context logging")
assert_true(
    container_ability_close_position ~= nil
        and container_move_cancel_position ~= nil
        and container_ability_close_position < container_move_cancel_position,
    "OpenContainer close request runs before loot task EndTask")
assert_true(
    loot_ability_close_position ~= nil
        and container_move_cancel_position ~= nil
        and loot_ability_close_position < container_move_cancel_position,
    "Loot ability close request runs before loot task EndTask")
assert_true(
    string.find(main_source, "core.sleep_movement_tracking_from_hook(source)", 1, true)
        ~= nil,
    "sleep movement tracking uses the core hook allowlist")
assert_true(
    string.find(main_source, "/Script/G1R.GameplayAbilitySleep:OnPlayerGoToSleep", 1, true)
        == nil,
    "sleep movement tracking avoids the untyped OnPlayerGoToSleep hook")
assert_true(string.find(main_source, "cancelled_sleep_task_identities", 1, true) ~= nil,
    "main remembers sleep tasks that were already ended")
assert_true(
    string.find(main_source, "core.sleep_task_scan_candidate_allowed({", 1, true)
        ~= nil,
    "main filters stale sleep task scan candidates")
assert_true(
    string.find(main_source, "core.sleep_task_cancel_context_allowed({", 1, true)
        ~= nil,
    "main gates sleep task scans by current sleep context")
assert_true(
    string.find(main_source, "[sleep-context-miss]", 1, true) ~= nil,
    "main logs sleep task evidence when the current context gate misses")
assert_true(
    string.find(main_source, "count_player_sleep_interaction_task_candidates", 1, true)
        ~= nil,
    "main can diagnose sleep task candidates without cancelling them")
local sleep_task_candidate_count_function =
    string.match(main_source,
        "local function count_player_sleep_interaction_task_candidates%(.-%)(.-)local function find_player_container_interaction_tasks")
assert_true(sleep_task_candidate_count_function ~= nil,
    "main has a dedicated sleep task candidate counter")
assert_true(
    string.find(sleep_task_candidate_count_function,
        "cancelled_sleep_task_identities", 1, true) ~= nil,
    "sleep task candidate counter ignores already ended sleep tasks")
assert_true(
    string.find(main_source, "player_sleep_task_candidates = sleep_task_candidate_count",
        1, true) ~= nil,
    "main lets explicit player sleep task candidates recover a missed sleep context")
assert_true(
    string.find(main_source, "core.object_name_is_sleep_ability", 1, true)
        ~= nil,
    "main uses the broader dump-backed sleep ability detector")
assert_true(
    string.find(main_source, "cancelled_sleep_task_identities = {}", 1, true)
        ~= nil,
    "main resets stale sleep task markers on sleep start")
assert_true(
    string.find(main_source, "ability = find_player_sleep_bed_ability()", 1, true)
        ~= nil,
    "sleep movement tracking can resolve the player sleep ability when hook context is unavailable")
assert_true(string.find(main_source, 'tracked_interaction.phase = "sleep-task"', 1, true)
        ~= nil,
    "main marks freshly hooked player sleep tasks")
local ladder_guard_position =
    string.find(main_source, "text_is_ladder_interaction_context", 1, true)
local sleep_scan_position =
    string.find(main_source, "local sleep_tasks = {}", 1, true)
assert_true(ladder_guard_position ~= nil, "main checks ladder interaction context")
assert_true(ladder_guard_position < sleep_scan_position,
    "ladder target guard runs before task scans and cancel attempts")
local ladder_context_function =
    string.match(main_source,
        "local function free_point_ladder_context_text%(.-%)(.-)local function container_ability_target_context_text")
assert_true(ladder_context_function ~= nil,
    "main has a dedicated ladder context reader")
assert_true(string.find(ladder_context_function, '"m_InteractiveActor"', 1, true) ~= nil,
    "ladder context reads the interactive actor")
assert_true(string.find(ladder_context_function, '"ActionFilter"', 1, true) ~= nil,
    "ladder context reads action filters for traversal tags")
assert_true(string.find(ladder_context_function, '"m_InteractionSpot"', 1, true) ~= nil,
    "ladder context reads interaction spot handles")
assert_true(string.find(main_source,
        "tracked_interaction.source", 1, true) ~= nil,
    "main blocks traversal using tracked source")
assert_true(
    string.find(main_source,
        "core.ladder_free_point_context_should_be_read({", 1, true) ~= nil,
    "main gates ladder context reads")
assert_true(
    string.find(main_source,
        "tracked_target = tracked_interaction.target", 1, true) ~= nil,
    "ladder context gate uses tracked interaction target")
assert_true(
    string.find(main_source,
        "if read_ladder_context then", 1, true) ~= nil,
    "main skips ladder context reads for known non-ladder targets")
assert_true(string.find(main_source,
        '"/Script/G1R.AbilityTaskGeneric:EndTaskAsCancelled"', 1, true) ~= nil,
    "main maps EndTaskAsCancelled to AbilityTaskGeneric")
assert_true(string.find(main_source,
        '"/Script/G1R.AbilityTaskGeneric:BP_ExternalCancel"', 1, true) ~= nil,
    "main maps BP_ExternalCancel to AbilityTaskGeneric")
assert_true(string.find(main_source, "RequestEndAnyOngoingInteraction", 1, true) == nil,
    "main avoids unavailable character RequestEndAnyOngoingInteraction method")
assert_true(string.find(main_source, "CancelAllCurrentActionsAndMovement", 1, true) == nil,
    "main avoids unavailable character CancelAllCurrentActionsAndMovement method")

local diagnostics_source =
    assert(io.open("Scripts/runtime_diagnostics.lua", "r")):read("*a")
assert_true(string.find(diagnostics_source, '"OnRequestEndQuick"', 1, true) ~= nil,
    "runtime diagnostics scans InteractFreePoint quick end")
assert_true(string.find(diagnostics_source, '"CancelCrafting"', 1, true) ~= nil,
    "runtime diagnostics scans crafting cancel UI method")
assert_true(string.find(diagnostics_source, '"OnLocalCloseRequested"', 1, true) == nil,
    "runtime diagnostics avoids OpenContainer local close")
assert_true(string.find(diagnostics_source, '"OnCloseRequested"', 1, true) == nil,
    "runtime diagnostics avoids OpenContainer close")
assert_true(string.find(diagnostics_source, "GameplayAbilityOpenContainer", 1, true) == nil,
    "runtime diagnostics avoids OpenContainer scans")
assert_true(string.find(diagnostics_source, '"EndTaskAsCancelled"', 1, true) ~= nil,
    "runtime diagnostics scans generic task cancellation")
assert_true(string.find(diagnostics_source, "RequestEndAnyOngoingInteraction", 1, true) == nil,
    "runtime diagnostics avoids unavailable RequestEndAnyOngoingInteraction term")
assert_true(string.find(diagnostics_source, "CancelAllCurrentActionsAndMovement", 1, true) == nil,
    "runtime diagnostics avoids unavailable CancelAllCurrentActionsAndMovement term")

local interaction_task_cancel_methods = core.interaction_task_cancel_method_names()
assert_equal(interaction_task_cancel_methods[1], "EndTask",
    "first task cancel method")
assert_equal(interaction_task_cancel_methods[2], "EndTaskAsCancelled",
    "second task cancel method")

local sleep_ability_cancel_methods = core.interaction_sleep_ability_cancel_method_names()
assert_equal(sleep_ability_cancel_methods[1], "K2_CancelAbility",
    "first sleep ability cleanup method")
assert_equal(sleep_ability_cancel_methods[2], "K2_EndAbility",
    "second sleep ability cleanup method")

local sleep_montage_cancel_methods = core.sleep_montage_cancel_method_names()
assert_equal(sleep_montage_cancel_methods[1], "StopAnimMontage",
    "first sleep montage cancel method")
assert_equal(sleep_montage_cancel_methods[2], "Montage_Stop",
    "second sleep montage cancel method")

local sleep_root_task_cancel_methods = core.sleep_root_task_cancel_method_names()
assert_equal(sleep_root_task_cancel_methods[1], "EndTask",
    "first sleep root task cancel method")
assert_equal(sleep_root_task_cancel_methods[2], "EndTaskAsCancelled",
    "second sleep root task cancel method")

local sleep_interaction_task_cancel_methods =
    core.sleep_interaction_task_cancel_method_names()
assert_equal(sleep_interaction_task_cancel_methods[1], "EndTask",
    "first sleep interaction task cancel method")
assert_equal(#sleep_interaction_task_cancel_methods, 1,
    "sleep interaction task cancel uses the stable task end only")

assert_true(core.sleep_movement_tracking_from_hook(
        "/Script/G1R.GameplayAbilitySleep:OnActivateAbility_Scriptable"),
    "sleep movement tracks the typed sleep ability activation hook")
assert_false(core.sleep_movement_tracking_from_hook(
        "/Script/G1R.GameplayAbilitySleep:OnSleepUICloseButtonClicked"),
    "sleep movement does not track sleep UI close")
assert_false(core.sleep_movement_tracking_from_hook(
        "/Script/G1R.GameplayAbilitySleep:OnPlayerGoToSleep"),
    "sleep movement avoids the untyped OnPlayerGoToSleep hook")
assert_false(core.sleep_movement_should_try_ability_cancel({
        root_task_success = true,
    }),
    "sleep movement skips ability cancel after root task success")
assert_true(core.sleep_movement_should_try_ability_cancel({
        root_task_success = false,
    }),
    "sleep movement uses ability cancel when root task did not end")
assert_false(core.sleep_task_cancel_should_try_montage({
        task_success = true,
    }),
    "sleep task cancel skips montage fallback after task success")
assert_true(core.sleep_task_cancel_should_try_montage({
        task_success = false,
    }),
    "sleep task cancel uses montage fallback when task did not end")
assert_false(core.sleep_task_scan_candidate_allowed({
        task_cancelled_before = true,
        tracked_task = false,
    }),
    "stale sleep task scan candidate is skipped")
assert_true(core.sleep_task_scan_candidate_allowed({
        task_cancelled_before = true,
        tracked_task = true,
    }),
    "freshly tracked sleep task is allowed even if its object name was seen before")
assert_true(core.sleep_task_scan_candidate_allowed({
        task_cancelled_before = false,
        tracked_task = false,
    }),
    "new sleep task scan candidate is allowed")
assert_true(core.sleep_task_cancel_context_allowed({
        tracked_phase = "sleep-task",
    }),
    "sleep task phase allows sleep task cancel")
assert_true(core.sleep_task_cancel_context_allowed({
        tracked_phase = "animation",
        tracked_object = player_sleep_task_name,
    }),
    "tracked player sleep task allows sleep task cancel")
assert_true(core.sleep_task_cancel_context_allowed({
        tracked_object = player_gameplay_sleep_ability_name,
    }),
    "tracked GameplayAbilitySleep allows sleep task cancel")
assert_true(core.sleep_task_cancel_context_allowed({
        free_point_context = "m_InteractiveActor=Interactive_Sleep_Bed_Low_C_UAID_123",
    }),
    "free point sleep bed context allows sleep task cancel")
assert_true(core.sleep_task_cancel_context_allowed({
        player_sleep_task_candidates = 1,
    }),
    "visible player sleep task candidate allows sleep task cancel")
assert_false(core.sleep_task_cancel_context_allowed({
        player_sleep_task_candidates = 0,
    }),
    "zero player sleep task candidates do not create sleep context")
assert_false(core.sleep_task_cancel_context_allowed({
        tracked_phase = "animation",
        tracked_target = "AS_male_sit_bench_start",
        free_point_context = "m_InteractiveActor=Interactive_Chair_WoodBench",
    }),
    "bench context does not allow sleep task cancel")

local container_interaction_task_cancel_methods =
    core.container_interaction_task_cancel_method_names()
assert_equal(#container_interaction_task_cancel_methods, 0,
    "container interaction task cancel is disabled")

local container_ability_cancel_methods =
    core.interaction_container_ability_cancel_method_names()
assert_equal(#container_ability_cancel_methods, 0,
    "container ability cancel is disabled")

local interaction_input_ability_class_paths = core.interaction_input_ability_class_paths()
assert_equal(#interaction_input_ability_class_paths, 0,
    "interaction input ability activation disabled")

local move_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotIgnoreOwner")
assert_true(move_tracking.track, "interact-with hook tracked")
assert_equal(move_tracking.kind, "use-object", "interact-with hook kind")
assert_equal(move_tracking.phase, "move", "interact-with hook phase")

local dump_backed_actor_move_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActor")
assert_true(dump_backed_actor_move_tracking.track,
    "dump-backed interact-with actor hook tracked")
assert_equal(dump_backed_actor_move_tracking.kind, "use-object",
    "dump-backed interact-with actor hook kind")
assert_equal(dump_backed_actor_move_tracking.phase, "move",
    "dump-backed interact-with actor hook phase")

local dump_backed_goto_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_GotoInteractionSpot:TaskGotoInteractionSpot")
assert_true(dump_backed_goto_tracking.track,
    "dump-backed goto interaction spot hook tracked")
assert_equal(dump_backed_goto_tracking.kind, "use-object",
    "dump-backed goto interaction spot hook kind")
assert_equal(dump_backed_goto_tracking.phase, "move",
    "dump-backed goto interaction spot hook phase")

local montage_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions")
assert_true(montage_tracking.track, "montage hook tracked")
assert_equal(montage_tracking.kind, "ambient", "montage hook kind")
assert_equal(montage_tracking.phase, "animation", "montage hook phase")

local player_sleep_task_tracking = core.interaction_tracking_from_hook(
    "/Script/Angelscript.AbilityTask_Interaction_Player_SitAndSleep:SetupTransitions")
assert_false(player_sleep_task_tracking.track,
    "player sleep task hook is disabled because it can crash on bed interaction")
assert_equal(player_sleep_task_tracking.kind, "none", "player sleep task hook kind")
assert_equal(player_sleep_task_tracking.phase, "idle", "player sleep task hook phase")

local crafting_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.GameplayAbilityCrafting:EventPlayAction")
assert_false(crafting_tracking.track, "crafting hook not tracked as generic interaction")

local interact_free_point_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility")
assert_true(interact_free_point_tracking.track, "interact free point activation tracked")
assert_equal(interact_free_point_tracking.kind, "ambient", "interact free point kind")
assert_equal(interact_free_point_tracking.phase, "ability", "interact free point phase")

local open_container_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.GameplayAbilityOpenContainer:ActivateAbility")
assert_false(open_container_tracking.track, "open container activation not tracked")
assert_equal(open_container_tracking.kind, "none", "open container hook kind")
assert_equal(open_container_tracking.phase, "idle", "open container hook phase")

local bench_montage_tracking = core.interaction_tracking_from_montage_name(
    "AnimMontage /Game/Characters/Human/Animations/AM_Human_Sit_Bench_Enter")
assert_true(bench_montage_tracking.track, "bench sit montage tracked")
assert_equal(bench_montage_tracking.kind, "ambient", "bench sit montage kind")
assert_equal(bench_montage_tracking.phase, "animation", "bench sit montage phase")

local chair_montage_tracking = core.interaction_tracking_from_montage_name(
    "AM_Player_Chair_Sit_Down")
assert_true(chair_montage_tracking.track, "chair sit montage tracked")
assert_equal(chair_montage_tracking.kind, "ambient", "chair sit montage kind")

local sleep_bed_montage_tracking = core.interaction_tracking_from_montage_name(
    "AM_Human_Sleep_Bed_Low_Enter")
assert_true(sleep_bed_montage_tracking.track, "sleep bed montage tracked")
assert_equal(sleep_bed_montage_tracking.kind, "ambient", "sleep bed montage kind")

local unrelated_montage_tracking = core.interaction_tracking_from_montage_name(
    "AM_Human_DrawWeapon")
assert_false(unrelated_montage_tracking.track, "unrelated montage not tracked")

local candidates = core.discovery_hook_candidates()
local expected_candidates = {
    "/Script/G1R.GothicCharacter:GetInventory",
    "/Script/G1R.GothicCharacter:GetCarryComponent",
    "/Script/G1R.InventoryComponent:EquipItem",
    "/Script/G1R.InventoryComponent:UnEquipItem",
    "/Script/G1R.InventoryComponent:TakeOutTorch",
    "/Script/G1R.GameplayAbilityCrafting:EventPlayAction",
    "/Script/G1R.GameplayAbilityCrafting:EventAnimIdleEnd",
    "/Script/G1R.GameplayAbilityCrafting:EventAnimStartHud",
    "/Script/G1R.GameplayAbilityCrafting:OnCraftFinished",
    "/Script/G1R.GameplayAbilityCrafting:ButtonCraftingMenuExit_Bind",
    "/Script/G1R.GameplayAbilityCrafting:Multicast_StartCrafting",
    "/Script/G1R.GameplayAbilityCrafting:Multicast_SetCraftingState",
    "/Script/G1R.GameplayAbilityCrafting:Server_StartCrafting",
    "/Script/G1R.GameplayAbilityCrafting:Server_SetCraftingState",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithNavLink",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotIgnoreOwner",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotRandomAction",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpot",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActorRandomAction",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActor",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractHereWithoutSpot",
    "/Script/G1R.AbilityTask_InteractWith:TaskFindAndInteractWithSpotRandomAction",
    "/Script/G1R.AbilityTask_InteractWith:TaskFindAndInteractWithSpot",
    "/Script/G1R.AbilityTask_GotoInteractionSpot:TaskGotoInteractionSpot",
    "/Script/G1R.AbilityTask_GotoInteractionSpot:TaskFindAndGotoSpot",
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions",
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions_Implementation",
    "/Script/Angelscript.UAbilityTask_Interaction_Human_Cook_Pan:SetupTransitions",
    "/Script/Angelscript.UAbilityTask_Interaction_Human_Cook_Pan:SetupTransitions_Implementation",
    "/Script/Angelscript.UAbilityTask_Interaction_Player_Cook_Cauldron:SetupTransitions",
    "/Script/Angelscript.UAbilityTask_Interaction_Player_Cook_Cauldron:SetupTransitions_Implementation",
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility",
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_OnEndAbility",
    "/Script/G1R.GameplayAbilityInteract:K2_ActivateAbility",
    "/Script/G1R.GameplayAbilityInteract:K2_OnEndAbility",
    "/Script/G1R.GameplayAbilityInteractionBase:K2_ActivateAbility",
    "/Script/G1R.GameplayAbilityInteractionBase:K2_OnEndAbility",
    "/Script/G1R.AbilityTask_EndEquip:DoEndEquip",
    "/Script/G1R.AbilityTask_DrawWeapon:TaskDrawTorch",
    "/Script/Engine.PlayerController:ClientRestart",
    "/Script/Engine.PlayerController:InputKey",
    "/Script/Engine.PlayerInput:InputKey",
    "/Script/EnhancedInput.EnhancedPlayerInput:InputKey",
    "/Script/EnhancedInput.EnhancedPlayerInput:InjectInputForAction",
    "/Script/G1R.GameplayAbilitySleep:OnSleepUICloseButtonClicked",
    "/Script/G1R.GameplayAbilitySleep:Server_OnSleepUICloseButtonClicked",
    "/Script/G1R.GameplayAbilitySleep:OnActivateAbility_Scriptable",
    "/Script/G1R.GameplayAbilitySleep:OnGoToSleepAnimationFinished",
    "/Script/G1R.GameplayAbilitySleep:Client_StopAllMagicAbilitiesMontages",
    "/Script/Engine.Character:PlayAnimMontage",
    "/Script/Engine.AnimInstance:Montage_Play",
    "/Script/Engine.AnimInstance:Montage_Stop",
}
assert_equal(#candidates, #expected_candidates, "candidate count")
for index, expected in ipairs(expected_candidates) do
    assert_equal(candidates[index], expected, "candidate " .. tostring(index))
end

local saw_end_equip = false
local saw_interact_with = false
local saw_cook_pan = false
local saw_crafting = false
local saw_client_restart = false
local saw_player_input_key = false
local saw_interact_free_point = false
local saw_sleep_close = false
local saw_sleep_start = false
for _, candidate in ipairs(core.discovery_hook_candidates()) do
    if candidate == "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithNavLink" then
        saw_interact_with = true
    elseif candidate == "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActor" then
        saw_interact_with = true
    elseif candidate == "/Script/G1R.AbilityTask_GotoInteractionSpot:TaskGotoInteractionSpot" then
        saw_interact_with = true
    elseif candidate == "/Script/G1R.GameplayAbilityCrafting:EventPlayAction" then
        saw_crafting = true
    elseif candidate == "/Script/Angelscript.UAbilityTask_Interaction_Human_Cook_Pan:SetupTransitions" then
        saw_cook_pan = true
    elseif candidate == "/Script/G1R.AbilityTask_EndEquip:DoEndEquip" then
        saw_end_equip = true
    elseif candidate == "/Script/Engine.PlayerController:ClientRestart" then
        saw_client_restart = true
    elseif candidate == "/Script/Engine.PlayerController:InputKey" then
        saw_player_input_key = true
    elseif candidate == "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility" then
        saw_interact_free_point = true
    elseif candidate == "/Script/G1R.GameplayAbilitySleep:OnSleepUICloseButtonClicked" then
        saw_sleep_close = true
    elseif candidate == "/Script/G1R.GameplayAbilitySleep:OnActivateAbility_Scriptable" then
        saw_sleep_start = true
    elseif candidate == "/Script/Angelscript.AbilityTask_Interaction_Player_SitAndSleep:SetupTransitions" then
        error("crash-prone player sleep task hook must stay disabled")
    end
end
assert_true(saw_interact_with, "candidate includes AbilityTask_InteractWith")
assert_true(saw_crafting, "candidate includes GameplayAbilityCrafting")
assert_true(saw_cook_pan, "candidate includes cook pan task")
assert_true(saw_end_equip, "candidate includes AbilityTask_EndEquip")
assert_true(saw_client_restart, "candidate includes ClientRestart")
assert_true(saw_player_input_key, "candidate includes PlayerController InputKey")
assert_true(saw_interact_free_point, "candidate includes InteractFreePoint activation")
assert_true(saw_sleep_close, "candidate includes GameplayAbilitySleep close")
assert_true(saw_sleep_start, "candidate includes GameplayAbilitySleep activation")

local instance_scan_classes = core.runtime_instance_scan_classes()
assert_equal(instance_scan_classes[1], "AbilityTask_Interaction_Human_Cook_Pan",
    "first runtime instance scan class")

local saw_pan_scan_class = false
local saw_cauldron_scan_class = false
local saw_base_task_scan_class = false
local saw_player_sleep_task_scan_class = false
local saw_crafting_scan_class = false
local saw_sleep_ability_scan_class = false
local saw_interact_free_point_scan_class = false
local saw_interaction_base_scan_class = false
for _, class_name in ipairs(instance_scan_classes) do
    if class_name == "AbilityTask_Interaction_Human_Cook_Pan" then
        saw_pan_scan_class = true
    elseif class_name == "AbilityTask_Interaction_Player_Cook_Cauldron" then
        saw_cauldron_scan_class = true
    elseif class_name == "AbilityTask_Interaction_Player_SitAndSleep" then
        saw_player_sleep_task_scan_class = true
    elseif class_name == "AbilityTask_InteractionSpot_Montage" then
        saw_base_task_scan_class = true
    elseif class_name == "GameplayAbilityCrafting" then
        saw_crafting_scan_class = true
    elseif class_name == "GameplayAbilitySleep" then
        saw_sleep_ability_scan_class = true
    elseif class_name == "GameplayAbilityInteractFreePoint" then
        saw_interact_free_point_scan_class = true
    elseif class_name == "GameplayAbilityInteractionBase" then
        saw_interaction_base_scan_class = true
    end
end
assert_true(saw_pan_scan_class, "runtime instance scan includes cook pan")
assert_true(saw_cauldron_scan_class, "runtime instance scan includes player cook cauldron")
assert_true(saw_base_task_scan_class, "runtime instance scan includes base montage task")
assert_true(saw_player_sleep_task_scan_class,
    "runtime instance scan includes player sleep task")
assert_true(saw_crafting_scan_class, "runtime instance scan includes crafting ability")
assert_true(saw_sleep_ability_scan_class,
    "runtime instance scan includes sleep ability")
assert_true(saw_interact_free_point_scan_class,
    "runtime instance scan includes InteractFreePoint ability")
assert_true(saw_interaction_base_scan_class,
    "runtime instance scan includes interaction base ability")
for _, class_name in ipairs(instance_scan_classes) do
    assert_false(class_name == "AbilityTask_Interaction_Player_OpenContainer"
            or class_name == "UAbilityTask_Interaction_Player_OpenContainer",
        "runtime instance scan excludes unobserved player container task")
    assert_false(class_name == "GA_Human_OpenContainer"
            or class_name == "GA_Human_OpenContainer_Swimming",
        "runtime instance scan excludes open container ability")
end

local instance_scan_match_terms = core.runtime_instance_scan_match_terms()
assert_equal(instance_scan_match_terms[1], "interact", "first runtime instance scan match term")

local saw_pan_scan_term = false
local saw_cauldron_scan_term = false
local saw_craft_scan_term = false
local saw_interact_scan_term = false
local saw_sleep_scan_term = false
local saw_bed_scan_term = false
for _, term in ipairs(instance_scan_match_terms) do
    if term == "pan" then
        saw_pan_scan_term = true
    elseif term == "cauldron" then
        saw_cauldron_scan_term = true
    elseif term == "craft" then
        saw_craft_scan_term = true
    elseif term == "interact" then
        saw_interact_scan_term = true
    elseif term == "sleep" then
        saw_sleep_scan_term = true
    elseif term == "bed" then
        saw_bed_scan_term = true
    end
end
assert_true(saw_pan_scan_term, "runtime instance scan match terms include pan")
assert_true(saw_cauldron_scan_term, "runtime instance scan match terms include cauldron")
assert_true(saw_craft_scan_term, "runtime instance scan match terms include craft")
assert_true(saw_interact_scan_term, "runtime instance scan match terms include interact")
assert_true(saw_sleep_scan_term, "runtime instance scan match terms include sleep")
assert_true(saw_bed_scan_term, "runtime instance scan match terms include bed")
for _, term in ipairs(instance_scan_match_terms) do
    assert_false(term == "container" or term == "chest",
        "runtime instance scan match terms exclude container/chest")
end

local keys = core.parse_cancel_keys(" f , escape , t ")
assert_equal(keys[1], "F", "normalized key 1")
assert_equal(keys[2], "ESCAPE", "normalized key 2")
assert_equal(keys[3], "T", "normalized key 3")

local empty_keys = core.parse_cancel_keys("")
assert_equal(empty_keys[1], "F", "empty keys default 1")
assert_equal(empty_keys[2], "ESCAPE", "empty keys default 2")

print("g1r_cancel_interaction_core.test.lua: PASS")
