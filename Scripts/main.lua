local MOD_NAME = "[G1R_CancelInteraction]"
local VERSION = "0.3.0"
local CONFIG_FILE_NAME = "G1R_CancelInteraction.ini"

local core = require("cancel_core")
local ModRuntime = require("mod_runtime")
local PlayerAsc = require("player_asc")

local config = core.config_from_ini({})
local runtime = nil
local player_asc = nil
local hotkey_runtime_enabled = false
local hotkey_game_thread_busy = false
local controller_cancel_ability_input_hook_registered = {}
local controller_cancel_enhanced_input_hook_registered = {}
local controller_input_discovery_hook_registered = {}
local controller_trigger_discovery_marker = ""
local controller_trigger_discovery_seen = {}
local controller_trigger_discovery_count = 0
local controller_mapping_summary_marker = ""
local controller_cancel_action_cache_key = ""
local controller_cancel_action_names = nil
local controller_cancel_enhanced_match_marker = ""
local last_controller_enhanced_input_scan_ms = -1000000
local last_hotkey_ms = -1000000
local cached_hero = nil
local cached_hero_identity = ""
local cached_anim_instance = nil
local cached_player_input = nil
local cached_player_input_identity = ""
local tracked_interaction = {
    active = false,
    kind = "none",
    source = "",
    target = "",
    phase = "idle",
    started_at_ms = 0,
    priority = 0,
}

local function log(message)
    print(string.format("%s %s\n", MOD_NAME, tostring(message)))
end

local function debug_log(message)
    if config.debug then
        log("[debug] " .. tostring(message))
    end
end

local function discovery_log(message)
    if config.discovery_mode == true then
        log("[debug] " .. tostring(message))
    end
end

local function log_value(value)
    return runtime:log_value(value)
end

runtime = ModRuntime.new({
    core = core,
    log = log,
    debug_log = debug_log,
})

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
                .. " ControllerCancelEnabled="
                .. tostring(config.controller_cancel_enabled)
                .. " ControllerCancelKeys="
                .. table.concat(config.controller_cancel_keys or {}, ",")
                .. " CooldownMs=" .. tostring(config.cooldown_ms))
            return
        end
    end
    config = core.config_from_ini({})
    log("Config not found; using defaults.")
end

local function looks_like_player_character(character)
    if not runtime:is_usable_object(character) then
        return false
    end
    local name = runtime:get_full_name(character)
    return runtime:contains(name, "PlayerCharacter")
        or runtime:contains(name, "GothicPlayerCharacter")
        or runtime:contains(name, "BP_Player")
end

local function mark_hero(hero, source)
    if not looks_like_player_character(hero) then
        return false
    end
    local hero_identity = runtime:get_full_name(hero)
    local cache_update = core.classify_cached_hero_update({
        previous_identity = cached_hero_identity,
        next_identity = hero_identity,
        source = source,
    })
    if cache_update.changed then
        cached_anim_instance = nil
    end
    cached_hero = hero
    cached_hero_identity = hero_identity
    if cache_update.refresh_runtime_refs then
        pcall(function()
            cached_anim_instance = hero.Mesh.AnimScriptInstance
        end)
    end
    if cache_update.should_log then
        debug_log("Player cached from " .. tostring(source)
            .. ": " .. hero_identity)
    end
    return true
end

local function mark_hero_from_context(context, source)
    local hero = runtime:get_param_object(context)
    if not hero and runtime:is_usable_object(context) then
        hero = context
    end
    return mark_hero(hero, source)
end

local function object_is_local_player_input(object)
    if object == nil or cached_player_input == nil then
        return false
    end
    if object == cached_player_input then
        return true
    end
    if cached_player_input_identity == ""
        or not runtime:is_usable_object(object)
    then
        return false
    end
    return runtime:get_full_name(object) == cached_player_input_identity
end

local function refresh_player_from_controller()
    local pc = runtime:resolve_player_controller()
    if not runtime:is_usable_object(pc) then
        return false
    end
    local ok, pawn = pcall(function()
        return pc.Pawn
    end)
    return ok and mark_hero(pawn, "PlayerController.Pawn")
end

local function refresh_controller_input_snapshot()
    local snapshot = runtime:player_controller_input_snapshot()
    local previous_identity = cached_player_input_identity
    cached_player_input = snapshot.player_input
    cached_player_input_identity = runtime:is_usable_object(cached_player_input)
        and runtime:get_full_name(cached_player_input)
        or ""
    if cached_player_input_identity ~= previous_identity then
        controller_cancel_action_cache_key = ""
        controller_cancel_action_names = nil
    end
    return snapshot
end

local function log_controller_input_snapshot()
    if config.debug ~= true and config.discovery_mode ~= true then
        return
    end
    local snapshot = refresh_controller_input_snapshot()
    if config.debug == true then
        debug_log("[controller-input] " .. tostring(snapshot.diagnostics))
    end
    if config.discovery_mode ~= true then
        return
    end
    discovery_log("[controller-input-config] "
        .. runtime:gothic_input_config_summary(snapshot.input_config))
    local key_names = {}
    for _, configured_key in ipairs(config.controller_cancel_keys or {}) do
        for _, key in ipairs(runtime:controller_input_key_values_from_name(
            configured_key)) do
            local source = key.source and ("[" .. tostring(key.source) .. "]")
                or ""
            table.insert(key_names, tostring(key.name) .. source)
        end
    end
    if #key_names == 0 then
        table.insert(key_names, "none")
    end
    discovery_log("[controller-input] keys="
        .. table.concat(config.controller_cancel_keys or {}, ",")
        .. " candidates=" .. table.concat(key_names, ","))
    if #key_names == 1 and key_names[1] == "none" then
        local available_names, scan_error = runtime:available_key_names({
            "gamepad",
            "xbox",
            "ps4",
            "ps5",
            "controller",
            "circle",
            "face",
        }, 32)
        if #available_names > 0 then
            discovery_log("[controller-input] key-table matches="
                .. table.concat(available_names, ","))
        elseif scan_error ~= nil then
            discovery_log("[controller-input] key-table scan="
                .. tostring(scan_error))
        else
            discovery_log("[controller-input] key-table matches=none")
        end
    end
end

local function player_state_from_owner(object)
    if runtime:is_usable_object(object) then
        local ok, player_state = pcall(function() return object.PlayerState end)
        if ok and runtime:is_usable_object(player_state) then
            return player_state
        end
    end
end

local function current_player_state_object()
    local pc_state = player_state_from_owner(runtime:resolve_player_controller())
    return pc_state or player_state_from_owner(cached_hero)
end

player_asc = PlayerAsc.new({
    runtime = runtime,
    core = core,
    debug_log = debug_log,
    player_state = current_player_state_object,
})

local function object_is_player_ability_system(object)
    if not runtime:is_usable_object(object) or player_asc == nil then
        return false
    end
    local ok, context = pcall(function()
        return player_asc:current_context()
    end)
    if not ok or context == nil or context.ok ~= true
        or not runtime:is_usable_object(context.ability_system)
    then
        return false
    end
    if object == context.ability_system then
        return true
    end
    return runtime:get_full_name(object)
        == runtime:get_full_name(context.ability_system)
end

local function now_ms()
    return math.floor(os.clock() * 1000)
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
    if runtime:is_usable_object(cached_hero) then
        snapshot.rotation_mode = read_number(
            "hero.m_DataModule_Locomotion.m_RotationMode",
            function()
                return cached_hero.m_DataModule_Locomotion.m_RotationMode
            end)
        snapshot.movement_state = read_number(
            "hero.m_DataModule_Locomotion.m_MovementState",
            function()
                return cached_hero.m_DataModule_Locomotion.m_MovementState
            end)
        snapshot.movement_action = read_number(
            "hero.m_DataModule_Locomotion.m_MovementAction",
            function()
                return cached_hero.m_DataModule_Locomotion.m_MovementAction
            end)
        snapshot.requested_movement_action = read_number(
            "hero.m_DataModule_Locomotion.m_RequestedMovementAction",
            function()
                return cached_hero.m_DataModule_Locomotion.m_RequestedMovementAction
            end)
    end
    if runtime:is_usable_object(cached_anim_instance) then
        pcall(function()
            snapshot.anim_is_in_combat = cached_anim_instance.m_IsInCombat
        end)
        pcall(function()
            snapshot.anim_is_alive = cached_anim_instance.m_IsAlive
        end)
        pcall(function()
            snapshot.anim_is_conversation =
                cached_anim_instance.bIsInConversation
        end)
        pcall(function()
            snapshot.anim_is_cinematic = cached_anim_instance.bIsInCinematic
        end)
    end
    return snapshot
end

local function format_snapshot(snapshot)
    snapshot = snapshot or {}
    return "rotationMode=" .. log_value(snapshot.rotation_mode)
        .. " movementState=" .. log_value(snapshot.movement_state)
        .. " movementAction=" .. log_value(snapshot.movement_action)
        .. " requestedMovementAction="
        .. log_value(snapshot.requested_movement_action)
        .. " animCombat=" .. log_value(snapshot.anim_is_in_combat)
        .. " animAlive=" .. log_value(snapshot.anim_is_alive)
        .. " animConversation=" .. log_value(snapshot.anim_is_conversation)
        .. " animCinematic=" .. log_value(snapshot.anim_is_cinematic)
end

local function clear_tracked_interaction(reason)
    debug_log("[movement-track] cleared reason=" .. tostring(reason)
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target))
    tracked_interaction.active = false
    tracked_interaction.kind = "none"
    tracked_interaction.source = ""
    tracked_interaction.target = ""
    tracked_interaction.phase = "idle"
    tracked_interaction.started_at_ms = 0
    tracked_interaction.priority = 0
    last_controller_enhanced_input_scan_ms = -1000000
    controller_cancel_enhanced_match_marker = ""
    controller_trigger_discovery_marker = ""
    controller_trigger_discovery_seen = {}
    controller_trigger_discovery_count = 0
    controller_mapping_summary_marker = ""
end

local task_is_finished

local function object_looks_like_movement_task(object)
    local identity = runtime:object_identity_text(object)
    return core.movement_task_tracking_priority(identity) > 0
end

local function task_debug_value_text(value)
    if runtime:is_usable_object(value) then
        return runtime:object_identity_text(value)
    end
    if value == nil then
        return "nil"
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number"
        or value_type == "boolean"
    then
        return log_value(value)
    end
    return runtime:param_to_log_string(value)
end

local function task_debug_value_diagnostics(value)
    local diagnostics_text = runtime:ue4ss_value_diagnostics(value)
    if diagnostics_text == "" then
        return ""
    end
    return "[" .. diagnostics_text .. "]"
end

local function task_debug_property_text(object, property_name)
    local ok, value = runtime:get_object_property(object, property_name)
    if ok ~= true then
        return property_name .. "=read-failed:" .. log_value(value)
    end
    local text = property_name .. "=" .. task_debug_value_text(value)
        .. task_debug_value_diagnostics(value)
    if property_name == "MoveTask" or property_name == "TurnTask" then
        local method_ok, method_value =
            runtime:get_object_property_value_method(object, property_name)
        if method_ok == true then
            text = text .. " GetPropertyValue." .. property_name .. "="
                .. task_debug_value_text(method_value)
                .. task_debug_value_diagnostics(method_value)
        else
            text = text .. " GetPropertyValue." .. property_name
                .. "=read-failed:" .. log_value(method_value)
        end
    end
    return text
end

local function task_debug_flags(object, object_identity)
    local parts = {}
    if runtime:contains(object_identity, "AbilityTask_MoveIntoPositionForInteraction") then
        table.insert(parts, task_debug_property_text(object,
            "bIsReadyToStartAnimation"))
        table.insert(parts, task_debug_property_text(object, "MoveTask"))
        table.insert(parts, task_debug_property_text(object, "TurnTask"))
    end
    if #parts == 0 then
        return ""
    end
    return " " .. table.concat(parts, " ")
end

local function track_movement_task(source, object, target)
    if not runtime:is_usable_object(object) then
        return false
    end
    local object_identity = runtime:object_identity_text(object)
    if runtime:contains(object_identity, "Default__") then
        return false
    end
    local snapshot = locomotion_snapshot()
    local tracking = core.classify_movement_task_tracking({
        identity = object_identity,
        movement_action = snapshot.movement_action,
        requested_movement_action = snapshot.requested_movement_action,
    })
    if tracking.track ~= true then
        if config.discovery_mode == true then
            local flags = task_debug_flags(object, object_identity)
            discovery_log("[movement-track] ignored source=" .. tostring(source)
                .. " reason=" .. tostring(tracking.reason)
                .. " priority=" .. tostring(tracking.priority)
                .. " object=" .. object_identity
                .. " " .. format_snapshot(snapshot)
                .. flags)
        end
        return false
    end
    local priority = tracking.priority
    local current_priority = tonumber(tracked_interaction.priority) or 0
    if tracked_interaction.active ~= true then
        last_controller_enhanced_input_scan_ms = -1000000
        controller_cancel_enhanced_match_marker = ""
    end
    tracked_interaction.active = true
    tracked_interaction.kind = "use-object"
    tracked_interaction.phase = "move"
    tracked_interaction.started_at_ms = now_ms()
    if priority >= current_priority then
        tracked_interaction.source = tostring(source)
        tracked_interaction.target = tostring(target or object_identity)
        tracked_interaction.priority = priority
    end
    discovery_log("[movement-track] source=" .. tostring(source)
        .. " object=" .. object_identity
        .. " target=" .. tostring(tracked_interaction.target)
        .. " priority=" .. tostring(priority)
        .. task_debug_flags(object, object_identity))
    return true
end

local function movement_task_from_params(context, ...)
    local context_object = runtime:get_param_object(context)
    if not context_object and runtime:is_usable_object(context) then
        context_object = context
    end
    if object_looks_like_movement_task(context_object) then
        return context_object
    end
    for index = 1, select("#", ...) do
        local object = runtime:get_param_object(select(index, ...))
        if object_looks_like_movement_task(object) then
            return object
        end
    end
    return nil
end

local function mark_interaction_context(source, context, ...)
    local tracking = core.interaction_tracking_from_hook(source)
    if tracking.track ~= true then
        return false
    end
    local object = movement_task_from_params(context, ...)
    return track_movement_task(source, object, runtime:param_to_log_string(select(1, ...)))
end

local function install_movement_task_object_notifications()
    if type(NotifyOnNewObject) ~= "function" then
        debug_log("NotifyOnNewObject unavailable; using hooks only")
        return 0
    end
    local registered = 0
    for _, class_name in ipairs(core.movement_task_notify_class_names()) do
        local ok, err = pcall(function()
            NotifyOnNewObject(class_name, function(object)
                track_movement_task("NotifyOnNewObject:" .. tostring(class_name),
                    object, runtime:object_identity_text(object))
            end)
        end)
        if ok then
            registered = registered + 1
            debug_log("Movement task notification registered "
                .. tostring(class_name))
        else
            debug_log("Movement task notification failed "
                .. tostring(class_name) .. ": " .. log_value(err))
        end
    end
    return registered
end

local function is_console_open()
    local console = nil
    pcall(function()
        local pc = runtime:resolve_player_controller()
        if not runtime:is_usable_object(pc) then
            return
        end
        local player = pc.Player
        if not runtime:is_usable_object(player) then
            return
        end
        local viewport_client = player.ViewportClient
        if not runtime:is_usable_object(viewport_client) then
            return
        end
        console = viewport_client.ViewportConsole
    end)
    if runtime:is_usable_object(console) then
        local ok, state = pcall(function()
            local value = console.ConsoleState
            if not value then
                return "None"
            end
            if type(value) == "string" then
                return value
            end
            if value.ToString then
                return value:ToString()
            end
            return tostring(value)
        end)
        return ok and state and state ~= "None"
    end
    return false
end

local function current_menu_open_state()
    local pc = runtime:resolve_player_controller()
    if not runtime:is_usable_object(pc) then
        return core.classify_menu_open_state()
    end
    local ok, show_mouse_cursor, paused = pcall(function()
        return pc.bShowMouseCursor == true, pc:IsPaused() == true
    end)
    if not ok then
        return core.classify_menu_open_state()
    end
    return core.classify_menu_open_state({
        show_mouse_cursor = show_mouse_cursor,
        paused = paused,
    })
end

local function current_safety_state(snapshot)
    snapshot = snapshot or locomotion_snapshot()
    local active_interaction = tracked_interaction.active == true
    local menu_state = current_menu_open_state()
    local airborne = snapshot.movement_state == 3
        or snapshot.movement_action == 5
        or snapshot.requested_movement_action == 5
    local dialogue_or_cutscene = snapshot.anim_is_conversation == true
        or snapshot.anim_is_cinematic == true
    return {
        player_ready = runtime:is_usable_object(cached_hero),
        interaction_active = active_interaction,
        interaction_kind = tracked_interaction.kind,
        interaction_phase = tracked_interaction.phase,
        movement_action = snapshot.movement_action,
        requested_movement_action = snapshot.requested_movement_action,
        paused = false,
        menu_open = menu_state.open,
        menu_open_reason = menu_state.reason,
        menu_mouse_cursor = menu_state.show_mouse_cursor,
        menu_paused = menu_state.paused,
        console_open = is_console_open(),
        dialogue_or_cutscene = dialogue_or_cutscene,
        alive = snapshot.anim_is_alive ~= false,
        unsafe_transition = false,
        airborne = airborne,
        combat_or_finisher = snapshot.anim_is_in_combat == true,
    }
end

local function player_locomotion_module()
    if not runtime:is_usable_object(cached_hero) then
        return nil
    end
    local ok, locomotion = pcall(function()
        return cached_hero.m_DataModule_Locomotion
    end)
    if ok and runtime:is_usable_object(locomotion) then
        return locomotion
    end
    return nil
end

local function try_stop_controller_movement()
    local pc = runtime:resolve_player_controller()
    if not runtime:is_usable_object(pc) then
        return false
    end
    local ok, value, mode = runtime:call_method(pc, "StopMovement")
    debug_log("[locomotion-cancel] StopMovement ok=" .. tostring(ok)
        .. " mode=" .. tostring(mode)
        .. " result=" .. log_value(value))
    return ok == true
end

local function task_cancel_arg_variants(method_name)
    if method_name == "EndTaskWithResult" then
        return {
            runtime:pack_args(2),
            runtime:pack_args("Cancelled"),
            runtime:pack_args(),
        }
    end
    return { runtime:pack_args() }
end

local function task_cancel_call_succeeded(method_name, value)
    if method_name == "EndTaskWithResult" then
        return value ~= false
    end
    return true
end

local function ability_cancel_call_succeeded(value)
    return value ~= false
end

function task_is_finished(task)
    local ok, value = runtime:call_method(task, "BP_IsFinished")
    if ok == true then
        local result = runtime:get_param_value(value)
        if type(result) == "boolean" then
            return result
        end
        local text = string.lower(log_value(result or ""))
        return text == "true"
    end
    return false
end

local function try_cancel_locomotion_interaction(key_name, snapshot, options)
    options = options or {}
    local clear_tracking_on_success = options.clear_tracking ~= false
    local state = current_safety_state(snapshot)
    state.key_name = key_name
    local safety = core.classify_movement_interaction_cancel(state)
    if safety.allowed ~= true then
        debug_log("[locomotion-cancel] blocked key=" .. tostring(key_name)
            .. " reason=" .. tostring(safety.reason))
        return false
    end

    local locomotion = player_locomotion_module()
    if not runtime:is_usable_object(locomotion) then
        debug_log("[locomotion-cancel] no locomotion module")
        return false
    end

    for _, spec in ipairs(core.locomotion_cancel_specs()) do
        if spec.method then
            local args = runtime:pack_array_args(spec.args)
            local ok, value, mode =
                runtime:call_method_with_arg_pack(locomotion, spec.method, args)
            debug_log("[locomotion-cancel] method=" .. tostring(spec.method)
                .. " args=" .. tostring(args.n or 0)
                .. " ok=" .. tostring(ok)
                .. " mode=" .. tostring(mode)
                .. " result=" .. log_value(value))
            if ok == true and value ~= false then
                try_stop_controller_movement()
                if clear_tracking_on_success then
                    clear_tracked_interaction("locomotion-cancelled:"
                        .. tostring(spec.method))
                end
                log("[locomotion-cancel] key=" .. tostring(key_name)
                    .. " method=" .. tostring(spec.method)
                    .. " locomotion=" .. runtime:get_full_name(locomotion))
                return true
            end
        elseif spec.property then
            local ok, value = runtime:set_object_property(locomotion, spec.property,
                spec.value)
            debug_log("[locomotion-cancel] property="
                .. tostring(spec.property)
                .. " value=" .. tostring(spec.value)
                .. " ok=" .. tostring(ok)
                .. " result=" .. log_value(value))
            if ok == true then
                try_stop_controller_movement()
                if clear_tracking_on_success then
                    clear_tracked_interaction("locomotion-cancelled:"
                        .. tostring(spec.property))
                end
                log("[locomotion-cancel] key=" .. tostring(key_name)
                    .. " property=" .. tostring(spec.property)
                    .. " locomotion=" .. runtime:get_full_name(locomotion))
                return true
            end
        end
    end

    log("[locomotion-cancel] failed key=" .. tostring(key_name)
        .. " locomotion=" .. runtime:get_full_name(locomotion))
    return false
end

local function cancel_movement_freepoint_ability_object(
    key_name, ability, ability_identity, context, locomotion_cancelled)
    if not runtime:is_usable_object(ability)
        or not core.freepoint_ability_is_cancelable(ability_identity)
    then
        return false
    end
    for _, method_name in ipairs(core.freepoint_ability_cancel_method_names()) do
        local ok, value, mode = runtime:call_method(ability, method_name)
        if ok == true and ability_cancel_call_succeeded(value) then
            if tracked_interaction.active == true then
                clear_tracked_interaction("movement-followup-ability-cancelled:"
                    .. tostring(method_name))
            end
            log("[movement-followup-ability-cancel] key="
                .. tostring(key_name)
                .. " method=" .. tostring(method_name)
                .. " mode=" .. tostring(mode)
                .. " taskLocomotion=" .. tostring(locomotion_cancelled)
                .. " context=" .. tostring(context)
                .. " ability=" .. runtime:get_full_name(ability))
            return true
        end
        debug_log("[movement-followup-ability-cancel] method="
            .. tostring(method_name)
            .. " ok=" .. tostring(ok)
            .. " mode=" .. tostring(mode)
            .. " result=" .. log_value(value)
            .. " ability=" .. tostring(ability_identity))
    end
    return false
end

local function try_cancel_player_freepoint_ability(
    key_name, locomotion_cancelled, options)
    options = options or {}
    local ability, ability_identity = player_asc:find_freepoint_ability()
    if not runtime:is_usable_object(ability) then
        return false
    end
    local root_task_read =
        runtime:read_object_property(ability, "RootInteractionTask")
    local root_task = runtime:resolve_object_reference(root_task_read.value)
        or root_task_read.value
    local root_task_identity = runtime:property_identity_text(root_task)
    debug_log("[movement-freepoint-lookup-state] key=" .. tostring(key_name)
        .. " ability=" .. tostring(ability_identity)
        .. " " .. runtime:property_text(ability, "bIsActive")
        .. " " .. runtime:property_text(ability, "m_AbilityEnded")
        .. " " .. runtime:property_text(ability, "bEndRequested")
        .. " " .. runtime:property_text(ability,
            "m_InteractiveActor")
        .. " RootInteractionTask=" .. tostring(root_task_identity)
        .. "(" .. tostring(root_task_read.source or "unknown")
        .. ":" .. runtime:property_read_status(root_task_read.ok,
            root_task_read.value) .. ")")
    if options.block_ladder_root_task == true
        and core.root_interaction_task_blocks_movement_key_cancel(
            root_task_identity)
    then
        if tracked_interaction.active == true then
            clear_tracked_interaction("blocked-ladder-root-task")
        end
        debug_log("[movement-followup-ability-cancel] skipped"
            .. " reason=blocked-ladder-root-task"
            .. " key=" .. tostring(key_name)
            .. " taskLocomotion=" .. tostring(locomotion_cancelled)
            .. " ability=" .. tostring(ability_identity)
            .. " rootTask=" .. tostring(root_task_identity))
        return false, "blocked-ladder-root-task"
    end
    return cancel_movement_freepoint_ability_object(key_name, ability,
        ability_identity, "player-freepoint-lookup", locomotion_cancelled)
end

local function log_interaction_cancel_attempt(key_name, state, safety)
    debug_log("[interaction-cancel-attempt] key=" .. tostring(key_name)
        .. " allowed=" .. tostring(safety.allowed)
        .. " reason=" .. tostring(safety.reason)
        .. " interactionActive=" .. tostring(state.interaction_active)
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target)
        .. " phase=" .. tostring(tracked_interaction.phase)
        .. " menuOpen=" .. tostring(state.menu_open)
        .. " menuReason=" .. tostring(state.menu_open_reason)
        .. " menuPaused=" .. tostring(state.menu_paused)
        .. " menuMouseCursor=" .. tostring(state.menu_mouse_cursor))
end

local function try_clear_inactive_movement_window(
    key_name, safety, asc_task)
    if safety.reason ~= "movement action inactive"
        or tracked_interaction.active ~= true
    then
        return false
    end
    local cancelled, freepoint_reason =
        try_cancel_player_freepoint_ability(key_name, false, {
            block_ladder_root_task = not runtime:is_usable_object(asc_task),
        })
    if cancelled then
        return true
    end
    if freepoint_reason == "blocked-ladder-root-task" then
        return false
    end
    clear_tracked_interaction("movement-window-inactive")
    return false
end

local function try_cancel_without_player_movement_task(key_name, task_source)
    debug_log("[movement-only-cancel] no player ASC movement task"
        .. " source=" .. tostring(task_source))
    local cancelled, freepoint_reason =
        try_cancel_player_freepoint_ability(key_name, false, {
            block_ladder_root_task = true,
        })
    if cancelled then
        return true
    end
    if freepoint_reason == "blocked-ladder-root-task" then
        return false
    end
    clear_tracked_interaction("no-player-asc-movement-task")
    return false
end

local function log_player_movement_task_state(key_name, task, task_identity,
    task_source)
    discovery_log("[movement-cancel-owner-state] key="
        .. tostring(key_name)
        .. " object=" .. task_identity
        .. " ownerReason=player-asc-task"
        .. " taskSource=" .. tostring(task_source))

    discovery_log("[movement-cancel-task-state] key="
        .. tostring(key_name)
        .. " object=" .. task_identity
        .. " source=" .. tostring(task_source)
        .. task_debug_flags(task, task_identity))
end

local function try_cancel_movement_task_object(key_name, task, task_source)
    for _, method_name in ipairs(core.movement_task_cancel_method_names()) do
        for _, args in ipairs(task_cancel_arg_variants(method_name)) do
            local ok, value, mode =
                runtime:call_method_with_arg_pack(task, method_name, args)
            if ok == true and task_cancel_call_succeeded(method_name, value) then
                return {
                    method_name = method_name,
                    args = args,
                    mode = mode,
                }
            end
            debug_log("[movement-only-cancel] method="
                .. tostring(method_name)
                .. " args=" .. tostring(args.n or 0)
                .. " ok=" .. tostring(ok)
                .. " mode=" .. tostring(mode)
                .. " source=" .. tostring(task_source)
                .. " result=" .. log_value(value)
                .. " object=" .. runtime:get_full_name(task))
        end
    end
    return nil
end

local function try_cancel_active_player_movement_task(key_name, snapshot,
    task, task_identity, task_source)
    if task_identity == nil or task_identity == "" then
        task_identity = runtime:object_identity_text(task)
    end
    local locomotion_cancelled = try_cancel_locomotion_interaction(
        key_name, snapshot, { clear_tracking = false })
    if not runtime:is_usable_object(task) then
        debug_log("[movement-only-cancel] tracked movement task invalid"
            .. " after locomotion cancel")
        if try_cancel_player_freepoint_ability(key_name, locomotion_cancelled)
        then
            return true
        end
        clear_tracked_interaction("movement-task-invalid")
        return false
    end

    log_player_movement_task_state(key_name, task, task_identity, task_source)
    if task_is_finished(task) then
        debug_log("[movement-only-cancel] tracked movement task finished"
            .. " source=" .. tostring(task_source)
            .. " object=" .. runtime:get_full_name(task))
        if try_cancel_player_freepoint_ability(key_name, locomotion_cancelled)
        then
            return true
        end
        clear_tracked_interaction("movement-task-finished")
        return false
    end

    local cancelled_task =
        try_cancel_movement_task_object(key_name, task, task_source)
    if cancelled_task ~= nil then
        local freepoint_cancelled =
            try_cancel_player_freepoint_ability(key_name, locomotion_cancelled)
        if freepoint_cancelled ~= true
            and tracked_interaction.active == true
        then
            clear_tracked_interaction("movement-only-cancelled:"
                .. tostring(cancelled_task.method_name))
        end
        log("[movement-only-cancel] key=" .. tostring(key_name)
            .. " method=" .. tostring(cancelled_task.method_name)
            .. " args=" .. tostring(cancelled_task.args.n or 0)
            .. " mode=" .. tostring(cancelled_task.mode)
            .. " taskLocomotion=" .. tostring(locomotion_cancelled)
            .. " source=" .. tostring(task_source)
            .. " task=" .. runtime:get_full_name(task))
        return true
    end

    if try_cancel_player_freepoint_ability(key_name, locomotion_cancelled) then
        return true
    end
    return false
end

local function try_cancel_movement_interaction(key_name, snapshot)
    local state = current_safety_state(snapshot)
    state.key_name = key_name
    local safety = core.classify_movement_interaction_cancel(state)
    log_interaction_cancel_attempt(key_name, state, safety)
    local asc_task, asc_task_identity, asc_task_source =
        player_asc:find_movement_task(key_name)
    if safety.allowed ~= true then
        return try_clear_inactive_movement_window(key_name, safety, asc_task)
    end

    local task = asc_task
    local task_identity = asc_task_identity
    local task_source = asc_task_source
    local tracked_phase_is_move = tracked_interaction.phase == "move"
    if not tracked_phase_is_move then
        debug_log("[movement-only-cancel] no tracked move phase; "
            .. "not cancelling without movement task")
        return false
    end
    if not runtime:is_usable_object(task) then
        return try_cancel_without_player_movement_task(
            key_name, task_source)
    end
    return try_cancel_active_player_movement_task(key_name, snapshot,
        task, task_identity, task_source)
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
        .. " source=" .. tostring(tracked_interaction.source)
        .. " target=" .. tostring(tracked_interaction.target)
        .. " phase=" .. tostring(tracked_interaction.phase)
        .. " menuOpen=" .. tostring(safety_state.menu_open)
        .. " menuReason=" .. tostring(safety_state.menu_open_reason)
        .. " menuPaused=" .. tostring(safety_state.menu_paused)
        .. " menuMouseCursor="
        .. tostring(safety_state.menu_mouse_cursor)
        .. " " .. format_snapshot(snapshot))

    try_cancel_movement_interaction(key_name, snapshot)
end

local function on_cancel_hotkey(key_name)
    if not hotkey_runtime_enabled then
        debug_log("Cancel hotkey ignored: runtime disabled")
        return
    end
    local now = now_ms()
    if core.cancel_hotkey_should_enter_game_thread({
            key_name = key_name,
            interaction_active = tracked_interaction.active == true,
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
                debug_log("Cancel hotkey ignored: game-thread busy")
                return
            end
            hotkey_game_thread_busy = true
            local request_ok, request_err = pcall(log_cancel_attempt, key_name)
            hotkey_game_thread_busy = false
            if not request_ok then
                log("Cancel attempt failed: " .. log_value(request_err))
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
        local ok, normalized, err =
            runtime:register_key_bind(key_name, on_cancel_hotkey)
        if ok then
            registered_any = true
            log("Registered cancel key " .. tostring(normalized))
        else
            log("Failed to register cancel key " .. tostring(normalized)
                .. ": " .. log_value(err))
        end
    end
    hotkey_runtime_enabled = registered_any
    return registered_any
end

local function ability_input_id_text(param)
    local value = runtime:get_param_value(param)
    if value == nil then
        return ""
    end
    return runtime:log_value(value)
end

local function on_controller_cancel_ability_input(hook_name, context, input_id)
    if config.controller_cancel_enabled ~= true
        or tracked_interaction.active ~= true
    then
        return nil
    end
    local ability_system = runtime:get_param_object(context)
    if not object_is_player_ability_system(ability_system) then
        return nil
    end

    local input_id_value = ability_input_id_text(input_id)
    local cancel_input = string.find(tostring(hook_name), ":InputCancel", 1,
        true) ~= nil
    if not cancel_input then
        cancel_input = core.ability_input_id_is_cancel(input_id_value)
    end

    debug_log("[controller-cancel-ability-input] hook="
        .. tostring(hook_name)
        .. " inputID=" .. tostring(input_id_value)
        .. " cancel=" .. tostring(cancel_input)
        .. " asc=" .. runtime:property_identity_text(ability_system))
    if cancel_input then
        on_cancel_hotkey("ESCAPE")
    end
    return nil
end

local function install_controller_cancel_ability_input_hooks()
    if config.controller_cancel_enabled ~= true then
        return 0
    end
    local registered = 0
    for _, hook_name in ipairs(
        core.controller_cancel_ability_input_hook_candidates())
    do
        if controller_cancel_ability_input_hook_registered[hook_name] ~= true
        then
            local ok = runtime:register_hook(hook_name, function(context,
                input_id)
                return on_controller_cancel_ability_input(hook_name, context,
                    input_id)
            end, nil, false)
            if ok then
                controller_cancel_ability_input_hook_registered[hook_name] =
                    true
                registered = registered + 1
            end
        end
    end
    if registered > 0 then
        hotkey_runtime_enabled = true
        log("Controller cancel ability input hooks registered: "
            .. tostring(registered))
    end
    return registered
end

local function controller_enhanced_input_scan_due()
    local now = now_ms()
    if now - last_controller_enhanced_input_scan_ms < 10 then
        return false
    end
    last_controller_enhanced_input_scan_ms = now
    return true
end

local function controller_discovery_param_summary(...)
    local args = { ... }
    local parts = {}
    for index = 1, math.min(#args, 4) do
        local param = args[index]
        local object = runtime:get_param_object(param)
        if runtime:is_usable_object(object) then
            table.insert(parts, "p" .. tostring(index) .. "="
                .. runtime:property_identity_text(object))
        else
            table.insert(parts, "p" .. tostring(index) .. "="
                .. runtime:property_identity_text(runtime:get_param_value(
                    param)))
        end
    end
    if #args > 4 then
        table.insert(parts, "more=" .. tostring(#args - 4))
    end
    if #parts == 0 then
        return "none"
    end
    return table.concat(parts, " ")
end

local function trigger_property_summary(trigger)
    local parts = {}
    for _, property_name in ipairs({
        "ActuationThreshold",
        "LastValue",
        "bShouldAlwaysTick",
        "m_BufferTimeThreshold",
        "m_TagsToListen",
    }) do
        local read = runtime:read_object_property(trigger, property_name)
        if read.ok == true and read.value ~= nil then
            local value = runtime:resolve_object_reference(read.value)
                or read.value
            table.insert(parts, tostring(property_name) .. "="
                .. runtime:property_identity_text(value)
                .. "(" .. tostring(read.source or "unknown") .. ")")
        end
    end
    if #parts == 0 then
        return "none"
    end
    return table.concat(parts, " ")
end

local function compact_diagnostic_text(value, max_length)
    local text = tostring(value or "")
    max_length = math.max(16, math.floor(tonumber(max_length) or 160))
    if #text <= max_length then
        return text
    end
    return text:sub(1, max_length - 3) .. "..."
end

local function diagnostic_text_matches_any(text, needles)
    for _, needle in ipairs(needles) do
        if runtime:contains(text, needle) then
            return true
        end
    end
    return false
end

local function member_diagnostic_text(value, members, call_member)
    local parts = {}
    for _, member in ipairs(members or {}) do
        local name = type(member) == "table" and member.name or member
        local label = type(member) == "table"
            and (member.label or member.name) or member
        local member_value = nil
        if call_member == true then
            local ok, result = runtime:call_value_method(value, name)
            if ok then
                member_value = runtime:get_param_value(result)
            end
        else
            member_value = runtime:value_field(value, name)
        end
        local field_text = runtime:property_identity_text(member_value)
        if field_text ~= "" then
            table.insert(parts, tostring(label) .. "="
                .. compact_diagnostic_text(field_text, 160))
        end
    end
    return table.concat(parts, ",")
end

local function enhanced_key_value_diagnostics(key_value)
    local key_text = runtime:property_identity_text(key_value)
    local key_fields = member_diagnostic_text(key_value, {
        { name = "KeyName", label = "keyName" },
        { name = "Name", label = "name" },
        { name = "DisplayName", label = "displayName" },
        { name = "DisplayNameText", label = "displayNameText" },
    })
    local key_methods = member_diagnostic_text(key_value,
        { "GetFName", "GetDisplayName", "ToString" }, true)
    return {
        raw = key_text ~= "" and key_text or "none",
        fields = key_fields ~= "" and key_fields or "none",
        methods = key_methods ~= "" and key_methods or "none",
        search = key_text .. " " .. key_fields .. " " .. key_methods,
    }
end

local function enhanced_mapping_key_diagnostics(mapping)
    return enhanced_key_value_diagnostics(runtime:value_field(mapping, "Key"))
end

local function configured_controller_key_needles()
    local needles = {}
    for _, configured_key in ipairs(config.controller_cancel_keys or {}) do
        table.insert(needles, configured_key)
        for _, key in ipairs(runtime:controller_input_key_values_from_name(
            configured_key)) do
            local name = tostring(key.name or "")
            if name ~= "" then
                table.insert(needles, name)
            end
        end
    end
    return needles
end

local function controller_cancel_action_names_for_player_input(player_input)
    local cache_key = runtime:property_identity_text(player_input)
        .. "|" .. table.concat(config.controller_cancel_keys or {}, ",")
    if cache_key == controller_cancel_action_cache_key
        and controller_cancel_action_names ~= nil
    then
        return controller_cancel_action_names
    end

    local mapped = runtime:enhanced_action_mapping_actions_for_keys(
        player_input, configured_controller_key_needles(), 16)
    controller_cancel_action_cache_key = cache_key
    controller_cancel_action_names = mapped.actions or {}
    debug_log("[controller-cancel-enhanced-input] mapped actions="
        .. tostring(#controller_cancel_action_names)
        .. " detail=" .. tostring(mapped.detail))
    return controller_cancel_action_names
end

local function local_player_input_from_args(args)
    for index = 1, math.min(#args, 5) do
        local object = runtime:get_param_object(args[index])
        if object_is_local_player_input(object) then
            return object, index
        end
    end
    return nil, nil
end

local function enhanced_action_mapping_summary(player_input)
    local mappings_read = runtime:read_object_property(player_input,
        "EnhancedActionMappings")
    local mappings_value = runtime:resolve_object_reference(
        mappings_read.value) or mappings_read.value
    local mappings = runtime:array_items(mappings_value, 512)
    local key_candidates = {}
    local action_candidates = {}
    local samples = {}
    local visible = 0
    local action_needles = { "Cancel", "Back", "Menu" }
    local key_needles = configured_controller_key_needles()

    for _, mapping in ipairs(mappings) do
        local action_text = runtime:property_identity_text(
            runtime:value_field(mapping, "Action"))
        local key = enhanced_mapping_key_diagnostics(mapping)
        local triggers = runtime:array_items(runtime:value_field(mapping,
            "Triggers"), 16)
        local has_key = key.raw ~= "none" or key.fields ~= "none"
            or key.methods ~= "none"
        if action_text ~= "" or has_key then
            visible = visible + 1
        end
        local entry = "action="
            .. compact_diagnostic_text(action_text, 140)
            .. " keyRaw=" .. compact_diagnostic_text(key.raw, 100)
            .. " keyFields=" .. compact_diagnostic_text(key.fields, 220)
            .. " keyMethods=" .. compact_diagnostic_text(key.methods, 220)
            .. " triggers=" .. tostring(#triggers)
        if #samples < 8 and (action_text ~= "" or has_key) then
            table.insert(samples, entry)
        end
        if #key_candidates < 16
            and diagnostic_text_matches_any(key.search, key_needles)
        then
            table.insert(key_candidates, entry)
        end
        if #action_candidates < 8
            and diagnostic_text_matches_any(action_text, action_needles)
        then
            table.insert(action_candidates, entry)
        end
    end

    local key_entries = #key_candidates > 0
        and table.concat(key_candidates, " || ") or "none"
    local action_entries = #action_candidates > 0
        and table.concat(action_candidates, " || ") or "none"
    local sample_entries = #samples > 0
        and table.concat(samples, " || ") or "none"
    return "total=" .. tostring(#mappings)
        .. " visible=" .. tostring(visible)
        .. " keyCandidates=" .. tostring(#key_candidates)
        .. " actionCandidates=" .. tostring(#action_candidates)
        .. " keyEntries=" .. key_entries
        .. " actionEntries=" .. action_entries
        .. " sampleEntries=" .. sample_entries
end

local function enhanced_action_instance_summary(player_input)
    local read = runtime:read_object_property(player_input,
        "ActionInstanceData")
    local value = runtime:resolve_object_reference(read.value) or read.value
    local entries = {}
    local needles = { "Jump", "Fly", "Cancel", "Back", "Menu" }
    for _, item in ipairs(runtime:map_items(value, 80)) do
        local action_text = runtime:property_identity_text(item.key)
        local instance = item.value
        local event_text = runtime:property_identity_text(
            runtime:value_field(instance, "TriggerEvent"))
        local source_text = runtime:property_identity_text(
            runtime:value_field(instance, "SourceAction"))
        if #entries < 12
            and diagnostic_text_matches_any(action_text .. " "
                .. source_text .. " " .. event_text, needles)
        then
            table.insert(entries, "action="
                .. compact_diagnostic_text(action_text, 130)
                .. " event=" .. compact_diagnostic_text(event_text, 40)
                .. " source="
                .. compact_diagnostic_text(source_text, 130))
        end
    end
    return runtime:property_probe_text("ActionInstanceData", read)
        .. " entries=" .. (#entries > 0 and table.concat(entries, " || ")
            or "none")
end

local function on_controller_cancel_enhanced_input(context, ...)
    if config.controller_cancel_enabled ~= true
        or tracked_interaction.active ~= true
    then
        return nil
    end

    local args = { ... }
    local player_input = local_player_input_from_args(args)
    if player_input == nil or controller_enhanced_input_scan_due() ~= true then
        return nil
    end

    local action_names =
        controller_cancel_action_names_for_player_input(player_input)
    if #action_names == 0 then
        return nil
    end

    local action = runtime:enhanced_action_instance_triggered_action(
        player_input, action_names,
        core.enhanced_input_trigger_event_is_pressed)
    if action.matched == true then
        local marker = tostring(tracked_interaction.started_at_ms)
            .. ":" .. tostring(tracked_interaction.target)
        if marker ~= controller_cancel_enhanced_match_marker then
            controller_cancel_enhanced_match_marker = marker
            log("[controller-cancel-enhanced-input] "
                .. tostring(action.detail))
        else
            debug_log("[controller-cancel-enhanced-input] duplicate "
                .. tostring(action.detail))
        end
        on_cancel_hotkey("ESCAPE")
    end
    return nil
end

local function install_controller_cancel_enhanced_input_hooks()
    if config.controller_cancel_enabled ~= true then
        return 0
    end
    local registered = 0
    for _, hook_name in ipairs(
        core.controller_cancel_enhanced_input_hook_candidates())
    do
        if controller_cancel_enhanced_input_hook_registered[hook_name] ~= true
        then
            local ok = runtime:register_hook(hook_name, function()
                return nil
            end, function(context, ...)
                return on_controller_cancel_enhanced_input(context, ...)
            end, false)
            if ok then
                controller_cancel_enhanced_input_hook_registered[hook_name] =
                    true
                registered = registered + 1
            end
        end
    end
    if registered > 0 then
        hotkey_runtime_enabled = true
        log("Controller cancel EnhancedInput hooks registered: "
            .. tostring(registered))
    end
    return registered
end

local function on_controller_input_discovery_hook(hook_name, phase, context, ...)
    if tracked_interaction.active ~= true then
        return nil
    end
    if hook_name == "/Script/EnhancedInput.InputTrigger:UpdateState" then
        local args = { ... }
        local player_input, player_input_index =
            local_player_input_from_args(args)
        if player_input == nil then
            return nil
        end
        if config.discovery_mode ~= true then
            return nil
        end
        local trigger = runtime:get_param_object(context)
        if not runtime:is_usable_object(trigger) then
            return nil
        end
        local modified_value = args[(player_input_index or 1) + 1]
        local marker = tostring(tracked_interaction.started_at_ms)
            .. ":" .. tostring(tracked_interaction.target)
        if marker ~= controller_trigger_discovery_marker then
            controller_trigger_discovery_marker = marker
            controller_trigger_discovery_seen = {}
            controller_trigger_discovery_count = 0
        end
        local mapping_summary = ""
        if controller_mapping_summary_marker ~= marker then
            controller_mapping_summary_marker = marker
            mapping_summary = " mappingSummary="
                .. enhanced_action_mapping_summary(player_input)
        end
        local trigger_text = runtime:property_identity_text(trigger)
        local value_text = runtime:property_identity_text(
            runtime:get_param_value(modified_value))
        local key = tostring(phase) .. "|" .. trigger_text .. "|" .. value_text
        if controller_trigger_discovery_seen[key] == true
            or controller_trigger_discovery_count >= 80
        then
            return nil
        end
        controller_trigger_discovery_seen[key] = true
        controller_trigger_discovery_count =
            controller_trigger_discovery_count + 1
        discovery_log("[controller-trigger-discovery] hook="
            .. tostring(hook_name)
            .. " phase=" .. tostring(phase)
            .. " trigger=" .. trigger_text
            .. " playerInput=" .. runtime:property_identity_text(player_input)
            .. mapping_summary
            .. " actionInstanceData="
            .. enhanced_action_instance_summary(player_input)
            .. " triggerProps=" .. trigger_property_summary(trigger)
            .. " value=" .. value_text
            .. " delta=" .. runtime:property_identity_text(
                runtime:get_param_value(args[(player_input_index or 1) + 2])))
        return nil
    end
    if config.discovery_mode ~= true then
        return nil
    end
    local object = runtime:get_param_object(context)
    discovery_log("[controller-input-discovery] hook=" .. tostring(hook_name)
        .. " phase=" .. tostring(phase)
        .. " context=" .. runtime:property_identity_text(object)
        .. " params=" .. controller_discovery_param_summary(...))
    return nil
end

local function install_controller_input_discovery_hooks()
    if config.discovery_mode ~= true then
        return 0
    end
    local registered = 0
    for _, hook_name in ipairs(core.controller_input_discovery_hook_candidates()) do
        if controller_input_discovery_hook_registered[hook_name] ~= true then
            local pre_hook = function(context, ...)
                return on_controller_input_discovery_hook(hook_name, "pre",
                    context, ...)
            end
            local post_hook = nil
            if hook_name == "/Script/EnhancedInput.InputTrigger:UpdateState" then
                post_hook = function(context, ...)
                    return on_controller_input_discovery_hook(hook_name, "post",
                        context, ...)
                end
            end
            local ok = runtime:register_hook(hook_name, pre_hook, post_hook,
                false)
            if ok then
                controller_input_discovery_hook_registered[hook_name] = true
                registered = registered + 1
            end
        end
    end
    if registered > 0 then
        log("Controller input discovery hooks registered: "
            .. tostring(registered))
    end
    return registered
end

local function install_tracking_hooks()
    local registered = 0
    for _, hook_name in ipairs(core.discovery_hook_candidates()) do
        local function on_tracking_hook(context, ...)
            mark_interaction_context(hook_name, context, ...)
            return nil
        end
        local ok = runtime:register_hook(hook_name, on_tracking_hook,
            on_tracking_hook, false)
        if ok then
            registered = registered + 1
        end
    end
    log("Tracking hooks registered: " .. tostring(registered))
    return registered
end

local function install_player_hooks()
    local ok_any = false
    for _, hook_name in ipairs(core.player_context_hook_candidates()) do
        if hook_name == "/Script/Engine.PlayerController:ClientRestart" then
            ok_any = runtime:register_hook(hook_name, function(context, new_pawn)
                runtime:set_player_controller(runtime:get_param_object(context))
                if not mark_hero_from_context(new_pawn,
                    "PlayerController:ClientRestart")
                then
                    refresh_player_from_controller()
                end
                refresh_controller_input_snapshot()
                debug_log("ClientRestart observed; player context refreshed.")
                log_controller_input_snapshot()
                install_controller_cancel_ability_input_hooks()
                install_controller_cancel_enhanced_input_hooks()
                install_controller_input_discovery_hooks()
                return nil
            end, nil, false) or ok_any
        else
            local source = hook_name:match(":([^:]+)$") or hook_name
            ok_any = runtime:register_hook(hook_name, function(context)
                mark_hero_from_context(context, "GothicCharacter:" .. source)
                return nil
            end, nil, false) or ok_any
        end
    end
    refresh_player_from_controller()
    refresh_controller_input_snapshot()
    return ok_any
end

load_config()
if not runtime:required_lua_api_available() then
    hotkey_runtime_enabled = false
    log("Loaded v" .. VERSION .. " in degraded mode.")
else
    local player_hooks_installed = install_player_hooks()
    local tracking_hook_count = install_tracking_hooks()
    local task_notification_count = install_movement_task_object_notifications()
    local cancel_hotkeys_installed = install_cancel_hotkeys()
    log_controller_input_snapshot()
    local controller_cancel_ability_input_hook_count =
        install_controller_cancel_ability_input_hooks()
    local controller_cancel_enhanced_input_hook_count =
        install_controller_cancel_enhanced_input_hooks()
    local controller_input_discovery_hook_count =
        install_controller_input_discovery_hooks()
    local hotkey_state = cancel_hotkeys_installed
        and "cancel hotkeys enabled"
        or "cancel hotkeys disabled"
    hotkey_state = hotkey_state .. "; controller cancel "
        .. "ability input hooks="
        .. tostring(controller_cancel_ability_input_hook_count)
        .. "; controller enhanced input hooks="
        .. tostring(controller_cancel_enhanced_input_hook_count)
        .. "; controller input discovery hooks="
        .. tostring(controller_input_discovery_hook_count)
    if player_hooks_installed then
        log("Loaded v" .. VERSION .. " with player hooks and "
            .. tostring(tracking_hook_count) .. " tracking hooks; "
            .. "task notifications=" .. tostring(task_notification_count)
            .. "; " .. hotkey_state .. ".")
    else
        log("Loaded v" .. VERSION .. " without player hooks; tracking hooks="
            .. tostring(tracking_hook_count)
            .. "; task notifications=" .. tostring(task_notification_count)
            .. "; " .. hotkey_state .. ".")
    end
end
