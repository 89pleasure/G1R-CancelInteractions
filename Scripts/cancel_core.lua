local core = {}

local DEFAULT_CANCEL_KEYS = {
    "ESCAPE",
    "A",
    "W",
    "S",
    "D",
    "RIGHT_MOUSE_BUTTON",
}
local DEFAULT_CONTROLLER_CANCEL_KEY = "CONTROLLER_FACE_RIGHT"
local DEFAULT_CONTROLLER_CANCEL_KEYS = {
    DEFAULT_CONTROLLER_CANCEL_KEY,
    "CONTROLLER_FACE_BOTTOM",
}
local ABILITY_INPUT_CANCEL = 2
local MOVEMENT_ACTION_NONE = 0
local MOVEMENT_ACTION_INTERACT = 7
local MOVEMENT_ACTION_INTERACTION = 8
local CONTROLLER_FACE_RIGHT_ALIASES = {
    "Gamepad_FaceButton_Right",
    "GAMEPAD_FACE_BUTTON_RIGHT",
    "GAMEPAD_FACEBUTTON_RIGHT",
    "Gamepad_FaceButton_East",
    "GAMEPAD_FACE_BUTTON_EAST",
    "GAMEPAD_FACEBUTTON_EAST",
    "XboxTypeS_B",
    "XBOX_TYPE_S_B",
    "PS4_Circle",
    "PS4_CIRCLE",
    "PS5_Circle",
    "PS5_CIRCLE",
}
local CONTROLLER_FACE_BOTTOM_ALIASES = {
    "Gamepad_FaceButton_Bottom",
    "GAMEPAD_FACE_BUTTON_BOTTOM",
    "GAMEPAD_FACEBUTTON_BOTTOM",
    "Gamepad_FaceButton_South",
    "GAMEPAD_FACE_BUTTON_SOUTH",
    "GAMEPAD_FACEBUTTON_SOUTH",
    "XboxTypeS_A",
    "XBOX_TYPE_S_A",
    "PS4_Cross",
    "PS4_CROSS",
    "PS5_Cross",
    "PS5_CROSS",
}
local CONTROLLER_FACE_LEFT_ALIASES = {
    "Gamepad_FaceButton_Left",
    "GAMEPAD_FACE_BUTTON_LEFT",
    "GAMEPAD_FACEBUTTON_LEFT",
    "Gamepad_FaceButton_West",
    "GAMEPAD_FACE_BUTTON_WEST",
    "GAMEPAD_FACEBUTTON_WEST",
    "XboxTypeS_X",
    "XBOX_TYPE_S_X",
    "PS4_Square",
    "PS4_SQUARE",
    "PS5_Square",
    "PS5_SQUARE",
}
local CONTROLLER_FACE_TOP_ALIASES = {
    "Gamepad_FaceButton_Top",
    "GAMEPAD_FACE_BUTTON_TOP",
    "GAMEPAD_FACEBUTTON_TOP",
    "Gamepad_FaceButton_North",
    "GAMEPAD_FACE_BUTTON_NORTH",
    "GAMEPAD_FACEBUTTON_NORTH",
    "XboxTypeS_Y",
    "XBOX_TYPE_S_Y",
    "PS4_Triangle",
    "PS4_TRIANGLE",
    "PS5_Triangle",
    "PS5_TRIANGLE",
}
local CANCEL_KEY_ALIASES = {
    RIGHTMOUSEBUTTON = "RIGHT_MOUSE_BUTTON",
    CONTROLLER_FACE_RIGHT = CONTROLLER_FACE_RIGHT_ALIASES,
    CONTROLLER_BACK = "CONTROLLER_FACE_RIGHT",
    CONTROLLER_FACE_BOTTOM = CONTROLLER_FACE_BOTTOM_ALIASES,
    CONTROLLER_CROSS = "CONTROLLER_FACE_BOTTOM",
    CONTROLLER_FACE_LEFT = CONTROLLER_FACE_LEFT_ALIASES,
    CONTROLLER_XBOX_X = "CONTROLLER_FACE_LEFT",
    CONTROLLER_FACE_TOP = CONTROLLER_FACE_TOP_ALIASES,
}
local COMPACT_CANCEL_KEY_ALIASES = {
    CONTROLLERBACK = "CONTROLLER_BACK",
    CONTROLLERFACERIGHT = "CONTROLLER_FACE_RIGHT",
    CONTROLLERFACEBOTTOM = "CONTROLLER_FACE_BOTTOM",
    CONTROLLERCROSS = "CONTROLLER_CROSS",
    CONTROLLERFACELEFT = "CONTROLLER_FACE_LEFT",
    CONTROLLERXBOXX = "CONTROLLER_XBOX_X",
    CONTROLLERFACETOP = "CONTROLLER_FACE_TOP",
}

local function copy_array(values)
    local copy = {}
    for index, value in ipairs(values or {}) do
        copy[index] = value
    end
    return copy
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function core.safe_to_string(value)
    local ok, text = pcall(function()
        return tostring(value)
    end)
    if ok and text ~= nil then
        return text
    end
    return "<unprintable " .. type(value) .. ">"
end

function core.classify_menu_open_state(state)
    state = state or {}
    local show_mouse_cursor = state.show_mouse_cursor == true
    local paused = state.paused == true
    local reason = "closed"
    if show_mouse_cursor and paused then
        reason = "mouse cursor+paused"
    elseif show_mouse_cursor then
        reason = "mouse cursor"
    elseif paused then
        reason = "paused"
    end
    return {
        open = show_mouse_cursor or paused,
        reason = reason,
        show_mouse_cursor = show_mouse_cursor,
        paused = paused,
    }
end

local function upper(value)
    return string.upper(trim(value))
end

local function bool_from_string(value, default_value)
    local normalized = upper(value)
    if normalized == "" then
        return default_value
    end
    if normalized == "1" or normalized == "TRUE"
        or normalized == "YES" or normalized == "ON"
    then
        return true
    end
    if normalized == "0" or normalized == "FALSE"
        or normalized == "NO" or normalized == "OFF"
    then
        return false
    end
    return default_value
end

local function number_from_string(value, default_value, minimum)
    local parsed = tonumber(trim(value))
    if parsed == nil then
        return default_value
    end
    parsed = math.floor(parsed)
    if minimum ~= nil and parsed < minimum then
        return minimum
    end
    return parsed
end

function core.parse_ini(content)
    local result = {}
    for line in string.gmatch(tostring(content or ""), "[^\r\n]+") do
        local stripped = trim(line)
        if stripped ~= "" and stripped:sub(1, 1) ~= ";"
            and stripped:sub(1, 1) ~= "#"
        then
            local key, value = stripped:match("^([%w_%.%-]+)%s*=%s*(.-)%s*$")
            if key and value then
                result[upper(key)] = trim(value)
            end
        end
    end
    return result
end

function core.parse_cancel_keys(value)
    local keys = {}
    for part in string.gmatch(tostring(value or ""), "([^,]+)") do
        local key = upper(part)
        if key ~= "" then
            table.insert(keys, key)
        end
    end
    if #keys == 0 then
        return copy_array(DEFAULT_CANCEL_KEYS)
    end
    return keys
end

function core.parse_controller_cancel_keys(value, legacy_value)
    local keys = core.parse_cancel_keys(value)
    if tostring(value or "") == "" then
        keys = {}
    end
    if #keys == 0 then
        keys = core.parse_cancel_keys(legacy_value)
        if tostring(legacy_value or "") == "" then
            keys = {}
        end
    end
    if #keys == 0 then
        return copy_array(DEFAULT_CONTROLLER_CANCEL_KEYS)
    end
    return keys
end

function core.cancel_key_lookup_candidates(key_name)
    local normalized = upper(key_name)
    local candidates = {}
    local seen = {}
    local seen_alias = {}
    local function add_candidate(candidate)
        if candidate ~= nil and seen[candidate] ~= true then
            seen[candidate] = true
            table.insert(candidates, candidate)
        end
    end
    local function add_alias_candidates(alias_key)
        if alias_key == nil or seen_alias[alias_key] == true then
            return
        end
        seen_alias[alias_key] = true
        local alias = CANCEL_KEY_ALIASES[alias_key]
        if type(alias) == "table" then
            for _, candidate in ipairs(alias) do
                add_candidate(candidate)
            end
        elseif alias ~= nil then
            add_candidate(alias)
            add_alias_candidates(alias)
        end
    end
    if normalized ~= "" then
        add_candidate(normalized)
        local alias_key = COMPACT_CANCEL_KEY_ALIASES[normalized] or normalized
        if alias_key ~= normalized then
            add_candidate(alias_key)
        end
        add_alias_candidates(alias_key)
    end
    return candidates
end

function core.ability_input_id_is_cancel(input_id)
    local normalized = upper(input_id)
    if normalized == "CANCEL"
        or normalized == "EABILITYINPUTID::CANCEL"
    then
        return true
    end
    local numeric = tonumber(normalized)
    return numeric == ABILITY_INPUT_CANCEL
end

function core.enhanced_input_trigger_event_is_pressed(event_value)
    local normalized = upper(event_value)
    local numeric = tonumber(normalized)
    if numeric ~= nil then
        return numeric == 1 or numeric == 2
    end
    return normalized == "TRIGGERED"
        or normalized == "STARTED"
        or normalized == "ETRIGGEREVENT::TRIGGERED"
        or normalized == "ETRIGGEREVENT::STARTED"
end

function core.enhanced_input_trigger_context_is_press_candidate(identity)
    local text = tostring(identity or "")
    return string.find(text, "InputTriggerPressed", 1, true) ~= nil
        or string.find(text, "InputTriggerDown", 1, true) ~= nil
end

function core.controller_cancel_action_requires_initial_guard(identity)
    local text = upper(identity)
    return string.find(text, "IA_ABILITY_ACTION_INTERACT", 1, true) ~= nil
        or string.find(text, "INPUTACTION_INTERACT", 1, true) ~= nil
end

function core.config_from_ini(ini)
    ini = ini or {}
    local controller_cancel_keys =
        core.parse_controller_cancel_keys(ini.CONTROLLERCANCELKEYS,
            ini.CONTROLLERCANCELKEY)
    return {
        debug = bool_from_string(ini.DEBUG, false),
        discovery_mode = bool_from_string(ini.DISCOVERYMODE, false),
        cancel_keys = core.parse_cancel_keys(ini.CANCELKEYS),
        controller_cancel_enabled =
            bool_from_string(ini.CONTROLLERCANCELENABLED, true),
        controller_cancel_key = controller_cancel_keys[1],
        controller_cancel_keys = controller_cancel_keys,
        cooldown_ms = number_from_string(ini.COOLDOWNMS, 250, 0),
    }
end

function core.new_timed_flags()
    local flags = { values = {} }

    function flags:open(name, duration_ms, now_ms)
        local start = tonumber(now_ms) or 0
        local duration = tonumber(duration_ms) or 0
        self.values[name] = {
            expires_at = start + duration,
        }
    end

    function flags:active(name, now_ms)
        local flag = self.values[name]
        if flag == nil then
            return false
        end
        local now = tonumber(now_ms) or 0
        if now >= flag.expires_at then
            self.values[name] = nil
            return false
        end
        return true
    end

    return flags
end

function core.classify_cached_hero_update(state)
    state = state or {}
    local previous_identity = trim(state.previous_identity)
    local next_identity = trim(state.next_identity)
    local readiness_poll =
        tostring(state.source or "") == "GothicCharacter:BP_IsGameplayReady"
    local changed = next_identity ~= "" and previous_identity ~= next_identity

    return {
        changed = changed,
        refresh_runtime_refs = changed or not readiness_poll,
        should_log = changed or not readiness_poll,
    }
end

function core.player_context_hook_candidates()
    return {
        "/Script/G1R.GothicCharacter:GetInventory",
        "/Script/G1R.GothicCharacter:GetCarryComponent",
        "/Script/Engine.PlayerController:ClientRestart",
    }
end

local function menu_open_blocks_cancel(state)
    if state.menu_open ~= true then
        return false
    end
    local reason = tostring(state.menu_open_reason or "")
    if state.menu_paused == true
        or reason == "paused"
        or reason == "mouse cursor+paused"
    then
        return true
    end
    if state.interaction_phase == "move"
        and (state.menu_mouse_cursor == true or reason == "mouse cursor")
    then
        return false
    end
    return true
end

function core.controller_cancel_ability_input_hook_candidates()
    return {
        "/Script/GameplayAbilities.AbilitySystemComponent:InputCancel",
        "/Script/GameplayAbilities.AbilitySystemComponent:PressInputID",
        "/Script/GameplayAbilities.AbilitySystemComponent:ReleaseInputID",
        "/Script/G1R.GothicAbilitySystemComponent:BP_AbilityLocalInputRelease",
    }
end

function core.controller_cancel_enhanced_input_hook_candidates()
    return {
        "/Script/EnhancedInput.InputTrigger:UpdateState",
    }
end

function core.controller_input_discovery_hook_candidates()
    return {
        "/Script/G1R.InputHintWidget:OnInputActionTriggered",
        "/Script/G1R.InputHintWidget:EmitInputActionTriggeredEvents",
        "/Script/G1R.InputHintWidget_CommonUI:OnInputActionReleased",
        "/Script/CommonUI.CommonButtonBase:BP_OnInputActionTriggered",
        "/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction",
        "/Script/G1R.GameplayAbilityCallInteractFunction:HandleLeaveInput",
        "/Script/G1R.GameplayAbilityLavaExtractor:HandleLeaveInput",
        "/Script/G1R.GameplayAbilityLever:HandleLeaveInputEvent",
        "/Script/G1R.GameplayAbilityPuzzleSwitch:HandleLeaveInput",
        "/Script/G1R.GameplayAbilityStatue:HandleLeaveInput",
    }
end

function core.classify_cancel_safety(state)
    state = state or {}
    if state.player_ready ~= true then
        return { allowed = false, reason = "player not ready" }
    end
    if state.interaction_active ~= true then
        return { allowed = false, reason = "no tracked interaction" }
    end
    if state.interaction_kind ~= "ambient"
        and state.interaction_kind ~= "workstation"
        and state.interaction_kind ~= "use-object"
    then
        return { allowed = false, reason = "interaction kind blocked" }
    end
    if state.paused == true then
        return { allowed = false, reason = "paused" }
    end
    if menu_open_blocks_cancel(state) then
        return { allowed = false, reason = "menu open" }
    end
    if state.console_open == true then
        return { allowed = false, reason = "console open" }
    end
    if state.dialogue_or_cutscene == true then
        return { allowed = false, reason = "dialogue or cutscene" }
    end
    if state.alive == false then
        return { allowed = false, reason = "player not alive" }
    end
    if state.unsafe_transition == true then
        return { allowed = false, reason = "unsafe transition" }
    end
    if state.airborne == true then
        return { allowed = false, reason = "airborne" }
    end
    if state.combat_or_finisher == true then
        return { allowed = false, reason = "combat or finisher" }
    end
    return { allowed = true, reason = "ok" }
end

function core.is_movement_cancel_key(key_name)
    local key = upper(key_name)
    return key == "A" or key == "W" or key == "S" or key == "D"
        or key == "ESCAPE"
        or key == "RIGHTMOUSEBUTTON" or key == "RIGHT_MOUSE_BUTTON"
end

function core.is_directional_movement_key(key_name)
    local key = upper(key_name)
    return key == "A" or key == "W" or key == "S" or key == "D"
end

function core.cancel_hotkey_should_enter_game_thread(state)
    state = state or {}
    if not core.is_movement_cancel_key(state.key_name) then
        return false
    end
    return state.interaction_active == true
end

function core.movement_action_is_interaction_active(movement_action)
    local action = tonumber(movement_action)
    return action == MOVEMENT_ACTION_INTERACT
        or action == MOVEMENT_ACTION_INTERACTION
end

function core.movement_cancel_window_is_active(state)
    state = state or {}
    return core.movement_action_is_interaction_active(state.movement_action)
        or core.movement_action_is_interaction_active(
            state.requested_movement_action)
end

function core.requested_movement_cancel_window_is_active(state)
    state = state or {}
    return core.movement_action_is_interaction_active(
        state.requested_movement_action)
end

function core.classify_movement_interaction_cancel(state)
    state = state or {}
    if not core.is_movement_cancel_key(state.key_name) then
        return { allowed = false, reason = "not movement key" }
    end
    if not core.requested_movement_cancel_window_is_active(state) then
        return { allowed = false, reason = "movement action inactive" }
    end

    local safety = core.classify_cancel_safety(state)
    if safety.allowed ~= true then
        return safety
    end
    return { allowed = true, reason = "movement interaction active" }
end

function core.ladder_movement_control_blocks_cancel(state)
    state = state or {}
    if state.anim_is_on_ladder ~= true then
        return false
    end
    if state.movement_task_ready_to_start_animation == true
        or state.movement_task_finished == true
    then
        return true
    end
    return state.has_player_asc_movement_task == false
        and core.root_interaction_task_blocks_movement_key_cancel(
            state.root_interaction_task_identity)
end

function core.movement_task_cancel_method_names()
    return {
        "EndTaskAsCancelled",
        "EndTaskWithResult",
        "BP_ExternalCancel",
        "EndTask",
    }
end

function core.freepoint_ability_cancel_method_names()
    return {
        "OnRequestEndQuick",
        "OnRequestEndNormal",
        "K2_CancelAbility",
    }
end

function core.locomotion_cancel_specs()
    return {
        {
            method = "SetRequestedMovementAction",
            args = { MOVEMENT_ACTION_NONE, true },
        },
        {
            method = "SetRequestedMovementAction",
            args = { MOVEMENT_ACTION_NONE, false },
        },
        {
            method = "Server_SetRequestedMovementAction",
            args = { MOVEMENT_ACTION_NONE },
        },
        {
            property = "m_RequestedMovementAction",
            value = MOVEMENT_ACTION_NONE,
        },
    }
end

function core.movement_task_notify_class_names()
    return {
        "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction",
        "/Script/G1R.AbilityTask_InteractWith",
    }
end

function core.movement_task_tracking_priority(identity)
    local text = tostring(identity or "")
    if string.find(text, "AbilityTask_MoveIntoPositionForInteraction",
        1, true) ~= nil
    then
        return 30
    end
    if string.find(text, "AbilityTask_InteractWith", 1, true) ~= nil then
        return 10
    end
    return 0
end

function core.movement_task_is_cancelable(identity)
    local text = tostring(identity or "")
    return string.find(text, "AbilityTask_MoveIntoPositionForInteraction",
            1, true) ~= nil
end

function core.freepoint_ability_is_cancelable(identity)
    return string.find(tostring(identity or ""),
        "GameplayAbilityInteractFreePoint", 1, true) ~= nil
end

function core.root_interaction_task_blocks_movement_key_cancel(identity)
    return string.find(tostring(identity or ""),
        "AbilityTask_Interaction_Human_Ladder", 1, true) ~= nil
end

local function object_path_from_identity(identity)
    local text = trim(identity)
    if text == "" then
        return ""
    end
    local quoted_path = string.match(text, "'(/[^']+)'")
    if quoted_path ~= nil and quoted_path ~= "" then
        return quoted_path
    end
    local spaced_path = string.match(text, "%s(/%S+)")
    if spaced_path ~= nil and spaced_path ~= "" then
        return spaced_path:gsub("'+$", "")
    end
    local leading_path = string.match(text, "^(/%S+)")
    if leading_path ~= nil and leading_path ~= "" then
        return leading_path:gsub("'+$", "")
    end
    return ""
end

function core.object_identity_belongs_to_owner_path(object_identity,
    owner_identity)
    local object_path = object_path_from_identity(object_identity)
    local owner_path = object_path_from_identity(owner_identity)
    if object_path == "" or owner_path == "" then
        return false
    end
    return string.sub(object_path, 1, #owner_path + 1)
        == owner_path .. "."
end

function core.classify_movement_task_tracking(state)
    state = state or {}
    local priority = core.movement_task_tracking_priority(state.identity)
    if priority <= 0 then
        return { track = false, reason = "not movement task", priority = 0 }
    end
    if not core.requested_movement_cancel_window_is_active(state) then
        return {
            track = false,
            reason = "movement action inactive",
            priority = priority,
        }
    end
    return {
        track = true,
        reason = "movement action active",
        priority = priority,
    }
end

function core.interaction_tracking_from_hook(hook_name)
    local normalized = tostring(hook_name or "")
    if string.find(normalized, "AbilityTask_InteractWith:", 1, true) ~= nil then
        return { track = true, kind = "use-object", phase = "move" }
    end
    if string.find(normalized, "AbilityTask_MoveIntoPositionForInteraction:",
            1, true) ~= nil
    then
        return { track = true, kind = "use-object", phase = "move" }
    end
    return { track = false, kind = "none", phase = "idle" }
end

function core.discovery_hook_candidates()
    return {
        "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:BP_TaskMoveIntoPositionForInteraction",
    }
end

function core.movement_task_end_hook_candidates()
    return {
        "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:HandleAlignmentFinished",
    }
end

function core.interaction_end_hook_candidates()
    return {
        "/Script/G1R.GameplayAbilityInteractFreePoint:OnInteractionTaskEnded",
    }
end

function core.reflected_call_modes(preferred_mode)
    if preferred_mode == "call" then
        return { "call", "self" }
    end
    if preferred_mode == "self" then
        return { "self", "call" }
    end
    return { "self", "call" }
end

return core
