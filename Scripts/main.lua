local MOD_NAME = "[G1R_CancelInteraction]"
local VERSION = "0.2.0"
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
local last_successful_crafting_cancel_ms = -1000000
local last_runtime_instance_scan_ms = -1000000
local cached_hero = nil
local cached_inventory = nil
local cached_carry_component = nil
local cached_player_controller = nil
local cached_anim_instance = nil
local tracked_crafting = {
    ability = nil,
    state = nil,
    source = "",
    last_seen_ms = -1000000,
}
local tracked_interaction = {
    active = false,
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
    ButtonCraftingMenuExit_Bind = {
        "/Script/G1R.GameplayAbilityCrafting:ButtonCraftingMenuExit_Bind",
    },
    OnCraftFinished = { "/Script/G1R.GameplayAbilityCrafting:OnCraftFinished" },
}

local RUNTIME_INSTANCE_SCAN_COOLDOWN_MS = 750
local CRAFTING_ACTIVITY_TIMEOUT_MS = 15000
local CRAFTING_CANCEL_LOCKOUT_MS = 2000

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
    return string.find(string.lower(tostring(haystack or "")), string.lower(tostring(needle or "")), 1, true) ~= nil
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
    if cached_hero ~= hero then
        cached_inventory = nil
        cached_carry_component = nil
        cached_anim_instance = nil
    end
    cached_hero = hero
    pcall(function()
        cached_anim_instance = hero.Mesh.AnimScriptInstance
    end)
    debug_log("Player cached from " .. tostring(source) .. ": " .. get_full_name(hero))
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

local function find_reflected_function(object, method_name)
    local cached = reflected_function_cache[method_name]
    if cached then
        return cached, reflected_function_path_cache[method_name] or method_name
    end

    local candidates = {}
    local ok, class = pcall(function()
        return object:GetClass()
    end)
    if ok and is_usable_object(class) then
        local class_name = get_full_name(class):match("^Class%s+(.+)$")
        if class_name and class_name ~= "" then
            table.insert(candidates, class_name .. ":" .. method_name)
            table.insert(candidates, class_name .. "." .. method_name)
        end
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
            reflected_function_cache[method_name] = found
            reflected_function_path_cache[method_name] = candidate
            return found, candidate
        end
    end

    return nil, nil
end

local function call_reflected_function(object, method_name, args, unpack_args, previous_error)
    local ufunction, path = find_reflected_function(object, method_name)
    if not ufunction then
        return false, previous_error or "method not found"
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
    if config.runtime_function_scan ~= true then
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

local function crafting_recent(now)
    if not is_usable_object(tracked_crafting.ability) then
        return false
    end
    return (tonumber(now) or now_ms()) - tracked_crafting.last_seen_ms
        <= CRAFTING_ACTIVITY_TIMEOUT_MS
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

local function current_safety_state()
    local snapshot = locomotion_snapshot()
    local airborne = snapshot.movement_state == 3
        or snapshot.movement_action == 5
        or snapshot.requested_movement_action == 5
    local dialogue_or_cutscene = snapshot.anim_is_conversation == true
        or snapshot.anim_is_cinematic == true
    return {
        player_ready = is_usable_object(cached_hero),
        interaction_active = tracked_interaction.active == true,
        interaction_kind = tracked_interaction.kind,
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

local function log_cancel_attempt(key_name)
    local safety = core.classify_cancel_safety(current_safety_state())
    local snapshot = locomotion_snapshot()
    debug_log("[cancel-attempt] key=" .. tostring(key_name)
        .. " allowed=" .. tostring(safety.allowed)
        .. " reason=" .. tostring(safety.reason)
        .. " interactionActive=" .. tostring(tracked_interaction.active)
        .. " interactionKind=" .. tostring(tracked_interaction.kind)
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target)
        .. " phase=" .. tostring(tracked_interaction.phase)
        .. " " .. format_snapshot(snapshot))
    if snapshot.movement_action == 7 or snapshot.requested_movement_action == 7 then
        log_runtime_instance_scan("cancel-hotkey:" .. tostring(key_name), snapshot)
        try_cancel_crafting(key_name, snapshot)
    end
end

local function on_cancel_hotkey(key_name)
    if not hotkey_runtime_enabled then
        debug_log("Cancel hotkey ignored: runtime disabled")
        return
    end
    local now = now_ms()
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
