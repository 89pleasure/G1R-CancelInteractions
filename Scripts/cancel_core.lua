local core = {}

local DEFAULT_CANCEL_KEYS = { "F", "ESCAPE", "A", "W", "S", "D" }

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
end

function core.classify_movement_interaction_cancel(state)
    state = state or {}
    if not core.is_movement_cancel_key(state.key_name) then
        return { allowed = false, reason = "not movement key" }
    end
    if state.interaction_cancel_lockout == true then
        return { allowed = false, reason = "interaction cancel cooldown" }
    end
    local safety = core.classify_cancel_safety(state)
    if safety.allowed ~= true then
        return safety
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
    if tonumber(state.movement_action) == 7 then
        return { allowed = true, reason = "crafting active" }
    end
    return { allowed = false, reason = "crafting idle" }
end

function core.crafting_cancel_method_names()
    return {
        "K2_CancelAbility",
        "K2_EndAbility",
        "ButtonCraftingMenuExit_Bind",
        "OnCraftFinished",
    }
end

function core.interaction_cancel_method_names()
    return {
        "RequestEndAnyOngoingInteraction",
        "EndAnyOngoingInteraction",
        "TryEndInteraction",
        "StopInteractingWith",
        "EndState_Cancel",
        "CancelAllCurrentActionsAndMovement",
        "EndTask",
    }
end

function core.interaction_tracking_from_hook(hook_name)
    local normalized = tostring(hook_name or "")
    if string.find(normalized, "AbilityTask_InteractWith:", 1, true) ~= nil then
        return { track = true, kind = "use-object", phase = "move" }
    end
    if string.find(normalized, "AbilityTask_InteractionSpot_Montage:", 1, true) ~= nil then
        return { track = true, kind = "ambient", phase = "animation" }
    end
    return { track = false, kind = "none", phase = "idle" }
end

function core.reflected_call_modes(preferred_mode)
    if preferred_mode == "self" then
        return { "self", "call", "bare" }
    end
    if preferred_mode == "bare" then
        return { "bare", "call", "self" }
    end
    return { "call", "self", "bare" }
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
        "/Script/G1R.AbilityTask_EndEquip:DoEndEquip",
        "/Script/G1R.AbilityTask_DrawWeapon:TaskDrawTorch",
        "/Script/Engine.PlayerController:ClientRestart",
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
        "AbilityTask_InteractionSpot_Montage",
        "UAbilityTask_InteractionSpot_Montage",
        "GameplayAbilityCrafting",
        "UGameplayAbilityCrafting",
        "AbilityTask_CraftItems",
        "UAbilityTask_CraftItems",
    }
end

function core.runtime_instance_scan_match_terms()
    return {
        "cook",
        "pan",
        "cauldron",
        "craft",
    }
end

return core
