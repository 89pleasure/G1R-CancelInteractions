package.path = "Scripts/?.lua;" .. package.path

local core = require("cancel_core")
local mod_runtime = require("mod_runtime")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s expected=%s actual=%s",
            label, tostring(expected), tostring(actual)))
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

local function assert_nil(value, label)
    if value ~= nil then
        error(label .. " expected nil, got " .. tostring(value))
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

local function read_file(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local function assert_not_contains(text, needle, label)
    if string.find(text, needle, 1, true) ~= nil then
        error(label .. " contains forbidden text: " .. needle)
    end
end

local parsed = core.parse_ini([[
Debug=true
DiscoveryMode=false
CancelKeys=ESCAPE, A
ControllerCancelEnabled=false
ControllerCancelKey=CustomControllerBack
CooldownMs=300
]])

local config = core.config_from_ini(parsed)
assert_true(config.debug, "debug")
assert_nil(config.timing, "timing config removed")
assert_false(config.discovery_mode, "discovery")
assert_equal(config.cancel_keys[1], "ESCAPE", "first cancel key")
assert_equal(config.cancel_keys[2], "A", "second cancel key")
assert_false(config.controller_cancel_enabled, "controller cancel override")
assert_equal(config.controller_cancel_key, "CUSTOMCONTROLLERBACK",
    "controller cancel key override")
assert_nil(config.controller_cancel_poll_enabled,
    "controller cancel poll config removed")
assert_nil(config.controller_cancel_poll_keys,
    "controller cancel poll keys removed")
assert_equal(config.cooldown_ms, 300, "cooldown")

local defaults = core.config_from_ini({})
assert_false(defaults.debug, "default debug")
assert_nil(defaults.timing, "default timing config removed")
assert_false(defaults.discovery_mode, "default discovery")
assert_equal(defaults.cancel_keys[1], "ESCAPE", "default first cancel key")
assert_equal(defaults.cancel_keys[2], "A", "default second cancel key")
assert_equal(defaults.cancel_keys[3], "W", "default third cancel key")
assert_equal(defaults.cancel_keys[4], "S", "default fourth cancel key")
assert_equal(defaults.cancel_keys[5], "D", "default fifth cancel key")
assert_equal(defaults.cancel_keys[6], "RIGHT_MOUSE_BUTTON",
    "default sixth cancel key")
assert_true(defaults.controller_cancel_enabled,
    "default controller cancel enabled")
assert_equal(defaults.controller_cancel_key, "CONTROLLER_BACK",
    "default controller cancel semantic key")
assert_nil(defaults.controller_cancel_poll_enabled,
    "default controller poll config removed")
assert_nil(defaults.controller_cancel_poll_keys,
    "default controller poll keys removed")
assert_equal(defaults.cooldown_ms, 250, "default cooldown")
assert_nil(defaults.pray_of_fire_fix_enabled,
    "pray of fire config removed from cancel mod")
assert_nil(defaults.runtime_function_scan,
    "runtime object scanning removed from cancel mod")

local unprintable = setmetatable({}, {
    __tostring = function()
        error("cannot stringify")
    end,
})
assert_equal(core.safe_to_string("ok"), "ok",
    "safe string preserves plain strings")
assert_equal(core.safe_to_string(unprintable), "<unprintable table>",
    "safe string handles tostring errors")

local closed_menu = core.classify_menu_open_state({
    show_mouse_cursor = false,
    paused = false,
})
assert_false(closed_menu.open, "closed menu state is not open")
assert_equal(closed_menu.reason, "closed", "closed menu state reason")

local cursor_menu = core.classify_menu_open_state({
    show_mouse_cursor = true,
    paused = false,
})
assert_true(cursor_menu.open, "cursor menu state is open")
assert_equal(cursor_menu.reason, "mouse cursor", "cursor menu state reason")

local paused_menu = core.classify_menu_open_state({
    show_mouse_cursor = false,
    paused = true,
})
assert_true(paused_menu.open, "paused menu state is open")
assert_equal(paused_menu.reason, "paused", "paused menu state reason")

local combined_menu = core.classify_menu_open_state({
    show_mouse_cursor = true,
    paused = true,
})
assert_true(combined_menu.open, "combined menu state is open")
assert_equal(combined_menu.reason, "mouse cursor+paused",
    "combined menu state reason")

local runtime_helper = mod_runtime.new({ core = core })
local nested_move_task = {
    get = function()
        return "raw-pointer-value"
    end,
    type = function()
        return "UObject"
    end,
    IsValid = function()
        return true
    end,
    GetFullName = function()
        return "AbilityTask_DirectMove /Engine/Transient.MoveTask_1"
    end,
    GetClass = function()
        return {
            type = function()
                return "UObject"
            end,
            IsValid = function()
                return true
            end,
            GetFullName = function()
                return "Class /Script/G1R.AbilityTask_DirectMove"
            end,
        }
    end,
}
local move_into_position_task = {
    MoveTask = nested_move_task,
    type = function()
        return "UObject"
    end,
    IsValid = function()
        return true
    end,
    GetFullName = function()
        return "AbilityTask_MoveIntoPositionForInteraction /Engine/Transient.Task_1"
    end,
}
assert_equal(runtime_helper:get_param_value(nested_move_task), nested_move_task,
    "runtime keeps UE4SS UObject userdata instead of unwrapping it via get")
local move_task_ok, move_task_value =
    runtime_helper:get_object_property(move_into_position_task, "MoveTask")
assert_true(move_task_ok, "runtime reads nested UObject property")
assert_equal(move_task_value, nested_move_task,
    "runtime preserves nested UObject property values")
assert_equal(runtime_helper:param_to_log_string(nested_move_task),
    "AbilityTask_DirectMove /Engine/Transient.MoveTask_1",
    "runtime logs nested UObject full name")
assert_equal(runtime_helper:ue4ss_value_diagnostics(false),
    "luaType=boolean",
    "runtime diagnostics do not call UObject methods on primitive values")
local nested_move_task_diagnostics =
    runtime_helper:ue4ss_value_diagnostics(nested_move_task)
assert_true(string.find(nested_move_task_diagnostics,
        "ue4ssType=UObject", 1, true) ~= nil,
    "runtime diagnostic includes UE4SS type")
assert_true(string.find(nested_move_task_diagnostics,
        "GetFullName=AbilityTask_DirectMove /Engine/Transient.MoveTask_1",
        1, true) ~= nil,
    "runtime diagnostic includes full name call result")
local tostring_wrapper = {
    type = function()
        return "FWeakObjectPtr"
    end,
    ToString = function()
        return "/Script/G1R.GothicAbilitySystemComponent'/Game/Maps/MainMap.MainMap:PersistentLevel.G1RPlayerState_1.AbilitySystemComponent'"
    end,
}
local tostring_wrapper_diagnostics =
    runtime_helper:ue4ss_value_diagnostics(tostring_wrapper)
assert_true(string.find(tostring_wrapper_diagnostics,
        "ToString=/Script/G1R.GothicAbilitySystemComponent'", 1, true) ~= nil,
    "runtime diagnostic includes ToString for non-UObject wrappers")
local property_value_task = {
    type = function()
        return "UObject"
    end,
    IsValid = function()
        return true
    end,
    GetPropertyValue = function(_, property_name)
        if property_name == "MoveTask" then
            return nested_move_task
        end
        return nil
    end,
}
local property_value_ok, property_value =
    runtime_helper:get_object_property_value_method(
        property_value_task, "MoveTask")
assert_true(property_value_ok,
    "runtime can read UObject property via GetPropertyValue")
assert_equal(property_value, nested_move_task,
    "runtime preserves GetPropertyValue UObject result")

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

assert_true(core.is_movement_cancel_key("A"), "A is movement cancel key")
assert_true(core.is_movement_cancel_key("w"), "W is movement cancel key")
assert_false(core.is_movement_cancel_key("F"),
    "F starts interactions and is not a movement-phase cancel key")
assert_true(core.is_movement_cancel_key("ESCAPE"),
    "ESCAPE is movement-phase cancel key")
assert_true(core.is_movement_cancel_key("RightMouseButton"),
    "right mouse button is movement-phase cancel key")
assert_true(core.is_movement_cancel_key("RIGHT_MOUSE_BUTTON"),
    "canonical right mouse button key is movement-phase cancel key")
assert_false(core.is_movement_cancel_key("T"),
    "unconfigured key is not a movement cancel key")

local right_mouse_button_lookup_candidates =
    core.cancel_key_lookup_candidates("RightMouseButton")
assert_equal(right_mouse_button_lookup_candidates[1], "RIGHTMOUSEBUTTON",
    "right mouse button lookup keeps requested compact alias first")
assert_equal(right_mouse_button_lookup_candidates[2], "RIGHT_MOUSE_BUTTON",
    "right mouse button lookup falls back to UE4SS canonical key")
local controller_back_lookup_candidates =
    core.cancel_key_lookup_candidates("controller_back")
assert_equal(controller_back_lookup_candidates[1], "CONTROLLER_BACK",
    "controller back lookup keeps semantic key first")
assert_true(contains_value(controller_back_lookup_candidates,
        "GAMEPAD_FACE_BUTTON_RIGHT"),
    "controller back lookup includes Unreal right face button")
assert_true(contains_value(controller_back_lookup_candidates,
        "GAMEPAD_FACEBUTTON_RIGHT"),
    "controller back lookup includes compact right face button fallback")

assert_false(core.cancel_hotkey_should_enter_game_thread({
        key_name = "W",
        interaction_active = false,
        movement_cancel_armed = false,
    }),
    "movement key without tracked interaction does not enter game thread")
assert_false(core.cancel_hotkey_should_enter_game_thread({
        key_name = "W",
        interaction_active = false,
        movement_cancel_armed = true,
    }),
    "removed movement fallback arming does not enter game thread")
assert_true(core.cancel_hotkey_should_enter_game_thread({
        key_name = "A",
        interaction_active = true,
        movement_cancel_armed = false,
    }),
    "tracked interaction movement key enters game thread")
assert_false(core.cancel_hotkey_should_enter_game_thread({
        key_name = "F",
        interaction_active = false,
        movement_cancel_armed = false,
    }),
    "F does not enter game thread as cancel key")

local function base_movement_state(overrides)
    local state = {
        key_name = "W",
        player_ready = true,
        interaction_active = true,
        interaction_kind = "use-object",
        interaction_phase = "move",
        interaction_cancel_lockout = false,
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
    }
    for key, value in pairs(overrides or {}) do
        state[key] = value
    end
    return state
end

local movement_interaction_allowed =
    core.classify_movement_interaction_cancel(base_movement_state())
assert_true(movement_interaction_allowed.allowed,
    "movement key active interaction cancel allowed")
assert_equal(movement_interaction_allowed.reason, "movement interaction active",
    "movement interaction allowed reason")

local tracked_move_task_without_requested_action_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_active = true,
        interaction_phase = "move",
        movement_action = 7,
        requested_movement_action = 0,
    }))
assert_false(tracked_move_task_without_requested_action_blocked.allowed,
    "tracked move task without requested movement action is blocked")
assert_equal(tracked_move_task_without_requested_action_blocked.reason,
    "movement action inactive",
    "tracked move task without requested movement action reason")

local requested_only_interaction_allowed =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_active = false,
        interaction_kind = "none",
        movement_action = 0,
        requested_movement_action = 7,
    }))
assert_false(requested_only_interaction_allowed.allowed,
    "requested-only movement action without tracked task is blocked")
assert_equal(requested_only_interaction_allowed.reason,
    "no tracked interaction",
    "requested-only movement action blocked reason")

local movement_action_eight_allowed =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_active = false,
        interaction_kind = "none",
        movement_action = 8,
        requested_movement_action = 0,
    }))
assert_false(movement_action_eight_allowed.allowed,
    "movement action 8 without tracked task is blocked")
assert_equal(movement_action_eight_allowed.reason, "movement action inactive",
    "movement action 8 without requested movement action blocked reason")

local movement_action_cast_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_active = false,
        interaction_kind = "none",
        movement_action = 12,
        requested_movement_action = 0,
    }))
assert_false(movement_action_cast_blocked.allowed,
    "movement action 12 casting spell does not cancel as interaction")
assert_equal(movement_action_cast_blocked.reason, "movement action inactive",
    "movement action 12 blocked reason")

local action_key_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        key_name = "F",
    }))
assert_false(action_key_blocked.allowed,
    "F is not a movement interaction cancel key")
assert_equal(action_key_blocked.reason, "not movement key",
    "F blocked reason")

local fresh_escape_allowed =
    core.classify_movement_interaction_cancel(base_movement_state({
        key_name = "ESCAPE",
    }))
assert_true(fresh_escape_allowed.allowed,
    "escape can cancel a freshly tracked movement interaction")

local menu_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        menu_open = true,
    }))
assert_false(menu_blocked.allowed, "menu blocks movement cancel")
assert_equal(menu_blocked.reason, "menu open", "menu blocked reason")

local movement_cursor_menu_allowed =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_phase = "move",
        menu_open = true,
        menu_open_reason = "mouse cursor",
        menu_mouse_cursor = true,
        menu_paused = false,
    }))
assert_true(movement_cursor_menu_allowed.allowed,
    "cursor-only menu state does not block movement cancel")
assert_equal(movement_cursor_menu_allowed.reason,
    "movement interaction active",
    "cursor-only menu movement cancel reason")

local movement_paused_menu_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_phase = "move",
        menu_open = true,
        menu_open_reason = "paused",
        menu_mouse_cursor = false,
        menu_paused = true,
    }))
assert_false(movement_paused_menu_blocked.allowed,
    "paused menu state still blocks movement cancel")
assert_equal(movement_paused_menu_blocked.reason, "menu open",
    "paused menu blocked reason")

local lockout_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        interaction_cancel_lockout = true,
    }))
assert_true(lockout_blocked.allowed,
    "recent cancel lockout no longer blocks movement cancel")

local non_key_blocked =
    core.classify_movement_interaction_cancel(base_movement_state({
        key_name = "T",
    }))
assert_false(non_key_blocked.allowed, "non cancel key blocked")
assert_equal(non_key_blocked.reason, "not movement key",
    "non cancel key reason")

local movement_task_cancel_methods = core.movement_task_cancel_method_names()
assert_equal(movement_task_cancel_methods[1], "EndTaskAsCancelled",
    "movement task prefers cancelled result")
assert_equal(movement_task_cancel_methods[2], "EndTaskWithResult",
    "movement task can pass EGenericTaskResult::Cancelled")
assert_equal(movement_task_cancel_methods[3], "BP_ExternalCancel",
    "movement task can use generic external cancel")
assert_equal(movement_task_cancel_methods[4], "EndTask",
    "movement task can fall back to GameplayTask EndTask")

local locomotion_cancel_specs = core.locomotion_cancel_specs()
assert_equal(locomotion_cancel_specs[1].method, "SetRequestedMovementAction",
    "locomotion cancel resets requested movement locally first")
assert_equal(locomotion_cancel_specs[1].args[1], 0,
    "locomotion cancel resets movement action to None")
assert_equal(locomotion_cancel_specs[1].args[2], true,
    "locomotion cancel first reset is replicated")
assert_equal(locomotion_cancel_specs[2].method, "SetRequestedMovementAction",
    "locomotion cancel retries local reset without replication")
assert_equal(locomotion_cancel_specs[2].args[2], false,
    "locomotion cancel second reset disables replication")
assert_equal(locomotion_cancel_specs[3].method, "Server_SetRequestedMovementAction",
    "locomotion cancel can call server movement reset")
assert_equal(locomotion_cancel_specs[4].property, "m_RequestedMovementAction",
    "locomotion cancel can directly clear requested movement property")
assert_equal(locomotion_cancel_specs[4].value, 0,
    "locomotion cancel property reset uses None")

local movement_task_notify_classes = core.movement_task_notify_class_names()
assert_equal(movement_task_notify_classes[1],
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction",
    "movement task notifications prefer move-into-position instances")
assert_false(contains_value(movement_task_notify_classes,
        "/Script/G1R.AbilityTask_GotoInteractionSpot"),
    "movement task notifications exclude goto interaction spot instances")
assert_true(contains_value(movement_task_notify_classes,
        "/Script/G1R.AbilityTask_InteractWith"),
    "movement task notifications include interact-with instances")
for _, class_name in ipairs(movement_task_notify_classes) do
    assert_true(string.sub(class_name, 1, 1) == "/",
        "movement task notification class is fully qualified")
    assert_true(string.find(class_name, "%.") ~= nil,
        "movement task notification class includes package and class name")
end
assert_true(core.movement_task_tracking_priority(
        "AbilityTask_MoveIntoPositionForInteraction /Engine/Transient.Task")
    > core.movement_task_tracking_priority(
        "AbilityTask_InteractWith /Engine/Transient.Task"),
    "concrete move-into-position task is preferred over generic interact-with task")
assert_equal(core.movement_task_tracking_priority(
        "AbilityTask_GotoInteractionSpot /Engine/Transient.Task"), 0,
    "goto interaction spot is not movement tracked")
assert_equal(core.movement_task_tracking_priority("OtherTask"), 0,
    "unrelated task has no tracking priority")
assert_true(core.movement_task_is_cancelable(
        "AbilityTask_MoveIntoPositionForInteraction /Engine/Transient.Task"),
    "move-into-position task can be cancelled as path movement")
assert_false(core.movement_task_is_cancelable(
        "AbilityTask_GotoInteractionSpot /Engine/Transient.Task"),
    "goto interaction spot task is not cancelled")
assert_false(core.movement_task_is_cancelable(
        "AbilityTask_InteractWith /Engine/Transient.Task"),
    "generic interact-with task is tracked but not cancelled as path movement")
assert_nil(core.movement_task_buffer_replacement_index,
    "movement task buffer replacement removed for single-task tracking")
local unknown_owner_filter = core.classify_movement_task_owner_filter({
    owner_known = false,
})
assert_false(unknown_owner_filter.allowed,
    "movement task owner filter blocks unknown owners")
assert_equal(unknown_owner_filter.reason, "owner unknown",
    "unknown owner filter reason")
local player_owner_filter = core.classify_movement_task_owner_filter({
    owner_known = true,
    owner_is_player = true,
})
assert_true(player_owner_filter.allowed,
    "movement task owner filter allows player-owned tasks")
assert_equal(player_owner_filter.reason, "player owner",
    "player owner filter reason")
local non_player_owner_filter = core.classify_movement_task_owner_filter({
    owner_known = true,
    owner_is_player = false,
})
assert_false(non_player_owner_filter.allowed,
    "movement task owner filter blocks non-player-owned tasks")
assert_equal(non_player_owner_filter.reason, "non-player owner",
    "non-player owner filter reason")
local npc_owner_signature = core.classify_movement_task_owner_signature({
    ability =
        "GameplayAbility_CharacterAI_Human /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.State_OC_GRD_Guard19_2147431817.GameplayAbility_CharacterAI_Human_2147383706",
    ability_system =
        "/Script/G1R.GothicAbilitySystemComponent'/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.State_OC_GRD_Guard19_2147431817.AbilitySystemComponent'",
})
assert_true(npc_owner_signature.owner_known,
    "npc owner signature is known")
assert_false(npc_owner_signature.owner_is_player,
    "npc owner signature is not player")
assert_equal(npc_owner_signature.reason, "npc owner signature",
    "npc owner signature reason")
local player_owner_signature = core.classify_movement_task_owner_signature({
    ability_system =
        "/Script/G1R.GothicAbilitySystemComponent'/Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_2147443446.AbilitySystemComponent'",
    owner_actor =
        "G1RPlayerState /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_2147443446",
    avatar_actor =
        "PlayerCharacterBP_C /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.PlayerCharacterBP_C_2147443175",
})
assert_true(player_owner_signature.owner_known,
    "player owner signature is known")
assert_true(player_owner_signature.owner_is_player,
    "player owner signature is player")
assert_equal(player_owner_signature.reason, "player owner signature",
    "player owner signature reason")
local unknown_owner_signature = core.classify_movement_task_owner_signature({
    ability = "GameplayAbility_OpenContainer /Engine/Transient.Ability",
})
assert_false(unknown_owner_signature.owner_known,
    "neutral owner signature remains unknown")
assert_equal(unknown_owner_signature.reason, "owner signature unknown",
    "unknown owner signature reason")
assert_equal(core.format_movement_task_owner_debug({
        reason = "player owner",
        ability = "GameplayAbility_Bench /Engine/Transient.Ability",
        avatar = "G1RHero /Game/Maps/MainMap.Hero",
    }),
    " ownerReason=player owner ability=GameplayAbility_Bench /Engine/Transient.Ability avatar=G1RHero /Game/Maps/MainMap.Hero",
    "movement task owner debug includes reason, ability and avatar")
assert_equal(core.format_movement_task_owner_debug({
        reason = "owner unknown",
    }),
    " ownerReason=owner unknown",
    "movement task owner debug handles missing reflected objects")
assert_equal(core.format_movement_task_owner_debug({
        reason = "owner unknown",
        owner_property = "Ability",
        owner_probe = "Ability=missing",
        owner_signature = "npc owner signature",
        ability_system =
            "/Script/G1R.GothicAbilitySystemComponent'/Game/Maps/MainMap.MainMap:PersistentLevel.State_OC_GRD_Guard19_2147431817.AbilitySystemComponent'",
        owner_actor =
            "G1RPlayerState /Game/Maps/MainMap.MainMap:PersistentLevel.G1RPlayerState_2147443446",
        avatar_actor =
            "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PersistentLevel.PlayerCharacterBP_C_2147443175",
    }),
    " ownerReason=owner unknown ownerProperty=Ability ownerProbe=Ability=missing ownerSignature=npc owner signature abilitySystem=/Script/G1R.GothicAbilitySystemComponent'/Game/Maps/MainMap.MainMap:PersistentLevel.State_OC_GRD_Guard19_2147431817.AbilitySystemComponent' ownerActor=G1RPlayerState /Game/Maps/MainMap.MainMap:PersistentLevel.G1RPlayerState_2147443446 avatarActor=PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PersistentLevel.PlayerCharacterBP_C_2147443175",
    "movement task owner debug includes cheap owner diagnostics")
assert_nil(core.classify_movement_task_cancel_set,
    "movement task cancel set policy removed for single-task tracking")
local inactive_task_tracking = core.classify_movement_task_tracking({
    identity = "AbilityTask_MoveIntoPositionForInteraction /Engine/Transient.Task",
    movement_action = 0,
    requested_movement_action = 0,
})
assert_false(inactive_task_tracking.track,
    "inactive movement window must not cache movement task")
assert_equal(inactive_task_tracking.reason, "movement action inactive",
    "inactive movement task tracking reason")
assert_equal(inactive_task_tracking.priority, 30,
    "inactive movement task still reports priority for diagnostics")
local animation_task_tracking = core.classify_movement_task_tracking({
    identity = "AbilityTask_MoveIntoPositionForInteraction /Engine/Transient.Task",
    movement_action = 7,
    requested_movement_action = 0,
})
assert_false(animation_task_tracking.track,
    "movement task without requested movement action is not cached")
assert_equal(animation_task_tracking.reason, "movement action inactive",
    "animation movement task tracking reason")
local active_task_tracking = core.classify_movement_task_tracking({
    identity = "AbilityTask_MoveIntoPositionForInteraction /Engine/Transient.Task",
    movement_action = 0,
    requested_movement_action = 7,
})
assert_true(active_task_tracking.track,
    "requested interaction movement can cache movement task")
assert_equal(active_task_tracking.priority, 30,
    "active movement task reports priority")
local goto_task_tracking = core.classify_movement_task_tracking({
    identity = "AbilityTask_GotoInteractionSpot /Engine/Transient.Task",
    movement_action = 0,
    requested_movement_action = 7,
})
assert_false(goto_task_tracking.track,
    "goto interaction spot is not cached as a movement task")
assert_equal(goto_task_tracking.reason, "not movement task",
    "goto interaction spot tracking reason")

local interact_with_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActor")
assert_true(interact_with_tracking.track, "interact-with hook tracked")
assert_equal(interact_with_tracking.kind, "use-object",
    "interact-with hook kind")
assert_equal(interact_with_tracking.phase, "move",
    "interact-with hook phase")

local goto_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_GotoInteractionSpot:TaskGotoInteractionSpot")
assert_false(goto_tracking.track, "goto interaction spot hook is not tracked")
assert_equal(goto_tracking.phase, "idle", "goto hook phase")

local move_into_position_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:BP_TaskMoveIntoPositionForInteraction")
assert_true(move_into_position_tracking.track,
    "move into position hook tracked")
assert_equal(move_into_position_tracking.phase, "move",
    "move into position hook phase")

for _, hook_name in ipairs({
    "/Script/G1R.GameplayAbilityCrafting:EventPlayAction",
    "/Script/G1R.GameplayAbilitySleep:OnActivateAbility_Scriptable",
    "/Script/G1R.GameplayAbilityOpenContainer:ActivateAbility",
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility",
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions",
}) do
    local tracking = core.interaction_tracking_from_hook(hook_name)
    assert_false(tracking.track, "specific hook is not movement tracked")
    assert_equal(tracking.kind, "none", "specific hook kind")
    assert_equal(tracking.phase, "idle", "specific hook phase")
end

local expected_candidates = {
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithNavLink",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotIgnoreOwner",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotRandomAction",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpot",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActorRandomAction",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithActor",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractHereWithoutSpot",
    "/Script/G1R.AbilityTask_InteractWith:TaskFindAndInteractWithSpotRandomAction",
    "/Script/G1R.AbilityTask_InteractWith:TaskFindAndInteractWithSpot",
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:BP_TaskMoveIntoPositionForInteraction",
}
local candidates = core.discovery_hook_candidates()
assert_equal(#candidates, #expected_candidates, "movement hook count")
for index, expected in ipairs(expected_candidates) do
    assert_equal(candidates[index], expected,
        "movement hook " .. tostring(index))
end

assert_nil(core.interaction_spot_reachability_hook_candidates,
    "goto interaction spot reachability diagnostics removed")

local controller_fallback_candidates =
    core.controller_cancel_fallback_hook_candidates()
assert_true(contains_value(controller_fallback_candidates,
        "/Script/G1R.GameplayAbilityCallInteractFunction:HandleLeaveInput"),
    "controller fallback includes gameplay leave input")
assert_true(contains_value(controller_fallback_candidates,
        "/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction"),
    "controller fallback includes CommonUI back action")
assert_nil(core.parse_controller_cancel_poll_keys,
    "controller poll config parser removed")
assert_nil(core.controller_cancel_poll_hook_candidates,
    "controller poll hooks removed")
assert_nil(core.controller_input_discovery_hook_candidates,
    "controller input discovery hooks removed")

assert_nil(core.classify_crafting_cancel, "crafting policy removed")
assert_nil(core.crafting_cancel_method_names, "crafting methods removed")
assert_nil(core.container_move_task_property_names, "container policy removed")
assert_nil(core.open_container_close_method_names, "container close removed")
assert_nil(core.loot_ability_close_method_names, "loot policy removed")
assert_nil(core.interaction_sleep_ability_cancel_method_names,
    "sleep ability cleanup removed")
assert_nil(core.sleep_montage_cancel_method_names,
    "sleep montage cleanup removed")
assert_nil(core.interaction_tracking_from_montage_name,
    "montage tracking helper removed")
assert_nil(core.pray_of_fire_fix_hook_candidates,
    "pray of fire fix removed from cancel mod")
assert_nil(core.runtime_instance_scan_classes,
    "runtime instance scans removed from cancel mod")

local main_source = read_file("Scripts/main.lua")
local core_source = read_file("Scripts/cancel_core.lua")
local mod_runtime_source = read_file("Scripts/mod_runtime.lua")
local readme_source = read_file("README.md")
local ini_source = read_file("G1R_CancelInteraction.ini")

assert_equal(type(mod_runtime.new), "function",
    "runtime helper module exposes constructor")
assert_true(string.find(mod_runtime_source,
        "ModRuntime.__index = ModRuntime", 1, true) ~= nil,
    "runtime helper module uses class-style table")
assert_true(string.find(main_source,
        'local ModRuntime = require("mod_runtime")', 1, true) ~= nil,
    "main uses runtime helper module")
assert_true(string.find(main_source,
        "local function discovery_log(message)", 1, true) ~= nil,
    "main has a discovery-only log helper")
assert_false(string.find(main_source,
        'require("runtime_diagnostics")', 1, true) ~= nil,
    "main no longer depends on runtime diagnostics helper")
assert_false(string.find(main_source,
        "diagnostics:log_discovery_event", 1, true) ~= nil,
    "main no longer emits broad discovery hook parameter dumps")
for _, helper_name in ipairs({
    "static_find_object",
    "function_exists",
    "register_hook",
    "find_reflected_function",
    "call_reflected_function",
    "call_method",
    "get_object_property",
    "register_key_bind",
    "key_value_from_name",
}) do
    assert_false(string.find(main_source,
            "local function " .. helper_name, 1, true) ~= nil,
        "main does not define helper " .. helper_name)
    assert_true(string.find(mod_runtime_source,
            "function ModRuntime:" .. helper_name, 1, true) ~= nil,
        "runtime helper owns " .. helper_name)
end

assert_true(string.find(main_source, "NotifyOnNewObject", 1, true) ~= nil,
    "main tracks constructed movement task instances")
assert_true(string.find(main_source,
        "core.movement_task_notify_class_names()", 1, true) ~= nil,
    "main reads movement task notify class names from core")
assert_true(string.find(main_source,
        "core.classify_movement_task_tracking", 1, true) ~= nil,
    "main classifies movement task tracking against locomotion state")
assert_true(string.find(main_source,
        "if config.discovery_mode == true then", 1, true) ~= nil,
    "main keeps passive ignored movement task logs in discovery mode")
assert_true(string.find(main_source, "local priority = tracking.priority",
        1, true) ~= nil,
    "main ranks movement task tracking candidates from classification")
assert_false(string.find(main_source,
        "install_controller_input_discovery_hooks", 1, true) ~= nil,
    "main removes controller input discovery hook installer")
assert_false(string.find(main_source,
        "controller_input_discovery_hook_candidates", 1, true) ~= nil,
    "main removes controller input discovery hook candidates")
assert_false(string.find(main_source,
        "interaction_spot_reachability", 1, true) ~= nil,
    "main does not install goto reachability diagnostics")
assert_false(string.find(main_source,
        "reachability hooks", 1, true) ~= nil,
    "main startup log does not mention removed reachability diagnostics")
assert_true(string.find(main_source, "tracked_interaction.priority", 1, true) ~= nil,
    "main stores movement task tracking priority")
assert_false(string.find(main_source, "tracked_interaction.tasks", 1, true) ~= nil,
    "main no longer stores multiple movement tasks")
assert_false(string.find(main_source, "MAX_TRACKED_MOVEMENT_TASKS", 1, true) ~= nil,
    "main removes movement task buffer sizing")
assert_false(string.find(main_source,
        "core.movement_task_buffer_replacement_index", 1, true) ~= nil,
    "main removes task buffer replacement policy")
assert_false(string.find(main_source,
        "[movement-track] replaced buffered task", 1, true) ~= nil,
    "main removes buffered task replacement diagnostics")
assert_true(string.find(main_source,
        "movement_task_owner_filter", 1, true) ~= nil,
    "main keeps cancel-time movement task owner filtering")
assert_true(string.find(main_source,
        "local function movement_task_owner_filter(object)", 1, true) ~= nil,
    "main probes owner state only when owner filtering is called")
assert_true(string.find(main_source,
        "local function movement_task_owner_context(object)", 1, true) ~= nil,
    "main builds reusable movement task owner context")
assert_true(string.find(main_source,
        "value = direct_ok == true and direct_value or nil", 1, true) ~= nil,
    "main does not treat failed direct owner property reads as values")
assert_true(string.find(main_source,
        "method_value = method_ok == true and method_value or nil", 1, true) ~= nil,
    "main does not treat failed GetPropertyValue owner reads as values")
assert_true(string.find(main_source,
        "local function property_identity_text(value)", 1, true) ~= nil,
    "main normalizes UObject or string owner properties for diagnostics")
assert_true(string.find(main_source,
        'read_owner_property(object, "AbilitySystemComponent")', 1, true) ~= nil
        and string.find(main_source,
            "runtime:get_object_property_value_method", 1, true) ~= nil,
    "main diagnoses AbilitySystemComponent through GetPropertyValue")
assert_true(string.find(main_source,
        'discovery_log("[movement-cancel-owner-state]', 1, true) ~= nil,
    "main keeps owner diagnostics behind discovery logging")
assert_false(string.find(main_source, "OwnerAbility", 1, true) ~= nil,
    "main does not probe OwnerAbility in the movement hotpath")
assert_false(string.find(main_source, "OwningAbility", 1, true) ~= nil,
    "main does not probe OwningAbility in the movement hotpath")
assert_false(string.find(main_source,
        "GetAvatarActorFromActorInfo", 1, true) ~= nil,
    "main does not resolve movement task owner avatars in the hotpath")
assert_false(string.find(main_source, "GetAvatarCharacter", 1, true) ~= nil,
    "main does not probe direct movement task avatars in the hotpath")
assert_true(string.find(main_source,
        'read_owner_property(ability_system, "OwnerActor")', 1, true) ~= nil,
    "main probes ability system owner actor through owner context")
assert_true(string.find(main_source,
        'read_owner_property(ability_system, "AvatarActor")', 1, true) ~= nil,
    "main probes ability system avatar actor through owner context")
assert_true(string.find(main_source,
        "filter.owner_actor", 1, true) ~= nil,
    "main includes owner actor in movement task diagnostics")
assert_true(string.find(main_source,
        "filter.avatar_actor", 1, true) ~= nil,
    "main includes avatar actor in movement task diagnostics")
assert_true(string.find(main_source,
        'discovery_log("[movement-track] source=', 1, true) ~= nil,
    "main keeps full movement task logs behind discovery mode")
assert_false(string.find(main_source,
        'debug_log("[movement-track] source=', 1, true) ~= nil,
    "debug mode alone does not emit full movement task logs")
assert_false(string.find(main_source,
        "local owner_filter = movement_task_owner_filter(object)", 1, true) ~= nil,
    "movement tracking does not owner-filter before cancel")
assert_false(string.find(main_source,
        "for _, task in ipairs(tasks) do", 1, true) ~= nil,
    "movement cancel no longer loops over tracked tasks")
assert_true(string.find(main_source,
        '[movement-cancel-task-state]', 1, true) ~= nil,
    "movement cancel logs current task state in discovery mode")
assert_true(string.find(main_source,
        '[movement-cancel-owner-state]', 1, true) ~= nil,
    "movement cancel logs owner and ability system state in discovery mode")
assert_true(string.find(main_source,
        "local owner_filter = movement_task_owner_filter(task)", 1, true) ~= nil,
    "movement cancel forces owner filtering before cancelling a task")
assert_true(string.find(main_source,
        '[movement-only-cancel] skipped owner-filtered task', 1, true) ~= nil,
    "movement cancel skips owner-filtered movement tasks")
assert_true(string.find(main_source,
        "core.movement_task_is_cancelable", 1, true) ~= nil,
    "main filters tracked tasks before calling movement task cancel methods")
assert_false(string.find(main_source,
        "core.classify_movement_task_cancel_set", 1, true) ~= nil,
    "main removes multi-task cancel set policy")
assert_false(string.find(main_source,
        "ready_to_start_animation", 1, true) ~= nil,
    "main no longer feeds animation readiness into cancel policy")
assert_true(string.find(main_source,
        'clear_tracked_interaction("non-path-task-active")', 1, true) ~= nil,
    "main clears tracking when the movement window has reached the object task")
assert_false(string.find(main_source,
        "kept higher priority task", 1, true) ~= nil,
    "main does not discard equal-window movement tasks by priority")
assert_true(string.find(main_source, "bIsReadyToStartAnimation", 1, true) ~= nil,
    "main logs move-into-position animation readiness")
assert_true(string.find(main_source, '"MoveTask"', 1, true) ~= nil,
    "main logs move-into-position nested move task in discovery mode")
assert_true(string.find(main_source, '"TurnTask"', 1, true) ~= nil,
    "main logs move-into-position nested turn task in discovery mode")
assert_true(string.find(main_source,
        "runtime:object_identity_text(value)", 1, true) ~= nil,
    "main logs nested task object identities when readable")
assert_false(string.find(main_source, "bFailIfClaimed", 1, true) ~= nil,
    "main no longer reads goto interaction spot claim behavior")
assert_true(string.find(main_source,
        "local function task_debug_flags(object, object_identity)", 1, true) ~= nil,
    "task debug flags receive object identity")
assert_true(string.find(main_source,
        'runtime:contains(object_identity, "AbilityTask_MoveIntoPositionForInteraction")',
        1, true) ~= nil,
    "move-into-position debug flags are class-gated")
assert_false(string.find(main_source,
        'runtime:contains(object_identity, "AbilityTask_GotoInteractionSpot")',
        1, true) ~= nil,
    "goto interaction spot debug flags are removed")
assert_false(string.find(main_source,
        "[movement-track] ignored-readiness", 1, true) ~= nil,
    "ignored move-into-position tasks do not log readiness diagnostics outside discovery mode")
assert_true(string.find(main_source,
        "local function try_cancel_movement_interaction", 1, true) ~= nil,
    "main keeps a dedicated movement-only cancel function")
assert_true(string.find(main_source,
        "local function try_cancel_locomotion_interaction", 1, true) ~= nil,
    "main can cancel movement through locomotion state")
assert_true(string.find(main_source,
        "clear_tracking = false", 1, true) ~= nil,
    "movement-only cancel can reset locomotion before clearing tracked tasks")
local movement_locomotion_position = string.find(main_source,
    "local locomotion_cancelled = try_cancel_locomotion_interaction(",
    1, true)
local movement_task_cancel_position = string.find(main_source,
    "local owner_filter = movement_task_owner_filter(task)",
    1, true)
assert_true(movement_locomotion_position ~= nil
        and movement_task_cancel_position ~= nil
        and movement_locomotion_position < movement_task_cancel_position,
    "movement-only cancel resets locomotion before owner-filtering the tracked path task")
local cancel_task_state_position = string.find(main_source,
    "[movement-cancel-task-state]", 1, true)
local cancel_owner_state_position = string.find(main_source,
    "[movement-cancel-owner-state]", 1, true)
local task_finished_position = string.find(main_source,
    "if task_is_finished(task) then", 1, true)
local owner_skip_position = string.find(main_source,
    "if owner_filter.allowed ~= true then", 1, true)
assert_true(cancel_task_state_position ~= nil
        and task_finished_position ~= nil
        and cancel_task_state_position < task_finished_position,
    "movement cancel logs task state before checking whether the task finished")
assert_true(cancel_owner_state_position ~= nil
        and task_finished_position ~= nil
        and cancel_owner_state_position < task_finished_position,
    "movement cancel logs owner state before checking whether the task finished")
assert_true(owner_skip_position ~= nil
        and task_finished_position ~= nil
        and owner_skip_position < task_finished_position,
    "movement cancel skips non-player tasks before checking or cancelling them")
assert_true(string.find(main_source,
        "runtime:call_method_with_arg_pack(locomotion, spec.method, args)",
        1, true) ~= nil,
    "main delegates reflected locomotion calls to runtime helper")
assert_true(string.find(main_source,
        "runtime:register_key_bind", 1, true) ~= nil,
    "main delegates keybind registration to runtime helper")
assert_false(string.find(main_source,
        "on_cancel_hotkey(normalized)", 1, true) ~= nil,
    "main does not close over same-line normalized keybind local")
assert_false(string.find(main_source, "RegisterKeyBind", 1, true) ~= nil,
    "main does not directly register keybinds")
assert_true(string.find(mod_runtime_source,
        "/Script/G1R.DataModule_Locomotion:SetRequestedMovementAction", 1, true) ~= nil,
    "runtime helper reflects local locomotion movement reset")
assert_true(string.find(mod_runtime_source,
        "/Script/G1R.DataModule_Locomotion:Server_SetRequestedMovementAction", 1, true) ~= nil,
    "runtime helper reflects server locomotion movement reset")
assert_false(string.find(mod_runtime_source,
        "/Script/GameplayAbilities.GameplayAbility:GetAvatarActorFromActorInfo",
        1, true) ~= nil,
    "runtime helper does not keep unused ability avatar lookup")
assert_false(string.find(mod_runtime_source,
        "/Script/G1R.AbilityTaskGeneric:GetAvatarCharacter", 1, true) ~= nil,
    "runtime helper does not keep unused direct task avatar lookup")
assert_true(string.find(mod_runtime_source, "RegisterKeyBind", 1, true) ~= nil,
    "runtime helper owns keybind registration")
assert_true(string.find(mod_runtime_source, "handler(normalized)", 1, true) ~= nil,
    "runtime helper passes normalized key to keybind handler")
assert_false(string.find(main_source, "ControllerCancelPoll", 1, true) ~= nil,
    "main removes controller poll config references")
assert_false(string.find(core_source, "ControllerCancelPoll", 1, true) ~= nil,
    "core removes controller poll config references")
assert_false(string.find(mod_runtime_source, "controller_poll", 1, true) ~= nil,
    "runtime helper removes controller poll state")
assert_false(string.find(mod_runtime_source, "poll_controller_cancel_inputs", 1, true) ~= nil,
    "runtime helper removes controller poll input scanner")
assert_false(string.find(readme_source, "ControllerCancelPoll", 1, true) ~= nil,
    "readme removes controller poll option")
assert_false(string.find(ini_source, "ControllerCancelPoll", 1, true) ~= nil,
    "config removes controller poll option")
assert_false(string.find(main_source, "config.timing", 1, true) ~= nil,
    "main removes timing diagnostics")
assert_false(string.find(core_source, "TIMING", 1, true) ~= nil,
    "core removes timing config parsing")
assert_true(string.find(main_source,
        "local locomotion_cancelled = try_cancel_locomotion_interaction(", 1, true) ~= nil,
    "movement task cancel also resets locomotion in the same attempt")
local locomotion_cleanup_position = string.find(main_source,
    "local locomotion_cancelled = try_cancel_locomotion_interaction(",
    1, true)
local task_clear_position = string.find(main_source,
    'clear_tracked_interaction("movement-only-cancelled:',
    1, true)
assert_true(locomotion_cleanup_position ~= nil
        and task_clear_position ~= nil
        and locomotion_cleanup_position < task_clear_position,
    "movement task cancel runs locomotion cleanup before clearing tracking")
assert_true(string.find(main_source,
        'clear_tracked_interaction("movement-window-inactive")', 1, true) ~= nil,
    "inactive movement window clears stale tracked task")
assert_false(string.find(main_source,
        "return try_cancel_locomotion_interaction(key_name, snapshot)", 1, true) ~= nil,
    "movement cancel does not blindly fall back to locomotion")
assert_true(string.find(main_source,
        "interaction_active = tracked_interaction.active == true", 1, true) ~= nil,
    "hotkey gate requires a tracked interaction before entering game thread")
assert_true(string.find(main_source,
        "taskLocomotion=", 1, true) ~= nil,
    "movement task cancel logs whether same-attempt locomotion reset ran")
assert_false(string.find(main_source,
        "table.insert(candidates, string.gsub", 1, true) ~= nil,
    "main does not pass string.gsub multiple return values into table.insert")
assert_false(string.find(main_source,
        'if tracked_interaction.phase ~= "move" then', 1, true) ~= nil,
    "main does not use the old non-move phase fallback branch")
assert_false(string.find(main_source, "MOVEMENT_CANCEL_ARM_MS", 1, true) ~= nil,
    "main removed movement cancel arming timer")
assert_false(string.find(main_source, "INTERACTION_ACTIVITY_TIMEOUT_MS", 1, true) ~= nil,
    "main removed tracked interaction activity timer")
assert_false(string.find(main_source, "INTERACTION_CANCEL_LOCKOUT_MS", 1, true) ~= nil,
    "main removed interaction cancel lockout timer")
assert_false(string.find(main_source, "last_successful_interaction_cancel_ms", 1, true) ~= nil,
    "main removed successful cancel lockout state")
assert_true(string.find(main_source,
        "core.movement_task_cancel_method_names()", 1, true) ~= nil,
    "main uses generic movement task methods")
assert_false(string.find(main_source, "FindAllOf", 1, true) ~= nil,
    "main movement cancel path avoids global object scans")

for _, forbidden in ipairs({
    "tracked_crafting",
    "try_cancel_crafting",
    "GameplayAbilityCrafting",
    "CancelCrafting",
    "crafting_",
    "try_cancel_sleep",
    "GameplayAbilitySleep",
    "sleep_",
    "try_cancel_container",
    "GameplayAbilityOpenContainer",
    "InventoryLootContainer",
    "LootContainer",
    "loot_",
    "InteractFreePoint",
    "free_point",
    "InteractionSpot_Montage",
    "PlayAnimMontage",
    "StopAnimMontage",
    "Montage_Stop",
    "PrayOfFire",
    "InnosPray",
    "FirePuzzle",
    "RuntimeFunctionScan",
}) do
    assert_not_contains(main_source, forbidden, "main source")
    assert_not_contains(core_source, forbidden, "core source")
    assert_not_contains(readme_source, forbidden, "readme")
    assert_not_contains(ini_source, forbidden, "config")
end

local main_lines = 0
for _ in string.gmatch(main_source, "\n") do
    main_lines = main_lines + 1
end
assert_true(main_lines <= 1450, "main.lua remains movement-only sized")

print("g1r_cancel_interaction_core.test.lua: PASS")
