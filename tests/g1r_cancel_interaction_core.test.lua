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

local parsed = core.parse_ini([[
Debug=true
DiscoveryMode=false
CancelKeys=F, ESCAPE
CooldownMs=300
AllowMontageFallback=true
RuntimeFunctionScan=true
RuntimeFunctionScanLimit=12
]])

local config = core.config_from_ini(parsed)
assert_true(config.debug, "debug")
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
local container_move_task_properties = core.container_move_task_property_names()
assert_equal(container_move_task_properties[1], "m_TaskMoveTo",
    "container move task uses dump property name")
assert_equal(container_move_task_properties[2], "TaskMoveTo",
    "container move task accepts generated alias")
local container_move_task_methods = core.container_move_task_cancel_method_names()
assert_equal(container_move_task_methods[1], "EndTaskAsCancelled",
    "container move task prefers cancelled result")
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
assert_equal(movement_action_cancel_methods[#movement_action_cancel_methods],
    "OnRequestEndNormal", "last movement action cancel method")

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
    string.find(main_source, "core.interaction_container_context_should_block({", 1, true)
        ~= nil,
    "main blocks container context before generic interaction cancel")
assert_true(
    string.find(main_source, "count_player_container_interaction_task_candidates",
        1, true) ~= nil,
    "main can observe LootWorldContainer task candidates before enabling container cancel")
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
    string.find(main_source, "container_move_task_property_names", 1, true) ~= nil,
    "main uses dump-backed OpenContainer movement task properties")
assert_true(
    string.find(main_source, 'log("[container-context] key=', 1, true) ~= nil,
    "main logs non-debug container context evidence")
assert_true(
    string.find(main_source, "widgets=", 1, true) ~= nil,
    "container context evidence includes chest widget count")
local free_point_container_context_function =
    string.match(main_source,
        "local function free_point_container_context_text%(.-%)(.-)local function free_point_ladder_context_text")
assert_true(free_point_container_context_function ~= nil,
    "main has a dedicated container free point context reader")
assert_true(
    string.find(free_point_container_context_function, '"m_InteractiveActor"', 1, true)
        ~= nil,
    "container free point context reads the interactive actor")
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
local container_move_cancel_position =
    string.find(main_source,
        "if try_cancel_container_move_task(key_name, container_ability) then",
        1, true)
assert_true(
    sleep_context_position ~= nil
        and container_move_cancel_position ~= nil
        and sleep_context_position < container_move_cancel_position,
    "sleep cancellation context is evaluated before container move task scan")
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
