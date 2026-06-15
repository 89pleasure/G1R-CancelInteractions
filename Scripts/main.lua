local MOD_NAME = "[G1R_CancelInteraction]"
local VERSION = "0.3.0"
local CONFIG_FILE_NAME = "G1R_CancelInteraction.ini"

local core = require("cancel_core")
local ModRuntime = require("mod_runtime")

local config = core.config_from_ini({})
local runtime = nil
local hotkey_runtime_enabled = false
local hotkey_game_thread_busy = false
local last_hotkey_ms = -1000000
local cached_hero = nil
local cached_hero_identity = ""
local cached_anim_instance = nil
local tracked_interaction = {
    active = false,
    object = nil,
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
                .. " ControllerCancelKey="
                .. tostring(config.controller_cancel_key)
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

local function object_is_cached_hero(object)
    if not runtime:is_usable_object(object)
        or not runtime:is_usable_object(cached_hero)
    then
        return false
    end
    if object == cached_hero then
        return true
    end
    return runtime:get_full_name(object) == cached_hero_identity
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
    tracked_interaction.object = nil
    tracked_interaction.kind = "none"
    tracked_interaction.source = ""
    tracked_interaction.target = ""
    tracked_interaction.phase = "idle"
    tracked_interaction.started_at_ms = 0
    tracked_interaction.priority = 0
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

local function owner_property_status(ok, value)
    if ok ~= true or value == nil then
        return "missing"
    end
    if runtime:is_usable_object(value) then
        return "object"
    end
    return type(value)
end

local function property_identity_text(value)
    if runtime:is_usable_object(value) then
        return runtime:object_identity_text(value)
    end
    local value_type = type(value)
    if value == nil then
        return ""
    end
    if value_type == "string" or value_type == "number"
        or value_type == "boolean"
    then
        return log_value(value)
    end
    local tostring_ok, tostring_value =
        runtime:call_value_method(value, "ToString")
    if tostring_ok and tostring_value ~= nil then
        local text = log_value(tostring_value)
        if text ~= "" and text ~= "None" then
            return text
        end
    end
    return runtime:param_to_log_string(value)
end

local function owner_property_value_is_informative(value)
    if runtime:is_usable_object(value) then
        return true
    end
    if value == nil then
        return false
    end
    local text = property_identity_text(value)
    return text ~= "" and text ~= "None" and text ~= "<userdata>"
end

local function read_owner_property(object, property_name)
    local direct_ok, direct_value =
        runtime:get_object_property(object, property_name)
    local method_ok, method_value =
        runtime:get_object_property_value_method(object, property_name)
    local read = {
        ok = direct_ok,
        value = direct_ok == true and direct_value or nil,
        source = "direct",
        direct_ok = direct_ok,
        direct_value = direct_value,
        method_ok = method_ok,
        method_value = method_ok == true and method_value or nil,
    }
    if method_ok == true
        and (direct_ok ~= true
            or (owner_property_value_is_informative(method_value)
                and not owner_property_value_is_informative(direct_value)))
    then
        read.ok = method_ok
        read.value = method_value
        read.source = "GetPropertyValue"
    end
    return read
end

local function owner_property_probe_text(property_name, read)
    read = read or {}
    return tostring(property_name) .. "=" .. tostring(read.source or "unknown")
        .. ":" .. owner_property_status(read.ok, read.value)
        .. "(direct=" .. owner_property_status(read.direct_ok,
            read.direct_value)
        .. ",GetPropertyValue." .. tostring(property_name) .. "="
        .. owner_property_status(read.method_ok, read.method_value)
        .. ")"
end

local function movement_task_owner_context(object)
    local ability_read = read_owner_property(object, "Ability")
    local ability_system_read =
        read_owner_property(object, "AbilitySystemComponent")
    if not owner_property_value_is_informative(ability_system_read.value)
        and runtime:is_usable_object(ability_read.value)
    then
        local ability_system_from_ability =
            read_owner_property(ability_read.value, "AbilitySystemComponent")
        if owner_property_value_is_informative(
            ability_system_from_ability.value)
        then
            ability_system_from_ability.source =
                "Ability." .. tostring(ability_system_from_ability.source)
            ability_system_read = ability_system_from_ability
        end
    end

    local ability_system = ability_system_read.value
    local owner_actor_read = read_owner_property(ability_system, "OwnerActor")
    local avatar_actor_read = read_owner_property(ability_system, "AvatarActor")
    local owner_property = ""
    if runtime:is_usable_object(ability_read.value) then
        owner_property = "Ability"
    elseif owner_property_value_is_informative(ability_system) then
        owner_property = "AbilitySystemComponent"
    end
    return {
        ability = property_identity_text(ability_read.value),
        ability_system = property_identity_text(ability_system),
        owner_actor = property_identity_text(owner_actor_read.value),
        avatar_actor = property_identity_text(avatar_actor_read.value),
        owner_property = owner_property,
        owner_probe = table.concat({
            owner_property_probe_text("Ability", ability_read),
            owner_property_probe_text("AbilitySystemComponent",
                ability_system_read),
            owner_property_probe_text("OwnerActor", owner_actor_read),
            owner_property_probe_text("AvatarActor", avatar_actor_read),
        }, ";"),
    }
end

local function movement_task_owner_filter(object)
    local context = movement_task_owner_context(object)
    local signature = core.classify_movement_task_owner_signature({
        ability = context.ability,
        ability_system = context.ability_system,
        owner_actor = context.owner_actor,
        avatar_actor = context.avatar_actor,
    })
    local owner_known = signature.owner_known == true
    local filter = core.classify_movement_task_owner_filter({
        owner_known = owner_known,
        owner_is_player = signature.owner_is_player == true,
    })
    filter.owner_property = context.owner_property
    filter.owner_probe = context.owner_probe
    filter.owner_signature = signature.reason
    filter.ability = context.ability
    filter.ability_system = context.ability_system
    filter.owner_actor = context.owner_actor
    filter.avatar_actor = context.avatar_actor
    return filter
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
    tracked_interaction.active = true
    tracked_interaction.kind = "use-object"
    tracked_interaction.phase = "move"
    tracked_interaction.started_at_ms = now_ms()
    if not runtime:is_usable_object(tracked_interaction.object)
        or priority > current_priority
    then
        tracked_interaction.object = object
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

local function try_cancel_movement_interaction(key_name, snapshot)
    local state = current_safety_state(snapshot)
    state.key_name = key_name
    local safety = core.classify_movement_interaction_cancel(state)
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
    if safety.allowed ~= true then
        if safety.reason == "movement action inactive"
            and tracked_interaction.active == true
        then
            clear_tracked_interaction("movement-window-inactive")
        end
        return false
    end

    local task = tracked_interaction.object
    local tracked_phase_is_move = tracked_interaction.phase == "move"
    if not tracked_phase_is_move then
        debug_log("[movement-only-cancel] no tracked move phase; "
            .. "not cancelling without movement task")
    elseif not runtime:is_usable_object(task) then
        debug_log("[movement-only-cancel] no tracked movement task")
        clear_tracked_interaction("no-usable-movement-tasks")
    else
        local task_identity = runtime:object_identity_text(task)
        if not core.movement_task_is_cancelable(task_identity) then
            debug_log("[movement-only-cancel] skipped non-path task"
                .. " object=" .. runtime:get_full_name(task))
            clear_tracked_interaction("non-path-task-active")
            return false
        end
        local locomotion_cancelled = try_cancel_locomotion_interaction(
            key_name, snapshot, { clear_tracking = false })
        if not runtime:is_usable_object(task) then
            debug_log("[movement-only-cancel] tracked movement task invalid"
                .. " after locomotion cancel")
            clear_tracked_interaction("movement-task-invalid")
            return false
        end

        local owner_filter = movement_task_owner_filter(task)
        discovery_log("[movement-cancel-owner-state] key="
            .. tostring(key_name)
            .. " object=" .. task_identity
            .. core.format_movement_task_owner_debug(owner_filter))
        if owner_filter.allowed ~= true then
            debug_log("[movement-only-cancel] skipped owner-filtered task"
                .. " reason=" .. tostring(owner_filter.reason)
                .. " object=" .. runtime:get_full_name(task))
            return false
        end

        discovery_log("[movement-cancel-task-state] key="
            .. tostring(key_name)
            .. " object=" .. task_identity
            .. task_debug_flags(task, task_identity))
        if task_is_finished(task) then
            debug_log("[movement-only-cancel] tracked movement task finished"
                .. " object=" .. runtime:get_full_name(task))
            clear_tracked_interaction("movement-task-finished")
            return false
        end

        local cancelled_task = nil
        for _, method_name in ipairs(core.movement_task_cancel_method_names()) do
            for _, args in ipairs(task_cancel_arg_variants(method_name)) do
                local ok, value, mode =
                    runtime:call_method_with_arg_pack(task, method_name, args)
                if ok == true and task_cancel_call_succeeded(method_name, value) then
                    cancelled_task = {
                        method_name = method_name,
                        args = args,
                        mode = mode,
                    }
                    break
                end
                debug_log("[movement-only-cancel] method="
                    .. tostring(method_name)
                    .. " args=" .. tostring(args.n or 0)
                    .. " ok=" .. tostring(ok)
                    .. " mode=" .. tostring(mode)
                    .. " result=" .. log_value(value)
                    .. " object=" .. runtime:get_full_name(task))
            end
            if cancelled_task ~= nil then
                break
            end
        end

        if cancelled_task ~= nil then
            if tracked_interaction.active == true then
                clear_tracked_interaction("movement-only-cancelled:"
                    .. tostring(cancelled_task.method_name))
            end
            log("[movement-only-cancel] key=" .. tostring(key_name)
                .. " method=" .. tostring(cancelled_task.method_name)
                .. " args=" .. tostring(cancelled_task.args.n or 0)
                .. " mode=" .. tostring(cancelled_task.mode)
                .. " taskLocomotion=" .. tostring(locomotion_cancelled)
                .. " task=" .. runtime:get_full_name(task))
            return true
        end
    end

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

local function install_controller_cancel_hotkeys()
    if config.controller_cancel_enabled ~= true then
        return false
    end
    local ok, normalized, err = runtime:register_key_bind(
        config.controller_cancel_key, function()
            on_cancel_hotkey("ESCAPE")
        end)
    if not ok and err == "unknown key" then
        log("Controller cancel keybind unavailable "
            .. tostring(config.controller_cancel_key)
            .. "; trying fallback hooks")
        return false
    end
    if ok then
        hotkey_runtime_enabled = true
        log("Registered controller cancel key " .. tostring(normalized)
            .. " -> ESCAPE")
        return true
    end
    log("Failed to register controller cancel key " .. tostring(normalized)
        .. ": " .. log_value(err))
    return false
end

local function install_controller_cancel_fallback_hooks()
    if config.controller_cancel_enabled ~= true then
        return 0
    end
    local registered = 0
    for _, hook_name in ipairs(core.controller_cancel_fallback_hook_candidates()) do
        local ok = runtime:register_hook(hook_name, function()
            debug_log("[controller-cancel-fallback] hook="
                .. tostring(hook_name) .. " -> ESCAPE")
            on_cancel_hotkey("ESCAPE")
            return nil
        end, nil, false)
        if ok then
            registered = registered + 1
        end
    end
    if registered > 0 then
        hotkey_runtime_enabled = true
        log("Controller cancel fallback hooks registered: "
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
                debug_log("ClientRestart observed; player context refreshed.")
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
    local controller_cancel_hotkeys_installed =
        install_controller_cancel_hotkeys()
    local controller_cancel_fallback_hook_count = 0
    if not controller_cancel_hotkeys_installed then
        controller_cancel_fallback_hook_count =
            install_controller_cancel_fallback_hooks()
    end
    local hotkey_state = cancel_hotkeys_installed
        and "cancel hotkeys enabled"
        or "cancel hotkeys disabled"
    hotkey_state = hotkey_state .. "; controller cancel "
        .. (controller_cancel_hotkeys_installed and "keybind enabled"
            or ("fallback hooks="
                .. tostring(controller_cancel_fallback_hook_count)))
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
