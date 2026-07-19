local MOD_NAME = "G1R_CancelInteraction"
local VERSION = "0.7.2"
local CONFIG_FILE_NAME = "G1R_CancelInteraction.ini"
local DIRECTIONAL_CANCEL_EDGE_MS = 50
local FREEPOINT_INIT_DELAY_MS = 1

local BLOCKING_INTERACTION_SET_MOVE_HOOK =
    "/Script/G1R.GameplayAbilityBlockingInteraction:SetMoveToTask"
local BLOCKING_INTERACTION_MOVE_ENDED_HOOK =
    "/Script/G1R.GameplayAbilityBlockingInteraction:OnMoveToTaskEnded"
local FREEPOINT_MOVE_TASK_CLASS =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction"
local FREEPOINT_MOVE_TASK_FACTORY_HOOK =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:"
    .. "BP_TaskMoveIntoPositionForInteraction"
local FREEPOINT_ALIGNMENT_ENDED_HOOK =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:"
    .. "HandleAlignmentFinished"
local FREEPOINT_INTERACTION_ENDED_HOOK =
    "/Script/G1R.GameplayAbilityInteractFreePoint:OnInteractionTaskEnded"
local CONVERSATION_UI_HOOK =
    "/Script/G1R.GameplayAbilityConversationV2WithUI:ClientShowConversationUI"
local CONVERSATION_GROUP_CLASS = "/Script/G1R.ConversationGroup"
local K2_CANCEL_ABILITY_PATH =
    "/Script/GameplayAbilities.GameplayAbility:K2_CancelAbility"
local FREEPOINT_QUICK_END_PATH =
    "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndQuick"

local core = require("cancel_core")
local pleasureLib = require("pleasure_lib_loader").new(MOD_NAME)
if type(pleasureLib) ~= "table" then return end

local config = core.config_from_ini({})
local active_interaction = nil
local recent_cancelled_interaction = nil
local active_conversation = nil
local pending_interaction_cancel = nil
local pending_conversation_cancel = nil
local finished_freepoint_task_objects = setmetatable({}, { __mode = "k" })
local finished_freepoint_task_identities = {}
local scheduled_freepoint_task_objects = setmetatable({}, { __mode = "k" })
local shown_conversation_objects = setmetatable({}, { __mode = "k" })
local shown_conversation_identities = {}
local key_bind_callbacks = {}
local pending_game_thread_callbacks = {}
local pending_game_thread_callback_id = 0
local runtime_generation = 0
local conversation_generation = 0
local map_lifecycle_callback = nil
local k2_cancel_ability = nil
local freepoint_quick_end = nil
local freepoint_lifecycle_ready = false

local function log(message)
    pleasureLib:log(message)
end

local function debug_log(message)
    if config.debug ~= true then return end
    if type(message) == "function" then
        local ok, built = pcall(message)
        message = ok and built or ("log-builder-failed: " .. tostring(built))
    end
    pleasureLib:debug_log(message)
end

local function unwrap(value)
    return pleasureLib:unwrap(value)
end

local function is_valid(object)
    return pleasureLib:is_valid(object)
end

local function full_name(object)
    return pleasureLib:full_name(object)
end

local function read_property(object, property_name)
    return pleasureLib:try(function()
        return unwrap(object[property_name])
    end)
end

local function tracked_object_matches(tracked, object, identity)
    if tracked == nil then return false end
    if object ~= nil and tracked.object == object then return true end
    return core.identities_match(tracked.identity, identity)
end

local function tracked_task_matches(tracked, task, identity)
    if tracked == nil then return false end
    if task ~= nil and tracked.task == task then return true end
    return core.identities_match(tracked.task_identity, identity)
end

local function invalidate_record(record)
    if record ~= nil then record.cancel_allowed = false end
end

local function config_candidate_paths()
    local paths = {}
    local directory = pleasureLib:script_directory()
    if directory then
        table.insert(paths, directory .. "..\\" .. CONFIG_FILE_NAME)
        table.insert(paths, directory .. CONFIG_FILE_NAME)
    end
    table.insert(paths, "Mods\\G1R_CancelInteraction\\" .. CONFIG_FILE_NAME)
    table.insert(paths,
        "ue4ss\\Mods\\G1R_CancelInteraction\\" .. CONFIG_FILE_NAME)
    table.insert(paths, CONFIG_FILE_NAME)
    return paths
end

local function load_config()
    for _, path in ipairs(config_candidate_paths()) do
        local content = pleasureLib:read_text_file(path)
        if content ~= nil then
            config = core.config_from_ini(pleasureLib:parse_ini(content))
            pleasureLib:set_debug(config.debug)
            log("Loaded config from " .. tostring(path)
                .. ": Debug=" .. tostring(config.debug)
                .. " CancelKeys=" .. table.concat(config.cancel_keys, ","))
            return
        end
    end
    config = core.config_from_ini({})
    pleasureLib:set_debug(config.debug)
    log("Config not found; using defaults.")
end

local function execute_in_game_thread(label, callback)
    if type(ExecuteInGameThread) ~= "function" then
        log("ExecuteInGameThread unavailable for " .. tostring(label))
        return false
    end

    pending_game_thread_callback_id = pending_game_thread_callback_id + 1
    local callback_id = pending_game_thread_callback_id
    local callback_generation = runtime_generation
    local wrapped
    wrapped = function()
        pending_game_thread_callbacks[callback_id] = nil
        if callback_generation ~= runtime_generation then
            debug_log("Discarded stale game-thread callback for "
                .. tostring(label))
            return
        end
        pleasureLib:safe(label, callback)
    end
    pending_game_thread_callbacks[callback_id] = wrapped

    local ok, err = pcall(function()
        ExecuteInGameThread(wrapped)
    end)
    if not ok then
        pending_game_thread_callbacks[callback_id] = nil
        log("Could not schedule " .. tostring(label) .. ": "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    return true
end

local function clear_interaction(reason)
    if active_interaction ~= nil then
        debug_log("Interaction window closed: " .. tostring(reason)
            .. " object=" .. tostring(active_interaction.identity))
        invalidate_record(active_interaction)
    end
    active_interaction = nil
end

local function clear_recent_interaction(reason)
    if recent_cancelled_interaction ~= nil then
        debug_log("Interaction edge window closed: " .. tostring(reason)
            .. " object="
            .. tostring(recent_cancelled_interaction.identity))
        invalidate_record(recent_cancelled_interaction)
    end
    recent_cancelled_interaction = nil
end

local function clear_conversation(reason)
    if active_conversation ~= nil then
        debug_log("Conversation window closed: " .. tostring(reason)
            .. " object=" .. tostring(active_conversation.identity))
        invalidate_record(active_conversation)
    end
    active_conversation = nil
end

local function reset_runtime_context(reason)
    runtime_generation = runtime_generation + 1
    conversation_generation = conversation_generation + 1
    clear_interaction(reason)
    clear_recent_interaction(reason)
    clear_conversation(reason)

    invalidate_record(pending_interaction_cancel)
    invalidate_record(pending_conversation_cancel)
    pending_interaction_cancel = nil
    pending_conversation_cancel = nil
    finished_freepoint_task_objects = setmetatable({}, { __mode = "k" })
    finished_freepoint_task_identities = {}
    scheduled_freepoint_task_objects = setmetatable({}, { __mode = "k" })
    shown_conversation_objects = setmetatable({}, { __mode = "k" })
    shown_conversation_identities = {}
end

local function schedule_edge_expiry(label, record, is_current, expire)
    local callback_generation = runtime_generation
    local schedule_ok, scheduled = pcall(function()
        return pleasureLib:delay_game_thread(
            DIRECTIONAL_CANCEL_EDGE_MS, function()
                if callback_generation ~= runtime_generation
                    or not is_current(record)
                then
                    return
                end
                expire(label .. " expired")
            end)
    end)
    if not schedule_ok or scheduled ~= true then
        expire(label .. " scheduler unavailable")
        log("Could not schedule " .. tostring(label) .. " expiry: "
            .. pleasureLib:safe_to_string(
                schedule_ok and "scheduler unavailable" or scheduled))
    end
end

local function retain_cancelled_interaction_edge(record)
    clear_recent_interaction("replaced")
    active_interaction = nil
    record.move_cancelled = true
    recent_cancelled_interaction = record
    debug_log("Interaction move ended as cancelled; retaining input edge: "
        .. tostring(record.identity))
    schedule_edge_expiry("interaction input edge", record,
        function(candidate)
            return recent_cancelled_interaction == candidate
        end,
        clear_recent_interaction)
end

local function handle_interaction_end(cancelled, matches_active,
        matches_recent, matches_pending, reason)
    if matches_active then
        if cancelled then
            retain_cancelled_interaction_edge(active_interaction)
        else
            clear_interaction(reason)
        end
    elseif matches_recent and not cancelled then
        clear_recent_interaction(reason)
    end

    if matches_pending then
        local preserve_directional_cancel = cancelled
            and pending_interaction_cancel.directional_cancel_requested
                == true
        if preserve_directional_cancel then
            pending_interaction_cancel.move_cancelled = true
            debug_log("Preserved directional cancel across cancelled "
                .. "lifecycle result: "
                .. tostring(pending_interaction_cancel.identity))
        else
            invalidate_record(pending_interaction_cancel)
            pending_interaction_cancel = nil
        end
    end
end

local function on_set_move_to_task(context)
    local ability = unwrap(context)
    local identity = full_name(ability)
    local classification = core.classify_blocking_interaction(identity)

    if classification.action == "track" and is_valid(ability) then
        if pending_interaction_cancel ~= nil
            and pending_interaction_cancel.directional_cancel_requested == true
        then
            debug_log("Ignored move-to restart while directional cancel is "
                .. "pending: " .. tostring(identity))
            return
        end
        if recent_cancelled_interaction ~= nil
            and recent_cancelled_interaction.kind == "freepoint"
            and recent_cancelled_interaction.cancel_allowed == true
        then
            debug_log("Ignored blocking move-to during FreePoint "
                .. "directional edge: " .. tostring(identity))
            return
        end
        if active_interaction ~= nil
            and active_interaction.kind == "freepoint"
            and is_valid(active_interaction.object)
            and read_property(active_interaction.object,
                "m_AbilityEnded") ~= true
            and read_property(active_interaction.object,
                "bEndRequested") ~= true
            and is_valid(active_interaction.task)
            and read_property(active_interaction.task,
                "bIsReadyToStartAnimation") ~= true
        then
            debug_log("Kept higher-priority FreePoint interaction while "
                .. "blocking move-to started: " .. tostring(identity))
            return
        end
        if pending_interaction_cancel ~= nil then
            invalidate_record(pending_interaction_cancel)
            pending_interaction_cancel = nil
        end
        clear_recent_interaction("new move-to task")
        clear_interaction("replaced by new move-to task")
        active_interaction = {
            kind = "blocking",
            object = ability,
            identity = identity,
            cancel_allowed = true,
            directional_cancel_requested = false,
            move_cancelled = false,
        }
        debug_log("Interaction window opened: " .. identity)
    elseif classification.action == "clear" then
        invalidate_record(pending_interaction_cancel)
        pending_interaction_cancel = nil
        clear_recent_interaction(classification.reason)
        clear_interaction(classification.reason)
    else
        debug_log("Ignored blocking interaction: "
            .. tostring(classification.reason)
            .. " object=" .. tostring(identity))
    end
end

local function on_move_to_task_ended(context, _move_to_task, result)
    local ability = unwrap(context)
    local identity = full_name(ability)
    local cancelled = core.generic_task_result_is_cancelled(unwrap(result))
    handle_interaction_end(cancelled,
        active_interaction ~= nil
            and active_interaction.kind == "blocking"
            and tracked_object_matches(active_interaction, ability, identity),
        recent_cancelled_interaction ~= nil
            and recent_cancelled_interaction.kind == "blocking"
            and tracked_object_matches(recent_cancelled_interaction,
                ability, identity),
        pending_interaction_cancel ~= nil
            and pending_interaction_cancel.kind == "blocking"
            and tracked_object_matches(pending_interaction_cancel,
                ability, identity),
        "move-to task ended")
end

local function freepoint_task_was_finished(task, identity)
    if task ~= nil and finished_freepoint_task_objects[task] == true then
        return true
    end
    return identity ~= ""
        and finished_freepoint_task_identities[identity] == true
end

local function mark_freepoint_task_finished(task, identity)
    if task ~= nil then finished_freepoint_task_objects[task] = true end
    if identity ~= "" then
        finished_freepoint_task_identities[identity] = true
    end
end

local function find_freepoint_task_in_values(context, ...)
    local function candidate(value)
        local object = unwrap(value)
        if not is_valid(object) then return nil end
        local identity = full_name(object)
        if core.is_move_to_interaction_task_identity(identity)
            and string.find(identity, "Default__", 1, true) == nil
        then
            return object
        end
        return nil
    end

    local task = candidate(context)
    if task ~= nil then return task end
    for index = 1, select("#", ...) do
        task = candidate(select(index, ...))
        if task ~= nil then return task end
    end
    return nil
end

local function exclude_mining_interaction(reason)
    invalidate_record(pending_interaction_cancel)
    pending_interaction_cancel = nil
    clear_recent_interaction(reason)
    clear_interaction(reason)
end

local function try_track_freepoint_task(task, source)
    if not is_valid(task) then return "ignored" end

    local task_identity = full_name(task)
    if not core.is_move_to_interaction_task_identity(task_identity)
        or string.find(task_identity, "Default__", 1, true) ~= nil
        or freepoint_task_was_finished(task, task_identity)
    then
        return "ignored"
    end
    if not freepoint_lifecycle_ready
        or not is_valid(freepoint_quick_end)
    then
        return "ignored"
    end

    local ability = read_property(task, "Ability")
    if not is_valid(ability) then return "not-ready" end

    local ability_identity = full_name(ability)
    if not core.is_freepoint_ability_identity(ability_identity)
        or not core.is_player_identity(ability_identity)
    then
        return "ignored"
    end
    if read_property(ability, "m_AbilityEnded") == true
        or read_property(ability, "bEndRequested") == true
    then
        return "ignored"
    end

    local interactive_actor = read_property(ability, "m_InteractiveActor")
    local actor_identity = full_name(interactive_actor)
    if core.is_mining_identity(ability_identity .. " "
            .. task_identity .. " " .. actor_identity)
    then
        exclude_mining_interaction("FreePoint mining excluded")
        return "mining"
    end

    if tracked_task_matches(active_interaction, task, task_identity)
        or tracked_task_matches(recent_cancelled_interaction,
            task, task_identity)
        or tracked_task_matches(pending_interaction_cancel,
            task, task_identity)
    then
        return "duplicate"
    end
    if pending_interaction_cancel ~= nil then
        debug_log("Ignored FreePoint task while cancel is pending: "
            .. tostring(task_identity))
        return "pending"
    end

    local root_task = read_property(ability, "RootInteractionTask")
    clear_recent_interaction("new FreePoint move task")
    clear_interaction("replaced by FreePoint move task")
    active_interaction = {
        kind = "freepoint",
        object = ability,
        identity = ability_identity,
        task = task,
        task_identity = task_identity,
        root_task = root_task,
        root_task_identity = full_name(root_task),
        target_identity = actor_identity,
        source = source,
        cancel_allowed = true,
        directional_cancel_requested = false,
        move_cancelled = false,
    }
    debug_log("FreePoint interaction window opened: source="
        .. tostring(source)
        .. " ability=" .. tostring(ability_identity)
        .. " task=" .. tostring(task_identity)
        .. " target=" .. tostring(actor_identity))
    return "tracked"
end

local function schedule_freepoint_task_initialization(task, source)
    if not is_valid(task)
        or scheduled_freepoint_task_objects[task] == true
    then
        return
    end

    scheduled_freepoint_task_objects[task] = true
    local callback_generation = runtime_generation
    local schedule_ok, scheduled = pcall(function()
        return pleasureLib:delay_game_thread(
            FREEPOINT_INIT_DELAY_MS, function()
                scheduled_freepoint_task_objects[task] = nil
                if callback_generation ~= runtime_generation
                    or not is_valid(task)
                then
                    return
                end
                try_track_freepoint_task(task,
                    tostring(source) .. "+delayed")
            end)
    end)
    if not schedule_ok or scheduled ~= true then
        scheduled_freepoint_task_objects[task] = nil
        log("Could not schedule FreePoint task initialization: "
            .. pleasureLib:safe_to_string(
                schedule_ok and "scheduler unavailable" or scheduled))
    end
end

local function observe_freepoint_task(task, source)
    task = unwrap(task)
    if not is_valid(task) then return end
    local status = try_track_freepoint_task(task, source)
    if status == "not-ready" then
        schedule_freepoint_task_initialization(task, source)
    end
end

local function on_freepoint_factory_post(context, ...)
    local task = find_freepoint_task_in_values(context, ...)
    if task ~= nil then
        observe_freepoint_task(task, "factory")
    end
end

local function on_new_freepoint_task(value)
    local task = unwrap(value)
    if not is_valid(task) then return end
    local task_identity = full_name(task)
    if core.is_move_to_interaction_task_identity(task_identity)
        and string.find(task_identity, "Default__", 1, true) == nil
    then
        schedule_freepoint_task_initialization(
            task, "NotifyOnNewObject")
    end
end

local function freepoint_ability_matches(record, ability, identity)
    return record ~= nil and record.kind == "freepoint"
        and tracked_object_matches(record, ability, identity)
end

local function freepoint_end_matches(record, ability, ability_identity,
        ended_task, ended_task_identity)
    if not freepoint_ability_matches(record, ability, ability_identity) then
        return false
    end

    local root_task = record.root_task
    local root_task_identity = record.root_task_identity or ""
    if not is_valid(root_task) then
        root_task = read_property(ability, "RootInteractionTask")
        root_task_identity = full_name(root_task)
    end
    if ended_task ~= nil then
        if not is_valid(root_task) and root_task_identity == "" then
            return false
        end
        return root_task == ended_task
            or core.identities_match(
                root_task_identity, ended_task_identity)
    end
    return false
end

local function on_freepoint_alignment_ended(context, _alignment_task, result)
    local task = unwrap(context)
    local task_identity = full_name(task)
    mark_freepoint_task_finished(task, task_identity)
    local cancelled = core.generic_task_result_is_cancelled(unwrap(result))
    handle_interaction_end(cancelled,
        active_interaction ~= nil
            and active_interaction.kind == "freepoint"
            and tracked_task_matches(active_interaction,
                task, task_identity),
        recent_cancelled_interaction ~= nil
            and recent_cancelled_interaction.kind == "freepoint"
            and tracked_task_matches(recent_cancelled_interaction,
                task, task_identity),
        pending_interaction_cancel ~= nil
            and pending_interaction_cancel.kind == "freepoint"
            and tracked_task_matches(pending_interaction_cancel,
                task, task_identity),
        "FreePoint alignment ended")
end

local function mark_record_task_finished(record)
    if record ~= nil and record.kind == "freepoint" then
        mark_freepoint_task_finished(record.task, record.task_identity or "")
    end
end

local function on_freepoint_interaction_ended(context, ended_task_value, result)
    local ability = unwrap(context)
    local ability_identity = full_name(ability)
    local ended_task = unwrap(ended_task_value)
    local ended_task_identity = full_name(ended_task)
    local matches_active = freepoint_end_matches(active_interaction,
        ability, ability_identity, ended_task, ended_task_identity)
    local matches_recent = freepoint_end_matches(recent_cancelled_interaction,
        ability, ability_identity, ended_task, ended_task_identity)
    local matches_pending = freepoint_end_matches(pending_interaction_cancel,
        ability, ability_identity, ended_task, ended_task_identity)

    if matches_active then mark_record_task_finished(active_interaction) end
    if matches_recent then
        mark_record_task_finished(recent_cancelled_interaction)
    end
    if matches_pending then
        mark_record_task_finished(pending_interaction_cancel)
    end

    handle_interaction_end(
        core.generic_task_result_is_cancelled(unwrap(result)),
        matches_active, matches_recent, matches_pending,
        "FreePoint interaction task ended")
end

local function conversation_was_shown(group, identity)
    if group ~= nil and shown_conversation_objects[group] == true then
        return true
    end
    return identity ~= "" and shown_conversation_identities[identity] == true
end

local function mark_conversation_shown(group, identity)
    if group ~= nil then
        shown_conversation_objects[group] = true
    end
    if identity ~= "" then
        shown_conversation_identities[identity] = true
    end
end

local function on_new_conversation_group(value)
    local group = unwrap(value)
    local callback_generation = runtime_generation
    local callback_conversation_generation = conversation_generation
    local schedule_ok, scheduled = pcall(function()
        return pleasureLib:delay_game_thread(1, function()
            if callback_generation ~= runtime_generation
                or callback_conversation_generation
                    ~= conversation_generation
                or not is_valid(group)
            then
                return
            end

            local identity = full_name(group)
            if conversation_was_shown(group, identity) then
                debug_log("Ignored conversation after UI became visible: "
                    .. tostring(identity))
                return
            end

            local initiator = read_property(group, "Initiator")
            local initiator_identity = full_name(initiator)
            if not core.is_player_identity(initiator_identity) then
                debug_log("Ignored non-player conversation: "
                    .. tostring(identity))
                return
            end

            if pending_conversation_cancel ~= nil then
                pending_conversation_cancel.cancel_allowed = false
                pending_conversation_cancel = nil
            end
            active_conversation = {
                object = group,
                identity = identity,
                cancel_allowed = true,
            }
            debug_log("Conversation window opened: " .. tostring(identity))
        end)
    end)
    if not schedule_ok or scheduled ~= true then
        log("Could not schedule ConversationGroup initialization: "
            .. pleasureLib:safe_to_string(
                schedule_ok and "scheduler unavailable" or scheduled))
    end
end

local function on_conversation_ui_shown(context)
    -- Invalidate every not-yet-initialized group observed before this UI event.
    conversation_generation = conversation_generation + 1

    local ability = unwrap(context)
    local group = read_property(ability, "ConversationGroup")
    local identity = full_name(group)

    if is_valid(group) then
        mark_conversation_shown(group, identity)
        if tracked_object_matches(active_conversation, group, identity) then
            clear_conversation("conversation UI shown")
        end
        if tracked_object_matches(pending_conversation_cancel, group, identity)
        then
            pending_conversation_cancel.cancel_allowed = false
        end
        return
    end

    -- Fail closed if the UI hook fires but its group cannot be read.
    clear_conversation("conversation UI shown without group")
    if pending_conversation_cancel ~= nil then
        pending_conversation_cancel.cancel_allowed = false
    end
end

local function cancel_blocking_interaction(interaction)
    if interaction == nil or interaction.cancel_allowed ~= true
        or not is_valid(interaction.object)
    then
        return false
    end
    if read_property(interaction.object, "m_AbilityEnded") == true then
        return false
    end
    if not is_valid(k2_cancel_ability) then
        log("K2_CancelAbility unavailable; interaction was not cancelled")
        return false
    end

    local property_ok, property_err = pcall(function()
        interaction.object.m_ApplyCooldown = false
    end)
    if not property_ok then
        log("Could not disable interaction cooldown; interaction was not "
            .. "cancelled: " .. pleasureLib:safe_to_string(property_err))
        return false
    end

    local ok, err = pcall(function()
        k2_cancel_ability(interaction.object)
    end)
    if not ok then
        log("K2_CancelAbility failed: "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    debug_log("Cancelled interaction: " .. tostring(interaction.identity))
    return true
end

local function cancel_freepoint_interaction(interaction)
    if interaction == nil or interaction.cancel_allowed ~= true
        or not is_valid(interaction.object)
    then
        return false
    end
    if read_property(interaction.object, "m_AbilityEnded") == true
        or read_property(interaction.object, "bEndRequested") == true
    then
        return false
    end

    local current_identity = full_name(interaction.object)
    if not core.is_freepoint_ability_identity(current_identity)
        or not core.is_player_identity(current_identity)
        or core.is_mining_identity(current_identity .. " "
            .. tostring(interaction.task_identity) .. " "
            .. tostring(interaction.target_identity))
    then
        return false
    end

    if is_valid(interaction.task) then
        local ready =
            read_property(interaction.task, "bIsReadyToStartAnimation")
        if ready == true or ready == 1 then
            debug_log("Skipped FreePoint cancel at animation handoff: "
                .. tostring(interaction.task_identity)
                .. " ready=" .. tostring(ready))
            return false
        end
        if interaction.move_cancelled ~= true
            and ready ~= false and ready ~= 0
        then
            return false
        end
    elseif interaction.move_cancelled ~= true then
        return false
    end
    if not is_valid(freepoint_quick_end) then
        log("OnRequestEndQuick unavailable; FreePoint interaction was not "
            .. "cancelled")
        return false
    end

    local ok, err = pcall(function()
        freepoint_quick_end(interaction.object)
    end)
    if not ok then
        log("OnRequestEndQuick failed: "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    debug_log("Cancelled FreePoint interaction: "
        .. tostring(interaction.identity)
        .. " task=" .. tostring(interaction.task_identity))
    return true
end

local function cancel_interaction(interaction)
    if interaction ~= nil and interaction.kind == "freepoint" then
        return cancel_freepoint_interaction(interaction)
    end
    return cancel_blocking_interaction(interaction)
end

local function cancel_conversation(conversation)
    if conversation == nil or conversation.cancel_allowed ~= true
        or not is_valid(conversation.object)
    then
        return false
    end
    if read_property(conversation.object, "bEndRequested") == true then
        return false
    end

    local ok, err = pcall(function()
        conversation.object:RequestEndConversation()
    end)
    if not ok then
        log("RequestEndConversation failed: "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    debug_log("Cancelled conversation: " .. tostring(conversation.identity))
    return true
end

local function request_cancel(key_name)
    local directional = core.is_directional_cancel_key(key_name)
    local interaction = active_interaction
    if interaction == nil and directional then
        interaction = recent_cancelled_interaction
    end
    local conversation = active_conversation
    if interaction == nil and conversation == nil then
        return false
    end

    if interaction ~= nil then
        if active_interaction == interaction then active_interaction = nil end
        if recent_cancelled_interaction == interaction then
            recent_cancelled_interaction = nil
        end
        interaction.directional_cancel_requested = directional
        if pending_interaction_cancel ~= interaction then
            invalidate_record(pending_interaction_cancel)
        end
        pending_interaction_cancel = interaction
    end
    if conversation ~= nil then
        active_conversation = nil
        if pending_conversation_cancel ~= conversation then
            invalidate_record(pending_conversation_cancel)
        end
        pending_conversation_cancel = conversation
    end

    local scheduled = execute_in_game_thread("cancel request", function()
        local cancelled_interaction = cancel_interaction(interaction)
        local cancelled_conversation = cancel_conversation(conversation)
        if pending_interaction_cancel == interaction then
            pending_interaction_cancel = nil
        end
        if pending_conversation_cancel == conversation then
            pending_conversation_cancel = nil
        end
        if cancelled_interaction or cancelled_conversation then
            debug_log("Cancel request handled for key " .. tostring(key_name))
        end
    end)
    if not scheduled then
        invalidate_record(interaction)
        invalidate_record(conversation)
        if pending_interaction_cancel == interaction then
            pending_interaction_cancel = nil
        end
        if pending_conversation_cancel == conversation then
            pending_conversation_cancel = nil
        end
    end
    return scheduled
end

local function register_cancel_key(key_name)
    if type(RegisterKeyBind) ~= "function" or type(Key) ~= "table" then
        return false, "RegisterKeyBind or Key unavailable"
    end
    for _, candidate in ipairs(
        core.cancel_key_lookup_candidates(key_name))
    do
        local ok_key, key_value = pcall(function()
            return Key[candidate]
        end)
        if ok_key and key_value ~= nil then
            local callback = function()
                request_cancel(candidate)
            end
            local ok, err = pcall(function()
                RegisterKeyBind(key_value, callback)
            end)
            if ok then
                table.insert(key_bind_callbacks, callback)
                return true, candidate
            end
            return false, err
        end
    end
    return false, "unknown key"
end

local function install_map_lifecycle_hook()
    if type(RegisterLoadMapPreHook) ~= "function" then
        debug_log("RegisterLoadMapPreHook unavailable")
        return false
    end
    map_lifecycle_callback = function()
        reset_runtime_context("load-map-pre")
    end
    local ok, err = pcall(function()
        RegisterLoadMapPreHook(map_lifecycle_callback)
    end)
    if not ok then
        map_lifecycle_callback = nil
        log("Could not register map lifecycle hook: "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    return true
end

local function install_conversation_notification()
    if type(NotifyOnNewObject) ~= "function" then
        log("NotifyOnNewObject unavailable; conversation cancel is disabled")
        return false
    end
    local ok, err = pcall(function()
        NotifyOnNewObject(CONVERSATION_GROUP_CLASS,
            on_new_conversation_group)
    end)
    if not ok then
        log("Could not register ConversationGroup notification: "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    return true
end

local function install_freepoint_task_notification()
    if type(NotifyOnNewObject) ~= "function" then
        log("NotifyOnNewObject unavailable; FreePoint notification disabled")
        return false
    end
    local ok, err = pcall(function()
        NotifyOnNewObject(FREEPOINT_MOVE_TASK_CLASS,
            on_new_freepoint_task)
    end)
    if not ok then
        log("Could not register FreePoint task notification: "
            .. pleasureLib:safe_to_string(err))
        return false
    end
    return true
end

load_config()
k2_cancel_ability = pleasureLib:find_object(K2_CANCEL_ABILITY_PATH)
if not is_valid(k2_cancel_ability) then
    log("K2_CancelAbility was not found; interaction cancel is disabled")
end
freepoint_quick_end = pleasureLib:find_object(FREEPOINT_QUICK_END_PATH)
if not is_valid(freepoint_quick_end) then
    log("OnRequestEndQuick was not found; FreePoint cancel is disabled")
end

local set_move_hook = pleasureLib:register_hook(
    BLOCKING_INTERACTION_SET_MOVE_HOOK, on_set_move_to_task)
local move_ended_hook = pleasureLib:register_hook(
    BLOCKING_INTERACTION_MOVE_ENDED_HOOK, on_move_to_task_ended)
local freepoint_factory_hook = pleasureLib:register_hook(
    FREEPOINT_MOVE_TASK_FACTORY_HOOK,
    function() return nil end,
    on_freepoint_factory_post)
local freepoint_alignment_hook = pleasureLib:register_hook(
    FREEPOINT_ALIGNMENT_ENDED_HOOK, on_freepoint_alignment_ended)
local freepoint_ended_hook = pleasureLib:register_hook(
    FREEPOINT_INTERACTION_ENDED_HOOK, on_freepoint_interaction_ended)
local conversation_ui_hook = pleasureLib:register_hook(
    CONVERSATION_UI_HOOK, on_conversation_ui_shown)
local freepoint_notification = install_freepoint_task_notification()
local conversation_notification = install_conversation_notification()
local map_lifecycle_hook = install_map_lifecycle_hook()
freepoint_lifecycle_ready = is_valid(freepoint_quick_end)
    and (freepoint_factory_hook or freepoint_notification)
    and freepoint_alignment_hook
    and freepoint_ended_hook

local registered_keys = 0
for _, key_name in ipairs(config.cancel_keys) do
    local ok, result = register_cancel_key(key_name)
    if ok then
        registered_keys = registered_keys + 1
        debug_log("Registered cancel key " .. tostring(result))
    else
        log("Could not register cancel key " .. tostring(key_name)
            .. ": " .. pleasureLib:safe_to_string(result))
    end
end

log("Loaded v" .. VERSION
    .. " interactionHooks=" .. tostring(set_move_hook and move_ended_hook)
    .. " freePointHooks=" .. tostring(freepoint_lifecycle_ready)
    .. " conversationHooks="
    .. tostring(conversation_ui_hook and conversation_notification)
    .. " mapLifecycle=" .. tostring(map_lifecycle_hook)
    .. " cancelKeys=" .. tostring(registered_keys))

return {
    request_cancel = request_cancel,
    reset_runtime_context = reset_runtime_context,
}
