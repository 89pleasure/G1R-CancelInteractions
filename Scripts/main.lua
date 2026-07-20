local MOD_NAME = "G1R_CancelInteraction"
local VERSION = "0.8.6"
local CONFIG_FILE_NAME = "G1R_CancelInteraction.ini"
local DIRECTIONAL_CANCEL_EDGE_MS = 50
local FREEPOINT_INIT_DELAY_MS = 1
local FREEPOINT_INIT_TIMEOUT_MS = 100
local MINING_ORE_ROLLBACK_DELAYS_MS = { 1, 50, 250, 1000 }
local MINING_REWARD_HUD_SUPPRESSION_MS = 1100
local ORE_COMPARISON_EPSILON = 0.001

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
local ITEM_ADDED_FOR_HUD_HOOK =
    "/Script/G1R.InventoryComponent:OnItemAddedForHUD"
local K2_CANCEL_ABILITY_PATH =
    "/Script/GameplayAbilities.GameplayAbility:K2_CancelAbility"
local K2_HAS_AUTHORITY_PATH =
    "/Script/GameplayAbilities.GameplayAbility:K2_HasAuthority"
local GET_AVATAR_ACTOR_PATH =
    "/Script/GameplayAbilities.GameplayAbility:GetAvatarActorFromActorInfo"
local GET_CHARACTER_INVENTORY_PATH =
    "/Script/G1R.GothicCharacter:GetInventory"
local GAMEPLAY_STATICS_CDO_PATH =
    "/Script/Engine.Default__GameplayStatics"
local GET_GAME_STATE_PATH =
    "/Script/Engine.GameplayStatics:GetGameState"
local GET_CHARACTER_ORE_PATH =
    "/Script/G1R.TraderManager:GetCharacterOre"
local REMOVE_CHARACTER_ORE_PATH =
    "/Script/G1R.TraderManager:RemoveCharacterOre"
local FREEPOINT_QUICK_END_PATH =
    "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndQuick"

local core = require("cancel_core")
local pleasureLib = require("pleasure_lib_loader").new(MOD_NAME)
if type(pleasureLib) ~= "table" then return end
local ue_helpers = nil
pcall(function()
    local candidate = require("UEHelpers")
    if type(candidate) == "table" then ue_helpers = candidate end
end)

local config = core.config_from_ini({})
local config_path = nil
local active_interaction = nil
local recent_cancelled_interaction = nil
local active_conversation = nil
local pending_interaction_cancel = nil
local pending_conversation_cancel = nil
local finished_freepoint_task_objects = setmetatable({}, { __mode = "k" })
local finished_freepoint_task_identities = {}
local scheduled_freepoint_task_objects = setmetatable({}, { __mode = "k" })
local unresolved_freepoint_task_objects = {}
local unresolved_freepoint_task_count = 0
local shown_conversation_objects = setmetatable({}, { __mode = "k" })
local shown_conversation_identities = {}
local key_bind_callbacks = {}
local registered_cancel_keys = {}
local registered_key_count = 0
local native_setting_handles = {}
local pending_game_thread_callbacks = {}
local pending_game_thread_callback_id = 0
local runtime_generation = 0
local conversation_generation = 0
local map_lifecycle_callback = nil
local cached_trader_manager = nil
local active_mining_ore_rollback = nil
local mining_ore_rollback_serial = 0
local active_mining_reward_hud_suppression = nil
local mining_reward_hud_suppression_serial = 0
local k2_cancel_ability = nil
local k2_has_authority = nil
local get_avatar_actor = nil
local get_character_inventory = nil
local gameplay_statics_cdo = nil
local get_game_state = nil
local get_character_ore = nil
local remove_character_ore = nil
local freepoint_quick_end = nil
local freepoint_lifecycle_ready = false
local set_move_hook = false
local move_ended_hook = false
local freepoint_factory_hook = false
local freepoint_alignment_hook = false
local freepoint_ended_hook = false
local freepoint_notification = false
local conversation_ui_hook = false
local conversation_notification = false
local mining_reward_hud_hook = false
local map_lifecycle_hook = false

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

local function set_hook_param(param, value)
    if param == nil or value == nil then return false end
    return pleasureLib:safe("set hook parameter", function()
        if type(param.set) == "function" then
            param:set(value)
            return true
        end
        if type(param.Set) == "function" then
            param:Set(value)
            return true
        end
        return false
    end) == true
end

local function resolve_trader_manager(world_context)
    if is_valid(cached_trader_manager) then
        return cached_trader_manager
    end

    local game_state = nil
    if is_valid(gameplay_statics_cdo) and is_valid(get_game_state)
        and is_valid(world_context)
    then
        local ok, value = pcall(function()
            return unwrap(get_game_state(
                gameplay_statics_cdo, world_context))
        end)
        if ok then game_state = value end
    end
    if type(ue_helpers) == "table"
        and type(ue_helpers.GetGameStateBase) == "function"
        and not is_valid(game_state)
    then
        local ok, value = pcall(ue_helpers.GetGameStateBase)
        if ok then game_state = unwrap(value) end
    end
    if not is_valid(game_state) then return nil end

    local manager = read_property(game_state, "m_TraderManager")
    if not is_valid(manager) then return nil end
    cached_trader_manager = manager
    return manager
end

local function mining_ability_has_authority(ability)
    if not is_valid(ability) or not is_valid(k2_has_authority) then
        return false
    end
    local ok, value = pcall(function()
        return unwrap(k2_has_authority(ability))
    end)
    return ok and (value == true or value == 1)
end

local function resolve_mining_character(ability)
    if not is_valid(ability) or not is_valid(get_avatar_actor) then
        return nil
    end
    local ok, character = pcall(function()
        return unwrap(get_avatar_actor(ability))
    end)
    if not ok or not is_valid(character) then return nil end
    return character
end

local function resolve_mining_inventory(character)
    if not is_valid(character) or not is_valid(get_character_inventory) then
        return nil
    end
    local ok, inventory = pcall(function()
        return unwrap(get_character_inventory(character))
    end)
    if not ok or not is_valid(inventory) then return nil end
    return inventory
end

local function read_character_ore(manager, character)
    if not is_valid(manager) or not is_valid(character)
        or not is_valid(get_character_ore)
    then
        return nil
    end
    local ok, value = pcall(function()
        return unwrap(get_character_ore(manager, character))
    end)
    value = ok and tonumber(value) or nil
    if value == nil or value ~= value
        or value == math.huge or value == -math.huge
    then
        return nil
    end
    return value
end

local function request_character_ore_removal(manager, character, amount)
    if not is_valid(manager) or not is_valid(character)
        or not is_valid(remove_character_ore)
        or type(amount) ~= "number" or amount <= 0
    then
        return false, "ore rollback context unavailable"
    end
    local ok, err = pcall(function()
        remove_character_ore(manager, character, amount)
    end)
    if not ok then
        return false, pleasureLib:safe_to_string(err)
    end
    return true
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

local function is_tracked_blocking_mining(record)
    return record ~= nil
        and record.kind == "blocking"
        and record.mining == true
        and record.cancel_allowed == true
        and core.is_mining_identity(record.identity)
        and is_valid(record.object)
end

local function capture_mining_inventory(record)
    if record == nil or not is_valid(record.mining_character) then
        return false
    end
    if is_valid(record.mining_inventory)
        and core.identities_match(
            record.mining_inventory_identity,
            full_name(record.mining_inventory))
    then
        return true
    end

    local inventory = resolve_mining_inventory(record.mining_character)
    if not is_valid(inventory) then
        debug_log("Mining reward HUD inventory unavailable: ability="
            .. tostring(record.identity)
            .. " character="
            .. tostring(record.mining_character_identity))
        return false
    end
    record.mining_inventory = inventory
    record.mining_inventory_identity = full_name(inventory)
    return true
end

local function capture_mining_ore_baseline(record)
    if type(record.mining_ore_before) == "number"
        and is_valid(record.mining_character)
        and is_valid(record.mining_trader_manager)
        and record.mining_has_authority == true
        and core.identities_match(
            record.mining_character_identity,
            full_name(record.mining_character))
        and core.identities_match(
            record.mining_trader_manager_identity,
            full_name(record.mining_trader_manager))
    then
        capture_mining_inventory(record)
        return true
    end
    if not is_tracked_blocking_mining(record) then return false end

    if not mining_ability_has_authority(record.object) then
        debug_log("Mining ore baseline skipped without authority: ability="
            .. tostring(record.identity))
        return false
    end

    local character = resolve_mining_character(record.object)
    local manager = resolve_trader_manager(character)
    local ore_before = read_character_ore(manager, character)
    if ore_before == nil then
        debug_log("Mining ore baseline unavailable: ability="
            .. tostring(record.identity)
            .. " character=" .. tostring(full_name(character))
            .. " traderManager=" .. tostring(full_name(manager)))
        return false
    end

    record.mining_character = character
    record.mining_character_identity = full_name(character)
    record.mining_trader_manager = manager
    record.mining_trader_manager_identity = full_name(manager)
    record.mining_ore_before = ore_before
    record.mining_has_authority = true
    record.mining_ore_remove_pending = 0
    record.mining_ore_last_observed = ore_before
    capture_mining_inventory(record)
    debug_log("Mining ore baseline captured: ability="
        .. tostring(record.identity)
        .. " character=" .. tostring(record.mining_character_identity)
        .. " ore=" .. tostring(ore_before))
    return true
end

local function clear_mining_reward_hud_suppression(reason, expected_record)
    local suppression = active_mining_reward_hud_suppression
    if suppression == nil
        or (expected_record ~= nil
            and suppression.record ~= expected_record)
    then
        return
    end
    active_mining_reward_hud_suppression = nil
    debug_log("Mining reward HUD suppression closed: "
        .. tostring(reason)
        .. " ability=" .. tostring(suppression.ability_identity))
end

local function arm_mining_reward_hud_suppression(record, reason)
    if record == nil
        or record.mining_reward_hud_suppressed == true
        or config.keep_ore_on_mining_cancellation == true
        or mining_reward_hud_hook ~= true
        or record.mining_has_authority ~= true
        or not is_valid(remove_character_ore)
        or not capture_mining_inventory(record)
    then
        return false
    end

    local current = active_mining_reward_hud_suppression
    if current ~= nil and current.record == record
        and current.generation == runtime_generation
    then
        return true
    end

    clear_mining_reward_hud_suppression("replaced")
    mining_reward_hud_suppression_serial =
        mining_reward_hud_suppression_serial + 1
    local suppression = {
        record = record,
        ability_identity = record.identity,
        inventory = record.mining_inventory,
        inventory_identity = record.mining_inventory_identity,
        generation = runtime_generation,
        token = mining_reward_hud_suppression_serial,
    }
    active_mining_reward_hud_suppression = suppression

    local ok, scheduled = pcall(function()
        return pleasureLib:delay_game_thread(
            MINING_REWARD_HUD_SUPPRESSION_MS, function()
                if active_mining_reward_hud_suppression == suppression
                    and suppression.generation == runtime_generation
                    and suppression.token
                        == mining_reward_hud_suppression_serial
                then
                    clear_mining_reward_hud_suppression("expired")
                end
            end)
    end)
    if not ok or scheduled ~= true then
        active_mining_reward_hud_suppression = nil
        log("Could not schedule mining reward HUD suppression expiry")
        return false
    end

    debug_log("Mining reward HUD suppression armed: "
        .. tostring(reason)
        .. " ability=" .. tostring(record.identity)
        .. " inventory=" .. tostring(record.mining_inventory_identity))
    return true
end

local function on_item_added_for_hud(context, item, count)
    local suppression = active_mining_reward_hud_suppression
    if suppression == nil then return end
    if suppression.generation ~= runtime_generation
        or config.keep_ore_on_mining_cancellation == true
    then
        clear_mining_reward_hud_suppression("runtime changed")
        return
    end

    local inventory = unwrap(context)
    if not is_valid(inventory)
        or not (inventory == suppression.inventory
            or core.identities_match(
                full_name(inventory), suppression.inventory_identity))
    then
        return
    end

    local item_identity = full_name(unwrap(item))
    local amount = tonumber(unwrap(count))
    if not core.is_mining_ore_item_identity(item_identity)
        or amount == nil or amount <= 0
    then
        return
    end

    local suppressed = set_hook_param(count, 0)
    if suppressed then
        suppression.record.mining_reward_hud_suppressed = true
        debug_log("Suppressed cancelled mining reward HUD notification: "
            .. "amount=" .. tostring(amount)
            .. " item=" .. tostring(item_identity)
            .. " ability=" .. tostring(suppression.ability_identity))
    else
        log("Could not suppress cancelled mining reward HUD notification")
    end
    clear_mining_reward_hud_suppression(
        suppressed and "notification consumed" or "parameter unavailable")
end

local function apply_mining_ore_rollback(record, source)
    if record == nil or type(record.mining_ore_before) ~= "number"
        or not is_valid(record.mining_character)
        or not is_valid(record.mining_trader_manager)
        or record.mining_has_authority ~= true
        or not core.identities_match(
            record.mining_character_identity,
            full_name(record.mining_character))
        or not core.identities_match(
            record.mining_trader_manager_identity,
            full_name(record.mining_trader_manager))
    then
        return false
    end

    local current = read_character_ore(
        record.mining_trader_manager, record.mining_character)
    if current == nil then
        debug_log("Mining ore rollback read failed: source="
            .. tostring(source)
            .. " ability=" .. tostring(record.identity))
        return false
    end

    local baseline = record.mining_ore_before
    local pending = tonumber(record.mining_ore_remove_pending) or 0
    local previous = tonumber(record.mining_ore_last_observed)
    if previous ~= nil and current < previous and pending > 0 then
        pending = math.max(0, pending - (previous - current))
    end
    if current <= baseline + ORE_COMPARISON_EPSILON then
        record.mining_ore_remove_pending = 0
        record.mining_ore_last_observed = current
        return true
    end

    local rewarded_delta =
        math.floor((current - baseline) + ORE_COMPARISON_EPSILON)
    local amount = math.floor(math.max(0, rewarded_delta - pending))
    record.mining_ore_last_observed = current
    if amount <= 0 then
        record.mining_ore_remove_pending = pending
        return true
    end

    local removed, err = request_character_ore_removal(
        record.mining_trader_manager, record.mining_character, amount)
    if not removed then
        log("Could not roll back mining ore: "
            .. pleasureLib:safe_to_string(err)
            .. (record.mining_reward_hud_suppressed == true
                and "; its reward notification was already suppressed"
                or ""))
        return false
    end
    record.mining_ore_remove_pending = pending + amount
    debug_log("Requested mining ore rollback: source="
        .. tostring(source)
        .. " baseline=" .. tostring(baseline)
        .. " current=" .. tostring(current)
        .. " amount=" .. tostring(amount)
        .. " ability=" .. tostring(record.identity))
    return true
end

local function schedule_mining_ore_rollback(record)
    if not capture_mining_ore_baseline(record) then
        log("Mining was cancelled, but its ore baseline was unavailable; "
            .. "the reward could not be rolled back")
        return false
    end

    mining_ore_rollback_serial = mining_ore_rollback_serial + 1
    record.mining_ore_rollback_token = mining_ore_rollback_serial
    active_mining_ore_rollback = record
    apply_mining_ore_rollback(record, "immediate")
    local callback_generation = runtime_generation
    local callback_token = record.mining_ore_rollback_token
    local all_scheduled = true
    for index, delay_ms in ipairs(MINING_ORE_ROLLBACK_DELAYS_MS) do
        local final_check =
            index == #MINING_ORE_ROLLBACK_DELAYS_MS
        local callback_delay = delay_ms
        local callback_is_final = final_check
        local ok, scheduled = pcall(function()
            return pleasureLib:delay_game_thread(callback_delay, function()
                if callback_generation ~= runtime_generation
                    or active_mining_ore_rollback ~= record
                    or record.mining_ore_rollback_token ~= callback_token
                then
                    return
                end
                apply_mining_ore_rollback(
                    record, tostring(callback_delay) .. "ms")
                if callback_is_final
                    and active_mining_ore_rollback == record
                then
                    local final_ore = read_character_ore(
                        record.mining_trader_manager,
                        record.mining_character)
                    if type(final_ore) == "number"
                        and final_ore > record.mining_ore_before
                            + ORE_COMPARISON_EPSILON
                    then
                        log("Mining ore rollback did not reach its "
                            .. "baseline; remaining delta="
                            .. tostring(
                                final_ore - record.mining_ore_before)
                            .. (record.mining_reward_hud_suppressed == true
                                and "; its reward notification was already "
                                    .. "suppressed"
                                or ""))
                    elseif type(final_ore) ~= "number"
                        and record.mining_reward_hud_suppressed == true
                    then
                        log("Mining ore rollback could not be verified after "
                            .. "its reward notification was suppressed")
                    end
                    active_mining_ore_rollback = nil
                end
            end)
        end)
        if not ok or scheduled ~= true then
            all_scheduled = false
        end
    end
    if not all_scheduled then
        log("Could not schedule every mining ore rollback check")
    end
    return true
end

local function clear_active_mining_ore_rollback(reason)
    if active_mining_ore_rollback == nil then return end
    active_mining_ore_rollback = nil
    debug_log("Mining ore rollback window closed: " .. tostring(reason))
end

local function refresh_blocking_move_task(record)
    if record == nil or record.kind ~= "blocking"
        or not is_valid(record.object)
    then
        return nil, ""
    end

    local task = read_property(record.object, "m_TaskMoveTo")
    if not is_valid(task) then task = record.move_task end
    local identity = full_name(task)
    if is_valid(task) then
        record.move_task = task
        record.move_task_identity = identity
    end
    return task, identity
end

local function mining_record_matches_task(record, task)
    if not is_tracked_blocking_mining(record) or not is_valid(task) then
        return false
    end

    local move_task, move_task_identity =
        refresh_blocking_move_task(record)
    local task_identity = full_name(task)
    return move_task == task
        or core.identities_match(move_task_identity, task_identity)
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
    local candidate_paths = config_candidate_paths()
    for _, path in ipairs(candidate_paths) do
        local content = pleasureLib:read_text_file(path)
        if content ~= nil then
            config_path = path
            config = core.config_from_ini(pleasureLib:parse_ini(content))
            pleasureLib:set_debug(config.debug)
            log("Loaded config from " .. tostring(path)
                .. ": Debug=" .. tostring(config.debug)
                .. " EnableBenchAndLadderCancellation="
                .. tostring(config.enable_bench_and_ladder_cancellation)
                .. " EnableConversationCancellation="
                .. tostring(config.enable_conversation_cancellation)
                .. " EnableWASDCancellation="
                .. tostring(config.enable_wasd_cancellation)
                .. " KeepOreOnMiningCancellation="
                .. tostring(config.keep_ore_on_mining_cancellation)
                .. " CancelKeys=" .. table.concat(config.cancel_keys, ","))
            return
        end
    end
    config_path = candidate_paths[1]
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
        clear_mining_reward_hud_suppression(
            reason, active_interaction)
        debug_log("Interaction window closed: " .. tostring(reason)
            .. " object=" .. tostring(active_interaction.identity))
        invalidate_record(active_interaction)
    end
    active_interaction = nil
end

local function clear_recent_interaction(reason)
    if recent_cancelled_interaction ~= nil then
        clear_mining_reward_hud_suppression(
            reason, recent_cancelled_interaction)
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
    cached_trader_manager = nil
    clear_active_mining_ore_rollback(reason)
    clear_mining_reward_hud_suppression(reason)
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
    unresolved_freepoint_task_objects = {}
    unresolved_freepoint_task_count = 0
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
        if cancelled and config.enable_wasd_cancellation == true
            and active_interaction.cancel_allowed == true
        then
            retain_cancelled_interaction_edge(active_interaction)
        else
            clear_interaction(reason)
        end
    elseif matches_recent and not cancelled then
        clear_recent_interaction(reason)
    end

    if matches_pending then
        local preserve_directional_cancel = cancelled
            and config.enable_wasd_cancellation == true
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
        clear_active_mining_ore_rollback("new blocking interaction")
        clear_mining_reward_hud_suppression("new blocking interaction")
        if pending_interaction_cancel ~= nil then
            invalidate_record(pending_interaction_cancel)
            pending_interaction_cancel = nil
        end
        clear_recent_interaction("new move-to task")
        clear_interaction("replaced by new move-to task")
        local move_task = read_property(ability, "m_TaskMoveTo")
        active_interaction = {
            kind = "blocking",
            object = ability,
            identity = identity,
            move_task = move_task,
            move_task_identity = full_name(move_task),
            mining = classification.mining == true,
            cancel_allowed = true,
            directional_cancel_requested = false,
            move_cancelled = false,
        }
        if classification.mining == true then
            capture_mining_ore_baseline(active_interaction)
            debug_log("Mining interaction window opened: ability="
                .. tostring(identity)
                .. " moveTask="
                .. tostring(active_interaction.move_task_identity))
        else
            debug_log("Interaction window opened: " .. identity)
        end
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

local function on_move_to_task_ended(context, move_to_task_value, result)
    local ability = unwrap(context)
    local identity = full_name(ability)
    local move_to_task = unwrap(move_to_task_value)
    local unwrapped_result = unwrap(result)
    local cancelled = core.generic_task_result_is_cancelled(unwrapped_result)
    local matches_active = active_interaction ~= nil
        and active_interaction.kind == "blocking"
        and tracked_object_matches(active_interaction, ability, identity)
    local matches_recent = recent_cancelled_interaction ~= nil
        and recent_cancelled_interaction.kind == "blocking"
        and tracked_object_matches(
            recent_cancelled_interaction, ability, identity)
    local matches_pending = pending_interaction_cancel ~= nil
        and pending_interaction_cancel.kind == "blocking"
        and tracked_object_matches(
            pending_interaction_cancel, ability, identity)
    if core.is_mining_identity(identity) then
        debug_log("Mining move-to task ended: ability="
            .. tostring(identity)
            .. " task=" .. tostring(full_name(move_to_task))
            .. " result=" .. tostring(unwrapped_result)
            .. " cancelled=" .. tostring(cancelled)
            .. " abilityEnded="
            .. tostring(read_property(ability, "m_AbilityEnded")))
    end
    if cancelled and matches_active
        and active_interaction.mining == true
        and active_interaction.cancel_allowed == true
        and config.enable_wasd_cancellation == true
        and config.keep_ore_on_mining_cancellation ~= true
    then
        arm_mining_reward_hud_suppression(
            active_interaction, "cancelled movement edge")
    end
    handle_interaction_end(cancelled, matches_active, matches_recent,
        matches_pending, "move-to task ended")
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

local function mark_freepoint_task_unresolved(task)
    if task == nil or unresolved_freepoint_task_objects[task] == true then
        return
    end
    unresolved_freepoint_task_objects[task] = true
    unresolved_freepoint_task_count = unresolved_freepoint_task_count + 1
end

local function clear_freepoint_task_unresolved(task)
    if task == nil or unresolved_freepoint_task_objects[task] ~= true then
        return
    end
    unresolved_freepoint_task_objects[task] = nil
    unresolved_freepoint_task_count =
        math.max(0, unresolved_freepoint_task_count - 1)
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
        local has_mining_record =
            is_tracked_blocking_mining(active_interaction)
            or is_tracked_blocking_mining(
                recent_cancelled_interaction)
            or is_tracked_blocking_mining(
                pending_interaction_cancel)
        if has_mining_record then
            debug_log("Kept blocking Mining interaction; FreePoint "
                .. "mining remains excluded: "
                .. tostring(actor_identity)
                .. " task=" .. tostring(task_identity))
            return "mining-blocking"
        end
        exclude_mining_interaction(
            "FreePoint mining has no blocking Mining record")
        return "mining-blocking-untracked"
    end

    local cancellation_enabled =
        config.enable_bench_and_ladder_cancellation == true
    local cancel_allowed = cancellation_enabled
        and freepoint_lifecycle_ready
        and is_valid(freepoint_quick_end)

    if tracked_task_matches(active_interaction, task, task_identity)
        or tracked_task_matches(recent_cancelled_interaction,
            task, task_identity)
        or tracked_task_matches(pending_interaction_cancel,
            task, task_identity)
    then
        return "duplicate"
    end
    if pending_interaction_cancel ~= nil then
        if cancel_allowed then
            debug_log("Ignored FreePoint task while cancel is pending: "
                .. tostring(task_identity))
            return "pending"
        end
        invalidate_record(pending_interaction_cancel)
        pending_interaction_cancel = nil
    end

    local root_task = read_property(ability, "RootInteractionTask")
    clear_active_mining_ore_rollback("new FreePoint interaction")
    clear_mining_reward_hud_suppression("new FreePoint interaction")
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
        cancel_allowed = cancel_allowed,
        directional_cancel_requested = false,
        move_cancelled = false,
    }
    debug_log("FreePoint interaction window opened: cancellation="
        .. tostring(cancel_allowed)
        .. " source="
        .. tostring(source)
        .. " ability=" .. tostring(ability_identity)
        .. " task=" .. tostring(task_identity)
        .. " target=" .. tostring(actor_identity))
    return cancel_allowed and "tracked" or "disabled"
end

local function suppress_unclassified_freepoint_fallback(task, reason)
    local preserved_mining = false
    if pending_interaction_cancel ~= nil
        and pending_interaction_cancel.kind == "blocking"
    then
        if is_tracked_blocking_mining(pending_interaction_cancel) then
            preserved_mining = true
            debug_log("Kept pending Mining interaction across unresolved "
                .. "FreePoint task: task=" .. tostring(full_name(task))
                .. " exactMoveTask="
                .. tostring(mining_record_matches_task(
                    pending_interaction_cancel, task)))
        else
            invalidate_record(pending_interaction_cancel)
            pending_interaction_cancel = nil
        end
    end
    if recent_cancelled_interaction ~= nil
        and recent_cancelled_interaction.kind == "blocking"
    then
        if is_tracked_blocking_mining(recent_cancelled_interaction) then
            preserved_mining = true
            debug_log("Kept recent Mining interaction across unresolved "
                .. "FreePoint task: task=" .. tostring(full_name(task))
                .. " exactMoveTask="
                .. tostring(mining_record_matches_task(
                    recent_cancelled_interaction, task)))
        else
            clear_recent_interaction(reason)
        end
    end
    if active_interaction ~= nil
        and active_interaction.kind == "blocking"
    then
        if is_tracked_blocking_mining(active_interaction) then
            preserved_mining = true
            debug_log("Kept active Mining interaction across unresolved "
                .. "FreePoint task: task=" .. tostring(full_name(task))
                .. " exactMoveTask="
                .. tostring(mining_record_matches_task(
                    active_interaction, task)))
        else
            clear_interaction(reason)
        end
    end
    return preserved_mining
end

local schedule_freepoint_task_check
schedule_freepoint_task_check = function(task, source, delay_ms, final_attempt)
    if not is_valid(task)
        or scheduled_freepoint_task_objects[task] == true
    then
        return false
    end

    scheduled_freepoint_task_objects[task] = true
    mark_freepoint_task_unresolved(task)
    local callback_generation = runtime_generation
    local schedule_ok, scheduled = pcall(function()
        return pleasureLib:delay_game_thread(
            delay_ms, function()
                scheduled_freepoint_task_objects[task] = nil
                if callback_generation ~= runtime_generation
                    or not is_valid(task)
                then
                    clear_freepoint_task_unresolved(task)
                    return
                end
                local status = try_track_freepoint_task(task,
                    tostring(source) .. "+delayed")
                if status == "not-ready" and not final_attempt then
                    schedule_freepoint_task_check(task, source,
                        FREEPOINT_INIT_TIMEOUT_MS, true)
                else
                    if status == "not-ready" then
                        local mining_preserved =
                            suppress_unclassified_freepoint_fallback(
                                task,
                                "FreePoint initialization timed out")
                        if mining_preserved then
                            debug_log("FreePoint task owner remained "
                                .. "unavailable; verified Mining blocking "
                                .. "fallback was kept")
                        else
                            log("FreePoint task owner remained unavailable; "
                                .. "blocking fallback was closed")
                        end
                    end
                    clear_freepoint_task_unresolved(task)
                end
            end)
    end)
    if not schedule_ok or scheduled ~= true then
        scheduled_freepoint_task_objects[task] = nil
        local mining_preserved =
            suppress_unclassified_freepoint_fallback(task,
                "FreePoint initialization scheduler unavailable")
        clear_freepoint_task_unresolved(task)
        log("Could not schedule FreePoint task initialization: "
            .. pleasureLib:safe_to_string(
                schedule_ok and "scheduler unavailable" or scheduled)
            .. (mining_preserved
                and "; verified Mining blocking fallback was kept"
                or "; blocking fallback was closed"))
        return false
    end
    return true
end

local function schedule_freepoint_task_initialization(task, source)
    schedule_freepoint_task_check(
        task, source, FREEPOINT_INIT_DELAY_MS, false)
end

local function observe_freepoint_task(task, source)
    task = unwrap(task)
    if not is_valid(task) then return end
    local status = try_track_freepoint_task(task, source)
    if status == "not-ready" then
        schedule_freepoint_task_initialization(task, source)
    else
        clear_freepoint_task_unresolved(task)
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
    clear_freepoint_task_unresolved(task)
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
    if config.enable_conversation_cancellation ~= true then return end

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
    if config.enable_conversation_cancellation ~= true then return end

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
    if unresolved_freepoint_task_count > 0
        and not is_tracked_blocking_mining(interaction)
    then
        debug_log("Skipped interaction cancel while a FreePoint task is "
            .. "still initializing")
        return false
    end
    local roll_back_mining_ore = interaction.mining == true
        and config.keep_ore_on_mining_cancellation ~= true
    if roll_back_mining_ore then
        local current_identity = full_name(interaction.object)
        if not is_tracked_blocking_mining(interaction)
            or not core.is_mining_identity(current_identity)
            or not core.is_player_identity(current_identity)
        then
            return false
        end
        capture_mining_ore_baseline(interaction)
    end

    if interaction.mining == true
        and interaction.move_cancelled == true
    then
        if roll_back_mining_ore then
            arm_mining_reward_hud_suppression(
                interaction, "cancelled movement handled")
            local rollback_scheduled =
                schedule_mining_ore_rollback(interaction)
            if not rollback_scheduled then
                clear_mining_reward_hud_suppression(
                    "ore rollback unavailable", interaction)
            end
            debug_log("Mining movement had already cancelled before the "
                .. "key callback; ore rollback scheduled="
                .. tostring(rollback_scheduled)
                .. " ability=" .. tostring(interaction.identity))
            return rollback_scheduled
        end
        debug_log("Mining movement had already cancelled before the key "
            .. "callback; retained its ore reward: "
            .. tostring(interaction.identity))
        return true
    end

    local ability_ended =
        read_property(interaction.object, "m_AbilityEnded") == true
    if ability_ended then
        if not roll_back_mining_ore then return false end
        arm_mining_reward_hud_suppression(
            interaction, "ended ability handled")
        local rollback_scheduled =
            schedule_mining_ore_rollback(interaction)
        if not rollback_scheduled then
            clear_mining_reward_hud_suppression(
                "ore rollback unavailable", interaction)
        end
        debug_log("Mining ability had already ended before the key callback; "
            .. "ore rollback scheduled="
            .. tostring(rollback_scheduled)
            .. " ability="
            .. tostring(interaction.identity)
            .. " moveCancelled="
            .. tostring(interaction.move_cancelled == true))
        return rollback_scheduled
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

    if roll_back_mining_ore then
        arm_mining_reward_hud_suppression(
            interaction, "K2 cancellation")
    end
    local ok, err = pcall(function()
        k2_cancel_ability(interaction.object)
    end)
    if not ok then
        clear_mining_reward_hud_suppression(
            "K2 cancellation failed", interaction)
        log("K2_CancelAbility failed: "
            .. pleasureLib:safe_to_string(err))
        return false
    end

    if roll_back_mining_ore then
        local rollback_scheduled =
            schedule_mining_ore_rollback(interaction)
        if not rollback_scheduled then
            clear_mining_reward_hud_suppression(
                "ore rollback unavailable", interaction)
        end
        debug_log("Dispatched mining ability cancellation with ore "
            .. "rollback: " .. tostring(interaction.identity)
            .. " hudSuppression="
            .. tostring(
                interaction.mining_reward_hud_suppressed == true
                or (active_mining_reward_hud_suppression ~= nil
                    and active_mining_reward_hud_suppression.record
                        == interaction)))
    else
        debug_log("Cancelled interaction: " .. tostring(interaction.identity))
    end
    return true
end

local function cancel_freepoint_interaction(interaction)
    if config.enable_bench_and_ladder_cancellation ~= true
        or interaction == nil or interaction.cancel_allowed ~= true
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
    if config.enable_conversation_cancellation ~= true
        or conversation == nil or conversation.cancel_allowed ~= true
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
    if not core.config_allows_cancel_key(config, key_name) then
        return false
    end

    local directional = core.is_directional_cancel_key(key_name)
    local interaction = active_interaction
    local freepoint_initializing = unresolved_freepoint_task_count > 0
    if (freepoint_initializing
        and not is_tracked_blocking_mining(interaction))
        or (interaction ~= nil and interaction.cancel_allowed ~= true)
    then
        interaction = nil
    end
    if interaction == nil and active_interaction == nil and directional
    then
        local recent = recent_cancelled_interaction
        if not freepoint_initializing
            or is_tracked_blocking_mining(recent)
        then
            interaction = recent
        end
        if interaction ~= nil
            and interaction.cancel_allowed ~= true
        then
            interaction = nil
        end
    end
    local conversation = nil
    if config.enable_conversation_cancellation == true then
        conversation = active_conversation
    end
    if interaction == nil and conversation == nil then
        return false
    end

    if interaction ~= nil then
        if is_tracked_blocking_mining(interaction) then
            debug_log("Mining cancel requested: key="
                .. tostring(key_name)
                .. " keepOre="
                .. tostring(config.keep_ore_on_mining_cancellation)
                .. " moveCancelled="
                .. tostring(interaction.move_cancelled == true)
                .. " unresolvedFreePointTasks="
                .. tostring(unresolved_freepoint_task_count)
                .. " ability=" .. tostring(interaction.identity))
        end
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
        if interaction ~= nil and not cancelled_interaction then
            clear_mining_reward_hud_suppression(
                "cancel request was not handled", interaction)
        end
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
        clear_mining_reward_hud_suppression(
            "cancel request was not scheduled", interaction)
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
            if registered_cancel_keys[candidate] == true then
                return true, candidate, false
            end
            local callback = function()
                request_cancel(candidate)
            end
            local ok, err = pcall(function()
                RegisterKeyBind(key_value, callback)
            end)
            if ok then
                table.insert(key_bind_callbacks, callback)
                registered_cancel_keys[candidate] = true
                registered_key_count = registered_key_count + 1
                return true, candidate, true
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

local function refresh_freepoint_lifecycle_ready()
    if config.enable_bench_and_ladder_cancellation == true
        and not is_valid(freepoint_quick_end)
    then
        freepoint_quick_end =
            pleasureLib:find_object(FREEPOINT_QUICK_END_PATH)
    end
    freepoint_lifecycle_ready =
        config.enable_bench_and_ladder_cancellation == true
        and is_valid(freepoint_quick_end)
        and (freepoint_factory_hook or freepoint_notification)
        and freepoint_alignment_hook
        and freepoint_ended_hook
    return freepoint_lifecycle_ready
end

local function ensure_conversation_lifecycle()
    if not conversation_ui_hook then
        conversation_ui_hook = pleasureLib:register_hook(
            CONVERSATION_UI_HOOK, on_conversation_ui_shown)
        if not conversation_ui_hook then
            log("Conversation UI hook unavailable; conversation cancel is "
                .. "disabled")
            return false
        end
    end

    if not conversation_notification then
        conversation_notification = install_conversation_notification()
    end
    return not not (conversation_ui_hook and conversation_notification)
end

local function ensure_cancel_key_bindings()
    for _, key_name in ipairs(config.cancel_keys) do
        if core.config_allows_cancel_key(config, key_name) then
            local ok, result, added = register_cancel_key(key_name)
            if ok then
                if added then
                    debug_log("Registered cancel key " .. tostring(result))
                end
            else
                log("Could not register cancel key " .. tostring(key_name)
                    .. ": " .. pleasureLib:safe_to_string(result))
            end
        else
            debug_log("Skipped disabled WASD cancel key "
                .. tostring(key_name))
        end
    end
    return registered_key_count
end

local function set_bench_and_ladder_cancellation(value)
    local enabled = value == true
    if config.enable_bench_and_ladder_cancellation == enabled then
        refresh_freepoint_lifecycle_ready()
        return true
    end

    config.enable_bench_and_ladder_cancellation = enabled
    if not enabled then freepoint_quick_end = nil end
    reset_runtime_context("bench and ladder setting changed")
    refresh_freepoint_lifecycle_ready()
    if enabled and freepoint_lifecycle_ready ~= true then
        log("Bench and ladder cancellation was enabled, but its FreePoint "
            .. "lifecycle is unavailable")
    end
    log("Native setting EnableBenchAndLadderCancellation="
        .. tostring(enabled))
    return true
end

local function set_conversation_cancellation(value)
    local enabled = value == true
    if config.enable_conversation_cancellation == enabled then
        if enabled then ensure_conversation_lifecycle() end
        return true
    end

    config.enable_conversation_cancellation = enabled
    reset_runtime_context("conversation setting changed")
    if enabled then ensure_conversation_lifecycle() end
    log("Native setting EnableConversationCancellation="
        .. tostring(enabled))
    return true
end

local function set_wasd_cancellation(value)
    local enabled = value == true
    if config.enable_wasd_cancellation == enabled then
        if enabled then ensure_cancel_key_bindings() end
        return true
    end

    config.enable_wasd_cancellation = enabled
    reset_runtime_context("WASD setting changed")
    if enabled then ensure_cancel_key_bindings() end
    log("Native setting EnableWASDCancellation=" .. tostring(enabled))
    return true
end

local function set_keep_ore_on_mining_cancellation(value)
    local enabled = value == true
    if config.keep_ore_on_mining_cancellation == enabled then
        return true
    end

    config.keep_ore_on_mining_cancellation = enabled
    if enabled then
        clear_active_mining_ore_rollback(
            "ore retention setting enabled")
        clear_mining_reward_hud_suppression(
            "ore retention setting enabled")
    end
    log("Native setting KeepOreOnMiningCancellation=" .. tostring(enabled))
    return true
end

local function native_setting_persistence(key)
    return {
        path = function()
            return config_path
        end,
        key = key,
    }
end

local function register_native_settings()
    if type(pleasureLib.register_game_bool_setting) ~= "function" then
        log("PleasureLib 0.5.1 native settings API unavailable")
        return 0
    end

    local definitions = {
        {
            id = MOD_NAME .. ".EnableBenchAndLadderCancellation",
            section = "G1R Cancel Interaction",
            default = true,
            get = function()
                return config.enable_bench_and_ladder_cancellation == true
            end,
            set = set_bench_and_ladder_cancellation,
            persist = native_setting_persistence(
                "EnableBenchAndLadderCancellation"),
            translations = {
                en = {
                    name = "Cancel bench and ladder approaches",
                    description = "Allows configured cancel keys to stop an "
                        .. "accidental bench or ladder interaction before the "
                        .. "hero arrives.",
                },
                de = {
                    name = "Zulauf zu Bänken und Leitern abbrechen",
                    description = "Erlaubt den konfigurierten Abbruchtasten, "
                        .. "eine versehentlich gestartete Bank- oder "
                        .. "Leiteraktion vor der Ankunft zu beenden.",
                },
            },
        },
        {
            id = MOD_NAME .. ".EnableConversationCancellation",
            section = "G1R Cancel Interaction",
            default = true,
            get = function()
                return config.enable_conversation_cancellation == true
            end,
            set = set_conversation_cancellation,
            persist = native_setting_persistence(
                "EnableConversationCancellation"),
            translations = {
                en = {
                    name = "Cancel early conversations",
                    description = "Allows configured cancel keys to end a "
                        .. "player-started conversation before the dialogue "
                        .. "screen opens.",
                },
                de = {
                    name = "Frühe Gespräche abbrechen",
                    description = "Erlaubt den konfigurierten Abbruchtasten, "
                        .. "ein vom Spieler gestartetes Gespräch zu beenden, "
                        .. "bevor der Dialogbildschirm erscheint.",
                },
            },
        },
        {
            id = MOD_NAME .. ".EnableWASDCancellation",
            section = "G1R Cancel Interaction",
            default = true,
            get = function()
                return config.enable_wasd_cancellation == true
            end,
            set = set_wasd_cancellation,
            persist = native_setting_persistence("EnableWASDCancellation"),
            translations = {
                en = {
                    name = "Cancel with WASD",
                    description = "Allows A, W, S, and D to act as cancel "
                        .. "keys. Other configured cancel keys are unaffected.",
                },
                de = {
                    name = "Mit WASD abbrechen",
                    description = "Erlaubt A, W, S und D als Abbruchtasten. "
                        .. "Andere konfigurierte Abbruchtasten bleiben "
                        .. "unverändert.",
                },
            },
        },
        {
            id = MOD_NAME .. ".KeepOreOnMiningCancellation",
            section = "G1R Cancel Interaction",
            default = false,
            get = function()
                return config.keep_ore_on_mining_cancellation == true
            end,
            set = set_keep_ore_on_mining_cancellation,
            persist = native_setting_persistence(
                "KeepOreOnMiningCancellation"),
            translations = {
                en = {
                    name = "Keep ore when cancelling mining",
                    description = "You can always cancel mining. On: You "
                        .. "get the ore even when cancelling. Off: "
                        .. "Cancelling gives no ore and no ore notification. "
                        .. "Default: Off.",
                },
                de = {
                    name = "Erz bei Abbruch behalten",
                    description = "Du kannst den Erzabbau immer abbrechen. "
                        .. "An: Auch bei Abbruch bekommst du das Erz. Aus: "
                        .. "Bei Abbruch bekommst du kein Erz und keine "
                        .. "Erz-Meldung. Standard: Aus.",
                },
            },
        },
    }

    local registered = 0
    for _, definition in ipairs(definitions) do
        local ok, handle = pcall(function()
            return pleasureLib:register_game_bool_setting(definition)
        end)
        if ok and type(handle) == "table" then
            table.insert(native_setting_handles, handle)
            registered = registered + 1
        else
            log("Could not register native setting "
                .. tostring(definition.id) .. ": "
                .. pleasureLib:safe_to_string(
                    ok and "registration rejected" or handle))
        end
    end
    return registered
end

load_config()
k2_cancel_ability = pleasureLib:find_object(K2_CANCEL_ABILITY_PATH)
if not is_valid(k2_cancel_ability) then
    log("K2_CancelAbility was not found; blocking interaction cancel is "
        .. "disabled")
end
k2_has_authority = pleasureLib:find_object(K2_HAS_AUTHORITY_PATH)
get_avatar_actor = pleasureLib:find_object(GET_AVATAR_ACTOR_PATH)
get_character_inventory =
    pleasureLib:find_object(GET_CHARACTER_INVENTORY_PATH)
gameplay_statics_cdo = pleasureLib:find_object(GAMEPLAY_STATICS_CDO_PATH)
get_game_state = pleasureLib:find_object(GET_GAME_STATE_PATH)
get_character_ore = pleasureLib:find_object(GET_CHARACTER_ORE_PATH)
remove_character_ore = pleasureLib:find_object(REMOVE_CHARACTER_ORE_PATH)
local mining_ore_rollback_functions_ready =
    is_valid(k2_has_authority)
    and is_valid(get_avatar_actor)
    and is_valid(gameplay_statics_cdo)
    and is_valid(get_game_state)
    and is_valid(get_character_ore)
    and is_valid(remove_character_ore)
if not mining_ore_rollback_functions_ready then
    log("Mining ore rollback functions were not found; mining can still be "
        .. "cancelled, but the ore reward cannot be removed")
end
if not is_valid(get_character_inventory) then
    log("GothicCharacter:GetInventory was not found; cancelled mining "
        .. "reward notifications cannot be suppressed")
end
if config.enable_bench_and_ladder_cancellation == true then
    freepoint_quick_end = pleasureLib:find_object(FREEPOINT_QUICK_END_PATH)
    if not is_valid(freepoint_quick_end) then
        log("OnRequestEndQuick was not found; bench and ladder cancel is "
            .. "disabled")
    end
end

set_move_hook = pleasureLib:register_hook(
    BLOCKING_INTERACTION_SET_MOVE_HOOK, on_set_move_to_task)
move_ended_hook = pleasureLib:register_hook(
    BLOCKING_INTERACTION_MOVE_ENDED_HOOK, on_move_to_task_ended)
mining_reward_hud_hook = pleasureLib:register_hook(
    ITEM_ADDED_FOR_HUD_HOOK, on_item_added_for_hud)
if mining_reward_hud_hook ~= true then
    log("OnItemAddedForHUD hook was not installed; cancelled mining "
        .. "reward notifications cannot be suppressed")
end
freepoint_factory_hook = pleasureLib:register_hook(
    FREEPOINT_MOVE_TASK_FACTORY_HOOK,
    function() return nil end,
    on_freepoint_factory_post)
freepoint_alignment_hook = pleasureLib:register_hook(
    FREEPOINT_ALIGNMENT_ENDED_HOOK, on_freepoint_alignment_ended)
freepoint_ended_hook = pleasureLib:register_hook(
    FREEPOINT_INTERACTION_ENDED_HOOK, on_freepoint_interaction_ended)
freepoint_notification = install_freepoint_task_notification()
if config.enable_conversation_cancellation == true then
    ensure_conversation_lifecycle()
end
map_lifecycle_hook = install_map_lifecycle_hook()
refresh_freepoint_lifecycle_ready()
ensure_cancel_key_bindings()
local registered_native_settings = register_native_settings()

log("Loaded v" .. VERSION
    .. " interactionHooks=" .. tostring(set_move_hook and move_ended_hook)
    .. " benchAndLadderEnabled="
    .. tostring(config.enable_bench_and_ladder_cancellation)
    .. " benchAndLadderReady=" .. tostring(freepoint_lifecycle_ready)
    .. " conversationEnabled="
    .. tostring(config.enable_conversation_cancellation)
    .. " conversationReady="
    .. tostring(conversation_ui_hook and conversation_notification)
    .. " wasdEnabled=" .. tostring(config.enable_wasd_cancellation)
    .. " keepMiningOre="
    .. tostring(config.keep_ore_on_mining_cancellation)
    .. " miningOreRollbackReady="
    .. tostring(mining_ore_rollback_functions_ready)
    .. " miningRewardHudReady="
    .. tostring(mining_reward_hud_hook == true
        and is_valid(get_character_inventory))
    .. " mapLifecycle=" .. tostring(map_lifecycle_hook)
    .. " cancelKeys=" .. tostring(registered_key_count)
    .. " nativeSettings=" .. tostring(registered_native_settings))

return {
    request_cancel = request_cancel,
    reset_runtime_context = reset_runtime_context,
}
