local MOD_NAME = "[G1R_CancelInteraction]"
local VERSION = "0.2.94"
local CONFIG_FILE_NAME = "G1R_CancelInteraction.ini"

local core = require("cancel_core")
local runtime_diagnostics = require("runtime_diagnostics")
local UEHelpers = nil
pcall(function()
    UEHelpers = require("UEHelpers")
end)

local config = core.config_from_ini({})
local diagnostics = nil
local hotkey_runtime_enabled = false
local hotkey_game_thread_busy = false
local last_hotkey_ms = -1000000
local movement_cancel_armed_until_ms = -1000000
local last_successful_crafting_cancel_ms = -1000000
local last_successful_interaction_cancel_ms = -1000000
local cached_hero = nil
local cached_hero_identity = ""
local cached_carry_component = nil
local cached_player_controller = nil
local cached_anim_instance = nil
local cached_sleep_bed_ability = nil
local cached_sleep_bed_owner_identity = ""
local cached_container_ability = nil
local cached_container_owner_identity = ""
local cached_loot_ability = nil
local cached_loot_owner_identity = ""
local cached_interact_free_point_ability = nil
local cached_interact_free_point_owner_identity = ""
local cancelled_sleep_task_identities = {}
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
    CancelCrafting = {
        "/Script/G1R.CraftingInProgress:CancelCrafting",
        "/Game/UI/Crafting/W_Crafting_InProgress.W_Crafting_InProgress_C:CancelCrafting",
    },
    OnRequestEndQuick = {
        "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndQuick",
    },
    OnRequestEndNormal = {
        "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndNormal",
    },
    EndTaskAsCancelled = {
        "/Script/G1R.AbilityTaskGeneric:EndTaskAsCancelled",
    },
    BP_ExternalCancel = {
        "/Script/G1R.AbilityTaskGeneric:BP_ExternalCancel",
    },
    EndTaskWithResult = {
        "/Script/G1R.AbilityTaskGeneric:EndTaskWithResult",
    },
    RequestClose = {
        "/Script/G1R.InventoryLootContainer:RequestClose",
    },
    CloseWidget = {
        "/Script/G1R.GothicCommonActivatableWidget:CloseWidget",
    },
    IsActivated = {
        "/Script/CommonUI.CommonActivatableWidget:IsActivated",
    },
    IsVisible = {
        "/Script/UMG.Widget:IsVisible",
    },
    GetVisibility = {
        "/Script/UMG.Widget:GetVisibility",
    },
    BP_OnHandleBackAction = {
        "/Script/CommonUI.CommonActivatableWidget:BP_OnHandleBackAction",
        "/Game/UI/LootContainers/W_LootContainer_Chest.W_LootContainer_Chest_C:BP_OnHandleBackAction",
    },
    BndEvt__W_LootContainer_Chest_Button_Close_K2Node_ComponentBoundEvent_2_ClickedEventBP__DelegateSignature = {
        "/Game/UI/LootContainers/W_LootContainer_Chest.W_LootContainer_Chest_C:BndEvt__W_LootContainer_Chest_Button_Close_K2Node_ComponentBoundEvent_2_ClickedEventBP__DelegateSignature",
    },
    OnLocalCloseRequested = {
        "/Script/G1R.GameplayAbilityOpenContainer:OnLocalCloseRequested",
    },
    OnCloseRequested = {
        "/Script/G1R.GameplayAbilityOpen:OnCloseRequested",
    },
    Server_OnCloseRequested = {
        "/Script/G1R.GameplayAbilityOpen:Server_OnCloseRequested",
        "/Script/G1R.GameplayAbilityLoot:Server_OnCloseRequested",
    },
    CloseLootContainer = {
        "/Script/G1R.GameplayAbilityLoot:CloseLootContainer",
    },
    StopPlayingMontage = {
        "/Script/G1R.AbilityTask_PlayMontage_Extended:StopPlayingMontage",
    },
    StopAnimMontage = { "/Script/Engine.Character:StopAnimMontage" },
    Montage_Stop = { "/Script/Engine.AnimInstance:Montage_Stop" },
    EndTask = { "/Script/GameplayTasks.GameplayTask:EndTask" },
    GetAvatarCharacter = {
        "/Script/G1R.AbilityTaskGeneric:GetAvatarCharacter",
    },
}

local MOVEMENT_CANCEL_ARM_MS = 4000
local CRAFTING_ACTIVITY_TIMEOUT_MS = 15000
local CRAFTING_CANCEL_LOCKOUT_MS = 2000
local CRAFTING_RETRACK_LOCKOUT_MS = 1500
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

local function log_value(value)
    return core.safe_to_string(value)
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
                .. " Timing=" .. tostring(config.timing)
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
        return log_value(value)
    end
    ok, value = pcall(function()
        return object:GetName()
    end)
    if ok and value then
        return log_value(value)
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
        local haystack_text = log_value(haystack or "")
        local needle_text = log_value(needle or "")
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
        cached_carry_component = nil
        cached_anim_instance = nil
        cached_sleep_bed_ability = nil
        cached_sleep_bed_owner_identity = ""
        cached_container_ability = nil
        cached_container_owner_identity = ""
        cached_loot_ability = nil
        cached_loot_owner_identity = ""
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

local function timing_log(label, fields)
    if config.timing ~= true then
        return
    end
    local suffix = tostring(fields or "")
    if suffix ~= "" then
        suffix = " " .. suffix
    end
    log("[timing] " .. tostring(label) .. suffix)
end

local function timed_find_all(class_name, label)
    label = label or "find-all"
    if type(FindAllOf) ~= "function" then
        timing_log(label, "class=" .. tostring(class_name)
            .. " available=false")
        return false, nil
    end

    local started_ms = config.timing == true and now_ms() or 0
    local ok, objects = pcall(function()
        return FindAllOf(class_name)
    end)
    if config.timing == true then
        local object_count = 0
        if ok and type(objects) == "table" then
            object_count = #objects
        end
        timing_log(label, "class=" .. tostring(class_name)
            .. " ok=" .. tostring(ok)
            .. " objects=" .. tostring(object_count)
            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
    end
    return ok, objects
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
    local message = "Hook failed " .. tostring(name) .. ": " .. log_value(pre_id)
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

    local value
    ok, value = pcall(function()
        return method(object, unpack_args(args, 1, args.n))
    end)
    if ok then
        return true, value, "direct-self"
    end
    local first_error = value

    return call_reflected_function(object, method_name, args, unpack_args, first_error)
end

local function param_to_log_string(param)
    local value = get_param_value(param)
    if value == nil then
        return ""
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return log_value(value)
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
        return log_value(value)
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
            return log_value(text)
        end
        method_ok, text = pcall(function()
            return method()
        end)
        if method_ok and text then
            return log_value(text)
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
            return log_value(text)
        end
    end

    local text_ok, text = pcall(function()
        return tostring(value)
    end)
    if text_ok and text then
        return log_value(text)
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
    local text = string.lower(log_value(value or ""))
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
    local number = tonumber(log_value(value or ""))
    if number == nil then
        debug_log("State read returned non-number for "
            .. tostring(description) .. ": " .. log_value(value))
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

diagnostics = runtime_diagnostics.new({
    core = core,
    get_config = function()
        return config
    end,
    log = log,
    contains = contains,
    now_ms = now_ms,
    find_all_of = function(kind)
        return FindAllOf(kind)
    end,
    find_all_of_available = function()
        return type(FindAllOf) == "function"
    end,
    is_usable_object = is_usable_object,
    get_full_name = get_full_name,
    get_class_full_name = get_class_full_name,
    get_param_object = get_param_object,
    param_to_log_string = param_to_log_string,
    locomotion_snapshot = locomotion_snapshot,
})

local function is_crafting_hook(hook_name)
    return contains(hook_name, "/Script/G1R.GameplayAbilityCrafting:")
end

local function clear_tracked_crafting(source)
    tracked_crafting.ability = nil
    tracked_crafting.state = nil
    tracked_crafting.source = tostring(source or "cleared")
    tracked_crafting.last_seen_ms = -1000000
end

local function mark_crafting_context(source, context, ...)
    local first_param = select(1, ...)
    local state = tonumber(param_to_log_string(first_param))
    if core.crafting_hook_should_clear_tracking(source, state) then
        clear_tracked_crafting(source)
        debug_log("Crafting tracking cleared from " .. tostring(source))
        return true
    end
    if core.crafting_hook_should_track_after_cancel(
            now_ms(),
            last_successful_crafting_cancel_ms,
            CRAFTING_RETRACK_LOCKOUT_MS) ~= true
    then
        clear_tracked_crafting("post-cancel-lockout:" .. tostring(source))
        debug_log("Crafting tracking ignored after recent cancel from " .. tostring(source))
        return false
    end

    local ability = get_param_object(context)
    if not ability and is_usable_object(context) then
        ability = context
    end
    if is_usable_object(ability) then
        tracked_crafting.ability = ability
    end

    if state ~= nil then
        tracked_crafting.state = state
    end
    tracked_crafting.source = tostring(source)
    tracked_crafting.last_seen_ms = now_ms()
end

local function player_state_identity()
    if is_usable_object(cached_hero) then
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
    end

    local controller = resolve_player_controller()
    if is_usable_object(controller) then
        local controller_player_state = nil
        pcall(function()
            controller_player_state = controller.PlayerState
        end)
        if is_usable_object(controller_player_state) then
            return get_full_name(controller_player_state)
        end
    end

    return ""
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
    local object_identity = object_identity_text(object)
    if core.object_name_is_player_sleep_interaction_task(object_identity) then
        cancelled_sleep_task_identities[object_identity] = nil
        tracked_interaction.kind = "ambient"
        tracked_interaction.phase = "sleep-task"
        log("[sleep-track] source=" .. tostring(source)
            .. " phase=sleep-task"
            .. " object=" .. object_identity)
        return true
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
    return hook_name == "/Script/G1R.GothicCharacter:GetInventory"
        or hook_name == "/Script/G1R.GothicCharacter:GetCarryComponent"
        or hook_name == "/Script/Engine.Character:PlayAnimMontage"
end

local function key_value_from_name(key_name)
    local normalized = string.upper(trim(key_name))
    for _, candidate in ipairs(core.cancel_key_lookup_candidates(normalized)) do
        local ok, value = pcall(function()
            return Key[candidate]
        end)
        if ok and value ~= nil then
            return value, candidate
        end
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

local function first_usable_object_property(object, property_names)
    if not is_usable_object(object) then
        return nil, ""
    end
    for _, property_name in ipairs(property_names or {}) do
        local ok, value = pcall(function()
            return object[property_name]
        end)
        if ok and is_usable_object(value) then
            return value, tostring(property_name)
        end
    end
    return nil, ""
end

local function crafting_progress_widget(ability)
    if not is_usable_object(ability) then
        return nil
    end

    local hud = nil
    for _, property_name in ipairs({
        "m_HUDCraftingController",
        "HUDCraftingController",
    }) do
        local ok, value = pcall(function()
            return ability[property_name]
        end)
        if ok and is_usable_object(value) then
            hud = value
            break
        end
    end
    if not is_usable_object(hud) then
        return nil
    end

    for _, property_name in ipairs({
        "m_UICraftingProgress",
        "UICraftingProgress",
    }) do
        local ok, value = pcall(function()
            return hud[property_name]
        end)
        if ok and is_usable_object(value) then
            return value
        end
    end
    return nil
end

local function finish_successful_crafting_cancel(key_name, method_name, mode, target)
    last_successful_crafting_cancel_ms = now_ms()
    clear_tracked_crafting("cancelled:" .. tostring(method_name))
    log("[crafting-cancel] key=" .. tostring(key_name)
        .. " method=" .. tostring(method_name)
        .. " mode=" .. tostring(mode)
        .. " object=" .. get_full_name(target))
    return true
end

local function task_cancel_arg_variants(method_name)
    if method_name == "EndTaskWithResult" then
        return { pack_args(1) } -- EGenericTaskResult::Cancelled
    end
    if method_name == "StopPlayingMontage" then
        return {
            pack_args(0.15),
            pack_args(0),
        }
    end
    return { pack_args() }
end

local function task_cancel_call_succeeded(method_name, value)
    if method_name == "StopPlayingMontage" then
        return value ~= false
    end
    return true
end

local function task_is_finished(task)
    local ok, value = call_method(task, "BP_IsFinished")
    return ok == true and value == true
end

local function try_cancel_task_with_methods(
    key_name, task, task_label, method_names, options)
    options = options or {}
    if not is_usable_object(task) then
        return false
    end
    local skip_finished_check = options.skip_finished_check == true
    if skip_finished_check then
        if config.timing == true then
            timing_log("crafting-task-finished", "key="
                .. tostring(key_name)
                .. " target=" .. tostring(task_label)
                .. " result=skipped")
        end
    elseif task_is_finished(task) then
        debug_log("[crafting-task-cancel] task finished"
            .. " target=" .. tostring(task_label)
            .. " object=" .. get_full_name(task))
        if config.timing == true then
            timing_log("crafting-task-finished", "key="
                .. tostring(key_name)
                .. " target=" .. tostring(task_label)
                .. " result=finished")
        end
        return false
    end

    for _, method_name in ipairs(method_names or {}) do
        for _, args in ipairs(task_cancel_arg_variants(method_name)) do
            local method_started_ms = config.timing == true and now_ms() or 0
            local ok, value, mode =
                call_method_with_arg_pack(task, method_name, args)
            if config.timing == true then
                timing_log("crafting-task-method", "key="
                    .. tostring(key_name)
                    .. " target=" .. tostring(task_label)
                    .. " method=" .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " ok=" .. tostring(ok)
                    .. " mode=" .. tostring(mode)
                    .. " elapsedMs=" .. tostring(now_ms() - method_started_ms))
            end
            if ok == true and task_cancel_call_succeeded(method_name, value) then
                return finish_successful_crafting_cancel(key_name,
                    tostring(task_label) .. "." .. tostring(method_name),
                    tostring(mode), task)
            end
            debug_log("[crafting-task-cancel] target=" .. tostring(task_label)
                .. " method=" .. tostring(method_name)
                .. " args=" .. tostring(args.n or 0)
                .. " ok=" .. tostring(ok)
                .. " mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(task))
        end
    end
    return false
end

local function try_cancel_crafting_tasks(key_name, crafting_ability)
    local move_task, move_property =
        first_usable_object_property(crafting_ability,
            core.crafting_move_task_property_names())
    if try_cancel_task_with_methods(key_name, move_task, move_property,
            core.crafting_move_task_cancel_method_names(), {
                skip_finished_check =
                    not core.crafting_task_finished_check_required({
                        property_name = move_property,
                    }),
            })
    then
        return true
    end

    local montage_task, montage_property =
        first_usable_object_property(crafting_ability,
            core.crafting_montage_task_property_names())
    if try_cancel_task_with_methods(key_name, montage_task, montage_property,
            core.crafting_montage_task_cancel_method_names())
    then
        return true
    end

    return false
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

    local crafting_ability = tracked_crafting.ability
    if try_cancel_crafting_tasks(key_name, crafting_ability) then
        return true
    end

    local progress_widget = crafting_progress_widget(crafting_ability)
    local ui_cancel_success = false
    local ui_cancel_mode = "none"
    if is_usable_object(progress_widget) then
        local ok, value, mode = call_method(progress_widget, "CancelCrafting")
        if ok == true then
            ui_cancel_success = true
            ui_cancel_mode = tostring(mode)
            debug_log("[crafting-cancel] method=CancelCrafting"
                .. " ok=true mode=" .. tostring(mode)
                .. " object=" .. get_full_name(progress_widget))
        else
            debug_log("[crafting-cancel] method=CancelCrafting"
                .. " ok=false mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(progress_widget))
        end
    else
        debug_log("[crafting-cancel] no crafting progress widget found")
    end

    for _, ui_state in ipairs(core.crafting_menu_exit_state_candidates()) do
        local args = pack_args(ui_state)
        local ok, value, mode =
            call_method_with_arg_pack(crafting_ability,
                "ButtonCraftingMenuExit_Bind", args)
        if ok == true then
            return finish_successful_crafting_cancel(key_name,
                "ButtonCraftingMenuExit_Bind(" .. tostring(ui_state) .. ")",
                tostring(mode) .. " uiCancel=" .. tostring(ui_cancel_success),
                crafting_ability)
        end
        debug_log("[crafting-cancel] method=ButtonCraftingMenuExit_Bind"
            .. " uiState=" .. tostring(ui_state)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. log_value(value))
    end

    if ui_cancel_success then
        log("[crafting-cancel] partial key=" .. tostring(key_name)
            .. " method=CancelCrafting"
            .. " mode=" .. tostring(ui_cancel_mode)
            .. " abilityExit=false"
            .. " object=" .. get_full_name(progress_widget))
    end
    log("[crafting-cancel] failed key=" .. tostring(key_name))
    return false
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

    local ok, objects = timed_find_all("GameplayAbilityInteractFreePoint",
        "find-player-interact-free-point")
    if not ok or type(objects) ~= "table" then
        debug_log("Player InteractFreePoint ability scan failed: " .. log_value(objects))
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
        and core.object_name_is_sleep_ability(get_full_name(cached_sleep_bed_ability))
    then
        return cached_sleep_bed_ability
    end

    cached_sleep_bed_ability = nil
    cached_sleep_bed_owner_identity = ""

    if type(FindAllOf) ~= "function" then
        return nil
    end

    for _, class_name in ipairs({
        "GameplayAbilitySleep",
        "UGameplayAbilitySleep",
        "GameplayAbilityInteractionBase",
        "GA_Human_Sleep_Bed_Low",
        "GA_Human_Sleep_Bed_High",
        "GA_Human_Sleep_Bed_Ground",
    }) do
        local ok, objects = timed_find_all(class_name,
            "find-player-sleep-bed-ability")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if is_usable_object(object) then
                    local object_name = get_full_name(object)
                    if core.object_name_belongs_to_owner(object_name, owner_identity)
                        and core.object_name_is_sleep_ability(object_name)
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
                .. tostring(class_name) .. ": " .. log_value(objects))
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
        and core.object_name_belongs_to_owner(
            object_identity_text(cached_container_ability), owner_identity)
        and core.object_name_is_container_ability(
            object_identity_text(cached_container_ability))
    then
        return cached_container_ability
    end

    cached_container_ability = nil
    cached_container_owner_identity = ""

    if type(FindAllOf) ~= "function" then
        return nil
    end

    for _, class_name in ipairs({
        "GameplayAbilityOpenContainer",
        "UGameplayAbilityOpenContainer",
        "GA_Human_OpenContainer",
        "GA_Human_OpenContainer_Swimming",
    }) do
        local ok, objects = timed_find_all(class_name,
            "find-player-container-ability")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                local object_identity = object_identity_text(object)
                if is_usable_object(object)
                    and core.object_name_is_container_ability(object_identity)
                    and core.object_name_belongs_to_owner(object_identity,
                        owner_identity)
                then
                    cached_container_ability = object
                    cached_container_owner_identity = owner_identity
                    debug_log("Player OpenContainer ability found: "
                        .. object_identity)
                    return object
                end
            end
        elseif not ok then
            debug_log("Player OpenContainer ability scan failed for class="
                .. tostring(class_name) .. ": " .. log_value(objects))
        end
    end

    debug_log("Player OpenContainer ability not found for owner="
        .. owner_identity)
    return nil
end

local function active_container_ability()
    if is_usable_object(tracked_interaction.object)
        and core.object_name_is_container_ability(
            object_identity_text(tracked_interaction.object))
    then
        return tracked_interaction.object
    end
    return find_player_container_ability()
end

local function object_name_is_loot_ability(object_name)
    local normalized = string.lower(tostring(object_name or ""))
    return string.find(normalized, "gameplayabilityloot", 1, true) ~= nil
        and string.find(normalized, "default__", 1, true) == nil
end

local function find_player_loot_ability()
    local owner_identity = player_state_identity()
    if owner_identity == "" then
        return nil
    end

    if is_usable_object(cached_loot_ability)
        and cached_loot_owner_identity == owner_identity
        and core.object_name_belongs_to_owner(
            object_identity_text(cached_loot_ability), owner_identity)
        and object_name_is_loot_ability(
            object_identity_text(cached_loot_ability))
    then
        return cached_loot_ability
    end

    cached_loot_ability = nil
    cached_loot_owner_identity = ""

    if type(FindAllOf) ~= "function" then
        return nil
    end

    for _, class_name in ipairs({
        "GameplayAbilityLoot",
        "UGameplayAbilityLoot",
    }) do
        local ok, objects = timed_find_all(class_name,
            "find-player-loot-ability")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                local object_identity = object_identity_text(object)
                if is_usable_object(object)
                    and object_name_is_loot_ability(object_identity)
                    and core.object_name_belongs_to_owner(object_identity,
                        owner_identity)
                then
                    cached_loot_ability = object
                    cached_loot_owner_identity = owner_identity
                    debug_log("Player Loot ability found: "
                        .. object_identity)
                    return object
                end
            end
        elseif not ok then
            debug_log("Player Loot ability scan failed for class="
                .. tostring(class_name) .. ": " .. log_value(objects))
        end
    end

    debug_log("Player Loot ability not found for owner=" .. owner_identity)
    return nil
end

local function free_point_container_context_text(ability)
    return object_property_context_text(ability, {
        "m_InteractiveActor",
        "m_InteractionSpot",
        "ActionFilter",
        "m_DefaultInteraction",
    })
end

local function free_point_ladder_context_text(ability)
    return object_property_context_text(ability, {
        "m_InteractiveActor",
        "m_InteractionSpot",
        "ActionFilter",
    })
end

local function free_point_sleep_context_text(ability)
    return object_property_context_text(ability, {
        "m_InteractiveActor",
        "m_InteractionSpot",
        "ActionFilter",
        "m_DefaultInteraction",
    })
end

local function container_ability_target_context_text(ability)
    return object_property_context_text(ability, {
        "m_TaskLootContainer",
        "TaskLootContainer",
        "m_InteractiveActor",
        "m_InteractionSpot",
        "m_InteractiveComponent",
        "m_InteractiveObjectDefinition",
        "m_DefaultInteraction",
        "m_AbilityEnded",
    })
end

local function log_container_context(key_name, context)
    context = context or {}
    local free_point_text = tostring(context.free_point_text or "")
    local ability_text = tostring(context.ability_text or "")
    local ability_ended = context.ability_ended == true
    local ability_context_active = core.container_ability_context_can_cancel({
        ability_available = ability_text ~= "",
        ability_ended = ability_ended,
        context_text = ability_text,
    })
    log("[container-context] key=" .. tostring(key_name)
        .. " tasks=" .. tostring(context.task_count or 0)
        .. " abilities=" .. tostring(context.ability_count or 0)
        .. " widgets=" .. tostring(context.widget_count or 0)
        .. " phase=" .. tostring(context.tracked_phase or "")
        .. " interactionSource={" .. tostring(context.tracked_source or "") .. "}"
        .. " interactionTarget={" .. tostring(context.tracked_target or "") .. "}"
        .. " freePointMatch="
        .. tostring(core.text_is_container_interaction_context(free_point_text))
        .. " abilityMatch="
        .. tostring(core.text_is_container_interaction_context(ability_text))
        .. " freePointAllowed="
        .. tostring(context.free_point_cancel_allowed == true)
        .. " freePointAbility="
        .. tostring(context.free_point_ability_available == true)
        .. " abilityEnded=" .. tostring(ability_ended)
        .. " abilityActiveMatch=" .. tostring(ability_context_active)
        .. " freePoint={" .. tostring(free_point_text) .. "}"
        .. " task={" .. tostring(context.task_sample or "") .. "}"
        .. " abilityObject={" .. tostring(context.ability_sample or "") .. "}"
        .. " widget={" .. tostring(context.widget_sample or "") .. "}"
        .. " widgetState={" .. tostring(context.widget_state or "") .. "}"
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

local function count_candidates_for_classes(class_names, predicate, failure_label)
    if type(FindAllOf) ~= "function" then
        return 0, ""
    end

    local total_started_ms = config.timing == true and now_ms() or 0
    local seen = {}
    local count = 0
    local first_identity = ""
    for _, class_name in ipairs(class_names) do
        local class_started_ms = config.timing == true and now_ms() or 0
        local before_count = count
        local ok, objects = timed_find_all(class_name,
            "candidate-find-all")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                local object_identity = object_identity_text(object)
                if is_usable_object(object)
                    and seen[object_identity] ~= true
                    and predicate(object, object_identity) == true
                then
                    seen[object_identity] = true
                    count = count + 1
                    if first_identity == "" then
                        first_identity = object_identity
                    end
                end
            end
        elseif not ok then
            debug_log(tostring(failure_label) .. " scan failed for class="
                .. tostring(class_name) .. ": " .. log_value(objects))
        end
        if config.timing == true then
            timing_log("candidate-class", "label="
                .. tostring(failure_label)
                .. " class=" .. tostring(class_name)
                .. " matched=" .. tostring(count - before_count)
                .. " totalMatched=" .. tostring(count)
                .. " elapsedMs=" .. tostring(now_ms() - class_started_ms))
        end
    end

    if config.timing == true then
        timing_log("candidate-total", "label=" .. tostring(failure_label)
            .. " classes=" .. tostring(#class_names)
            .. " matched=" .. tostring(count)
            .. " elapsedMs=" .. tostring(now_ms() - total_started_ms))
    end
    return count, first_identity
end

local function count_player_container_interaction_task_candidates()
    return count_candidates_for_classes({
        "AbilityTask_LootWorldContainer",
        "UAbilityTask_LootWorldContainer",
    }, function(task, task_identity)
        local task_context = object_property_context_text(task, {
            "m_ContainerActor",
        })
        local normalized = string.lower(tostring(task_identity or ""))
        return string.find(normalized, "abilitytask_lootworldcontainer", 1, true) ~= nil
            and core.text_is_container_interaction_context(task_context)
    end, "Player container interaction task")
end

local function count_player_container_ability_candidates()
    local owner_identity = player_state_identity()
    if owner_identity == "" then
        return 0, ""
    end

    return count_candidates_for_classes({
        "GameplayAbilityOpenContainer",
        "UGameplayAbilityOpenContainer",
        "GA_Human_OpenContainer",
        "GA_Human_OpenContainer_Swimming",
    }, function(_ability, ability_identity)
        return core.object_name_is_container_ability(ability_identity)
            and core.object_name_belongs_to_owner(ability_identity, owner_identity)
    end, "Player container ability")
end

local function count_loot_container_widget_candidates()
    return count_candidates_for_classes({
        "W_LootContainer_Chest_C",
        "UW_LootContainer_Chest_C",
    }, function(_widget, widget_identity)
        local normalized = string.lower(tostring(widget_identity or ""))
        return string.find(normalized, "w_lootcontainer_chest", 1, true) ~= nil
            and string.find(normalized, "default__", 1, true) == nil
    end, "Loot container widget")
end

local function find_loot_container_widgets()
    local widgets = {}
    if type(FindAllOf) ~= "function" then
        return widgets
    end

    for _, class_name in ipairs({
        "W_LootContainer_Chest_C",
        "UW_LootContainer_Chest_C",
    }) do
        local ok, objects = timed_find_all(class_name,
            "find-loot-container-widget")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                local object_identity = object_identity_text(object)
                local normalized = string.lower(tostring(object_identity or ""))
                if is_usable_object(object)
                    and string.find(normalized, "w_lootcontainer_chest", 1, true) ~= nil
                    and string.find(normalized, "default__", 1, true) == nil
                then
                    append_unique_object(widgets, object)
                end
            end
        elseif not ok then
            debug_log("Loot container widget scan failed for class="
                .. tostring(class_name) .. ": " .. log_value(objects))
        end
    end

    return widgets
end

local function loot_widget_runtime_state(widget)
    local state = {
        text = "",
        is_activated = nil,
        is_visible = nil,
    }
    if not is_usable_object(widget) then
        return state
    end

    local parts = {
        "object=" .. get_full_name(widget),
    }
    for _, method_name in ipairs({
        "IsActivated",
        "IsVisible",
        "GetVisibility",
    }) do
        local ok, value, mode = call_method(widget, method_name)
        if ok == true and type(value) == "boolean" then
            if method_name == "IsActivated" then
                state.is_activated = value
            elseif method_name == "IsVisible" then
                state.is_visible = value
            end
        end
        table.insert(parts, tostring(method_name)
            .. ".ok=" .. tostring(ok)
            .. ".mode=" .. tostring(mode)
            .. ".value=" .. log_value(value))
    end
    for _, property_name in ipairs({
        "Visibility",
        "RenderOpacity",
        "bIsEnabled",
        "bIsFocusable",
    }) do
        local ok, value = pcall(function()
            return widget[property_name]
        end)
        if ok then
            table.insert(parts, tostring(property_name)
                .. "=" .. log_value(value))
        end
    end
    state.text = table.concat(parts, " ")
    return state
end

local function widget_state_context_text(widget)
    return loot_widget_runtime_state(widget).text
end

local function find_player_sleep_interaction_tasks()
    local tasks = {}
    local tracked_task_identity = ""
    if tracked_interaction.active == true
        and is_usable_object(tracked_interaction.object)
    then
        tracked_task_identity = object_identity_text(tracked_interaction.object)
        if core.object_name_is_player_sleep_interaction_task(tracked_task_identity) then
            append_unique_object(tasks, tracked_interaction.object)
        else
            tracked_task_identity = ""
        end
    end
    if type(FindAllOf) ~= "function" then
        return tasks
    end

    for _, class_name in ipairs({
        "AbilityTask_Interaction_Player_SitAndSleep",
        "UAbilityTask_Interaction_Player_SitAndSleep",
        "AbilityTask_InteractionSpot_Montage",
    }) do
        local ok, objects = timed_find_all(class_name,
            "find-player-sleep-task")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                local object_identity = object_identity_text(object)
                if is_usable_object(object)
                    and core.object_name_is_player_sleep_interaction_task(object_identity)
                    and core.sleep_task_scan_candidate_allowed({
                        task_cancelled_before =
                            cancelled_sleep_task_identities[object_identity] == true,
                        tracked_task = object_identity == tracked_task_identity,
                    })
                then
                    append_unique_object(tasks, object)
                end
            end
        elseif not ok then
            debug_log("Player sleep interaction task scan failed for class="
                .. tostring(class_name) .. ": " .. log_value(objects))
        end
    end

    return tasks
end

local function count_player_sleep_interaction_task_candidates()
    local tracked_task_identity = ""
    if tracked_interaction.active == true
        and is_usable_object(tracked_interaction.object)
    then
        tracked_task_identity = object_identity_text(tracked_interaction.object)
        if not core.object_name_is_player_sleep_interaction_task(tracked_task_identity) then
            tracked_task_identity = ""
        end
    end
    if type(FindAllOf) ~= "function" then
        return 0
    end

    local seen = {}
    local count = 0
    for _, class_name in ipairs({
        "AbilityTask_Interaction_Player_SitAndSleep",
        "UAbilityTask_Interaction_Player_SitAndSleep",
        "AbilityTask_InteractionSpot_Montage",
    }) do
        local ok, objects = timed_find_all(class_name,
            "count-player-sleep-task")
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                local object_identity = object_identity_text(object)
                if is_usable_object(object)
                    and core.object_name_is_player_sleep_interaction_task(object_identity)
                    and core.sleep_task_scan_candidate_allowed({
                        task_cancelled_before =
                            cancelled_sleep_task_identities[object_identity] == true,
                        tracked_task = object_identity == tracked_task_identity,
                    })
                    and seen[object_identity] ~= true
                then
                    seen[object_identity] = true
                    count = count + 1
                end
            end
        elseif not ok then
            debug_log("Player sleep interaction task count failed for class="
                .. tostring(class_name) .. ": " .. log_value(objects))
        end
    end

    return count
end

local function find_player_container_interaction_tasks()
    local tasks = {}
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
    if core.sleep_movement_tracking_from_hook(source) ~= true then
        return false
    end

    local ability = get_param_object(context)
    if not ability and is_usable_object(context) then
        ability = context
    end
    if not is_usable_object(ability)
        or not core.object_name_is_sleep_ability(object_identity_text(ability))
    then
        ability = find_player_sleep_bed_ability()
    end
    if not is_usable_object(ability)
        or not core.object_name_is_sleep_ability(object_identity_text(ability))
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
    cancelled_sleep_task_identities = {}
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
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(ability))
        end
    end
    return return_any_success == true and any_success == true
end

local function try_cancel_container_ability(key_name, return_any_success, ability)
    return false
end

local function try_request_container_close(key_name, ability)
    ability = ability or active_container_ability()
    if not is_usable_object(ability) then
        return false
    end

    local any_success = false
    for _, method_name in ipairs(core.open_container_close_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        if ok == true then
            any_success = true
        end
        log("[container-ability-attempt] key=" .. tostring(key_name)
            .. " method=" .. tostring(method_name)
            .. " ok=" .. tostring(ok)
            .. " mode=" .. tostring(mode)
            .. " result=" .. log_value(value)
            .. " object=" .. get_full_name(ability))
    end
    return any_success
end

local function try_request_loot_ability_close(key_name, ability)
    ability = ability or find_player_loot_ability()
    if not is_usable_object(ability) then
        return false
    end

    local any_success = false
    for _, method_name in ipairs(core.loot_ability_close_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        if ok == true then
            any_success = true
        end
        log("[loot-ability-attempt] key=" .. tostring(key_name)
            .. " method=" .. tostring(method_name)
            .. " ok=" .. tostring(ok)
            .. " mode=" .. tostring(mode)
            .. " result=" .. log_value(value)
            .. " object=" .. get_full_name(ability))
    end
    return any_success
end

local function task_is_active(task)
    if not is_usable_object(task) then
        return false
    end
    local ok, value = call_method(task, "BP_IsActive")
    if ok == true then
        return value == true
    end
    return false
end

local function task_avatar_matches_player(task)
    if not is_usable_object(task) then
        return false
    end
    if not is_usable_object(cached_hero) then
        refresh_player_from_controller()
    end
    local ok, avatar = call_method(task, "GetAvatarCharacter")
    if ok == true and is_usable_object(avatar) then
        local avatar_name = get_full_name(avatar)
        if cached_hero_identity ~= "" and avatar_name == cached_hero_identity then
            return true
        end
        return mark_hero(avatar, "container interaction task avatar")
    end
    return false
end

local function root_interaction_task(ability)
    if not is_usable_object(ability) then
        return nil
    end
    for _, property_name in ipairs(core.root_interaction_task_property_names()) do
        local ok, task = pcall(function()
            return ability[property_name]
        end)
        if ok and is_usable_object(task) then
            return task
        end
    end
    return nil
end

local function append_interaction_task_tree(objects, task, depth)
    if depth <= 0 or not is_usable_object(task) then
        return
    end
    append_unique_object(objects, task)
    for _, property_name in ipairs(core.root_interaction_subtask_property_names()) do
        local ok, subtask = pcall(function()
            return task[property_name]
        end)
        if ok and is_usable_object(subtask) then
            append_interaction_task_tree(objects, subtask, depth - 1)
        end
    end
end

local function try_cancel_container_root_task_target(
    key_name, task, task_index, attempt_log_name, options)
    options = options or {}
    attempt_log_name = attempt_log_name or "[container-root-task-attempt]"
    if not is_usable_object(task) then
        return false
    end
    local target_started_ms = config.timing == true and now_ms() or 0
    local skip_finished_check = options.skip_finished_check == true
    if skip_finished_check then
        if config.timing == true then
            timing_log("container-root-task-finished", "key="
                .. tostring(key_name)
                .. " target=" .. tostring(task_index)
                .. " result=skipped")
        end
    elseif task_is_finished(task) then
        debug_log("[container-root-task-cancel] task finished"
            .. " target=" .. tostring(task_index)
            .. " object=" .. get_full_name(task))
        if config.timing == true then
            timing_log("container-root-task-target", "key="
                .. tostring(key_name)
                .. " target=" .. tostring(task_index)
                .. " result=finished"
                .. " elapsedMs=" .. tostring(now_ms() - target_started_ms))
        end
        return false
    end

    for _, method_name in ipairs(
        core.container_root_interaction_task_cancel_method_names())
    do
        for _, args in ipairs(task_cancel_arg_variants(method_name)) do
            local method_started_ms = config.timing == true and now_ms() or 0
            local ok, value, mode =
                call_method_with_arg_pack(task, method_name, args)
            local method_elapsed_ms =
                config.timing == true and (now_ms() - method_started_ms) or 0
            log(tostring(attempt_log_name) .. " key=" .. tostring(key_name)
                .. " target=" .. tostring(task_index)
                .. " method=" .. tostring(method_name)
                .. " args=" .. tostring(args.n or 0)
                .. " ok=" .. tostring(ok)
                .. " mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(task))
            if config.timing == true then
                timing_log("container-root-task-method", "key="
                    .. tostring(key_name)
                    .. " target=" .. tostring(task_index)
                    .. " method=" .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " ok=" .. tostring(ok)
                    .. " mode=" .. tostring(mode)
                    .. " elapsedMs=" .. tostring(method_elapsed_ms))
            end
            if ok == true and task_cancel_call_succeeded(method_name, value) then
                if config.timing == true then
                    timing_log("container-root-task-target", "key="
                        .. tostring(key_name)
                        .. " target=" .. tostring(task_index)
                        .. " result=cancelled"
                        .. " method=" .. tostring(method_name)
                        .. " elapsedMs="
                        .. tostring(now_ms() - target_started_ms))
                end
                return true, method_name, mode
            end
        end
    end
    if config.timing == true then
        timing_log("container-root-task-target", "key="
            .. tostring(key_name)
            .. " target=" .. tostring(task_index)
            .. " result=failed"
            .. " elapsedMs=" .. tostring(now_ms() - target_started_ms))
    end
    return false
end

local function try_cancel_container_root_interaction_task(key_name, ability)
    if not is_usable_object(ability) then
        return false
    end
    local task = root_interaction_task(ability)
    if not is_usable_object(task) then
        log("[container-root-task-cancel] no-root key=" .. tostring(key_name)
            .. " ability=" .. get_full_name(ability))
        return false
    end

    local tasks = {}
    append_interaction_task_tree(tasks, task, 4)
    for index, candidate in ipairs(tasks) do
        local ok, method_name, mode =
            try_cancel_container_root_task_target(key_name, candidate, index)
        if ok == true then
            last_successful_interaction_cancel_ms = now_ms()
            clear_tracked_interaction("container-root-task-cancelled")
            log("[container-root-task-cancel] key=" .. tostring(key_name)
                .. " target=" .. tostring(index)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " ability=" .. get_full_name(ability)
                .. " root=" .. get_full_name(task)
                .. " object=" .. get_full_name(candidate))
            return true
        end
    end

    log("[container-root-task-cancel] failed key=" .. tostring(key_name)
        .. " ability=" .. get_full_name(ability)
        .. " root=" .. get_full_name(task))
    return false
end

local function try_cancel_container_player_interaction_task(
    key_name, task, task_index, scan_class_name)
    if not is_usable_object(task) then
        return false
    end

    local avatar_started_ms = config.timing == true and now_ms() or 0
    local avatar_matches = task_avatar_matches_player(task) == true
    if config.timing == true then
        timing_log("container-player-task-avatar", "key="
            .. tostring(key_name)
            .. " class=" .. tostring(scan_class_name)
            .. " target=" .. tostring(task_index)
            .. " result=" .. tostring(avatar_matches)
            .. " elapsedMs=" .. tostring(now_ms() - avatar_started_ms))
    end
    if avatar_matches ~= true then
        return false
    end
    local ok, method_name, mode =
        try_cancel_container_root_task_target(key_name, task, task_index,
            "[container-player-task-attempt]", {
                skip_finished_check =
                    not core.container_player_interaction_task_finished_check_required({
                        scan_class_name = scan_class_name,
                    }),
            })
    if ok == true then
        last_successful_interaction_cancel_ms = now_ms()
        clear_tracked_interaction("container-player-task-cancelled")
        log("[container-player-task-cancel] key=" .. tostring(key_name)
            .. " class=" .. tostring(scan_class_name)
            .. " target=" .. tostring(task_index)
            .. " method=" .. tostring(method_name)
            .. " mode=" .. tostring(mode)
            .. " object=" .. get_full_name(task))
        return true
    end
    return false
end

local function try_cancel_container_player_interaction_task_class(
    key_name, class_name, seen, scanned_count)
    if type(FindAllOf) ~= "function" then
        return false, scanned_count
    end
    local started_ms = config.timing == true and now_ms() or 0
    local before_scanned_count = scanned_count
    local ok, objects = timed_find_all(class_name,
        "container-player-task-find-all")
    if not ok or type(objects) ~= "table" then
        debug_log("[container-player-task-scan] class="
            .. tostring(class_name)
            .. " error=" .. log_value(objects))
        if config.timing == true then
            timing_log("container-player-task-class", "key="
                .. tostring(key_name)
                .. " class=" .. tostring(class_name)
                .. " ok=false"
                .. " scanned="
                .. tostring(scanned_count - before_scanned_count)
                .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        end
        return false, scanned_count
    end

    for _, object in ipairs(objects) do
        if is_usable_object(object) then
            local identity = object_identity_text(object)
            if seen[identity] ~= true then
                seen[identity] = true
                scanned_count = scanned_count + 1
                if try_cancel_container_player_interaction_task(
                        key_name, object, scanned_count, class_name)
                then
                    if config.timing == true then
                        timing_log("container-player-task-class", "key="
                            .. tostring(key_name)
                            .. " class=" .. tostring(class_name)
                            .. " ok=true"
                            .. " result=cancelled"
                            .. " scanned="
                            .. tostring(scanned_count - before_scanned_count)
                            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
                    end
                    return true, scanned_count
                end
            end
        end
    end
    if config.timing == true then
        timing_log("container-player-task-class", "key="
            .. tostring(key_name)
            .. " class=" .. tostring(class_name)
            .. " ok=true"
            .. " result=miss"
            .. " scanned=" .. tostring(scanned_count - before_scanned_count)
            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
    end
    return false, scanned_count
end

local function try_cancel_container_player_interaction_tasks(key_name)
    local started_ms = now_ms()
    local seen = {}
    local scanned_count = 0
    if tracked_interaction.active == true
        and is_usable_object(tracked_interaction.object)
    then
        local identity = object_identity_text(tracked_interaction.object)
        seen[identity] = true
        scanned_count = scanned_count + 1
        if try_cancel_container_player_interaction_task(
                key_name, tracked_interaction.object, scanned_count, "tracked")
        then
            if config.timing == true then
                timing_log("container-player-task-total", "key="
                    .. tostring(key_name)
                    .. " result=tracked"
                    .. " scanned=" .. tostring(scanned_count)
                    .. " elapsedMs=" .. tostring(now_ms() - started_ms))
            end
            return true
        end
    end

    for _, class_name in ipairs(
        core.container_player_interaction_task_scan_classes())
    do
        local ok
        ok, scanned_count =
            try_cancel_container_player_interaction_task_class(
                key_name, class_name, seen, scanned_count)
        if ok == true then
            debug_log("[container-player-task-scan] stopped key="
                .. tostring(key_name)
                .. " class=" .. tostring(class_name)
                .. " scanned=" .. tostring(scanned_count)
                .. " elapsedMs=" .. tostring(now_ms() - started_ms))
            if config.timing == true then
                timing_log("container-player-task-total", "key="
                    .. tostring(key_name)
                    .. " result=success"
                    .. " class=" .. tostring(class_name)
                    .. " scanned=" .. tostring(scanned_count)
                    .. " elapsedMs=" .. tostring(now_ms() - started_ms))
            end
            return true
        end
    end
    log("[container-player-task-cancel] failed key=" .. tostring(key_name)
        .. " tasks=" .. tostring(scanned_count)
        .. " elapsedMs=" .. tostring(now_ms() - started_ms))
    if config.timing == true then
        timing_log("container-player-task-total", "key=" .. tostring(key_name)
            .. " result=failed"
            .. " scanned=" .. tostring(scanned_count)
            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
    end
    return false
end

local function try_fast_cancel_container_movement(
    key_name, interact_free_point_ability)
    local started_ms = now_ms()
    local free_point_container_text =
        free_point_container_context_text(interact_free_point_ability)
    local free_point_fast_context = {
        tracked_source = tracked_interaction.source,
        tracked_target = tracked_interaction.target,
        tracked_phase = tracked_interaction.phase,
        free_point_context = free_point_container_text,
        ability_context = "",
        loot_ui_active = false,
    }
    local fast_path_allowed =
        core.container_fast_path_context_can_cancel(free_point_fast_context)
    if fast_path_allowed ~= true
        and (core.text_is_seating_interaction_context(
                free_point_fast_context.tracked_source) == true
            or core.text_is_seating_interaction_context(
                free_point_fast_context.tracked_target) == true
            or core.text_is_seating_interaction_context(
                free_point_fast_context.free_point_context) == true
            or core.text_is_sleep_interaction_context(
                free_point_fast_context.tracked_source) == true
            or core.text_is_sleep_interaction_context(
                free_point_fast_context.tracked_target) == true
            or core.text_is_sleep_interaction_context(
                free_point_fast_context.free_point_context) == true
            or core.text_is_ladder_interaction_context(
                free_point_fast_context.tracked_source) == true
            or core.text_is_ladder_interaction_context(
                free_point_fast_context.tracked_target) == true
            or core.text_is_ladder_interaction_context(
                free_point_fast_context.free_point_context) == true)
    then
        if config.timing == true then
            timing_log("container-fast-path", "key=" .. tostring(key_name)
                .. " result=blocked-non-container"
                .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        end
        return false, free_point_container_text, nil, ""
    end

    local container_ability = nil
    local container_ability_text = ""
    if fast_path_allowed ~= true then
        container_ability = active_container_ability()
        container_ability_text =
            container_ability_target_context_text(container_ability)
        fast_path_allowed = core.container_fast_path_context_can_cancel({
            tracked_source = tracked_interaction.source,
            tracked_target = tracked_interaction.target,
            tracked_phase = tracked_interaction.phase,
            free_point_context = free_point_container_text,
            ability_context = container_ability_text,
            loot_ui_active = false,
        })
    end
    if fast_path_allowed ~= true then
        if config.timing == true then
            timing_log("container-fast-path", "key=" .. tostring(key_name)
                .. " result=context-miss"
                .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        end
        return false, free_point_container_text, container_ability,
            container_ability_text
    end

    debug_log("[container-fast-path] key=" .. tostring(key_name)
        .. " phase=" .. tostring(tracked_interaction.phase)
        .. " freePoint={" .. tostring(free_point_container_text) .. "}"
        .. " ability={" .. tostring(container_ability_text) .. "}")
    if try_cancel_container_root_interaction_task(
            key_name, interact_free_point_ability)
    then
        debug_log("[container-fast-path] root success key="
            .. tostring(key_name)
            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        if config.timing == true then
            timing_log("container-fast-path", "key=" .. tostring(key_name)
                .. " result=root-success"
                .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        end
        return true, free_point_container_text, container_ability,
            container_ability_text
    end
    if try_cancel_container_player_interaction_tasks(key_name) then
        debug_log("[container-fast-path] player task success key="
            .. tostring(key_name)
            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        if config.timing == true then
            timing_log("container-fast-path", "key=" .. tostring(key_name)
                .. " result=player-task-success"
                .. " elapsedMs=" .. tostring(now_ms() - started_ms))
        end
        return true, free_point_container_text, container_ability,
            container_ability_text
    end

    debug_log("[container-fast-path] no task cancelled key="
        .. tostring(key_name)
        .. " elapsedMs=" .. tostring(now_ms() - started_ms))
    if config.timing == true then
        timing_log("container-fast-path", "key=" .. tostring(key_name)
            .. " result=no-task"
            .. " elapsedMs=" .. tostring(now_ms() - started_ms))
    end
    return false, free_point_container_text, container_ability,
        container_ability_text
end

local function try_cancel_container_move_task(key_name, ability)
    ability = ability or active_container_ability()
    if not is_usable_object(ability) then
        return false
    end

    local task, property_name = first_usable_object_property(ability,
        core.container_move_task_property_names())
    if not is_usable_object(task) then
        debug_log("[container-move-cancel] no move task"
            .. " ability=" .. get_full_name(ability))
        return false
    end
    local task_context = {
        property_name = property_name,
        task_name = get_full_name(task),
    }
    if core.container_task_active_check_required(task_context)
        and task_is_active(task) ~= true
    then
        debug_log("[container-move-cancel] move task inactive"
            .. " property=" .. tostring(property_name)
            .. " object=" .. get_full_name(task))
        return false
    end

    for _, method_name in ipairs(
        core.container_task_cancel_method_names(task_context))
    do
        for _, args in ipairs(task_cancel_arg_variants(method_name)) do
            local ok, value, mode =
                call_method_with_arg_pack(task, method_name, args)
            if ok == true
                and task_cancel_call_succeeded(method_name, value)
                and core.container_task_cancel_call_is_terminal(
                    task_context, method_name, value)
            then
                last_successful_interaction_cancel_ms = now_ms()
                clear_tracked_interaction("container-move-cancelled")
                log("[container-move-cancel] key=" .. tostring(key_name)
                    .. " property=" .. tostring(property_name)
                    .. " method=" .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " mode=" .. tostring(mode)
                    .. " ability=" .. get_full_name(ability)
                    .. " object=" .. get_full_name(task))
                return true
            end
            if ok == true then
                log("[container-move-attempt] key=" .. tostring(key_name)
                    .. " property=" .. tostring(property_name)
                    .. " method=" .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " mode=" .. tostring(mode)
                    .. " result=" .. log_value(value)
                    .. " ability=" .. get_full_name(ability)
                    .. " object=" .. get_full_name(task))
            end
            debug_log("[container-move-cancel] property="
                .. tostring(property_name)
                .. " method=" .. tostring(method_name)
                .. " args=" .. tostring(args.n or 0)
                .. " ok=" .. tostring(ok)
                .. " mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(task))
        end
    end

    log("[container-move-cancel] failed key=" .. tostring(key_name)
        .. " property=" .. tostring(property_name)
        .. " ability=" .. get_full_name(ability)
        .. " object=" .. get_full_name(task))
    return false
end

local function try_cancel_container_free_point_movement(key_name, ability, terminal)
    if not is_usable_object(ability) then
        log("[container-freepoint-cancel] unavailable key=" .. tostring(key_name))
        return false
    end

    local any_success = false
    local last_method = ""
    local last_mode = ""
    local last_value = nil
    for _, method_name in ipairs(core.movement_action_cancel_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        log("[container-freepoint-attempt] key=" .. tostring(key_name)
            .. " method=" .. tostring(method_name)
            .. " ok=" .. tostring(ok)
            .. " mode=" .. tostring(mode)
            .. " result=" .. log_value(value)
            .. " object=" .. get_full_name(ability))
        if ok == true then
            any_success = true
            last_method = tostring(method_name)
            last_mode = tostring(mode)
            last_value = value
        end
    end

    if any_success then
        if terminal == false then
            debug_log("[container-freepoint-cancel] non-terminal key="
                .. tostring(key_name)
                .. " method=" .. tostring(last_method)
                .. " mode=" .. tostring(last_mode)
                .. " result=" .. log_value(last_value)
                .. " object=" .. get_full_name(ability))
            return true
        end
        last_successful_interaction_cancel_ms = now_ms()
        clear_tracked_interaction("container-freepoint-cancelled")
        log("[container-freepoint-cancel] key=" .. tostring(key_name)
            .. " method=" .. tostring(last_method)
            .. " mode=" .. tostring(last_mode)
            .. " result=" .. log_value(last_value)
            .. " object=" .. get_full_name(ability))
        return true
    end

    log("[container-freepoint-cancel] failed key=" .. tostring(key_name)
        .. " object=" .. get_full_name(ability))
    return false
end

local function try_close_loot_container_widget(key_name)
    local widgets = find_loot_container_widgets()
    for _, widget in ipairs(widgets) do
        for _, method_name in ipairs(core.loot_container_widget_cancel_method_names()) do
            local ok, value, mode = call_method(widget, method_name)
            log("[container-ui-attempt] key=" .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " ok=" .. tostring(ok)
                .. " mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(widget))
            if ok == true
                and core.loot_container_widget_cancel_call_succeeded(method_name, value)
            then
                last_successful_interaction_cancel_ms = now_ms()
                clear_tracked_interaction("container-ui-cancelled")
                log("[container-ui-cancel] key=" .. tostring(key_name)
                    .. " method=" .. tostring(method_name)
                    .. " mode=" .. tostring(mode)
                    .. " object=" .. get_full_name(widget))
                return true
            end
        end
    end
    return false
end

local function sleep_root_interaction_task(ability)
    return root_interaction_task(ability)
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
            .. " result=" .. log_value(value)
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
                    .. " result=" .. log_value(value)
                    .. " object=" .. get_full_name(target))
            end
        end
    end
    return any_success
end

local function try_cancel_container_montage(key_name)
    return false
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
            .. " result=" .. log_value(value)
            .. " object=" .. get_full_name(task))
    end

    return false
end

local function try_cancel_container_interaction_task(key_name, task)
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
    local successful_sleep_task = nil
    for _, task in ipairs(sleep_tasks) do
        if try_cancel_sleep_interaction_task(key_name, task) then
            task_success = true
            successful_sleep_task = task
            break
        end
    end
    if task_success then
        cancelled_sleep_task_identities[object_identity_text(successful_sleep_task)] = true
        local ability_cleanup = false
        local montage_success = false
        if core.sleep_task_cancel_should_try_montage({
                task_success = task_success,
            })
        then
            montage_success = try_cancel_sleep_montage(key_name)
        end
        if sleep_interaction_allows_ability_cleanup() then
            ability_cleanup = try_cancel_sleep_ability(key_name, true)
        end
        debug_log("[sleep-task-cancel] key=" .. tostring(key_name)
            .. " montage=" .. tostring(montage_success)
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
    return false
end

local function try_fast_cancel_seating_movement(
    key_name, ability, free_point_context_text)
    if core.seating_fast_path_context_can_cancel({
            tracked_source = tracked_interaction.source,
            tracked_target = tracked_interaction.target,
            tracked_phase = tracked_interaction.phase,
            free_point_context = free_point_context_text,
        }) ~= true
    then
        return false
    end
    if not is_usable_object(ability) then
        return false
    end

    for _, method_name in ipairs(core.movement_action_cancel_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        if ok == true then
            last_successful_interaction_cancel_ms = now_ms()
            clear_tracked_interaction("seating-fast-cancelled")
            log("[seating-fast-cancel] key=" .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " object=" .. get_full_name(ability)
                .. " context={" .. tostring(free_point_context_text) .. "}")
            return true
        end
        debug_log("[seating-fast-cancel] method=" .. tostring(method_name)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. log_value(value)
            .. " object=" .. get_full_name(ability))
    end
    return false
end

local function try_cleanup_player_interaction_free_point(key_name, ability)
    if not is_usable_object(ability) then
        return false
    end

    for _, method_name in ipairs(core.movement_action_cancel_method_names()) do
        local ok, value, mode = call_method(ability, method_name)
        if ok == true then
            log("[interaction-freepoint-cleanup] key=" .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
                .. " object=" .. get_full_name(ability))
            return true
        end
        debug_log("[interaction-freepoint-cleanup] method="
            .. tostring(method_name)
            .. " ok=false mode=" .. tostring(mode)
            .. " result=" .. log_value(value)
            .. " object=" .. get_full_name(ability))
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
    local ability_success = false
    if core.sleep_movement_should_try_ability_cancel({
            root_task_success = root_task_success,
        })
    then
        ability_success = try_cancel_sleep_ability(key_name, true)
    end
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

    if core.text_is_ladder_interaction_context(tracked_interaction.source)
        or core.text_is_ladder_interaction_context(tracked_interaction.target)
    then
        debug_log("[interaction-cancel] blocked traversal source="
            .. tostring(tracked_interaction.source)
            .. " target=" .. tostring(tracked_interaction.target))
        return false
    end

    local interact_free_point_ability = find_player_interact_free_point_ability()
    local read_ladder_context = core.ladder_free_point_context_should_be_read({
        tracked_source = tracked_interaction.source,
        tracked_target = tracked_interaction.target,
    })
    if read_ladder_context then
        local free_point_ladder_text =
            free_point_ladder_context_text(interact_free_point_ability)
        if core.text_is_ladder_interaction_context(free_point_ladder_text)
        then
            debug_log("[interaction-cancel] blocked ladder target context={"
                .. tostring(free_point_ladder_text) .. "}")
            return false
        end
    end
    local fast_container_cancelled = false
    local free_point_container_text = ""
    local fast_container_ability = nil
    local fast_container_ability_text = ""
    fast_container_cancelled, free_point_container_text, fast_container_ability,
        fast_container_ability_text =
        try_fast_cancel_container_movement(key_name, interact_free_point_ability)
    if fast_container_cancelled then
        return true
    end

    local free_point_sleep_text =
        free_point_sleep_context_text(interact_free_point_ability)
    if try_fast_cancel_seating_movement(
            key_name, interact_free_point_ability, free_point_sleep_text)
    then
        return true
    end
    local sleep_task_cancel_context = core.sleep_task_cancel_context_allowed({
        tracked_source = tracked_interaction.source,
        tracked_target = tracked_interaction.target,
        tracked_object = object_identity_text(tracked_interaction.object),
        tracked_phase = tracked_interaction.phase,
        free_point_context = free_point_sleep_text,
    })
    local player_task_fallback_attempted = false
    local function try_player_task_fallback(stage)
        if core.player_interaction_task_fallback_should_scan({
                tracked_source = tracked_interaction.source,
                tracked_target = tracked_interaction.target,
                tracked_phase = tracked_interaction.phase,
                free_point_context = free_point_container_text,
                ability_context = fast_container_ability_text,
                free_point_ability_available =
                    is_usable_object(interact_free_point_ability),
                loot_ui_active = false,
            })
        then
            player_task_fallback_attempted = true
            local started_ms = config.timing == true and now_ms() or 0
            local player_task_cancelled =
                try_cancel_container_player_interaction_tasks(key_name)
            if config.timing == true then
                timing_log("player-task-fallback", "key=" .. tostring(key_name)
                    .. " stage=" .. tostring(stage)
                    .. " result=" .. tostring(player_task_cancelled)
                    .. " elapsedMs=" .. tostring(now_ms() - started_ms))
            end
            if player_task_cancelled then
                try_cleanup_player_interaction_free_point(
                    key_name, interact_free_point_ability)
                return true
            end
        end
        return false
    end
    if core.player_interaction_task_fallback_should_precede_sleep_probe({
            tracked_source = tracked_interaction.source,
            tracked_target = tracked_interaction.target,
            tracked_object = object_identity_text(tracked_interaction.object),
            tracked_phase = tracked_interaction.phase,
            free_point_context = free_point_sleep_text,
            ability_context = fast_container_ability_text,
            free_point_ability_available =
                is_usable_object(interact_free_point_ability),
            loot_ui_active = false,
        })
        and try_player_task_fallback("pre-sleep")
    then
        return true
    end
    local sleep_tasks = {}
    if not sleep_task_cancel_context then
        local sleep_task_candidate_count =
            count_player_sleep_interaction_task_candidates()
        if sleep_task_candidate_count > 0 then
            log("[sleep-context-miss] key=" .. tostring(key_name)
                .. " tasks=" .. tostring(sleep_task_candidate_count)
                .. " useTaskScan=true"
                .. " phase=" .. tostring(tracked_interaction.phase)
                .. " source=" .. tostring(tracked_interaction.source)
                .. " target=" .. tostring(tracked_interaction.target)
                .. " object=" .. object_identity_text(tracked_interaction.object)
                .. " freePoint={" .. tostring(free_point_sleep_text) .. "}")
        end
        sleep_task_cancel_context = core.sleep_task_cancel_context_allowed({
            tracked_source = tracked_interaction.source,
            tracked_target = tracked_interaction.target,
            tracked_object = object_identity_text(tracked_interaction.object),
            tracked_phase = tracked_interaction.phase,
            free_point_context = free_point_sleep_text,
            player_sleep_task_candidates = sleep_task_candidate_count,
        })
    end
    if sleep_task_cancel_context then
        sleep_tasks = find_player_sleep_interaction_tasks()
    end
    local sleep_interaction_context = #sleep_tasks > 0
    local sleep_interaction_cancelled = try_cancel_sleep_interaction(key_name, sleep_tasks)
    if sleep_interaction_cancelled then
        return true
    end
    if try_cancel_sleep_movement(key_name) then
        return true
    end
    if free_point_container_text == "" then
        free_point_container_text =
            free_point_container_context_text(interact_free_point_ability)
    end
    if player_task_fallback_attempted ~= true
        and try_player_task_fallback("post-sleep")
    then
        return true
    end
    local container_task_count, container_task_sample =
        count_player_container_interaction_task_candidates()
    local container_widget_count, container_widget_sample =
        count_loot_container_widget_candidates()
    local container_context = {
        tracked_source = tracked_interaction.source,
        tracked_target = tracked_interaction.target,
        tracked_object = object_identity_text(tracked_interaction.object),
        free_point_context = free_point_container_text,
        task_count = container_task_count,
        widget_count = container_widget_count,
    }
    local should_handle_container =
        core.interaction_container_context_should_attempt_cancel(container_context)
    local container_ability = nil
    local loot_ability = nil
    local container_ability_text = ""
    local container_ability_count = 0
    local container_ability_sample = ""
    local container_widget_state = ""
    local container_widget_runtime_state = {
        text = "",
        is_activated = nil,
        is_visible = nil,
    }
    if should_handle_container then
        container_ability = fast_container_ability
        if not is_usable_object(container_ability) then
            container_ability = active_container_ability()
        end
        container_ability_text = fast_container_ability_text
        if container_ability_text == "" then
            container_ability_text =
                container_ability_target_context_text(container_ability)
        end
        container_ability_count, container_ability_sample =
            count_player_container_ability_candidates()
        local container_widgets = find_loot_container_widgets()
        if #container_widgets > 0 then
            container_widget_runtime_state =
                loot_widget_runtime_state(container_widgets[1])
            container_widget_state = container_widget_runtime_state.text
        end
        local container_ability_ended = false
        if is_usable_object(container_ability) then
            pcall(function()
                container_ability_ended =
                    container_ability.m_AbilityEnded == true
                    or container_ability.AbilityEnded == true
            end)
        end
        local container_ui_visible =
            core.loot_container_widget_state_should_skip_cancel({
                widget_count = container_widget_count,
                is_activated = container_widget_runtime_state.is_activated,
                is_visible = container_widget_runtime_state.is_visible,
            })
        local free_point_cancel_allowed =
            core.container_free_point_movement_cancel_allowed({
                free_point_context = free_point_container_text,
                ability_context = container_ability_text,
                tracked_phase = tracked_interaction.phase,
                loot_ui_active = container_ui_visible,
            })
        log_container_context(key_name, {
            free_point_text = free_point_container_text,
            ability_text = container_ability_text,
            ability_ended = container_ability_ended,
            tracked_phase = tracked_interaction.phase,
            tracked_source = tracked_interaction.source,
            tracked_target = tracked_interaction.target,
            free_point_cancel_allowed = free_point_cancel_allowed,
            free_point_ability_available = is_usable_object(interact_free_point_ability),
            task_count = container_task_count,
            ability_count = container_ability_count,
            widget_count = container_widget_count,
            task_sample = container_task_sample,
            ability_sample = container_ability_sample,
            widget_sample = container_widget_sample,
            widget_state = container_widget_state,
        })
        if container_ui_visible then
            log("[container-ui-skip] key=" .. tostring(key_name)
                .. " widgets=" .. tostring(container_widget_count)
                .. " activated="
                .. tostring(container_widget_runtime_state.is_activated)
                .. " visible="
                .. tostring(container_widget_runtime_state.is_visible)
                .. " widget={" .. tostring(container_widget_sample) .. "}")
            return true
        end
        if free_point_cancel_allowed then
            if try_cancel_container_root_interaction_task(key_name, interact_free_point_ability) then
                return true
            end
            if try_cancel_container_player_interaction_tasks(key_name) then
                return true
            end
            local free_point_cancelled = try_cancel_container_free_point_movement(
                key_name, interact_free_point_ability, false)
            if free_point_cancelled then
                debug_log("[container-freepoint-cancel] non-terminal"
                    .. " key=" .. tostring(key_name))
            end
        end
        if try_close_loot_container_widget(key_name) then
            return true
        end
        try_request_container_close(key_name, container_ability)
        loot_ability = find_player_loot_ability()
        try_request_loot_ability_close(key_name, loot_ability)
        if try_cancel_container_move_task(key_name, container_ability) then
            return true
        end
        debug_log("[interaction-cancel] blocked container context source="
            .. tostring(tracked_interaction.source)
            .. " target=" .. tostring(tracked_interaction.target)
            .. " freePoint={" .. tostring(free_point_container_text) .. "}")
        return false
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
                local continue_after_success =
                    core.interaction_cancel_should_continue_after_success(object_identity, {
                        sleep_interaction_context = sleep_interaction_context,
                        sleep_task_cancelled = sleep_interaction_cancelled,
                        movement_action = state.movement_action,
                    })
                if continue_after_success ~= true then
                    clear_tracked_interaction("cancelled:" .. tostring(method_name))
                end
                log("[interaction-cancel] key=" .. tostring(key_name)
                    .. " method=" .. tostring(method_name)
                    .. " mode=" .. tostring(mode)
                    .. " continue=" .. tostring(continue_after_success)
                    .. " object=" .. object_name)
                if continue_after_success ~= true then
                    return true
                end
                break
            end
            debug_log("[interaction-cancel] method=" .. tostring(method_name)
                .. " ok=false mode=" .. tostring(mode)
                .. " result=" .. log_value(value)
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
    local attempt_started_ms = config.timing == true and now_ms() or 0
    local snapshot = locomotion_snapshot()
    local safety_state = current_safety_state(snapshot)
    safety_state.key_name = key_name
    local safety = core.classify_movement_interaction_cancel(safety_state)
    local function finish_timing(result, cancelled)
        if config.timing ~= true then
            return
        end
        timing_log("cancel-attempt-total", "key=" .. tostring(key_name)
            .. " result=" .. tostring(result)
            .. " cancelled=" .. tostring(cancelled)
            .. " movementAction=" .. tostring(snapshot.movement_action)
            .. " requestedMovementAction="
            .. tostring(snapshot.requested_movement_action)
            .. " interactionActive=" .. tostring(tracked_interaction.active)
            .. " kind=" .. tostring(tracked_interaction.kind)
            .. " source=" .. tostring(tracked_interaction.source)
            .. " target=" .. tostring(tracked_interaction.target)
            .. " elapsedMs=" .. tostring(now_ms() - attempt_started_ms))
    end
    debug_log("[cancel-attempt] key=" .. tostring(key_name)
        .. " allowed=" .. tostring(safety.allowed)
        .. " reason=" .. tostring(safety.reason)
        .. " interactionActive=" .. tostring(tracked_interaction.active)
        .. " interactionKind=" .. tostring(tracked_interaction.kind)
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target)
        .. " phase=" .. tostring(tracked_interaction.phase)
        .. " " .. runtime_diagnostics.format_snapshot(snapshot))
    local movement_action_active =
        snapshot.movement_action == 7 or snapshot.requested_movement_action == 7
    if movement_action_active then
        local crafting_started_ms = config.timing == true and now_ms() or 0
        local crafting_cancelled = try_cancel_crafting(key_name, snapshot)
        if config.timing == true then
            timing_log("crafting-attempt", "key=" .. tostring(key_name)
                .. " result=" .. tostring(crafting_cancelled)
                .. " elapsedMs=" .. tostring(now_ms() - crafting_started_ms))
        end
        if crafting_cancelled then
            movement_cancel_armed_until_ms = -1000000
            finish_timing("crafting", true)
            return
        end
        local crafting_state_after_attempt = current_crafting_cancel_state(snapshot)
        if core.crafting_interaction_fallback_after_attempt({
                movement_action_active = movement_action_active,
                crafting_cancelled = crafting_cancelled,
                crafting_recent = crafting_state_after_attempt.crafting_recent,
            })
        then
            local interaction_started_ms =
                config.timing == true and now_ms() or 0
            local interaction_cleanup =
                try_cancel_movement_interaction(key_name, snapshot)
            if config.timing == true then
                timing_log("interaction-attempt", "key=" .. tostring(key_name)
                    .. " context=crafting-fallback"
                    .. " result=" .. tostring(interaction_cleanup)
                    .. " elapsedMs="
                    .. tostring(now_ms() - interaction_started_ms))
            end
            movement_cancel_armed_until_ms = -1000000
            debug_log("[crafting-interaction-cleanup] key=" .. tostring(key_name)
                .. " crafting=" .. tostring(crafting_cancelled)
                .. " interaction=" .. tostring(interaction_cleanup))
            finish_timing("crafting-fallback", interaction_cleanup)
            return
        end
    end
    local interaction_started_ms = config.timing == true and now_ms() or 0
    local cancelled = try_cancel_movement_interaction(key_name, snapshot)
    if config.timing == true then
        timing_log("interaction-attempt", "key=" .. tostring(key_name)
            .. " context=default"
            .. " result=" .. tostring(cancelled)
            .. " elapsedMs=" .. tostring(now_ms() - interaction_started_ms))
    end
    if cancelled then
        movement_cancel_armed_until_ms = -1000000
    end
    if movement_action_active and not cancelled then
        diagnostics:log_runtime_instance_scan("cancel-hotkey:" .. tostring(key_name), snapshot)
        finish_timing("runtime-diagnostics", cancelled)
        return
    end
    finish_timing("interaction", cancelled)
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
                log("Cancel attempt logging failed: " .. log_value(request_err))
            end
        end)
    end)
    if not ok then
        log("ExecuteInGameThread failed for cancel hotkey: " .. log_value(err))
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
                log("Failed to register cancel key " .. tostring(normalized) .. ": " .. log_value(err))
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
            diagnostics:log_discovery_event(hook_name, context, ...)
            return nil
        end, nil, false)
        if ok then
            registered = registered + 1
        end
    end
    log("Tracking hooks registered: " .. tostring(registered))
    return registered
end

local function observation_arg_text(...)
    local parts = {}
    local count = select("#", ...)
    if count > 3 then
        count = 3
    end
    for index = 1, count do
        local text = param_to_log_string(select(index, ...))
        if text ~= "" then
            table.insert(parts, "arg" .. tostring(index) .. "=" .. text)
        end
    end
    return table.concat(parts, " ")
end

local function install_container_close_observation_hooks()
    local registered = 0
    for _, hook_name in ipairs(core.container_close_observation_hook_candidates()) do
        local ok = register_hook(hook_name, function(context, ...)
            local object = get_param_object(context)
            if not object and is_usable_object(context) then
                object = context
            end
            local object_text = object_identity_text(object)
            if is_usable_object(object)
                and core.object_name_is_container_ability(object_text)
            then
                local owner_identity = player_state_identity()
                if owner_identity == ""
                    or core.object_name_belongs_to_owner(
                        object_text, owner_identity)
                then
                    cached_container_ability = object
                    cached_container_owner_identity = owner_identity
                    debug_log("[container-observe-cache] ability="
                        .. tostring(object_text)
                        .. " owner=" .. tostring(owner_identity))
                end
            end
            if core.text_is_container_close_observation_context(
                    hook_name, object_text)
            then
                log("[container-close-observe] hook=" .. tostring(hook_name)
                    .. " object=" .. tostring(object_text)
                    .. " args={" .. observation_arg_text(...) .. "}")
            end
            return nil
        end, nil, false)
        if ok then
            registered = registered + 1
        end
    end
    log("Container close observation hooks registered: "
        .. tostring(registered))
    return registered
end

local function install_player_hooks()
    local ok_any = false
    for _, hook_name in ipairs(core.player_context_hook_candidates()) do
        if hook_name == "/Script/Engine.PlayerController:ClientRestart" then
            ok_any = register_hook(hook_name, function(context, new_pawn)
                cached_player_controller = get_param_object(context)
                if not mark_hero_from_context(new_pawn, "PlayerController:ClientRestart") then
                    refresh_player_from_controller()
                end
                debug_log("ClientRestart observed; player context refreshed.")
                return nil
            end, nil, false) or ok_any
        else
            local source = hook_name:match(":([^:]+)$") or hook_name
            ok_any = register_hook(hook_name, function(context)
                mark_hero_from_context(context, "GothicCharacter:" .. source)
                return nil
            end, nil, false) or ok_any
        end
    end
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
    local container_close_hook_count =
        install_container_close_observation_hooks()
    diagnostics:run_runtime_function_scan()
    local cancel_hotkeys_installed = install_cancel_hotkeys()
    local hotkey_state = cancel_hotkeys_installed
        and "cancel hotkeys enabled"
        or "cancel hotkeys disabled"
    if player_hooks_installed then
        log("Loaded v" .. VERSION .. " with player hooks and "
            .. tostring(tracking_hook_count) .. " tracking hooks; "
            .. "container close hooks="
            .. tostring(container_close_hook_count) .. "; "
            .. hotkey_state .. ".")
    else
        log("Loaded v" .. VERSION .. " without player hooks; tracking hooks="
            .. tostring(tracking_hook_count)
            .. "; container close hooks="
            .. tostring(container_close_hook_count)
            .. "; " .. hotkey_state .. ".")
    end
end
