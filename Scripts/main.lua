local MOD_NAME = "[G1R_CancelInteraction]"
local VERSION = "0.2.45"
local CONFIG_FILE_NAME = "G1R_CancelInteraction.ini"

local core = require("cancel_core")
local UEHelpers = nil
pcall(function()
    UEHelpers = require("UEHelpers")
end)

local config = core.config_from_ini({})
local hotkey_runtime_enabled = false
local hotkey_game_thread_busy = false
local last_hotkey_ms = -1000000
local movement_cancel_armed_until_ms = -1000000
local last_successful_crafting_cancel_ms = -1000000
local last_successful_interaction_cancel_ms = -1000000
local last_runtime_instance_scan_ms = -1000000
local cached_hero = nil
local cached_hero_identity = ""
local cached_inventory = nil
local cached_carry_component = nil
local cached_player_controller = nil
local cached_anim_instance = nil
local cached_sleep_bed_ability = nil
local cached_sleep_bed_owner_identity = ""
local cached_container_ability = nil
local cached_container_owner_identity = ""
local cached_interact_free_point_ability = nil
local cached_interact_free_point_owner_identity = ""
local tracked_crafting = {
    ability = nil,
    state = nil,
    source = "",
    last_seen_ms = -1000000,
}
local tracked_interaction = {
    active = false,
    object = nil,
    kind = "none",
    source = "",
    target = "",
    phase = "idle",
    started_at_ms = 0,
}
local reflected_function_cache = {}
local reflected_function_path_cache = {}
local reflected_function_mode_cache = {}
local reflected_method_paths = {
    K2_CancelAbility = {
        "/Script/GameplayAbilities.GameplayAbility:K2_CancelAbility",
    },
    K2_EndAbility = {
        "/Script/GameplayAbilities.GameplayAbility:K2_EndAbility",
    },
    OnSleepUICloseButtonClicked = {
        "/Script/G1R.GameplayAbilitySleep:OnSleepUICloseButtonClicked",
    },
    Server_OnSleepUICloseButtonClicked = {
        "/Script/G1R.GameplayAbilitySleep:Server_OnSleepUICloseButtonClicked",
    },
    Client_StopAllMagicAbilitiesMontages = {
        "/Script/G1R.GameplayAbilitySleep:Client_StopAllMagicAbilitiesMontages",
    },
    ButtonCraftingMenuExit_Bind = {
        "/Script/G1R.GameplayAbilityCrafting:ButtonCraftingMenuExit_Bind",
    },
    OnCraftFinished = { "/Script/G1R.GameplayAbilityCrafting:OnCraftFinished" },
    RequestEndAnyOngoingInteraction = {
        "/Script/G1R.GothicCharacter:RequestEndAnyOngoingInteraction",
        "/Script/G1R.GothicPlayerCharacter:RequestEndAnyOngoingInteraction",
    },
    EndAnyOngoingInteraction = {
        "/Script/G1R.GothicCharacter:EndAnyOngoingInteraction",
        "/Script/G1R.GothicPlayerCharacter:EndAnyOngoingInteraction",
    },
    TryEndInteraction = {
        "/Script/G1R.GothicCharacter:TryEndInteraction",
        "/Script/G1R.GothicPlayerCharacter:TryEndInteraction",
    },
    StopInteractingWith = {
        "/Script/G1R.AbilityTask_InteractWith:StopInteractingWith",
        "/Script/G1R.AbilityTask_InteractionSpot_Montage:StopInteractingWith",
    },
    EndState_Cancel = {
        "/Script/G1R.AbilityTask_InteractWith:EndState_Cancel",
        "/Script/G1R.AbilityTask_InteractionSpot_Montage:EndState_Cancel",
    },
    TransitionExit = {
        "/Script/G1R.AbilityTask_InteractionSpot_Montage:TransitionExit",
    },
    TransitionAfterMontageEnds = {
        "/Script/G1R.AbilityTask_InteractionSpot_Montage:TransitionAfterMontageEnds",
    },
    EndTaskAsCancelled = {
        "/Script/G1R.AbilityTask_InteractionSpot_Montage:EndTaskAsCancelled",
    },
    BP_ExternalCancel = {
        "/Script/GameplayAbilities.AbilityTask:BP_ExternalCancel",
    },
    CancelAllCurrentActionsAndMovement = {
        "/Script/G1R.GothicCharacter:CancelAllCurrentActionsAndMovement",
        "/Script/G1R.GothicPlayerCharacter:CancelAllCurrentActionsAndMovement",
    },
    StopAnimMontage = { "/Script/Engine.Character:StopAnimMontage" },
    Montage_Stop = { "/Script/Engine.AnimInstance:Montage_Stop" },
    EndTask = { "/Script/GameplayTasks.GameplayTask:EndTask" },
}

local RUNTIME_INSTANCE_SCAN_COOLDOWN_MS = 750
local MOVEMENT_CANCEL_ARM_MS = 4000
local CRAFTING_ACTIVITY_TIMEOUT_MS = 15000
local CRAFTING_CANCEL_LOCKOUT_MS = 2000
local INTERACTION_ACTIVITY_TIMEOUT_MS = 10000
local INTERACTION_CANCEL_LOCKOUT_MS = 1000

local function log(message)
    print(string.format("%s %s\n", MOD_NAME, tostring(message)))
end

local function debug_log(message)
    if config.debug then
        log("[debug] " .. tostring(message))
    end
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function script_directory()
    local ok, info = pcall(function()
        return debug.getinfo(1, "S")
    end)
    if not ok or not info or not info.source then
        return nil
    end
    local source = tostring(info.source)
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*[\\/])[^\\/]*$")
end

local function read_text_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function config_candidate_paths()
    local paths = {}
    local dir = script_directory()
    if dir then
        table.insert(paths, dir .. "..\\" .. CONFIG_FILE_NAME)
        table.insert(paths, dir .. CONFIG_FILE_NAME)
    end
    table.insert(paths, "Mods\\G1R_CancelInteraction\\" .. CONFIG_FILE_NAME)
    table.insert(paths, "ue4ss\\Mods\\G1R_CancelInteraction\\" .. CONFIG_FILE_NAME)
    table.insert(paths, CONFIG_FILE_NAME)
    return paths
end

local function load_config()
    for _, path in ipairs(config_candidate_paths()) do
        local content = read_text_file(path)
        if content then
            config = core.config_from_ini(core.parse_ini(content))
            log("Loaded config from " .. tostring(path)
                .. ": DiscoveryMode=" .. tostring(config.discovery_mode)
                .. " Debug=" .. tostring(config.debug)
                .. " CancelKeys=" .. table.concat(config.cancel_keys, ",")
                .. " CooldownMs=" .. tostring(config.cooldown_ms)
                .. " AllowMontageFallback=" .. tostring(config.allow_montage_fallback)
                .. " RuntimeFunctionScan=" .. tostring(config.runtime_function_scan)
                .. " RuntimeFunctionScanLimit=" .. tostring(config.runtime_function_scan_limit))
            return
        end
    end
    config = core.config_from_ini({})
    log("Config not found; using defaults.")
end

local function required_lua_api_available()
    local missing = {}
    local required_names = {
        "ExecuteInGameThread",
        "RegisterHook",
        "RegisterKeyBind",
        "StaticFindObject",
    }
    for _, name in ipairs(required_names) do
        if type(_G and _G[name]) ~= "function" then
            table.insert(missing, name)
        end
    end
    if #missing > 0 then
        log("Required UE4SS Lua API missing: " .. table.concat(missing, ", "))
        return false
    end
    return true
end

local function is_usable_object(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    if ok then
        return value == true
    end
    ok = pcall(function()
        local _ = object:GetFullName()
    end)
    return ok
end

local function get_full_name(object)
    if not is_usable_object(object) then
        return ""
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    if ok and value then
        return tostring(value)
    end
    ok, value = pcall(function()
        return object:GetName()
    end)
    if ok and value then
        return tostring(value)
    end
    return ""
end

local function get_param_value(param)
    if param == nil then
        return nil
    end
    local param_type = type(param)
    if param_type == "boolean" or param_type == "number" or param_type == "string" then
        return param
    end
    local ok, value = pcall(function()
        return param:get()
    end)
    if ok then return value end
    ok, value = pcall(function()
        return param:Get()
    end)
    if ok then return value end
    return param
end

local function get_param_object(param)
    local value = get_param_value(param)
    if is_usable_object(value) then
        return value
    end
    return nil
end

local function contains(haystack, needle)
    local ok, matched = pcall(function()
        local haystack_text = tostring(haystack or "")
        local needle_text = tostring(needle or "")
        if type(haystack_text) ~= "string" or type(needle_text) ~= "string" then
            return false
        end
        return string.find(string.lower(haystack_text), string.lower(needle_text), 1, true) ~= nil
    end)
    return ok and matched == true
end

local function looks_like_player_character(character)
    if not is_usable_object(character) then
        return false
    end
    local name = get_full_name(character)
    return contains(name, "PlayerCharacter")
        or contains(name, "GothicPlayerCharacter")
        or contains(name, "BP_Player")
end

local function mark_hero(hero, source)
    if not looks_like_player_character(hero) then
        return false
    end
    local hero_identity = get_full_name(hero)
    local cache_update = core.classify_cached_hero_update({
        previous_identity = cached_hero_identity,
        next_identity = hero_identity,
        source = source,
    })
    if cache_update.changed then
        cached_inventory = nil
        cached_carry_component = nil
        cached_anim_instance = nil
        cached_sleep_bed_ability = nil
        cached_sleep_bed_owner_identity = ""
        cached_container_ability = nil
        cached_container_owner_identity = ""
        cached_interact_free_point_ability = nil
        cached_interact_free_point_owner_identity = ""
    end
    cached_hero = hero
    cached_hero_identity = hero_identity
    if cache_update.refresh_runtime_refs then
        pcall(function()
            cached_anim_instance = hero.Mesh.AnimScriptInstance
        end)
    end
    if cache_update.should_log then
        debug_log("Player cached from " .. tostring(source) .. ": " .. hero_identity)
    end
    return true
end

local function mark_hero_from_context(context, source)
    local hero = get_param_object(context)
    if not hero and is_usable_object(context) then
        hero = context
    end
    return mark_hero(hero, source)
end

local function mark_inventory_from_context(context, source)
    local inventory = get_param_object(context)
    if not is_usable_object(inventory) then
        return false
    end
    local full_name = get_full_name(inventory)
    if not contains(full_name, "InventoryComponent") then
        return false
    end
    cached_inventory = inventory
    debug_log("Inventory cached from " .. tostring(source) .. ": " .. full_name)
    return true
end

local function mark_carry_from_context(context, source)
    local carry_component = get_param_object(context)
    if not carry_component and is_usable_object(context) then
        carry_component = context
    end
    if not is_usable_object(carry_component) then
        return false
    end
    local full_name = get_full_name(carry_component)
    if not contains(full_name, "CarryComponent") then
        return false
    end
    if not contains(full_name, "PlayerCharacter")
        and not contains(full_name, "GothicPlayerCharacter")
        and not contains(full_name, "BP_Player") then
        return false
    end
    cached_carry_component = carry_component
    debug_log("Carry component cached from " .. tostring(source) .. ": " .. full_name)
    return true
end

local function resolve_player_controller()
    if is_usable_object(cached_player_controller) then
        return cached_player_controller
    end
    if UEHelpers and type(UEHelpers.GetPlayerController) == "function" then
        local ok, pc = pcall(UEHelpers.GetPlayerController)
        if ok and is_usable_object(pc) then
            cached_player_controller = pc
            return pc
        end
    end
    local ok, pc = pcall(function()
        return FindFirstOf("PlayerController")
    end)
    if ok and is_usable_object(pc) then
        cached_player_controller = pc
        return pc
    end
    return nil
end

local function refresh_player_from_controller()
    local pc = resolve_player_controller()
    if not is_usable_object(pc) then
        return false
    end
    local ok, pawn = pcall(function()
        return pc.Pawn
    end)
    if ok and mark_hero(pawn, "PlayerController.Pawn") then
        return true
    end
    return false
end

local function now_ms()
    return math.floor(os.clock() * 1000)
end

local function static_find_object(name)
    local ok, object = pcall(function()
        return StaticFindObject(name)
    end)
    if ok and is_usable_object(object) then
        return object
    end
    return nil
end

local function function_exists(name)
    local dotted_name = string.gsub(name, ":([^:]+)$", ".%1")
    return static_find_object("Function " .. name)
        or static_find_object(name)
        or static_find_object("Function " .. dotted_name)
        or static_find_object(dotted_name)
end

local function register_hook(name, pre, post, required)
    local exists = function_exists(name)
    if not exists then
        local message = "Hook missing " .. tostring(name)
        if required then log(message) else debug_log(message) end
        return false
    end
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(name, pre, post)
    end)
    if ok then
        debug_log("Hook registered " .. tostring(name))
        return true, pre_id, post_id
    end
    local message = "Hook failed " .. tostring(name) .. ": " .. tostring(pre_id)
    if required then log(message) else debug_log(message) end
    return false
end

local function reflected_method_requires_gameplay_ability(method_name)
    return method_name == "K2_CancelAbility"
        or method_name == "K2_EndAbility"
end

local function find_reflected_function(object, method_name)
    local candidates = {}
    local class_name = ""
    local ok, class = pcall(function()
        return object:GetClass()
    end)
    if ok and is_usable_object(class) then
        class_name = get_full_name(class):match("^Class%s+(.+)$") or ""
        if class_name and class_name ~= "" then
            table.insert(candidates, class_name .. ":" .. method_name)
            table.insert(candidates, class_name .. "." .. method_name)
        end
    end

    local object_identity = get_full_name(object) .. " " .. tostring(class_name)
    if reflected_method_requires_gameplay_ability(method_name)
        and not core.object_name_can_use_gameplay_ability_method(object_identity)
    then
        return nil, "object is not a gameplay ability"
    end

    local cache_key = tostring(method_name) .. "|"
        .. tostring(class_name ~= "" and class_name or object_identity)
    local cached = reflected_function_cache[cache_key]
    if cached then
        return cached, reflected_function_path_cache[cache_key] or method_name
    end

    for _, path in ipairs(reflected_method_paths[method_name] or {}) do
        table.insert(candidates, path)
        local dotted_path = string.gsub(path, ":([^:]+)$", ".%1")
        table.insert(candidates, dotted_path)
    end

    for _, candidate in ipairs(candidates) do
        local found = static_find_object("Function " .. candidate)
            or static_find_object(candidate)
        if found then
            reflected_function_cache[cache_key] = found
            reflected_function_path_cache[cache_key] = candidate
            return found, candidate
        end
    end

    return nil, nil
end

local function call_reflected_function(object, method_name, args, unpack_args, previous_error)
    local ufunction, path = find_reflected_function(object, method_name)
    if not ufunction then
        return false, path or previous_error or "method not found"
    end

    local first_error = previous_error
    for _, mode in ipairs(core.reflected_call_modes(reflected_function_mode_cache[path])) do
        local ok, value = pcall(function()
            if mode == "self" then
                return ufunction(object, unpack_args(args, 1, args.n))
            end
            if mode == "bare" then
                return ufunction(unpack_args(args, 1, args.n))
            end
            return object:CallFunction(ufunction, unpack_args(args, 1, args.n))
        end)
        if ok then
            reflected_function_mode_cache[path] = mode
            return true, value, tostring(mode) .. ":" .. tostring(path)
        end
        if first_error == nil then
            first_error = value
        end
    end

    return false, first_error or "reflected call failed"
end

local function call_method(object, method_name, ...)
    if not is_usable_object(object) then
        return false, "object invalid"
    end
    if reflected_method_requires_gameplay_ability(method_name)
        and not core.object_name_can_use_gameplay_ability_method(get_full_name(object))
    then
        return false, "object is not a gameplay ability"
    end

    local args = { ... }
    args.n = select("#", ...)
    local unpack_args = table.unpack or unpack
    if not unpack_args then
        return false, "unpack unavailable"
    end

    local ok, method = pcall(function()
        return object[method_name]
    end)
    if not ok or not method then
        return call_reflected_function(object, method_name, args, unpack_args, "method not found")
    end

    local value = nil
    ok, value = pcall(function()
        return method(object, unpack_args(args, 1, args.n))
    end)
    if ok then
        return true, value, "direct-self"
    end
    local first_error = value

    ok, value = pcall(function()
        return method(unpack_args(args, 1, args.n))
    end)
    if ok then
        return true, value, "direct"
    end

    return call_reflected_function(object, method_name, args, unpack_args, first_error or value)
end

local runtime_scan_terms = {
    "AbilityTask_Interaction_Human_Cook_Pan",
    "AbilityTask_Interaction_Player_Cook_Cauldron",
    "AbilityTask_Interaction_Human_Cook_Cauldron",
    "AbilityTask_InteractionSpot_Montage",
    "AbilityTask_CraftItems",
    "BeginInteractionWithoutSpot",
    "CancelAbilitiesWithTag",
    "CancelAllCurrentActionsAndMovement",
    "CancelTasksOfClass",
    "EndAnyOngoingInteraction",
    "EndState_Cancel",
    "RequestEndAnyOngoingInteraction",
    "StartInteractingWith",
    "StopInteractingWith",
    "TryEndInteraction",
    "TryInteractionWithoutSpot",
    "GameplayAbilityCrafting",
    "AllowInstantCancelInteractions",
    "bAllowInterruptAtAnyTime",
    "bAllowInterruptLoopOnCancel",
    "m_IsDoingInteractAction",
    "State_Interact",
    "Action_Crafting_Cook_Pan",
    "Action_Crafting_Cook_Cauldron",
    "Action_Ambient_Cook_Cauldron",
}

local function runtime_scan_matches(full_name)
    for _, term in ipairs(runtime_scan_terms) do
        if contains(full_name, term) then
            return true
        end
    end
    return false
end

local function scan_runtime_objects(kind, limit)
    local ok, objects = pcall(function()
        return FindAllOf(kind)
    end)
    if not ok then
        log("[runtime-scan] " .. tostring(kind) .. " failed: " .. tostring(objects))
        return 0
    end
    if type(objects) ~= "table" then
        log("[runtime-scan] " .. tostring(kind) .. " returned " .. tostring(type(objects)))
        return 0
    end

    local matches = 0
    local logged = 0
    for _, object in ipairs(objects) do
        local full_name = get_full_name(object)
        if runtime_scan_matches(full_name) then
            matches = matches + 1
            if logged < limit then
                logged = logged + 1
                log("[runtime-scan] " .. tostring(kind) .. " " .. tostring(logged)
                    .. " " .. full_name)
            end
        end
    end
    log("[runtime-scan] " .. tostring(kind) .. " matches=" .. tostring(matches)
        .. " logged=" .. tostring(logged))
    return matches
end

local function run_runtime_function_scan()
    if core.startup_runtime_scan_allowed(config) ~= true then
        return
    end
    if type(FindAllOf) ~= "function" then
        log("[runtime-scan] FindAllOf is unavailable.")
        return
    end
    local limit = tonumber(config.runtime_function_scan_limit) or 80
    log("[runtime-scan] Starting targeted Class/Function scan.")
    scan_runtime_objects("Class", limit)
    scan_runtime_objects("Function", limit)
end

local function param_to_log_string(param)
    local value = get_param_value(param)
    if value == nil then
        return ""
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if is_usable_object(value) then
        return get_full_name(value)
    end
    return "<" .. value_type .. ">"
end

local function value_to_context_text(value)
    value = get_param_value(value)
    if value == nil then
        return ""
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if is_usable_object(value) then
        return get_full_name(value)
    end

    local ok, method = pcall(function()
        return value.ToString
    end)
    if ok and method then
        local method_ok, text = pcall(function()
            return method(value)
        end)
        if method_ok and text then
            return tostring(text)
        end
        method_ok, text = pcall(function()
            return method()
        end)
        if method_ok and text then
            return tostring(text)
        end
    end

    ok, method = pcall(function()
        return value.GetDebugString
    end)
    if ok and method then
        local method_ok, text = pcall(function()
            return method(value)
        end)
        if method_ok and text then
            return tostring(text)
        end
    end

    local text_ok, text = pcall(function()
        return tostring(value)
    end)
    if text_ok and text then
        return tostring(text)
    end
    return "<" .. value_type .. ">"
end

local function object_property_context_text(object, property_names)
    if not is_usable_object(object) then
        return ""
    end
    local parts = {}
    for _, property_name in ipairs(property_names) do
        local ok, value = pcall(function()
            return object[property_name]
        end)
        if ok and value ~= nil then
            local text = value_to_context_text(value)
            if text ~= "" then
                table.insert(parts, tostring(property_name) .. "=" .. text)
            end
        end
    end
    return table.concat(parts, " ")
end

local function object_bool_property(object, property_name)
    if not is_usable_object(object) then
        return nil
    end
    local ok, value = pcall(function()
        return object[property_name]
    end)
    if not ok then
        return nil
    end
    if type(value) == "boolean" then
        return value
    end
    local text = string.lower(tostring(value or ""))
    if text == "true" then
        return true
    end
    if text == "false" then
        return false
    end
    return nil
end

local function read_number(description, reader)
    local ok, value = pcall(reader)
    if not ok then
        return nil
    end
    local number = tonumber(tostring(value or ""))
    if number == nil then
        debug_log("State read returned non-number for "
            .. tostring(description) .. ": " .. tostring(value))
    end
    return number
end

local function locomotion_snapshot()
    local snapshot = {
        rotation_mode = nil,
        movement_state = nil,
        movement_action = nil,
        requested_movement_action = nil,
        anim_is_in_combat = nil,
        anim_is_alive = nil,
        anim_is_conversation = nil,
        anim_is_cinematic = nil,
    }
    if is_usable_object(cached_hero) then
        snapshot.rotation_mode = read_number("hero.m_DataModule_Locomotion.m_RotationMode",
            function()
                return cached_hero.m_DataModule_Locomotion.m_RotationMode
            end)
        snapshot.movement_state = read_number("hero.m_DataModule_Locomotion.m_MovementState",
            function()
                return cached_hero.m_DataModule_Locomotion.m_MovementState
            end)
        snapshot.movement_action = read_number("hero.m_DataModule_Locomotion.m_MovementAction",
            function()
                return cached_hero.m_DataModule_Locomotion.m_MovementAction
            end)
        snapshot.requested_movement_action = read_number(
            "hero.m_DataModule_Locomotion.m_RequestedMovementAction",
            function()
                return cached_hero.m_DataModule_Locomotion.m_RequestedMovementAction
            end)
    end
    if is_usable_object(cached_anim_instance) then
        pcall(function() snapshot.anim_is_in_combat = cached_anim_instance.m_IsInCombat end)
        pcall(function() snapshot.anim_is_alive = cached_anim_instance.m_IsAlive end)
        pcall(function() snapshot.anim_is_conversation = cached_anim_instance.bIsInConversation end)
        pcall(function() snapshot.anim_is_cinematic = cached_anim_instance.bIsInCinematic end)
    end
    return snapshot
end

local function format_snapshot(snapshot)
    return "rotationMode=" .. tostring(snapshot.rotation_mode)
        .. " movementState=" .. tostring(snapshot.movement_state)
        .. " movementAction=" .. tostring(snapshot.movement_action)
        .. " requestedMovementAction=" .. tostring(snapshot.requested_movement_action)
        .. " animCombat=" .. tostring(snapshot.anim_is_in_combat)
        .. " animAlive=" .. tostring(snapshot.anim_is_alive)
        .. " animConversation=" .. tostring(snapshot.anim_is_conversation)
        .. " animCinematic=" .. tostring(snapshot.anim_is_cinematic)
end

local function get_class_full_name(object)
    if not is_usable_object(object) then
        return ""
    end
    local ok, class = pcall(function()
        return object:GetClass()
    end)
    if ok and is_usable_object(class) then
        return get_full_name(class)
    end
    return ""
end

local function object_identity_text(object)
    return get_full_name(object) .. " " .. get_class_full_name(object)
end

local function matches_runtime_instance_scan_terms(object_name, class_name)
    local haystack = string.lower(tostring(object_name) .. " " .. tostring(class_name))
    for _, term in ipairs(core.runtime_instance_scan_match_terms()) do
        if string.find(haystack, term, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function log_runtime_instance_scan(source, snapshot)
    if config.runtime_function_scan ~= true or type(FindAllOf) ~= "function" then
        return
    end
    local now = now_ms()
    if now - last_runtime_instance_scan_ms < RUNTIME_INSTANCE_SCAN_COOLDOWN_MS then
        return
    end
    last_runtime_instance_scan_ms = now

    log("[runtime-instance-scan] source=" .. tostring(source)
        .. " " .. format_snapshot(snapshot or locomotion_snapshot()))
    for _, class_name in ipairs(core.runtime_instance_scan_classes()) do
        local ok, objects = pcall(function()
            return FindAllOf(class_name)
        end)
        if not ok then
            log("[runtime-instance-scan] class=" .. tostring(class_name)
                .. " failed=" .. tostring(objects))
        elseif type(objects) ~= "table" then
            log("[runtime-instance-scan] class=" .. tostring(class_name)
                .. " returned=" .. tostring(type(objects)))
        else
            local logged = 0
            local match_count = 0
            local match_logged = 0
            for _, object in ipairs(objects) do
                if is_usable_object(object) then
                    logged = logged + 1
                    local object_name = get_full_name(object)
                    local class_full_name = get_class_full_name(object)
                    if logged <= 4 then
                        log("[runtime-instance-scan] class=" .. tostring(class_name)
                            .. " index=" .. tostring(logged)
                            .. " object=" .. object_name
                            .. " objectClass=" .. class_full_name)
                    end
                    if matches_runtime_instance_scan_terms(object_name, class_full_name) then
                        match_count = match_count + 1
                        if match_logged < 12 then
                            match_logged = match_logged + 1
                            log("[runtime-instance-scan-match] class=" .. tostring(class_name)
                                .. " matchIndex=" .. tostring(match_count)
                                .. " object=" .. object_name
                                .. " objectClass=" .. class_full_name)
                        end
                    end
                end
            end
            log("[runtime-instance-scan] class=" .. tostring(class_name)
                .. " count=" .. tostring(logged))
            if logged > 0 then
                log("[runtime-instance-scan-match] class=" .. tostring(class_name)
                    .. " matchCount=" .. tostring(match_count))
            end
        end
    end
end

local function log_discovery_event(source, context, ...)
    if not config.discovery_mode and not config.debug then
        return
    end
    local params = {}
    local count = select("#", ...)
    for index = 1, count do
        params[index] = param_to_log_string(select(index, ...))
    end
    local context_name = get_full_name(get_param_object(context) or context)
    local snapshot = locomotion_snapshot()
    log("[discover] source=" .. tostring(source)
        .. " context=" .. tostring(context_name)
        .. " params=[" .. table.concat(params, " | ") .. "]"
        .. " " .. format_snapshot(snapshot))
end

local function is_crafting_hook(hook_name)
    return contains(hook_name, "/Script/G1R.GameplayAbilityCrafting:")
end

local function mark_crafting_context(source, context, ...)
    local ability = get_param_object(context)
    if not ability and is_usable_object(context) then
        ability = context
    end
    if is_usable_object(ability) then
        tracked_crafting.ability = ability
    end

    local first_param = select(1, ...)
    local state = tonumber(param_to_log_string(first_param))
    if state ~= nil then
        tracked_crafting.state = state
    end
    tracked_crafting.source = tostring(source)
    tracked_crafting.last_seen_ms = now_ms()
end

local function mark_interaction_context(source, context, ...)
    local tracking = core.interaction_tracking_from_hook(source)
    if tracking.track ~= true then
        return false
    end

    local object = get_param_object(context)
    if not object and is_usable_object(context) then
        object = context
    end

    tracked_interaction.active = true
    tracked_interaction.object = object
    tracked_interaction.kind = tracking.kind
    tracked_interaction.source = tostring(source)
    tracked_interaction.target = param_to_log_string(select(1, ...))
    tracked_interaction.phase = tracking.phase
    tracked_interaction.started_at_ms = now_ms()
    if core.object_name_is_container_ability(object_identity_text(object)) then
        local owner_identity = player_state_identity()
        local object_name = get_full_name(object)
        if owner_identity == ""
            or core.object_name_belongs_to_owner(object_name, owner_identity)
        then
            cached_container_ability = object
            cached_container_owner_identity = owner_identity
        end
    end
    debug_log("Interaction tracked from " .. tostring(source)
        .. " kind=" .. tostring(tracking.kind)
        .. " phase=" .. tostring(tracking.phase)
        .. " object=" .. get_full_name(object))
    return true
end

local function mark_montage_interaction_context(source, context, ...)
    local first_param = select(1, ...)
    local montage_name = param_to_log_string(first_param)
    local tracking = core.interaction_tracking_from_montage_name(montage_name)
    if tracking.track ~= true then
        return false
    end

    local object = nil
    if contains(source, "/Script/Engine.Character:PlayAnimMontage") then
        object = get_param_object(context)
        if not object and is_usable_object(context) then
            object = context
        end
        mark_hero(object, "seat montage")
    end
    if not is_usable_object(object) then
        object = cached_hero
    end
    if not is_usable_object(object) then
        object = get_param_object(context)
    end

    tracked_interaction.active = true
    tracked_interaction.object = object
    tracked_interaction.kind = tracking.kind
    tracked_interaction.source = tostring(source)
    tracked_interaction.target = montage_name
    tracked_interaction.phase = tracking.phase
    tracked_interaction.started_at_ms = now_ms()
    log("[interaction-track] source=" .. tostring(source)
        .. " kind=" .. tostring(tracking.kind)
        .. " phase=" .. tostring(tracking.phase)
        .. " target=" .. tostring(montage_name)
        .. " object=" .. get_full_name(object))
    return true
end

local function crafting_recent(now)
    if not is_usable_object(tracked_crafting.ability) then
        return false
    end
    return (tonumber(now) or now_ms()) - tracked_crafting.last_seen_ms
        <= CRAFTING_ACTIVITY_TIMEOUT_MS
end

local function interaction_recent(now)
    if tracked_interaction.active ~= true then
        return false
    end
    return (tonumber(now) or now_ms()) - tracked_interaction.started_at_ms
        <= INTERACTION_ACTIVITY_TIMEOUT_MS
end

local function discovery_context_can_mark_hero(hook_name)
    return hook_name == "/Script/G1R.GothicCharacter:BP_IsGameplayReady"
        or hook_name == "/Script/G1R.GothicCharacter:GetInventory"
        or hook_name == "/Script/G1R.GothicCharacter:GetCarryComponent"
        or hook_name == "/Script/Engine.Character:PlayAnimMontage"
end

local function key_value_from_name(key_name)
    local normalized = string.upper(trim(key_name))
    local ok, value = pcall(function()
        return Key[normalized]
    end)
    if ok and value ~= nil then
        return value, normalized
    end
    return nil, normalized
end

local function is_console_open()
    local console = nil
    pcall(function()
        local pc = resolve_player_controller()
        if not is_usable_object(pc) then return end
        local player = pc.Player
        if not is_usable_object(player) then return end
        local viewport_client = player.ViewportClient
        if not is_usable_object(viewport_client) then return end
        console = viewport_client.ViewportConsole
    end)
    if is_usable_object(console) then
        local ok, state = pcall(function()
            local value = console.ConsoleState
            if not value then return "None" end
            if type(value) == "string" then return value end
            if value.ToString then return value:ToString() end
            return tostring(value)
        end)
        return ok and state and state ~= "None"
    end
    return false
end

local function is_menu_open()
    local pc = resolve_player_controller()
    if not is_usable_object(pc) then
        return false
    end
    local ok, result = pcall(function()
        return pc.bShowMouseCursor == true or pc:IsPaused() == true
    end)
    return ok and result == true
end

local function current_safety_state(snapshot)
    snapshot = snapshot or locomotion_snapshot()
    local now = now_ms()
    local active_interaction = interaction_recent(now)
    if not active_interaction and tracked_interaction.active == true then
        tracked_interaction.active = false
        tracked_interaction.object = nil
        tracked_interaction.phase = "stale"
    end
    local airborne = snapshot.movement_state == 3
        or snapshot.movement_action == 5
        or snapshot.requested_movement_action == 5
    local dialogue_or_cutscene = snapshot.anim_is_conversation == true
        or snapshot.anim_is_cinematic == true
    return {
        player_ready = is_usable_object(cached_hero),
        interaction_active = active_interaction,
        interaction_cancel_lockout =
            now - last_successful_interaction_cancel_ms < INTERACTION_CANCEL_LOCKOUT_MS,
        interaction_kind = tracked_interaction.kind,
        sleep_movement_active = tracked_interaction.phase == "sleep-move",
        movement_action = snapshot.movement_action,
        requested_movement_action = snapshot.requested_movement_action,
        paused = false,
        menu_open = is_menu_open(),
        console_open = is_console_open(),
        dialogue_or_cutscene = dialogue_or_cutscene,
        alive = snapshot.anim_is_alive ~= false,
        unsafe_transition = false,
        airborne = airborne,
        combat_or_finisher = snapshot.anim_is_in_combat == true,
    }
end

local function current_crafting_cancel_state(snapshot)
    snapshot = snapshot or locomotion_snapshot()
    local now = now_ms()
    local airborne = snapshot.movement_state == 3
        or snapshot.movement_action == 5
        or snapshot.requested_movement_action == 5
    return {
        player_ready = is_usable_object(cached_hero),
        crafting_recent = crafting_recent(now),
        crafting_cancel_lockout =
            now - last_successful_crafting_cancel_ms < CRAFTING_CANCEL_LOCKOUT_MS,
        crafting_state = tracked_crafting.state,
        movement_action = snapshot.movement_action,
        requested_movement_action = snapshot.requested_movement_action,
        alive = snapshot.anim_is_alive ~= false,
        airborne = airborne,
        combat_or_finisher = snapshot.anim_is_in_combat == true,
    }
end

local function try_cancel_crafting(key_name, snapshot)
    local state = current_crafting_cancel_state(snapshot)
    local safety = core.classify_crafting_cancel(state)
    debug_log("[crafting-cancel-attempt] key=" .. tostring(key_name)
        .. " allowed=" .. tostring(safety.allowed)
        .. " reason=" .. tostring(safety.reason)
        .. " craftingState=" .. tostring(tracked_crafting.state)
        .. " craftingSource=" .. tostring(tracked_crafting.source)
        .. " craftingRecent=" .. tostring(state.crafting_recent)
        .. " ability=" .. get_full_name(tracked_crafting.ability))
    if safety.allowed ~= true then
        return false
    end

    for _, method_name in ipairs(core.crafting_cancel_method_names()) do
        local ok, value, mode = call_method(tracked_crafting.ability, method_name)
        if ok == true then
            last_successful_crafting_cancel_ms = now_ms()
            tracked_crafting.ability = nil
            tracked_crafting.state = nil
            tracked_crafting.source = "cancelled:" .. tostring(method_name)
            tracked_crafting.last_seen_ms = -1000000
            log("[crafting-cancel] key=" .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode))
            return true
        end
        debug_log("[crafting-cancel] method=" .. tostring(method_name)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. tostring(value))
    end
    log("[crafting-cancel] failed key=" .. tostring(key_name))
    return false
end

local function player_state_identity()
    if not is_usable_object(cached_hero) then
        return ""
    end

    local player_state = nil
    pcall(function()
        player_state = cached_hero.PlayerState
    end)
    if is_usable_object(player_state) then
        return get_full_name(player_state)
    end

    local character_state = nil
    pcall(function()
        character_state = cached_hero.m_CharacterState
    end)
    if is_usable_object(character_state) then
        return get_full_name(character_state)
    end

    return ""
end

local function find_player_interact_free_point_ability()
    local owner_identity = player_state_identity()
    if owner_identity == "" then
        return nil
    end

    if is_usable_object(cached_interact_free_point_ability)
        and cached_interact_free_point_owner_identity == owner_identity
        and core.object_name_belongs_to_owner(
            get_full_name(cached_interact_free_point_ability), owner_identity)
    then
        return cached_interact_free_point_ability
    end

    cached_interact_free_point_ability = nil
    cached_interact_free_point_owner_identity = ""

    if type(FindAllOf) ~= "function" then
        return nil
    end

    local ok, objects = pcall(function()
        return FindAllOf("GameplayAbilityInteractFreePoint")
    end)
    if not ok or type(objects) ~= "table" then
        debug_log("Player InteractFreePoint ability scan failed: " .. tostring(objects))
        return nil
    end

    for _, object in ipairs(objects) do
        if is_usable_object(object) then
            local object_name = get_full_name(object)
            if core.object_name_belongs_to_owner(object_name, owner_identity) then
                cached_interact_free_point_ability = object
                cached_interact_free_point_owner_identity = owner_identity
                debug_log("Player InteractFreePoint ability found: " .. object_name)
                return object
            end
        end
    end

    debug_log("Player InteractFreePoint ability not found for owner=" .. owner_identity)
    return nil
end

local function find_player_sleep_bed_ability()
    local owner_identity = player_state_identity()
    if owner_identity == "" then
        return nil
    end

    if is_usable_object(cached_sleep_bed_ability)
        and cached_sleep_bed_owner_identity == owner_identity
        and core.object_name_belongs_to_owner(get_full_name(cached_sleep_bed_ability), owner_identity)
        and core.object_name_is_sleep_bed_ability(get_full_name(cached_sleep_bed_ability))
    then
        return cached_sleep_bed_ability
    end

    cached_sleep_bed_ability = nil
    cached_sleep_bed_owner_identity = ""

    if type(FindAllOf) ~= "function" then
        return nil
    end

    for _, class_name in ipairs({
        "GameplayAbilityInteractionBase",
        "GA_Human_Sleep_Bed_Low",
        "GA_Human_Sleep_Bed_High",
        "GA_Human_Sleep_Bed_Ground",
    }) do
        local ok, objects = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if is_usable_object(object) then
                    local object_name = get_full_name(object)
                    if core.object_name_belongs_to_owner(object_name, owner_identity)
                        and core.object_name_is_sleep_bed_ability(object_name)
                    then
                        cached_sleep_bed_ability = object
                        cached_sleep_bed_owner_identity = owner_identity
                        debug_log("Player SleepBed ability found: " .. object_name)
                        return object
                    end
                end
            end
        elseif not ok then
            debug_log("Player SleepBed ability scan failed for class="
                .. tostring(class_name) .. ": " .. tostring(objects))
        end
    end

    debug_log("Player SleepBed ability not found for owner=" .. owner_identity)
    return nil
end

local function active_sleep_bed_ability()
    if is_usable_object(tracked_interaction.object)
        and core.object_name_is_sleep_bed_ability(object_identity_text(tracked_interaction.object))
    then
        return tracked_interaction.object
    end
    return find_player_sleep_bed_ability()
end

local function find_player_container_ability()
    local owner_identity = player_state_identity()
    if owner_identity == "" then
        return nil
    end

    if is_usable_object(cached_container_ability)
        and cached_container_owner_identity == owner_identity
        and core.object_name_belongs_to_owner(get_full_name(cached_container_ability),
            owner_identity)
        and core.object_name_is_container_ability(get_full_name(cached_container_ability))
    then
        return cached_container_ability
    end

    cached_container_ability = nil
    cached_container_owner_identity = ""

    if type(FindAllOf) ~= "function" then
        return nil
    end

    for _, class_name in ipairs({
        "GameplayAbilityInteractionBase",
        "GA_Human_OpenContainer",
        "GA_Human_OpenContainer_Swimming",
    }) do
        local ok, objects = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if is_usable_object(object) then
                    local object_name = get_full_name(object)
                    if core.object_name_belongs_to_owner(object_name, owner_identity)
                        and core.object_name_is_container_ability(object_name)
                    then
                        cached_container_ability = object
                        cached_container_owner_identity = owner_identity
                        debug_log("Player OpenContainer ability found: " .. object_name)
                        return object
                    end
                end
            end
        elseif not ok then
            debug_log("Player OpenContainer ability scan failed for class="
                .. tostring(class_name) .. ": " .. tostring(objects))
        end
    end

    debug_log("Player OpenContainer ability not found for owner=" .. owner_identity)
    return nil
end

local function active_container_ability()
    if is_usable_object(tracked_interaction.object)
        and core.object_name_is_container_ability(object_identity_text(tracked_interaction.object))
    then
        return tracked_interaction.object
    end
    return find_player_container_ability()
end

local function free_point_container_context_text(ability)
    return object_property_context_text(ability, {
        "ActionFilter",
    })
end

local function container_ability_target_context_text(ability)
    return object_property_context_text(ability, {
        "m_InteractiveActor",
        "m_InteractionSpot",
        "m_InteractiveComponent",
        "m_InteractiveObjectDefinition",
        "m_DefaultInteraction",
        "m_AbilityEnded",
    })
end

local function log_container_context(key_name, free_point_text, ability_text, task_count,
        ability_ended)
    if config.debug ~= true then
        return
    end
    local ability_context_active = core.container_ability_context_can_cancel({
        ability_available = ability_text ~= "",
        ability_ended = ability_ended,
        context_text = ability_text,
    })
    debug_log("[container-context] key=" .. tostring(key_name)
        .. " tasks=" .. tostring(task_count)
        .. " freePointMatch="
        .. tostring(core.text_is_container_interaction_context(free_point_text))
        .. " abilityMatch="
        .. tostring(core.text_is_container_interaction_context(ability_text))
        .. " abilityEnded=" .. tostring(ability_ended)
        .. " abilityActiveMatch=" .. tostring(ability_context_active)
        .. " freePoint={" .. tostring(free_point_text) .. "}"
        .. " ability={" .. tostring(ability_text) .. "}")
end

local function append_unique_object(objects, object)
    if not is_usable_object(object) then
        return
    end
    for _, existing in ipairs(objects) do
        if existing == object then
            return
        end
    end
    table.insert(objects, object)
end

local function insert_unique_object(objects, index, object)
    if not is_usable_object(object) then
        return false
    end
    for _, existing in ipairs(objects) do
        if existing == object then
            return false
        end
    end
    table.insert(objects, index, object)
    return true
end

local function find_player_sleep_interaction_tasks()
    local tasks = {}
    if type(FindAllOf) ~= "function" then
        return tasks
    end

    for _, class_name in ipairs({
        "AbilityTask_Interaction_Player_SitAndSleep",
        "UAbilityTask_Interaction_Player_SitAndSleep",
        "AbilityTask_InteractionSpot_Montage",
    }) do
        local ok, objects = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if is_usable_object(object)
                    and core.object_name_is_player_sleep_interaction_task(object_identity_text(object))
                then
                    append_unique_object(tasks, object)
                end
            end
        elseif not ok then
            debug_log("Player sleep interaction task scan failed for class="
                .. tostring(class_name) .. ": " .. tostring(objects))
        end
    end

    return tasks
end

local function find_player_container_interaction_tasks()
    local tasks = {}
    if type(FindAllOf) ~= "function" then
        return tasks
    end

    for _, class_name in ipairs({
        "AbilityTask_Interaction_Player_OpenContainer",
        "UAbilityTask_Interaction_Player_OpenContainer",
        "AbilityTask_InteractionSpot_Montage",
    }) do
        local ok, objects = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if is_usable_object(object)
                    and core.object_name_is_player_container_interaction_task(
                        object_identity_text(object))
                then
                    append_unique_object(tasks, object)
                end
            end
        elseif not ok then
            debug_log("Player container interaction task scan failed for class="
                .. tostring(class_name) .. ": " .. tostring(objects))
        end
    end

    return tasks
end

local function interaction_cancel_objects()
    local objects = {}
    append_unique_object(objects, find_player_interact_free_point_ability())
    append_unique_object(objects, tracked_interaction.object)
    append_unique_object(objects, cached_hero)
    append_unique_object(objects, cached_anim_instance)
    append_unique_object(objects, resolve_player_controller())
    append_unique_object(objects, cached_carry_component)
    return objects
end

local function mark_sleep_movement_context(source, context, ...)
    if source ~= "/Script/G1R.GameplayAbilitySleep:OnPlayerGoToSleep" then
        return false
    end

    local ability = get_param_object(context)
    if not ability and is_usable_object(context) then
        ability = context
    end
    if not is_usable_object(ability)
        or not core.object_name_is_sleep_bed_ability(object_identity_text(ability))
    then
        return false
    end

    local owner_identity = player_state_identity()
    local ability_name = get_full_name(ability)
    if owner_identity ~= "" and not core.object_name_belongs_to_owner(ability_name, owner_identity) then
        return false
    end

    cached_sleep_bed_ability = ability
    cached_sleep_bed_owner_identity = owner_identity
    tracked_interaction.active = true
    tracked_interaction.object = ability
    tracked_interaction.kind = "ambient"
    tracked_interaction.source = tostring(source)
    tracked_interaction.target = param_to_log_string(select(1, ...))
    tracked_interaction.phase = "sleep-move"
    tracked_interaction.started_at_ms = now_ms()
    log("[sleep-track] source=" .. tostring(source)
        .. " phase=sleep-move"
        .. " object=" .. ability_name)
    return true
end

local function clear_tracked_interaction(source)
    tracked_interaction.active = false
    tracked_interaction.object = nil
    tracked_interaction.kind = "none"
    tracked_interaction.source = tostring(source or "")
    tracked_interaction.target = ""
    tracked_interaction.phase = "idle"
    tracked_interaction.started_at_ms = 0
end

local function pack_args(...)
    local args = { ... }
    args.n = select("#", ...)
    return args
end

local function call_method_with_arg_pack(object, method_name, args)
    local unpack_args = table.unpack or unpack
    if not unpack_args then
        return false, "unpack unavailable"
    end
    args = args or { n = 0 }
    return call_method(object, method_name, unpack_args(args, 1, args.n or #args))
end

local function try_cancel_sleep_ability(key_name, return_any_success)
    local ability = active_sleep_bed_ability()
    if not is_usable_object(ability) then
        debug_log("[sleep-cancel] no player sleep ability found")
        return false
    end

    local any_success = false
    for _, method_name in ipairs(core.interaction_sleep_ability_cancel_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        if ok == true then
            any_success = true
            log("[sleep-cancel] key=" .. tostring(key_name)
                .. " target=ability"
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " object=" .. get_full_name(ability))
        else
            debug_log("[sleep-cancel] target=ability"
                .. " method=" .. tostring(method_name)
                .. " ok=false mode=" .. tostring(mode)
                .. " result=" .. tostring(value)
                .. " object=" .. get_full_name(ability))
        end
    end
    return return_any_success == true and any_success == true
end

local function try_cancel_container_ability(key_name, return_any_success, ability)
    ability = ability or active_container_ability()
    if not is_usable_object(ability) then
        debug_log("[container-cancel] no player container ability found")
        return false
    end

    local any_success = false
    for _, method_name in ipairs(core.interaction_container_ability_cancel_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        if ok == true then
            any_success = true
            log("[container-cancel] key=" .. tostring(key_name)
                .. " target=ability"
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " object=" .. get_full_name(ability))
        else
            debug_log("[container-cancel] target=ability"
                .. " method=" .. tostring(method_name)
                .. " ok=false mode=" .. tostring(mode)
                .. " result=" .. tostring(value)
                .. " object=" .. get_full_name(ability))
        end
    end
    return return_any_success == true and any_success == true
end

local function sleep_root_interaction_task(ability)
    if not is_usable_object(ability) then
        return nil
    end
    local task = nil
    pcall(function()
        task = ability.m_RootInteractionTask
    end)
    if is_usable_object(task) then
        return task
    end
    pcall(function()
        task = ability.RootInteractionTask
    end)
    if is_usable_object(task) then
        return task
    end
    return nil
end

local function try_cancel_sleep_root_task(key_name, ability)
    local task = sleep_root_interaction_task(ability)
    if not is_usable_object(task) then
        debug_log("[sleep-move-cancel] no root interaction task"
            .. " ability=" .. get_full_name(ability))
        return false
    end

    for _, method_name in ipairs(core.sleep_root_task_cancel_method_names()) do
        local ok, value, mode = call_method(task, method_name)
        if ok == true then
            log("[sleep-move-cancel] key=" .. tostring(key_name)
                .. " target=root-task"
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " object=" .. get_full_name(task))
            return true
        end
        debug_log("[sleep-move-cancel] target=root-task"
            .. " method=" .. tostring(method_name)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. tostring(value)
            .. " object=" .. get_full_name(task))
    end

    return false
end

local function sleep_montage_cancel_target(method_name)
    if method_name == "StopAnimMontage" then
        return cached_hero, {
            pack_args(nil),
            pack_args(),
        }
    end
    if method_name == "Montage_Stop" then
        return cached_anim_instance, {
            pack_args(0.15, nil),
            pack_args(0.15),
        }
    end
    return nil, {}
end

local function try_cancel_sleep_montage(key_name)
    local any_success = false
    for _, method_name in ipairs(core.sleep_montage_cancel_method_names()) do
        local target, variants = sleep_montage_cancel_target(method_name)
        if not is_usable_object(target) then
            debug_log("[sleep-montage-cancel] target invalid method="
                .. tostring(method_name))
        else
            for _, args in ipairs(variants) do
                local ok, value, mode = call_method_with_arg_pack(target, method_name, args)
                if ok == true then
                    any_success = true
                    log("[sleep-montage-cancel] key=" .. tostring(key_name)
                        .. " method=" .. tostring(method_name)
                        .. " args=" .. tostring(args.n or 0)
                        .. " mode=" .. tostring(mode)
                        .. " object=" .. get_full_name(target))
                    break
                end
                debug_log("[sleep-montage-cancel] method=" .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " ok=false mode=" .. tostring(mode)
                    .. " result=" .. tostring(value)
                    .. " object=" .. get_full_name(target))
            end
        end
    end
    return any_success
end

local function try_cancel_container_montage(key_name)
    local any_success = false
    for _, method_name in ipairs(core.sleep_montage_cancel_method_names()) do
        local target, variants = sleep_montage_cancel_target(method_name)
        if not is_usable_object(target) then
            debug_log("[container-montage-cancel] target invalid method="
                .. tostring(method_name))
        else
            for _, args in ipairs(variants) do
                local ok, value, mode = call_method_with_arg_pack(target, method_name, args)
                if ok == true then
                    any_success = true
                    log("[container-montage-cancel] key=" .. tostring(key_name)
                        .. " method=" .. tostring(method_name)
                        .. " args=" .. tostring(args.n or 0)
                        .. " mode=" .. tostring(mode)
                        .. " object=" .. get_full_name(target))
                    break
                end
                debug_log("[container-montage-cancel] method=" .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " ok=false mode=" .. tostring(mode)
                    .. " result=" .. tostring(value)
                    .. " object=" .. get_full_name(target))
            end
        end
    end
    return any_success
end

local function try_cancel_sleep_interaction_task(key_name, task)
    if not is_usable_object(task) then
        return false
    end

    for _, method_name in ipairs(core.sleep_interaction_task_cancel_method_names()) do
        local ok, value, mode = call_method(task, method_name)
        if ok == true then
            log("[sleep-task-cancel] key=" .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " object=" .. get_full_name(task))
            return true
        end
        debug_log("[sleep-task-cancel] method=" .. tostring(method_name)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. tostring(value)
            .. " object=" .. get_full_name(task))
    end

    return false
end

local function try_cancel_container_interaction_task(key_name, task)
    if not is_usable_object(task) then
        return false
    end

    for _, method_name in ipairs(core.container_interaction_task_cancel_method_names()) do
        local ok, value, mode = call_method(task, method_name)
        if ok == true then
            log("[container-task-cancel] key=" .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " object=" .. get_full_name(task))
            return true
        end
        debug_log("[container-task-cancel] method=" .. tostring(method_name)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. tostring(value)
            .. " object=" .. get_full_name(task))
    end

    return false
end

local function sleep_interaction_allows_ability_cleanup()
    return core.sleep_interaction_task_should_cleanup_ability({
        explicit_sleep_context = tracked_interaction.phase == "sleep-move",
    })
end

local function try_cancel_sleep_interaction(key_name, sleep_tasks)
    if #sleep_tasks == 0 then
        return false
    end
    for _, task in ipairs(sleep_tasks) do
        debug_log("Player sleep interaction task active: " .. object_identity_text(task))
    end

    local task_success = false
    for _, task in ipairs(sleep_tasks) do
        if try_cancel_sleep_interaction_task(key_name, task) then
            task_success = true
            break
        end
    end
    if task_success then
        local ability_cleanup = false
        try_cancel_sleep_montage(key_name)
        if sleep_interaction_allows_ability_cleanup() then
            ability_cleanup = try_cancel_sleep_ability(key_name, true)
        end
        debug_log("[sleep-task-cancel] key=" .. tostring(key_name)
            .. " abilityCleanup=" .. tostring(ability_cleanup))
        last_successful_interaction_cancel_ms = now_ms()
        clear_tracked_interaction("sleep-task-cancelled")
        return true
    end

    local ability_cleanup = false
    local montage_success = try_cancel_sleep_montage(key_name)
    if sleep_interaction_allows_ability_cleanup() then
        ability_cleanup = try_cancel_sleep_ability(key_name, true)
    end
    debug_log("[sleep-montage-cancel] key=" .. tostring(key_name)
        .. " abilityCleanup=" .. tostring(ability_cleanup))
    if montage_success then
        last_successful_interaction_cancel_ms = now_ms()
        clear_tracked_interaction("sleep-cancelled")
        return true
    end

    log("[sleep-cancel] failed key=" .. tostring(key_name))
    return false
end

local function try_cancel_container_interaction(key_name, container_tasks)
    for _, task in ipairs(container_tasks) do
        debug_log("Player container interaction task active: " .. object_identity_text(task))
    end

    local task_success = false
    for _, task in ipairs(container_tasks) do
        if try_cancel_container_interaction_task(key_name, task) then
            task_success = true
            break
        end
    end
    if task_success then
        try_cancel_container_montage(key_name)
        try_cancel_container_ability(key_name)
        last_successful_interaction_cancel_ms = now_ms()
        clear_tracked_interaction("container-task-cancelled")
        return true
    end

    local fallback_allowed = core.container_ability_fallback_allowed({
        container_task_count = #container_tasks,
        tracked_object_is_container =
            core.object_name_is_container_ability(object_identity_text(tracked_interaction.object)),
        tracked_animation_is_container = tracked_interaction.phase == "animation"
            and core.object_name_is_container_ability(tracked_interaction.target),
    })
    if fallback_allowed then
        local montage_success = try_cancel_container_montage(key_name)
        local ability_success = try_cancel_container_ability(key_name, true)
        if montage_success or ability_success then
            last_successful_interaction_cancel_ms = now_ms()
            clear_tracked_interaction("container-cancelled")
            return true
        end
    end

    return false
end

local function try_cancel_sleep_movement(key_name)
    if tracked_interaction.phase ~= "sleep-move" then
        return false
    end

    local ability = active_sleep_bed_ability()
    if not is_usable_object(ability) then
        debug_log("[sleep-move-cancel] no active sleep ability")
        return false
    end

    local root_task_success = try_cancel_sleep_root_task(key_name, ability)
    local ability_success = try_cancel_sleep_ability(key_name, true)
    if root_task_success or ability_success then
        last_successful_interaction_cancel_ms = now_ms()
        clear_tracked_interaction("sleep-move-cancelled")
        log("[sleep-move-cancel] key=" .. tostring(key_name)
            .. " complete rootTask=" .. tostring(root_task_success)
            .. " ability=" .. tostring(ability_success))
        return true
    end

    log("[sleep-move-cancel] failed key=" .. tostring(key_name)
        .. " ability=" .. get_full_name(ability))
    return false
end

local function try_cancel_movement_interaction(key_name, snapshot)
    local state = current_safety_state(snapshot)
    state.key_name = key_name
    local safety = core.classify_movement_interaction_cancel(state)
    debug_log("[interaction-cancel-attempt] key=" .. tostring(key_name)
        .. " allowed=" .. tostring(safety.allowed)
        .. " reason=" .. tostring(safety.reason)
        .. " interactionActive=" .. tostring(state.interaction_active)
        .. " interactionKind=" .. tostring(tracked_interaction.kind)
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target)
        .. " phase=" .. tostring(tracked_interaction.phase))
    if safety.allowed ~= true then
        return false
    end

    local sleep_tasks = find_player_sleep_interaction_tasks()
    local container_tasks = find_player_container_interaction_tasks()
    local sleep_interaction_context = #sleep_tasks > 0
    local interact_free_point_ability = find_player_interact_free_point_ability()
    local free_point_container_text =
        free_point_container_context_text(interact_free_point_ability)
    local free_point_container_context =
        core.text_is_container_interaction_context(free_point_container_text)
    local container_interaction_context = #container_tasks > 0
    local sleep_interaction_cancelled = try_cancel_sleep_interaction(key_name, sleep_tasks)
    if try_cancel_sleep_movement(key_name) then
        return true
    end
    local container_ability = active_container_ability()
    local container_ability_available = is_usable_object(container_ability)
    local container_ability_text = container_ability_target_context_text(container_ability)
    local container_ability_ended = object_bool_property(container_ability, "m_AbilityEnded")
    log_container_context(key_name, free_point_container_text, container_ability_text,
        #container_tasks, container_ability_ended)
    local active_container_ability_context = core.container_ability_context_can_cancel({
        ability_available = container_ability_available,
        ability_ended = container_ability_ended,
        context_text = container_ability_text,
    })
    if active_container_ability_context then
        debug_log("[container-cancel] active container ability context matched; trying ability first")
        if try_cancel_container_ability(key_name, true, container_ability) then
            last_successful_interaction_cancel_ms = now_ms()
            clear_tracked_interaction("container-free-point-cancelled")
            return true
        end
    end
    if try_cancel_container_interaction(key_name, container_tasks) then
        return true
    end
    local objects = interaction_cancel_objects()
    local index = 1
    while index <= #objects do
        local object = objects[index]
        local object_identity = object_identity_text(object)
        local method_names = core.interaction_cancel_method_names()
        for _, method_name in ipairs(method_names) do
            local ok, value, mode = call_method(object, method_name)
            if ok == true then
                last_successful_interaction_cancel_ms = now_ms()
                local object_name = get_full_name(object)
                local secondary_container_success = false
                if core.interaction_success_should_trigger_container_secondary_cancel(
                        object_identity, {
                            movement_action = state.movement_action,
                            container_ability_available = container_ability_available,
                            container_interaction_context = container_interaction_context,
                            free_point_container_context = free_point_container_context,
                        })
                then
                    secondary_container_success =
                        try_cancel_container_ability(key_name, true, container_ability)
                end
                local continue_after_success =
                    core.interaction_cancel_should_continue_after_success(object_identity, {
                        sleep_interaction_context = sleep_interaction_context,
                        sleep_task_cancelled = sleep_interaction_cancelled,
                        container_interaction_context = container_interaction_context,
                        movement_action = state.movement_action,
                    })
                if continue_after_success ~= true then
                    clear_tracked_interaction("cancelled:" .. tostring(method_name))
                end
                log("[interaction-cancel] key=" .. tostring(key_name)
                    .. " method=" .. tostring(method_name)
                    .. " mode=" .. tostring(mode)
                    .. " continue=" .. tostring(continue_after_success)
                    .. " secondaryContainer=" .. tostring(secondary_container_success)
                    .. " object=" .. object_name)
                if continue_after_success ~= true then
                    return true
                end
                break
            end
            debug_log("[interaction-cancel] method=" .. tostring(method_name)
                .. " ok=false mode=" .. tostring(mode)
                .. " result=" .. tostring(value)
                .. " object=" .. get_full_name(object))
        end
        index = index + 1
    end

    if sleep_interaction_cancelled then
        return true
    end

    log("[interaction-cancel] failed key=" .. tostring(key_name))
    return false
end

local function log_cancel_attempt(key_name)
    local snapshot = locomotion_snapshot()
    local safety_state = current_safety_state(snapshot)
    safety_state.key_name = key_name
    local safety = core.classify_movement_interaction_cancel(safety_state)
    debug_log("[cancel-attempt] key=" .. tostring(key_name)
        .. " allowed=" .. tostring(safety.allowed)
        .. " reason=" .. tostring(safety.reason)
        .. " interactionActive=" .. tostring(tracked_interaction.active)
        .. " interactionKind=" .. tostring(tracked_interaction.kind)
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target)
        .. " phase=" .. tostring(tracked_interaction.phase)
        .. " " .. format_snapshot(snapshot))
    local movement_action_active =
        snapshot.movement_action == 7 or snapshot.requested_movement_action == 7
    if movement_action_active then
        if try_cancel_crafting(key_name, snapshot) then
            movement_cancel_armed_until_ms = -1000000
            return
        end
        if current_crafting_cancel_state(snapshot).crafting_recent == true then
            return
        end
    end
    local cancelled = try_cancel_movement_interaction(key_name, snapshot)
    if cancelled then
        movement_cancel_armed_until_ms = -1000000
    end
    if movement_action_active and not cancelled then
        log_runtime_instance_scan("cancel-hotkey:" .. tostring(key_name), snapshot)
    end
end

local function on_cancel_hotkey(key_name)
    if not hotkey_runtime_enabled then
        debug_log("Cancel hotkey ignored: runtime disabled")
        return
    end
    local now = now_ms()
    if key_name == "F" or key_name == "ESCAPE" then
        movement_cancel_armed_until_ms = now + MOVEMENT_CANCEL_ARM_MS
    end
    if core.cancel_hotkey_should_enter_game_thread({
            key_name = key_name,
            interaction_active = tracked_interaction.active == true,
            movement_cancel_armed = now <= movement_cancel_armed_until_ms,
        }) ~= true
    then
        return
    end
    if now - last_hotkey_ms < config.cooldown_ms then
        debug_log("Cancel hotkey ignored by cooldown")
        return
    end
    last_hotkey_ms = now
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            if hotkey_game_thread_busy then
                debug_log("Cancel hotkey ignored: game-thread request already running")
                return
            end
            hotkey_game_thread_busy = true
            local request_ok, request_err = pcall(log_cancel_attempt, key_name)
            hotkey_game_thread_busy = false
            if not request_ok then
                log("Cancel attempt logging failed: " .. tostring(request_err))
            end
        end)
    end)
    if not ok then
        log("ExecuteInGameThread failed for cancel hotkey: " .. tostring(err))
    end
end

local function install_cancel_hotkeys()
    local registered_any = false
    for _, key_name in ipairs(config.cancel_keys) do
        local key_value, normalized = key_value_from_name(key_name)
        if key_value ~= nil then
            local ok, err = pcall(function()
                RegisterKeyBind(key_value, function()
                    on_cancel_hotkey(normalized)
                end)
            end)
            if ok then
                registered_any = true
                log("Registered cancel key " .. tostring(normalized))
            else
                log("Failed to register cancel key " .. tostring(normalized) .. ": " .. tostring(err))
            end
        else
            log("Unknown cancel key " .. tostring(key_name))
        end
    end
    hotkey_runtime_enabled = registered_any
    return registered_any
end

local function install_discovery_hooks()
    local registered = 0
    for _, hook_name in ipairs(core.discovery_hook_candidates()) do
        local ok = register_hook(hook_name, function(context, ...)
            if discovery_context_can_mark_hero(hook_name) then
                mark_hero_from_context(context, hook_name)
            end
            if is_crafting_hook(hook_name) then
                mark_crafting_context(hook_name, context, ...)
            end
            mark_sleep_movement_context(hook_name, context, ...)
            mark_interaction_context(hook_name, context, ...)
            mark_montage_interaction_context(hook_name, context, ...)
            log_discovery_event(hook_name, context, ...)
            return nil
        end, nil, false)
        if ok then
            registered = registered + 1
        end
    end
    log("Tracking hooks registered: " .. tostring(registered))
    return registered
end

local function install_player_hooks()
    local ok_any = false
    ok_any = register_hook("/Script/G1R.GothicCharacter:BP_IsGameplayReady", function(context)
        mark_hero_from_context(context, "GothicCharacter:BP_IsGameplayReady")
        return nil
    end, nil, false) or ok_any
    ok_any = register_hook("/Script/G1R.GothicCharacter:GetInventory", function(context)
        mark_hero_from_context(context, "GothicCharacter:GetInventory")
        return nil
    end, nil, false) or ok_any
    ok_any = register_hook("/Script/G1R.GothicCharacter:GetCarryComponent", function(context)
        mark_hero_from_context(context, "GothicCharacter:GetCarryComponent")
        return nil
    end, nil, false) or ok_any
    local client_restart_hooked = register_hook("/Script/Engine.PlayerController:ClientRestart", function(context, new_pawn)
        cached_player_controller = get_param_object(context)
        if not mark_hero_from_context(new_pawn, "PlayerController:ClientRestart") then
            refresh_player_from_controller()
        end
        debug_log("ClientRestart observed; player context refreshed.")
        return nil
    end, nil, false)
    ok_any = client_restart_hooked or ok_any
    refresh_player_from_controller()
    return ok_any
end

load_config()
if not required_lua_api_available() then
    hotkey_runtime_enabled = false
    log("Loaded v" .. VERSION .. " in degraded mode.")
else
    local player_hooks_installed = install_player_hooks()
    local tracking_hook_count = install_discovery_hooks()
    run_runtime_function_scan()
    local cancel_hotkeys_installed = install_cancel_hotkeys()
    local hotkey_state = cancel_hotkeys_installed
        and "cancel hotkeys enabled"
        or "cancel hotkeys disabled"
    if player_hooks_installed then
        log("Loaded v" .. VERSION .. " with player hooks and "
            .. tostring(tracking_hook_count) .. " tracking hooks; " .. hotkey_state .. ".")
    else
        log("Loaded v" .. VERSION .. " without player hooks; tracking hooks="
            .. tostring(tracking_hook_count) .. "; " .. hotkey_state .. ".")
    end
end
