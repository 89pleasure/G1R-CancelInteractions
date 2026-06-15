local core = {}

local DEFAULT_CANCEL_KEYS = {
    "ESCAPE",
    "A",
    "W",
    "S",
    "D",
    "RIGHT_MOUSE_BUTTON",
}
local DEFAULT_CONTROLLER_CANCEL_KEY = "CONTROLLER_BACK"
local MOVEMENT_ACTION_NONE = 0
local MOVEMENT_ACTION_INTERACT = 7
local MOVEMENT_ACTION_INTERACTION = 8
local CANCEL_KEY_ALIASES = {
    RIGHTMOUSEBUTTON = "RIGHT_MOUSE_BUTTON",
    CONTROLLER_BACK = {
        "GAMEPAD_FACE_BUTTON_RIGHT",
        "GAMEPAD_FACEBUTTON_RIGHT",
    },
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

local function key_from_string(value, default_value)
    local key = upper(value)
    if key == "" then
        return default_value
    end
    return key
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

function core.cancel_key_lookup_candidates(key_name)
    local normalized = upper(key_name)
    local candidates = {}
    if normalized ~= "" then
        table.insert(candidates, normalized)
        local alias = CANCEL_KEY_ALIASES[normalized]
        if type(alias) == "table" then
            for _, candidate in ipairs(alias) do
                if candidate ~= nil and candidate ~= normalized then
                    table.insert(candidates, candidate)
                end
            end
        elseif alias ~= nil and alias ~= normalized then
            table.insert(candidates, alias)
        end
    end
    return candidates
end

function core.config_from_ini(ini)
    ini = ini or {}
    return {
        debug = bool_from_string(ini.DEBUG, false),
        discovery_mode = bool_from_string(ini.DISCOVERYMODE, false),
        cancel_keys = core.parse_cancel_keys(ini.CANCELKEYS),
        controller_cancel_enabled =
            bool_from_string(ini.CONTROLLERCANCELENABLED, true),
        controller_cancel_key = key_from_string(ini.CONTROLLERCANCELKEY,
            DEFAULT_CONTROLLER_CANCEL_KEY),
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

function core.controller_cancel_fallback_hook_candidates()
    return {
        "/Script/G1R.GameplayAbilityCallInteractFunction:HandleLeaveInput",
        "/Script/G1R.GameplayAbilityLavaExtractor:HandleLeaveInput",
        "/Script/G1R.GameplayAbilityLever:HandleLeaveInputEvent",
        "/Script/G1R.GameplayAbilityPuzzleSwitch:HandleLeaveInput",
        "/Script/G1R.GameplayAbilityStatue:HandleLeaveInput",
        "/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction",
        "/Game/UI/QuickSlot/W_Crossbar.W_Crossbar_C:BP_OnHandleBackAction",
        "/Game/UI/QuickSlot/W_QuickWheel_DEPRECATED.W_QuickWheel_DEPRECATED_C:BP_OnHandleBackAction",
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
