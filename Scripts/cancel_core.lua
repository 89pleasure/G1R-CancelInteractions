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

local function movement_task_cancel_class(identity)
    local text = tostring(identity or "")
    if string.find(text, "AbilityTask_MoveIntoPositionForInteraction",
        1, true) ~= nil
    then
        return "move-into-position"
    end
    return ""
end

function core.movement_task_buffer_replacement_index(
    existing_identities,
    incoming_identity,
    max_tasks)
    local limit = tonumber(max_tasks) or 0
    if limit <= 0 or #(existing_identities or {}) < limit then
        return nil
    end
    if not core.movement_task_is_cancelable(incoming_identity) then
        return nil
    end
    for index, identity in ipairs(existing_identities or {}) do
        if core.movement_task_tracking_priority(identity) > 0
            and not core.movement_task_is_cancelable(identity)
        then
            return index
        end
    end
    local incoming_class = movement_task_cancel_class(incoming_identity)
    for index, identity in ipairs(existing_identities or {}) do
        if movement_task_cancel_class(identity) == incoming_class then
            return index
        end
    end
    local incoming_priority =
        core.movement_task_tracking_priority(incoming_identity)
    for index, identity in ipairs(existing_identities or {}) do
        if core.movement_task_tracking_priority(identity) < incoming_priority then
            return index
        end
    end
    return nil
end

function core.classify_movement_task_owner_filter(state)
    state = state or {}
    if state.owner_known ~= true then
        return { allowed = false, reason = "owner unknown" }
    end
    if state.owner_is_player == true then
        return { allowed = true, reason = "player owner" }
    end
    return { allowed = false, reason = "non-player owner" }
end

function core.classify_movement_task_owner_signature(state)
    state = state or {}
    local text = tostring(state.ability or "") .. " "
        .. tostring(state.ability_system or "")
        .. " " .. tostring(state.owner_actor or "")
        .. " " .. tostring(state.avatar_actor or "")
    if string.find(text, "G1RPlayerState", 1, true) ~= nil
        or string.find(text, "PlayerCharacterBP_C", 1, true) ~= nil
        or string.find(text, "GothicPlayerCharacter", 1, true) ~= nil
        or string.find(text, "BP_Player", 1, true) ~= nil
    then
        return {
            owner_known = true,
            owner_is_player = true,
            reason = "player owner signature",
        }
    end
    if string.find(text, "GameplayAbility_CharacterAI", 1, true) ~= nil
        or string.find(text, ".State_", 1, true) ~= nil
        or string.find(text, "GothicNPCState", 1, true) ~= nil
    then
        return {
            owner_known = true,
            owner_is_player = false,
            reason = "npc owner signature",
        }
    end
    return {
        owner_known = false,
        owner_is_player = false,
        reason = "owner signature unknown",
    }
end

function core.format_movement_task_owner_debug(filter)
    filter = filter or {}
    local parts = {}
    if filter.reason ~= nil and tostring(filter.reason) ~= "" then
        table.insert(parts, "ownerReason=" .. tostring(filter.reason))
    end
    if filter.owner_property ~= nil and tostring(filter.owner_property) ~= "" then
        table.insert(parts, "ownerProperty=" .. tostring(filter.owner_property))
    end
    if filter.owner_probe ~= nil and tostring(filter.owner_probe) ~= "" then
        table.insert(parts, "ownerProbe=" .. tostring(filter.owner_probe))
    end
    if filter.owner_signature ~= nil
        and tostring(filter.owner_signature) ~= ""
    then
        table.insert(parts, "ownerSignature="
            .. tostring(filter.owner_signature))
    end
    if filter.ability ~= nil and tostring(filter.ability) ~= "" then
        table.insert(parts, "ability=" .. tostring(filter.ability))
    end
    if filter.ability_system ~= nil
        and tostring(filter.ability_system) ~= ""
    then
        table.insert(parts, "abilitySystem="
            .. tostring(filter.ability_system))
    end
    if filter.owner_actor ~= nil and tostring(filter.owner_actor) ~= "" then
        table.insert(parts, "ownerActor=" .. tostring(filter.owner_actor))
    end
    if filter.avatar_actor ~= nil and tostring(filter.avatar_actor) ~= "" then
        table.insert(parts, "avatarActor=" .. tostring(filter.avatar_actor))
    end
    if filter.avatar ~= nil and tostring(filter.avatar) ~= "" then
        table.insert(parts, "avatar=" .. tostring(filter.avatar))
    end
    if filter.avatar_call ~= nil and tostring(filter.avatar_call) ~= "" then
        table.insert(parts, "avatarCall=" .. tostring(filter.avatar_call))
    end
    if filter.task_avatar ~= nil and tostring(filter.task_avatar) ~= "" then
        table.insert(parts, "taskAvatar=" .. tostring(filter.task_avatar))
    end
    if filter.task_avatar_call ~= nil
        and tostring(filter.task_avatar_call) ~= ""
    then
        table.insert(parts, "taskAvatarCall="
            .. tostring(filter.task_avatar_call))
    end
    if #parts == 0 then
        return ""
    end
    return " " .. table.concat(parts, " ")
end

local function movement_task_cancel_identity(entry)
    if type(entry) == "table" then
        return tostring(entry.identity or "")
    end
    return tostring(entry or "")
end

local function movement_task_ready_to_start_animation(entry)
    if type(entry) ~= "table" then
        return nil
    end
    if type(entry.ready_to_start_animation) == "boolean" then
        return entry.ready_to_start_animation
    end
    return nil
end

function core.classify_movement_task_cancel_set(identities)
    local path_count = 0
    local non_path_count = 0
    local path_not_ready_count = 0
    for _, entry in ipairs(identities or {}) do
        local identity = movement_task_cancel_identity(entry)
        if core.movement_task_is_cancelable(identity) then
            path_count = path_count + 1
            if movement_task_ready_to_start_animation(entry) == false then
                path_not_ready_count = path_not_ready_count + 1
            end
        elseif core.movement_task_tracking_priority(identity) > 0 then
            non_path_count = non_path_count + 1
        end
    end
    if non_path_count > 0 and path_not_ready_count <= 0 then
        return {
            allowed = false,
            reason = "non-path task active",
            path_count = path_count,
            non_path_count = non_path_count,
            path_not_ready_count = path_not_ready_count,
        }
    end
    if path_count <= 0 then
        return {
            allowed = false,
            reason = "no path task",
            path_count = path_count,
            non_path_count = non_path_count,
            path_not_ready_count = path_not_ready_count,
        }
    end
    if non_path_count > 0 then
        return {
            allowed = true,
            reason = "path task still moving",
            path_count = path_count,
            non_path_count = non_path_count,
            path_not_ready_count = path_not_ready_count,
        }
    end
    return {
        allowed = true,
        reason = "path task active",
        path_count = path_count,
        non_path_count = non_path_count,
        path_not_ready_count = path_not_ready_count,
    }
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
    if preferred_mode == "self" then
        return { "self", "call" }
    end
    return { "call", "self" }
end

return core
