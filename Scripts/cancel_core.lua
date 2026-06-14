local core = {}

local DEFAULT_CANCEL_KEYS = { "F", "ESCAPE", "A", "W", "S", "D" }
local MOVEMENT_ACTION_INTERACT = 7
local MOVEMENT_ACTION_INTERACTION = 8

local function default_cancel_keys()
    local keys = {}
    for index, key in ipairs(DEFAULT_CANCEL_KEYS) do
        keys[index] = key
    end
    return keys
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

local function upper(value)
    return string.upper(trim(value))
end

local function bool_from_string(value, default_value)
    local normalized = upper(value)
    if normalized == "" then
        return default_value
    end
    if normalized == "1" or normalized == "TRUE" or normalized == "YES" or normalized == "ON" then
        return true
    end
    if normalized == "0" or normalized == "FALSE" or normalized == "NO" or normalized == "OFF" then
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
        if stripped ~= "" and stripped:sub(1, 1) ~= ";" and stripped:sub(1, 1) ~= "#" then
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
        return default_cancel_keys()
    end
    return keys
end

function core.config_from_ini(ini)
    ini = ini or {}
    return {
        debug = bool_from_string(ini.DEBUG, false),
        discovery_mode = bool_from_string(ini.DISCOVERYMODE, false),
        cancel_keys = core.parse_cancel_keys(ini.CANCELKEYS),
        cooldown_ms = number_from_string(ini.COOLDOWNMS, 250, 0),
        allow_montage_fallback = bool_from_string(ini.ALLOWMONTAGEFALLBACK, false),
        runtime_function_scan = bool_from_string(ini.RUNTIMEFUNCTIONSCAN, false),
        runtime_function_scan_limit = number_from_string(ini.RUNTIMEFUNCTIONSCANLIMIT, 80, 1),
    }
end

function core.startup_runtime_scan_allowed(config)
    config = config or {}
    return config.discovery_mode == true and config.runtime_function_scan == true
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
    local readiness_poll = tostring(state.source or "") == "GothicCharacter:BP_IsGameplayReady"
    local changed = next_identity ~= "" and previous_identity ~= next_identity

    return {
        changed = changed,
        refresh_runtime_refs = changed or not readiness_poll,
        should_log = changed or not readiness_poll,
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
    if state.menu_open == true then
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
        or key == "F" or key == "ESCAPE"
end

function core.is_directional_movement_key(key_name)
    local key = upper(key_name)
    return key == "A" or key == "W" or key == "S" or key == "D"
end

function core.cancel_hotkey_should_enter_game_thread(state)
    state = state or {}
    if not core.is_directional_movement_key(state.key_name) then
        return true
    end
    return state.interaction_active == true
        or state.movement_cancel_armed == true
end

function core.movement_action_is_interaction_active(movement_action)
    local action = tonumber(movement_action)
    return action == MOVEMENT_ACTION_INTERACT
        or action == MOVEMENT_ACTION_INTERACTION
end

function core.classify_movement_interaction_cancel(state)
    state = state or {}
    if not core.is_movement_cancel_key(state.key_name) then
        return { allowed = false, reason = "not movement key" }
    end
    if state.interaction_cancel_lockout == true then
        return { allowed = false, reason = "interaction cancel cooldown" }
    end
    local sleep_movement_active = state.sleep_movement_active == true
    if not core.movement_action_is_interaction_active(state.movement_action)
        and not sleep_movement_active
    then
        return { allowed = false, reason = "movement action inactive" }
    end
    local effective_state = {}
    for key, value in pairs(state) do
        effective_state[key] = value
    end
    local movement_action_only = effective_state.interaction_active ~= true
    if movement_action_only then
        effective_state.interaction_active = true
        effective_state.interaction_kind = "ambient"
    end
    local safety = core.classify_cancel_safety(effective_state)
    if safety.allowed ~= true then
        return safety
    end
    if movement_action_only and upper(state.key_name) == "F" and not sleep_movement_active then
        return { allowed = false, reason = "action key movement-only start" }
    end
    if movement_action_only then
        return { allowed = true, reason = "movement action interaction active" }
    end
    if sleep_movement_active then
        return { allowed = true, reason = "sleep movement interaction active" }
    end
    return { allowed = true, reason = "movement interaction active" }
end

function core.classify_crafting_cancel(state)
    state = state or {}
    if state.player_ready ~= true then
        return { allowed = false, reason = "player not ready" }
    end
    if state.crafting_recent ~= true then
        return { allowed = false, reason = "no active crafting" }
    end
    if state.crafting_cancel_lockout == true then
        return { allowed = false, reason = "crafting cancel cooldown" }
    end
    local crafting_state = tonumber(state.crafting_state)
    if crafting_state == 8 then
        return { allowed = false, reason = "crafting finished" }
    end
    if state.alive == false then
        return { allowed = false, reason = "player not alive" }
    end
    if state.airborne == true then
        return { allowed = false, reason = "airborne" }
    end
    if state.combat_or_finisher == true then
        return { allowed = false, reason = "combat or finisher" }
    end
    if crafting_state ~= 0 then
        return { allowed = false, reason = "crafting action started" }
    end
    if tonumber(state.movement_action) == MOVEMENT_ACTION_INTERACT then
        return { allowed = true, reason = "crafting active" }
    end
    return { allowed = false, reason = "crafting idle" }
end

function core.crafting_hook_should_clear_tracking(source, crafting_state)
    local normalized = string.lower(tostring(source or ""))
    if string.find(normalized, "buttoncraftingmenuexit_bind", 1, true) ~= nil
        or string.find(normalized, "oncraftfinished", 1, true) ~= nil
    then
        return true
    end

    local state = tonumber(crafting_state)
    if state == nil then
        return false
    end
    return string.find(normalized, "setcraftingstate", 1, true) ~= nil
        and state >= 6
end

function core.crafting_hook_should_track_after_cancel(now_ms, last_cancel_ms, lockout_ms)
    local now_value = tonumber(now_ms) or 0
    local last_value = tonumber(last_cancel_ms) or -1000000
    local lockout_value = tonumber(lockout_ms) or 0
    return now_value - last_value >= lockout_value
end

function core.crafting_interaction_fallback_after_attempt(context)
    context = context or {}
    if context.movement_action_active ~= true then
        return false
    end
    return context.crafting_cancelled ~= true
        and context.crafting_recent == true
end

function core.crafting_cancel_method_names()
    return {
        "CancelCrafting",
        "ButtonCraftingMenuExit_Bind",
    }
end

function core.crafting_move_task_property_names()
    return {
        "m_TaskMoveTo",
        "TaskMoveTo",
    }
end

function core.crafting_move_task_cancel_method_names()
    return {
        "EndTaskAsCancelled",
        "EndTaskWithResult",
        "BP_ExternalCancel",
    }
end

function core.crafting_montage_task_property_names()
    return {
        "m_CharMontageTask",
        "CharMontageTask",
    }
end

function core.crafting_montage_task_cancel_method_names()
    return {
        "StopPlayingMontage",
        "EndTask",
    }
end

function core.crafting_menu_exit_state_candidates()
    return {
        8, -- EUICraftingStates::ExitDefault
        9, -- EUICraftingStates::ExitInProgress
    }
end

function core.interaction_cancel_method_names()
    return {
        "OnRequestEndQuick",
        "OnRequestEndNormal",
        "K2_CancelAbility",
        "K2_EndAbility",
        "EndTask",
        "EndTaskAsCancelled",
        "BP_ExternalCancel",
    }
end

function core.movement_action_cancel_method_names()
    return {
        "OnRequestEndQuick",
        "OnRequestEndNormal",
    }
end

function core.movement_action_task_cancel_method_names()
    return {}
end

function core.movement_action_task_class_names()
    return {}
end

function core.interaction_input_ability_class_paths()
    return {}
end

local function identity_path(identity)
    local value = trim(identity)
    local path = value:match("%s(/.+)$")
    return path or value
end

function core.object_name_belongs_to_owner(object_name, owner_identity)
    local object_text = tostring(object_name or "")
    local owner_path = identity_path(owner_identity)
    if owner_path == "" then
        return false
    end
    return string.find(object_text, owner_path, 1, true) ~= nil
end

function core.object_name_is_sleep_bed_ability(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return string.find(normalized, "sleep", 1, true) ~= nil
        and string.find(normalized, "bed", 1, true) ~= nil
end

function core.object_name_is_sleep_ability(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return core.object_name_is_sleep_bed_ability(normalized)
        or string.find(normalized, "gameplayabilitysleep", 1, true) ~= nil
end

function core.object_name_is_container_ability(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return string.find(normalized, "opencontainer", 1, true) ~= nil
        or string.find(normalized, "open_container", 1, true) ~= nil
        or (string.find(normalized, "container", 1, true) ~= nil
            and (string.find(normalized, "gameplayability", 1, true) ~= nil
                or string.find(normalized, "ga_", 1, true) ~= nil))
end

function core.text_is_container_interaction_context(text)
    local normalized = string.lower(tostring(text or ""))
    if normalized == "" then
        return false
    end
    return string.find(normalized, "interactive_chest", 1, true) ~= nil
        or string.find(normalized, "lootcontainer_chest", 1, true) ~= nil
        or string.find(normalized, "uiochest", 1, true) ~= nil
        or string.find(normalized, "chest", 1, true) ~= nil
        or string.find(normalized, "opencontainer", 1, true) ~= nil
        or string.find(normalized, "open_container", 1, true) ~= nil
        or string.find(normalized, "open.container", 1, true) ~= nil
        or string.find(normalized, "interact.container", 1, true) ~= nil
        or string.find(normalized, "interact.open.container", 1, true) ~= nil
        or string.find(normalized, "state.interact.container", 1, true) ~= nil
        or string.find(normalized, "abilitytask_interaction_player_opencontainer", 1, true)
            ~= nil
end

function core.text_is_ladder_interaction_context(text)
    local normalized = string.lower(tostring(text or ""))
    if normalized == "" then
        return false
    end
    return string.find(normalized, "ladder", 1, true) ~= nil
        or string.find(normalized, "navlink", 1, true) ~= nil
        or string.find(normalized, "traverse", 1, true) ~= nil
        or string.find(normalized, "wallclimb", 1, true) ~= nil
        or string.find(normalized, "wall_climb", 1, true) ~= nil
end

function core.text_is_seating_interaction_context(text)
    local normalized = string.lower(tostring(text or ""))
    if normalized == "" then
        return false
    end
    return string.find(normalized, "sit", 1, true) ~= nil
        or string.find(normalized, "bench", 1, true) ~= nil
        or string.find(normalized, "chair", 1, true) ~= nil
        or string.find(normalized, "stool", 1, true) ~= nil
end

function core.text_is_sleep_interaction_context(text)
    local normalized = string.lower(tostring(text or ""))
    if normalized == "" then
        return false
    end
    return string.find(normalized, "gameplayabilitysleep", 1, true) ~= nil
        or string.find(normalized, "sitandsleep", 1, true) ~= nil
        or string.find(normalized, "interact.sleep", 1, true) ~= nil
        or (string.find(normalized, "sleep", 1, true) ~= nil
            and string.find(normalized, "bed", 1, true) ~= nil)
end

function core.ladder_free_point_context_should_be_read(state)
    state = state or {}
    return core.text_is_seating_interaction_context(state.tracked_target) ~= true
        and core.text_is_seating_interaction_context(state.tracked_source) ~= true
end

function core.object_name_can_use_gameplay_ability_method(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return string.find(normalized, "gameplayability", 1, true) ~= nil
        or string.find(normalized, "ga_", 1, true) ~= nil
end

function core.object_name_is_sleep_interaction_task(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return string.find(normalized, "abilitytask_interaction", 1, true) ~= nil
        and string.find(normalized, "sleep", 1, true) ~= nil
end

function core.object_name_is_player_sleep_interaction_task(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return string.find(normalized, "abilitytask_interaction_player", 1, true) ~= nil
        and string.find(normalized, "sleep", 1, true) ~= nil
end

function core.interaction_cancel_should_continue_after_success(object_name, state)
    state = state or {}
    local normalized = string.lower(tostring(object_name or ""))
    if state.sleep_task_cancelled == true
        and string.find(normalized, "gameplayabilityinteractfreepoint", 1, true) ~= nil
    then
        return false
    end
    if core.object_name_is_sleep_bed_ability(normalized)
        or core.object_name_is_sleep_interaction_task(normalized)
    then
        return true
    end
    return state.sleep_interaction_context == true
        and string.find(normalized, "gameplayabilityinteractfreepoint", 1, true) ~= nil
end

function core.interaction_success_should_trigger_container_secondary_cancel(object_name, state)
    return false
end

function core.container_ability_fallback_allowed(context)
    return false
end

function core.container_ability_context_can_cancel(context)
    return false
end

function core.interaction_container_context_should_block(context)
    context = context or {}
    return core.text_is_container_interaction_context(context.tracked_source)
        or core.text_is_container_interaction_context(context.tracked_target)
        or core.text_is_container_interaction_context(context.free_point_context)
        or core.object_name_is_container_ability(context.tracked_object)
end

function core.sleep_interaction_task_should_cleanup_ability(context)
    context = context or {}
    return context.explicit_sleep_context == true
end

function core.interaction_task_cancel_method_names()
    return {
        "EndTask",
        "EndTaskAsCancelled",
        "BP_ExternalCancel",
    }
end

function core.interaction_sleep_ability_cancel_method_names()
    return {
        "K2_CancelAbility",
        "K2_EndAbility",
    }
end

function core.interaction_container_ability_cancel_method_names()
    return {}
end

function core.sleep_montage_cancel_method_names()
    return {
        "StopAnimMontage",
        "Montage_Stop",
    }
end

function core.sleep_interaction_task_cancel_method_names()
    return {
        "EndTask",
    }
end

function core.container_interaction_task_cancel_method_names()
    return {}
end

function core.sleep_root_task_cancel_method_names()
    return {
        "EndTask",
        "EndTaskAsCancelled",
        "BP_ExternalCancel",
    }
end

function core.sleep_movement_tracking_from_hook(hook_name)
    return tostring(hook_name or "")
        == "/Script/G1R.GameplayAbilitySleep:OnActivateAbility_Scriptable"
end

function core.sleep_movement_should_try_ability_cancel(context)
    context = context or {}
    return context.root_task_success ~= true
end

function core.sleep_task_cancel_should_try_montage(context)
    context = context or {}
    return context.task_success ~= true
end

function core.sleep_task_scan_candidate_allowed(context)
    context = context or {}
    if context.tracked_task == true then
        return true
    end
    return context.task_cancelled_before ~= true
end

function core.sleep_task_cancel_context_allowed(context)
    context = context or {}
    if context.tracked_phase == "sleep-task"
        or context.tracked_phase == "sleep-move"
    then
        return true
    end
    if core.object_name_is_sleep_ability(context.tracked_object)
        or core.object_name_is_player_sleep_interaction_task(context.tracked_object)
    then
        return true
    end
    if tonumber(context.player_sleep_task_candidates or 0) > 0 then
        return true
    end
    return core.text_is_sleep_interaction_context(context.tracked_source)
        or core.text_is_sleep_interaction_context(context.tracked_target)
        or core.text_is_sleep_interaction_context(context.free_point_context)
end

function core.interaction_tracking_from_hook(hook_name)
    local normalized = tostring(hook_name or "")
    local lower = string.lower(normalized)
    if string.find(normalized, "AbilityTask_InteractWith:", 1, true) ~= nil then
        return { track = true, kind = "use-object", phase = "move" }
    end
    if string.find(normalized, "AbilityTask_InteractionSpot_Montage:", 1, true) ~= nil then
        return { track = true, kind = "ambient", phase = "animation" }
    end
    if string.find(normalized, "GameplayAbilityInteractFreePoint:K2_ActivateAbility",
            1, true) ~= nil
    then
        return { track = true, kind = "ambient", phase = "ability" }
    end
    return { track = false, kind = "none", phase = "idle" }
end

function core.interaction_tracking_from_montage_name(montage_name)
    local normalized = string.lower(tostring(montage_name or ""))
    if normalized == "" then
        return { track = false, kind = "none", phase = "idle" }
    end
    if (string.find(normalized, "sit", 1, true) ~= nil
            or string.find(normalized, "bench", 1, true) ~= nil
            or string.find(normalized, "chair", 1, true) ~= nil
            or string.find(normalized, "stool", 1, true) ~= nil
            or core.object_name_is_sleep_bed_ability(normalized))
        and string.find(normalized, "cook", 1, true) == nil
    then
        return { track = true, kind = "ambient", phase = "animation" }
    end
    return { track = false, kind = "none", phase = "idle" }
end

function core.reflected_call_modes(preferred_mode)
    if preferred_mode == "self" then
        return { "self", "call" }
    end
    return { "call", "self" }
end

function core.discovery_hook_candidates()
    return {
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
end

function core.runtime_instance_scan_classes()
    return {
        "AbilityTask_Interaction_Human_Cook_Pan",
        "UAbilityTask_Interaction_Human_Cook_Pan",
        "AbilityTask_Interaction_Player_Cook_Cauldron",
        "UAbilityTask_Interaction_Player_Cook_Cauldron",
        "AbilityTask_Interaction_Human_Cook_Cauldron",
        "UAbilityTask_Interaction_Human_Cook_Cauldron",
        "AbilityTask_Interaction_Woman_Cook_Pan",
        "UAbilityTask_Interaction_Woman_Cook_Pan",
        "AbilityTask_Interaction_Player_SitAndSleep",
        "UAbilityTask_Interaction_Player_SitAndSleep",
        "AbilityTask_InteractionSpot_Montage",
        "UAbilityTask_InteractionSpot_Montage",
        "GameplayAbilityCrafting",
        "UGameplayAbilityCrafting",
        "GameplayAbilitySleep",
        "UGameplayAbilitySleep",
        "GA_Human_Sleep_Bed_Low",
        "GA_Human_Sleep_Bed_High",
        "GameplayAbilityInteractFreePoint",
        "UGameplayAbilityInteractFreePoint",
        "GameplayAbilityInteract",
        "UGameplayAbilityInteract",
        "GameplayAbilityInteractionBase",
        "UGameplayAbilityInteractionBase",
        "AbilityTask_CraftItems",
        "UAbilityTask_CraftItems",
    }
end

function core.runtime_instance_scan_match_terms()
    return {
        "interact",
        "freepoint",
        "sleep",
        "bed",
        "sit",
        "chair",
        "bench",
        "cook",
        "pan",
        "cauldron",
        "craft",
    }
end

return core
