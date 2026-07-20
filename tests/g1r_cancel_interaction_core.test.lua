package.path = "Scripts/?.lua;" .. package.path

local core = require("cancel_core")

local unpack_values = table.unpack or unpack
local tests = {}

local function test(name, callback)
    tests[#tests + 1] = {
        name = name,
        callback = callback,
    }
end

local function fail(message)
    error(message, 2)
end

local function assert_true(value, label)
    if value ~= true then
        fail((label or "value") .. " expected true, got " .. tostring(value))
    end
end

local function assert_false(value, label)
    if value ~= false then
        fail((label or "value") .. " expected false, got " .. tostring(value))
    end
end

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        fail(string.format("%s expected=%s actual=%s",
            label or "value", tostring(expected), tostring(actual)))
    end
end

local function assert_table_values(actual, expected, label)
    assert_equal(type(actual), "table", (label or "table") .. " type")
    assert_equal(#actual, #expected, (label or "table") .. " length")
    for index, expected_value in ipairs(expected) do
        assert_equal(actual[index], expected_value,
            string.format("%s[%d]", label or "table", index))
    end
end

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then
            return true
        end
    end
    return false
end

local DEFAULT_CANCEL_KEYS = {
    "F",
    "R",
    "ESCAPE",
    "A",
    "W",
    "S",
    "D",
    "RIGHT_MOUSE_BUTTON",
}

test("core exports the lean public policy API", function()
    for _, function_name in ipairs({
        "parse_cancel_keys",
        "config_from_ini",
        "cancel_key_lookup_candidates",
        "is_directional_cancel_key",
        "config_allows_cancel_key",
        "generic_task_result_is_cancelled",
        "is_freepoint_ability_identity",
        "is_move_to_interaction_task_identity",
        "classify_blocking_interaction",
        "is_player_identity",
        "is_mining_identity",
        "identities_match",
    }) do
        assert_equal(type(core[function_name]), "function",
            "core." .. function_name)
    end
end)

test("core uses the documented default keys and debug setting", function()
    assert_table_values(core.parse_cancel_keys(nil), DEFAULT_CANCEL_KEYS,
        "parse_cancel_keys defaults")

    local config = core.config_from_ini({})
    assert_false(config.debug, "default debug")
    assert_true(config.enable_bench_and_ladder_cancellation,
        "default bench and ladder cancellation")
    assert_true(config.enable_conversation_cancellation,
        "default conversation cancellation")
    assert_true(config.enable_wasd_cancellation,
        "default WASD cancellation")
    assert_false(config.keep_ore_on_mining_cancellation,
        "default mining ore retention")
    assert_table_values(config.cancel_keys, DEFAULT_CANCEL_KEYS,
        "config default keys")
end)

test("core parses native options with backward-compatible defaults",
    function()
        local disabled = core.config_from_ini({
            ENABLEBENCHANDLADDERCANCELLATION = "0",
            ENABLECONVERSATIONCANCELLATION = "off",
            ENABLEWASDCANCELLATION = "NO",
            KEEPOREONMININGCANCELLATION = "0",
        })
        assert_false(disabled.enable_bench_and_ladder_cancellation,
            "bench and ladder cancellation disabled")
        assert_false(disabled.enable_conversation_cancellation,
            "conversation cancellation disabled")
        assert_false(disabled.enable_wasd_cancellation,
            "WASD cancellation disabled")
        assert_false(disabled.keep_ore_on_mining_cancellation,
            "mining ore retention disabled")

        local enabled = core.config_from_ini({
            ENABLEBENCHANDLADDERCANCELLATION = "1",
            ENABLECONVERSATIONCANCELLATION = "yes",
            ENABLEWASDCANCELLATION = "ON",
            KEEPOREONMININGCANCELLATION = "true",
        })
        assert_true(enabled.enable_bench_and_ladder_cancellation,
            "bench and ladder cancellation enabled")
        assert_true(enabled.enable_conversation_cancellation,
            "conversation cancellation enabled")
        assert_true(enabled.enable_wasd_cancellation,
            "WASD cancellation enabled")
        assert_true(enabled.keep_ore_on_mining_cancellation,
            "mining ore retention enabled")

        local legacy_or_invalid = core.config_from_ini({
            ENABLEBENCHANDLADDERCANCELLATION = "invalid",
            ENABLECONVERSATIONCANCELLATION = "",
            KEEPOREONMININGCANCELLATION = "invalid",
        })
        assert_true(legacy_or_invalid.enable_bench_and_ladder_cancellation,
            "invalid bench and ladder setting uses default")
        assert_true(legacy_or_invalid.enable_conversation_cancellation,
            "empty conversation setting uses default")
        assert_true(legacy_or_invalid.enable_wasd_cancellation,
            "missing WASD setting uses default")
        assert_false(
            legacy_or_invalid.keep_ore_on_mining_cancellation,
            "invalid mining ore setting uses safe default")
    end)

test("core migrates the legacy mining option without overriding the new key",
    function()
        local legacy_enabled = core.config_from_ini({
            ENABLEMININGCANCELLATION = "true",
        })
        assert_true(legacy_enabled.keep_ore_on_mining_cancellation,
            "legacy true retains ore")

        local legacy_disabled = core.config_from_ini({
            ENABLEMININGCANCELLATION = "false",
        })
        assert_false(legacy_disabled.keep_ore_on_mining_cancellation,
            "legacy false does not retain ore")

        local new_key_wins = core.config_from_ini({
            KEEPOREONMININGCANCELLATION = "false",
            ENABLEMININGCANCELLATION = "true",
        })
        assert_false(new_key_wins.keep_ore_on_mining_cancellation,
            "new mining ore key takes precedence")
    end)

test("core normalizes configured cancel keys", function()
    local parsed = core.parse_cancel_keys(
        " r, F, escape, a, w, s, d, right_mouse_button ")
    assert_table_values(parsed, {
        "R",
        "F",
        "ESCAPE",
        "A",
        "W",
        "S",
        "D",
        "RIGHT_MOUSE_BUTTON",
    }, "configured keys")

    local config = core.config_from_ini({
        DEBUG = "true",
        CANCELKEYS = "R,F",
    })
    assert_true(config.debug, "configured debug")
    assert_table_values(config.cancel_keys, { "R", "F" },
        "configured config keys")
end)

test("core exposes usable lookup candidates", function()
    local f_candidates = core.cancel_key_lookup_candidates("f")
    assert_true(contains(f_candidates, "F"), "F lookup candidate")

    local mouse_candidates =
        core.cancel_key_lookup_candidates("right_mouse_button")
    assert_true(contains(mouse_candidates, "RIGHT_MOUSE_BUTTON"),
        "right mouse lookup candidate")
end)

test("core distinguishes directional keys and cancelled task results",
    function()
        for _, key_name in ipairs({ "A", "w", "S", "d" }) do
            assert_true(core.is_directional_cancel_key(key_name),
                key_name .. " is directional")
        end
        for _, key_name in ipairs({
            "F",
            "R",
            "ESCAPE",
            "RIGHT_MOUSE_BUTTON",
        }) do
            assert_false(core.is_directional_cancel_key(key_name),
                key_name .. " is not directional")
        end

        local wasd_disabled = {
            enable_wasd_cancellation = false,
        }
        assert_false(core.config_allows_cancel_key(wasd_disabled, "W"),
            "WASD setting overrides a configured movement key")
        assert_true(core.config_allows_cancel_key(wasd_disabled, "F"),
            "WASD setting leaves other keys enabled")
        assert_true(core.config_allows_cancel_key({}, "A"),
            "missing WASD setting preserves legacy behavior")

        for _, result in ipairs({
            1,
            "1",
            "Cancelled",
            "EGenericTaskResult::Cancelled",
            "EGenericTaskResult.Cancelled",
        }) do
            assert_true(core.generic_task_result_is_cancelled(result),
                tostring(result) .. " is cancelled")
        end
        for _, result in ipairs({
            0,
            2,
            "Success",
            "EGenericTaskResult::Failed",
            "",
        }) do
            assert_false(core.generic_task_result_is_cancelled(result),
                tostring(result) .. " is not cancelled")
        end
    end)

test("core identifies the narrow FreePoint ability and move task", function()
    assert_true(core.is_freepoint_ability_identity(
        "GameplayAbilityInteractFreePoint /Game/Map.G1RPlayerState_1."
        .. "GameplayAbilityInteractFreePoint_2"),
        "FreePoint ability identity")
    assert_false(core.is_freepoint_ability_identity(
        "GameplayAbilityBlockingInteraction /Game/Map.Ability_2"),
        "blocking ability is not FreePoint")
    assert_true(core.is_move_to_interaction_task_identity(
        "AbilityTask_MoveIntoPositionForInteraction /Game/Map.Task_3"),
        "move-into-position task identity")
    assert_false(core.is_move_to_interaction_task_identity(
        "AbilityTask_InteractWith /Game/Map.Task_3"),
        "other task identity rejected")
end)

test("core classifies player NPC and mining interactions", function()
    local player_identity =
        "GameplayAbilityBlockingInteraction "
        .. "/Game/Maps/Main.Main:PersistentLevel."
        .. "G1RPlayerState_1.GameplayAbilityBlockingInteraction_2"
    local npc_identity =
        "GameplayAbilityBlockingInteraction "
        .. "/Game/Maps/Main.Main:PersistentLevel."
        .. "State_OC_GRD_Guard_1.GameplayAbilityBlockingInteraction_2"
    local mining_identity =
        "GameplayAbilityMining "
        .. "/Game/Maps/Main.Main:PersistentLevel."
        .. "G1RPlayerState_1.GameplayAbilityMining_2"

    assert_true(core.is_player_identity(player_identity),
        "player identity recognized")
    assert_false(core.is_player_identity(npc_identity),
        "NPC identity rejected")
    assert_true(core.is_mining_identity(mining_identity),
        "mining identity recognized")
    assert_false(core.is_mining_identity(player_identity),
        "normal interaction is not mining")

    local player = core.classify_blocking_interaction(player_identity)
    assert_equal(player.action, "track", "player classification")
    assert_true(type(player.reason) == "string" and player.reason ~= "",
        "player classification reason")

    local npc = core.classify_blocking_interaction(npc_identity)
    assert_equal(npc.action, "ignore", "NPC classification")
    assert_true(type(npc.reason) == "string" and npc.reason ~= "",
        "NPC classification reason")

    local mining = core.classify_blocking_interaction(mining_identity)
    assert_equal(mining.action, "track", "mining classification")
    assert_true(type(mining.reason) == "string" and mining.reason ~= "",
        "mining classification reason")
    assert_true(mining.mining, "mining marker")

    local mining_with_legacy_argument =
        core.classify_blocking_interaction(mining_identity, false)
    assert_equal(mining_with_legacy_argument.action, "track",
        "mining classification is independent of reward setting")

    local missing = core.classify_blocking_interaction(nil)
    assert_equal(missing.action, "ignore", "missing identity classification")
end)

test("core identity matching is exact and rejects empty identities", function()
    local identity =
        "GameplayAbilityBlockingInteraction /Game/Maps/Main.Ability_1"
    assert_true(core.identities_match(identity, identity),
        "identical identities match")
    assert_false(core.identities_match(identity, identity .. "_Other"),
        "different identities do not match")
    assert_false(core.identities_match("", ""), "empty identities do not match")
    assert_false(core.identities_match(nil, identity),
        "missing identity does not match")
end)

test("core recognizes only the mining ore item identity marker", function()
    assert_true(core.is_mining_ore_item_identity(
        "ItMi_Orenugget /Script/Angelscript.Default__ItMi_Orenugget"),
        "mining ore item")
    assert_false(core.is_mining_ore_item_identity(
        "ItMi_Smith_Gold /Script/Angelscript.Default__ItMi_Smith_Gold"),
        "smithing gold is not mining ore")
    assert_false(core.is_mining_ore_item_identity(
        "ItFo_Apple /Script/Angelscript.Default__ItFo_Apple"),
        "unrelated item")
end)

local HOOK_SET_MOVE =
    "/Script/G1R.GameplayAbilityBlockingInteraction:SetMoveToTask"
local HOOK_MOVE_ENDED =
    "/Script/G1R.GameplayAbilityBlockingInteraction:OnMoveToTaskEnded"
local HOOK_FREEPOINT_FACTORY =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:"
    .. "BP_TaskMoveIntoPositionForInteraction"
local HOOK_FREEPOINT_ALIGNMENT =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction:"
    .. "HandleAlignmentFinished"
local HOOK_FREEPOINT_ENDED =
    "/Script/G1R.GameplayAbilityInteractFreePoint:OnInteractionTaskEnded"
local HOOK_CONVERSATION_UI =
    "/Script/G1R.GameplayAbilityConversationV2WithUI:ClientShowConversationUI"
local HOOK_ITEM_ADDED_FOR_HUD =
    "/Script/G1R.InventoryComponent:OnItemAddedForHUD"
local FREEPOINT_MOVE_TASK_CLASS =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction"
local CONVERSATION_GROUP_CLASS = "/Script/G1R.ConversationGroup"
local K2_CANCEL_PATH =
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
local NATIVE_BENCH_SETTING_ID =
    "G1R_CancelInteraction.EnableBenchAndLadderCancellation"
local NATIVE_CONVERSATION_SETTING_ID =
    "G1R_CancelInteraction.EnableConversationCancellation"
local NATIVE_WASD_SETTING_ID =
    "G1R_CancelInteraction.EnableWASDCancellation"
local NATIVE_MINING_SETTING_ID =
    "G1R_CancelInteraction.KeepOreOnMiningCancellation"
local EXPECTED_CONFIG_PATH =
    "Scripts\\..\\G1R_CancelInteraction.ini"

local RUNTIME_GLOBALS = {
    "Key",
    "RegisterHook",
    "RegisterKeyBind",
    "NotifyOnNewObject",
    "RegisterLoadMapPreHook",
    "ExecuteInGameThread",
    "ExecuteWithDelay",
    "StaticFindObject",
    "FindFirstOf",
    "FindAllOf",
}

local RuntimeEnv = {}
RuntimeEnv.__index = RuntimeEnv

local function pack_without_self(self_value, ...)
    local count = select("#", ...)
    local first = select(1, ...)
    local start_index = first == self_value and 2 or 1
    local packed = { n = math.max(0, count - start_index + 1) }
    local target_index = 1
    for source_index = start_index, count do
        packed[target_index] = select(source_index, ...)
        target_index = target_index + 1
    end
    return packed
end

local function first_value_of_type(values, expected_type, start_index)
    for index = start_index or 1, values.n or #values do
        if type(values[index]) == expected_type then
            return values[index], index
        end
    end
    return nil, nil
end

local function parse_ini_text(content)
    local parsed = {}
    for line in string.gmatch(tostring(content or ""), "[^\r\n]+") do
        local stripped = line:match("^%s*(.-)%s*$")
        if stripped ~= "" and stripped:sub(1, 1) ~= ";"
            and stripped:sub(1, 1) ~= "#"
        then
            local key, value =
                stripped:match("^([%w_%.%-]+)%s*=%s*(.-)%s*$")
            if key ~= nil then
                parsed[string.upper(key)] = value
            end
        end
    end
    return parsed
end

test("shipped INI matches the documented feature defaults", function()
    local file, open_error = io.open("G1R_CancelInteraction.ini", "r")
    assert_true(file ~= nil, "open shipped INI: " .. tostring(open_error))
    local content = file:read("*a")
    file:close()

    local config = core.config_from_ini(parse_ini_text(content))
    assert_false(config.debug, "shipped debug default")
    assert_true(config.enable_bench_and_ladder_cancellation,
        "shipped bench and ladder default")
    assert_true(config.enable_conversation_cancellation,
        "shipped conversation default")
    assert_true(config.enable_wasd_cancellation,
        "shipped WASD default")
    assert_false(config.keep_ore_on_mining_cancellation,
        "shipped mining ore default")
    assert_table_values(config.cancel_keys, DEFAULT_CANCEL_KEYS,
        "shipped cancel keys")
end)

function RuntimeEnv.new()
    local self = setmetatable({
        hooks = {},
        keybinds = {},
        notifications = {},
        map_pre_hooks = {},
        game_thread_callbacks = {},
        delayed_callbacks = {},
        logs = {},
        lookup_names = {},
        cancel_observations = {},
        authority_observations = {},
        avatar_observations = {},
        inventory_observations = {},
        game_state_observations = {},
        ore_read_observations = {},
        ore_remove_observations = {},
        ore_reward_observations = {},
        hud_item_observations = {},
        freepoint_end_calls = {},
        conversation_end_calls = {},
        native_bool_settings = {},
        native_bool_setting_order = {},
        config_text = nil,
        freepoint_quick_end_available = true,
        k2_has_authority_available = true,
        get_avatar_actor_available = true,
        get_character_inventory_available = true,
        gameplay_statics_cdo_available = true,
        get_game_state_available = true,
        get_character_ore_available = true,
        remove_character_ore_available = true,
        failed_hook_paths = {},
        installed = false,
        restored = false,
        old_globals = {},
        old_loader_preload = package.preload["pleasure_lib_loader"],
        old_loader_loaded = package.loaded["pleasure_lib_loader"],
        old_ue_helpers_preload = package.preload["UEHelpers"],
        old_ue_helpers_loaded = package.loaded["UEHelpers"],
    }, RuntimeEnv)

    self.generic_function = {
        valid = true,
        IsValid = function()
            return true
        end,
        GetFullName = function()
            return "Function /Script/CoreUObject.Object:MockFunction"
        end,
    }

    local function reflected_function(path, callback)
        local object = setmetatable({
            valid = true,
            IsValid = function()
                return true
            end,
            GetFullName = function()
                return "Function " .. path
            end,
        }, {
            __call = function(_, ...)
                return callback(...)
            end,
        })
        object.Call = function(_, ...)
            return callback(...)
        end
        object.call = object.Call
        return object
    end

    self.gameplay_statics_cdo = self:new_object(
        "GameplayStatics " .. GAMEPLAY_STATICS_CDO_PATH)
    self.mining_ore_item = self:new_object(
        "ItMi_Orenugget /Script/Angelscript.Default__ItMi_Orenugget")
    self.unrelated_item = self:new_object(
        "ItFo_Apple /Script/Angelscript.Default__ItFo_Apple")
    self.trader_manager = self:new_object(
        "TraderManager /Game/Maps/Main.Main:PersistentLevel."
        .. "TraderManager_1")
    self.game_state = self:new_object(
        "G1RGameState /Game/Maps/Main.Main:PersistentLevel.G1RGameState_1", {
            m_TraderManager = self.trader_manager,
        })

    self.k2_cancel_function = reflected_function(
        K2_CANCEL_PATH, function(ability)
            return self:record_cancel(self:unwrap(ability))
        end)
    self.k2_has_authority_function = reflected_function(
        K2_HAS_AUTHORITY_PATH, function(ability)
            ability = self:unwrap(ability)
            self.authority_observations[
                #self.authority_observations + 1] = ability
            return ability ~= nil and ability.has_authority ~= false
        end)
    self.get_avatar_actor_function = reflected_function(
        GET_AVATAR_ACTOR_PATH, function(ability)
            ability = self:unwrap(ability)
            self.avatar_observations[#self.avatar_observations + 1] = ability
            return ability and ability.avatar_character or nil
        end)
    self.get_character_inventory_function = reflected_function(
        GET_CHARACTER_INVENTORY_PATH, function(character)
            character = self:unwrap(character)
            self.inventory_observations[
                #self.inventory_observations + 1] = character
            return character and character.inventory_component or nil
        end)
    self.get_game_state_function = reflected_function(
        GET_GAME_STATE_PATH, function(cdo, world_context)
            cdo = self:unwrap(cdo)
            world_context = self:unwrap(world_context)
            self.game_state_observations[
                #self.game_state_observations + 1] = {
                    cdo = cdo,
                    world_context = world_context,
                }
            return self.game_state
        end)
    self.get_character_ore_function = reflected_function(
        GET_CHARACTER_ORE_PATH, function(manager, character)
            manager = self:unwrap(manager)
            character = self:unwrap(character)
            self.ore_read_observations[
                #self.ore_read_observations + 1] = {
                    manager = manager,
                    character = character,
                    ore = character and character.ore or nil,
                }
            return character and character.ore or nil
        end)
    self.remove_character_ore_function = reflected_function(
        REMOVE_CHARACTER_ORE_PATH, function(manager, character, amount)
            manager = self:unwrap(manager)
            character = self:unwrap(character)
            amount = tonumber(self:unwrap(amount)) or 0
            local before = character and tonumber(character.ore) or nil
            self.ore_remove_observations[
                #self.ore_remove_observations + 1] = {
                    manager = manager,
                    character = character,
                    amount = amount,
                    before = before,
                }
            if character ~= nil and before ~= nil then
                character.ore = math.max(0, before - amount)
            end
            return true
        end)

    self.freepoint_quick_end_function = setmetatable({
        valid = true,
        IsValid = function()
            return true
        end,
        GetFullName = function()
            return "Function " .. FREEPOINT_QUICK_END_PATH
        end,
    }, {
        __call = function(_, ability)
            return self:record_freepoint_end(self:unwrap(ability))
        end,
    })
    self.freepoint_quick_end_function.Call = function(_, ability)
        return self:record_freepoint_end(self:unwrap(ability))
    end
    self.freepoint_quick_end_function.call =
        self.freepoint_quick_end_function.Call

    self.lib = self:create_pleasure_lib()
    return self
end

function RuntimeEnv:unwrap(value)
    local current = value
    for _ = 1, 4 do
        if type(current) ~= "table" then
            break
        end
        if type(current.GetFullName) == "function"
            or current.identity ~= nil
        then
            break
        end
        local getter = current.get or current.Get
        if type(getter) ~= "function" then
            break
        end
        local ok, unwrapped = pcall(getter, current)
        if not ok or unwrapped == nil or unwrapped == current then
            break
        end
        current = unwrapped
    end
    return current
end

function RuntimeEnv:is_valid(value)
    local object = self:unwrap(value)
    if object == nil then
        return false
    end
    if type(object) == "table" and object.valid == false then
        return false
    end
    if type(object) == "table" and type(object.IsValid) == "function" then
        local ok, result = pcall(object.IsValid, object)
        if ok then
            result = self:unwrap(result)
            if result == false then
                return false
            end
            if result == true then
                return true
            end
        end
    end
    return type(object) == "table" or type(object) == "userdata"
end

function RuntimeEnv:full_name(value)
    local object = self:unwrap(value)
    if object == nil then
        return ""
    end
    if type(object) == "string" then
        return object
    end
    if type(object) == "table" and type(object.GetFullName) == "function" then
        local ok, result = pcall(object.GetFullName, object)
        if ok and result ~= nil then
            return tostring(result)
        end
    end
    if type(object) == "table" and object.identity ~= nil then
        return tostring(object.identity)
    end
    return ""
end

function RuntimeEnv:record_cancel(ability)
    if ability == nil then
        return false
    end
    self.cancel_observations[#self.cancel_observations + 1] = {
        ability = ability,
        cooldown = ability.m_ApplyCooldown,
    }
    ability.cancel_count = (ability.cancel_count or 0) + 1
    if core.is_mining_identity(self:full_name(ability)) then
        if type(ability.before_mining_reward) == "function" then
            ability.before_mining_reward(ability)
        end
        local amount = tonumber(ability.mining_reward_amount)
        if amount == nil then amount = 1 end
        local delay = tonumber(ability.mining_reward_delay_ms)
        if amount > 0 and delay ~= nil and delay > 0 then
            self.delayed_callbacks[#self.delayed_callbacks + 1] = {
                delay = delay,
                kind = "mock-mining-reward",
                callback = function()
                    self:credit_mining_reward(ability, amount, "delayed")
                end,
            }
        elseif amount > 0 then
            self:credit_mining_reward(ability, amount, "synchronous")
        end
    end
    ability.m_AbilityEnded = true
    if ability.k2_move_end_result ~= nil then
        ability.k2_move_end_count =
            (ability.k2_move_end_count or 0) + 1
        self:invoke_hook(HOOK_MOVE_ENDED,
            self:wrap(ability),
            self:wrap(ability.m_TaskMoveTo),
            self:wrap(ability.k2_move_end_result))
    end
    return true
end

function RuntimeEnv:credit_mining_reward(ability, amount, source)
    ability = self:unwrap(ability)
    local character = ability and ability.avatar_character or nil
    amount = tonumber(amount) or 0
    if character == nil or amount <= 0 then
        return false
    end
    local before = tonumber(character.ore) or 0
    character.ore = before + amount
    local displayed_amount = amount
    if self:has_hook(HOOK_ITEM_ADDED_FOR_HUD) then
        local count_param = self:mutable_param(amount)
        self:invoke_hook(HOOK_ITEM_ADDED_FOR_HUD,
            self:wrap(character.inventory_component),
            self:wrap(self.mining_ore_item),
            count_param)
        displayed_amount = tonumber(count_param.value) or 0
    end
    self.ore_reward_observations[
        #self.ore_reward_observations + 1] = {
            ability = ability,
            character = character,
            amount = amount,
            before = before,
            source = source,
            displayed_amount = displayed_amount,
        }
    self.hud_item_observations[#self.hud_item_observations + 1] = {
        inventory = character.inventory_component,
        item = self.mining_ore_item,
        original_amount = amount,
        displayed_amount = displayed_amount,
        source = source,
    }
    return true
end

function RuntimeEnv:emit_item_added_for_hud(inventory, item, amount)
    local count_param = self:mutable_param(amount)
    self:invoke_hook(HOOK_ITEM_ADDED_FOR_HUD,
        self:wrap(inventory), self:wrap(item), count_param)
    self.hud_item_observations[#self.hud_item_observations + 1] = {
        inventory = inventory,
        item = item,
        original_amount = amount,
        displayed_amount = tonumber(count_param.value),
        source = "manual",
    }
    return tonumber(count_param.value)
end

function RuntimeEnv:record_freepoint_end(ability)
    if ability == nil then return false end
    self.freepoint_end_calls[#self.freepoint_end_calls + 1] = ability
    ability.quick_end_count = (ability.quick_end_count or 0) + 1
    ability.bEndRequested = true
    return true
end

function RuntimeEnv:find_object(name)
    name = tostring(name)
    self.lookup_names[#self.lookup_names + 1] = name
    if name == K2_CANCEL_PATH then
        return self.k2_cancel_function
    end
    if name == K2_HAS_AUTHORITY_PATH then
        if self.k2_has_authority_available ~= true then return nil end
        return self.k2_has_authority_function
    end
    if name == GET_AVATAR_ACTOR_PATH then
        if self.get_avatar_actor_available ~= true then return nil end
        return self.get_avatar_actor_function
    end
    if name == GET_CHARACTER_INVENTORY_PATH then
        if self.get_character_inventory_available ~= true then return nil end
        return self.get_character_inventory_function
    end
    if name == GAMEPLAY_STATICS_CDO_PATH then
        if self.gameplay_statics_cdo_available ~= true then return nil end
        return self.gameplay_statics_cdo
    end
    if name == GET_GAME_STATE_PATH then
        if self.get_game_state_available ~= true then return nil end
        return self.get_game_state_function
    end
    if name == GET_CHARACTER_ORE_PATH then
        if self.get_character_ore_available ~= true then return nil end
        return self.get_character_ore_function
    end
    if name == REMOVE_CHARACTER_ORE_PATH then
        if self.remove_character_ore_available ~= true then return nil end
        return self.remove_character_ore_function
    end
    if name == FREEPOINT_QUICK_END_PATH then
        if self.freepoint_quick_end_available ~= true then return nil end
        return self.freepoint_quick_end_function
    end
    return self.generic_function
end

function RuntimeEnv:capture_hook(path, pre_hook, post_hook)
    if self.failed_hook_paths[path] == true then return false end
    if type(pre_hook) == "table" then
        post_hook = pre_hook.post or pre_hook.after
        pre_hook = pre_hook.pre or pre_hook.before or pre_hook.callback
    end
    self.hooks[path] = self.hooks[path] or {}
    self.hooks[path][#self.hooks[path] + 1] = {
        pre = type(pre_hook) == "function" and pre_hook or nil,
        post = type(post_hook) == "function" and post_hook or nil,
    }
    return true, #self.hooks[path], #self.hooks[path]
end

function RuntimeEnv:capture_keybind(key, callback)
    local name = key
    if type(key) == "table" then
        name = key.name or key.KeyName
    end
    name = string.upper(tostring(name or ""))
    self.keybinds[name] = self.keybinds[name] or {}
    self.keybinds[name][#self.keybinds[name] + 1] = callback
    return true, name
end

function RuntimeEnv:capture_notification(class_name, callback)
    self.notifications[class_name] = self.notifications[class_name] or {}
    self.notifications[class_name][#self.notifications[class_name] + 1] =
        callback
    return true
end

function RuntimeEnv:capture_game_bool_setting(options)
    if type(options) ~= "table"
        or type(options.id) ~= "string"
        or options.id == ""
    then
        return nil
    end
    if self.native_bool_settings[options.id] == nil then
        self.native_bool_setting_order[
            #self.native_bool_setting_order + 1] = options.id
    end
    self.native_bool_settings[options.id] = options
    return {
        id = options.id,
        refresh = function()
            return true
        end,
    }
end

function RuntimeEnv:set_native_bool(id, value)
    local setting = self.native_bool_settings[id]
    assert_true(type(setting) == "table",
        "native bool setting registered: " .. tostring(id))
    assert_equal(type(setting.set), "function",
        "native bool setting setter: " .. tostring(id))
    return setting.set(value)
end

function RuntimeEnv:create_pleasure_lib()
    local env = self
    local lib = {}

    lib.log = function(...)
        local args = pack_without_self(lib, ...)
        local message = args[1]
        if type(message) == "function" then
            local ok, built = pcall(message)
            message = ok and built or built
        end
        env.logs[#env.logs + 1] = tostring(message)
    end

    lib.debug_log = function(...)
        local args = pack_without_self(lib, ...)
        if env.debug_enabled == true then
            env.logs[#env.logs + 1] = "[debug] " .. tostring(args[1])
        end
    end

    lib.set_debug = function(...)
        local args = pack_without_self(lib, ...)
        env.debug_enabled = args[1] == true
    end

    lib.script_directory = function()
        return "Scripts\\"
    end

    lib.read_text_file = function()
        return env.config_text
    end

    lib.parse_ini = function(...)
        local args = pack_without_self(lib, ...)
        return parse_ini_text(args[1])
    end

    lib.split_list = function(...)
        local args = pack_without_self(lib, ...)
        local values = {}
        for part in string.gmatch(tostring(args[1] or ""), "([^,]+)") do
            values[#values + 1] = part:match("^%s*(.-)%s*$")
        end
        return values
    end

    lib.safe_to_string = function(...)
        local args = pack_without_self(lib, ...)
        local ok, text = pcall(tostring, args[1])
        return ok and text or "<unprintable>"
    end

    lib.trim = function(...)
        local args = pack_without_self(lib, ...)
        return tostring(args[1] or ""):match("^%s*(.-)%s*$")
    end

    lib.unwrap = function(...)
        local args = pack_without_self(lib, ...)
        return env:unwrap(args[1])
    end

    lib.is_valid = function(...)
        local args = pack_without_self(lib, ...)
        return env:is_valid(args[1])
    end

    lib.full_name = function(...)
        local args = pack_without_self(lib, ...)
        return env:full_name(args[1])
    end

    lib.find_object = function(...)
        local args = pack_without_self(lib, ...)
        local name = first_value_of_type(args, "string")
        return env:find_object(name)
    end

    lib.safe = function(...)
        local args = pack_without_self(lib, ...)
        local callback, callback_index =
            first_value_of_type(args, "function")
        if callback == nil then
            return false, "callback missing"
        end
        local callback_args = { n = 0 }
        for index = callback_index + 1, args.n do
            callback_args.n = callback_args.n + 1
            callback_args[callback_args.n] = args[index]
        end
        local ok, result = pcall(callback,
            unpack_values(callback_args, 1, callback_args.n))
        if ok then return result end
        env.logs[#env.logs + 1] =
            "safe callback failed: " .. tostring(result)
        return nil
    end

    lib.try = function(...)
        local args = pack_without_self(lib, ...)
        local callback = first_value_of_type(args, "function")
        if callback == nil then
            return nil
        end
        local ok, result = pcall(callback)
        if ok then
            return result
        end
        return nil
    end

    lib.register_hook = function(...)
        local args = pack_without_self(lib, ...)
        local path, path_index = first_value_of_type(args, "string")
        local pre_hook = args[path_index and (path_index + 1) or 2]
        local post_hook = args[path_index and (path_index + 2) or 3]
        return env:capture_hook(path, pre_hook, post_hook)
    end

    lib.register_game_bool_setting = function(...)
        local args = pack_without_self(lib, ...)
        local options = first_value_of_type(args, "table")
        return env:capture_game_bool_setting(options)
    end

    lib.register_key_bind = function(...)
        local args = pack_without_self(lib, ...)
        local callback = first_value_of_type(args, "function")
        local key = args[1]
        if type(key) == "string" and _G.Key[key] ~= nil then
            key = _G.Key[key]
        end
        return env:capture_keybind(key, callback)
    end

    lib.notify_on_new_object = function(...)
        local args = pack_without_self(lib, ...)
        local class_name, class_index =
            first_value_of_type(args, "string")
        local callback = first_value_of_type(args, "function",
            (class_index or 0) + 1)
        return env:capture_notification(class_name, callback)
    end

    lib.register_load_map_pre_hook = function(...)
        local args = pack_without_self(lib, ...)
        local callback = first_value_of_type(args, "function")
        env.map_pre_hooks[#env.map_pre_hooks + 1] = callback
        return true
    end

    lib.execute_in_game_thread = function(...)
        local args = pack_without_self(lib, ...)
        local callback = first_value_of_type(args, "function")
        env.game_thread_callbacks[#env.game_thread_callbacks + 1] =
            callback
        return true
    end

    lib.delay_game_thread = function(...)
        local args = pack_without_self(lib, ...)
        local delay = first_value_of_type(args, "number") or 0
        local callback = first_value_of_type(args, "function")
        env.delayed_callbacks[#env.delayed_callbacks + 1] = {
            delay = delay,
            callback = callback,
        }
        return true
    end
    lib.execute_with_delay = lib.delay_game_thread

    lib.get_property = function(...)
        local args = pack_without_self(lib, ...)
        local object = env:unwrap(args[1])
        if type(object) ~= "table" then
            return nil
        end
        return object[args[2]]
    end

    lib.set_property = function(...)
        local args = pack_without_self(lib, ...)
        local object = env:unwrap(args[1])
        if type(object) ~= "table" then
            return false
        end
        object[args[2]] = args[3]
        return true
    end

    lib.call_function = function(...)
        local args = pack_without_self(lib, ...)
        local object = env:unwrap(args[1])
        local ufunction = args[2]
        return ufunction(object)
    end

    return lib
end

function RuntimeEnv:install()
    if self.installed then
        return
    end
    self.installed = true

    for _, global_name in ipairs(RUNTIME_GLOBALS) do
        self.old_globals[global_name] = rawget(_G, global_name)
    end

    local key_table = {}
    for _, key_name in ipairs(DEFAULT_CANCEL_KEYS) do
        key_table[key_name] = { name = key_name }
    end
    key_table.RIGHTMOUSEBUTTON = key_table.RIGHT_MOUSE_BUTTON
    _G.Key = key_table

    _G.RegisterHook = function(path, pre_hook, post_hook)
        return self:capture_hook(path, pre_hook, post_hook)
    end

    _G.RegisterKeyBind = function(key, ...)
        local args = { ... }
        local callback = nil
        for index = #args, 1, -1 do
            if type(args[index]) == "function" then
                callback = args[index]
                break
            end
        end
        return self:capture_keybind(key, callback)
    end

    _G.NotifyOnNewObject = function(class_name, callback)
        return self:capture_notification(class_name, callback)
    end

    _G.RegisterLoadMapPreHook = function(callback)
        self.map_pre_hooks[#self.map_pre_hooks + 1] = callback
        return true
    end

    _G.ExecuteInGameThread = function(callback)
        self.game_thread_callbacks[#self.game_thread_callbacks + 1] =
            callback
        return true
    end

    _G.ExecuteWithDelay = function(delay, callback)
        self.delayed_callbacks[#self.delayed_callbacks + 1] = {
            delay = delay,
            callback = callback,
        }
        return true
    end

    _G.StaticFindObject = function(...)
        local args = { ... }
        local name = nil
        for index = #args, 1, -1 do
            if type(args[index]) == "string" then
                name = args[index]
                break
            end
        end
        return self:find_object(name)
    end

    _G.FindFirstOf = function()
        return nil
    end
    _G.FindAllOf = function()
        return {}
    end

    local loader = {}
    loader.new = function()
        return self.lib
    end
    loader.load = function()
        return self.lib
    end
    loader.load_or_log = function()
        return self.lib
    end

    package.loaded["pleasure_lib_loader"] = nil
    package.preload["pleasure_lib_loader"] = function()
        return loader
    end
    package.loaded["UEHelpers"] = nil
    package.preload["UEHelpers"] = function()
        return {}
    end
end

function RuntimeEnv:restore()
    if self.restored then
        return
    end
    self.restored = true

    for _, global_name in ipairs(RUNTIME_GLOBALS) do
        rawset(_G, global_name, self.old_globals[global_name])
    end
    package.preload["pleasure_lib_loader"] = self.old_loader_preload
    package.loaded["pleasure_lib_loader"] = self.old_loader_loaded
    package.preload["UEHelpers"] = self.old_ue_helpers_preload
    package.loaded["UEHelpers"] = self.old_ue_helpers_loaded
end

function RuntimeEnv:load_main()
    local chunk, load_error = loadfile("Scripts/main.lua")
    assert_true(chunk ~= nil, "load main.lua: " .. tostring(load_error))
    local ok, runtime_error = xpcall(chunk, debug.traceback)
    if not ok then
        error("main.lua failed to initialize:\n" .. tostring(runtime_error), 2)
    end
end

function RuntimeEnv:wrap(object)
    return {
        get = function()
            return object
        end,
        Get = function()
            return object
        end,
        type = function()
            return "RemoteUnrealParam"
        end,
    }
end

function RuntimeEnv:mutable_param(value)
    local param = {
        value = value,
    }
    param.get = function(self_value)
        return self_value.value
    end
    param.Get = param.get
    param.set = function(self_value, next_value)
        self_value.value = next_value
    end
    param.Set = param.set
    param.type = function()
        return "RemoteUnrealParam"
    end
    return param
end

function RuntimeEnv:new_object(identity, properties)
    local object = properties or {}
    object.identity = identity
    object.valid = object.valid ~= false
    object.IsValid = object.IsValid or function(self_value)
        return self_value.valid ~= false
    end
    object.GetFullName = object.GetFullName or function(self_value)
        return self_value.identity
    end
    return object
end

function RuntimeEnv:new_ability(identity)
    self.avatar_counter = (self.avatar_counter or 0) + 1
    local inventory_component = self:new_object(
        "InventoryComponent /Game/Maps/Main.Main:PersistentLevel."
        .. "G1RPlayerState_" .. tostring(self.avatar_counter)
        .. ".InventoryComponent")
    local avatar_character = self:new_object(
        "GothicCharacter /Game/Maps/Main.Main:PersistentLevel."
        .. "G1RPlayerCharacter_" .. tostring(self.avatar_counter), {
            ore = 0,
            inventory_component = inventory_component,
        })
    local ability = self:new_object(identity, {
        m_ApplyCooldown = true,
        m_AbilityEnded = false,
        has_authority = true,
        avatar_character = avatar_character,
        mining_reward_amount = 1,
        cancel_count = 0,
    })
    ability.CallFunction = function(self_value, ufunction, ...)
        return ufunction(self_value, ...)
    end
    ability.K2_CancelAbility = function(self_value)
        return self:record_cancel(self_value)
    end
    return ability
end

function RuntimeEnv:new_freepoint_ability(identity, interactive_actor)
    self.freepoint_root_counter = (self.freepoint_root_counter or 0) + 1
    local root_task = self:new_object(
        "AbilityTask_InteractionSpot /Game/Maps/Main.RootTask_"
        .. tostring(self.freepoint_root_counter))
    return self:new_object(identity, {
        m_AbilityEnded = false,
        bEndRequested = false,
        m_InteractiveActor = interactive_actor,
        RootInteractionTask = root_task,
        quick_end_count = 0,
    })
end

function RuntimeEnv:new_freepoint_move_task(identity, ability)
    return self:new_object(identity, {
        Ability = ability,
        bIsReadyToStartAnimation = false,
    })
end

function RuntimeEnv:new_conversation(identity, initiator)
    local conversation = self:new_object(identity, {
        Initiator = initiator,
        request_end_count = 0,
    })
    conversation.RequestEndConversation = function(self_value)
        self_value.request_end_count = self_value.request_end_count + 1
        self.conversation_end_calls[#self.conversation_end_calls + 1] =
            self_value
        return true
    end
    return conversation
end

function RuntimeEnv:has_hook(path)
    return type(self.hooks[path]) == "table" and #self.hooks[path] > 0
end

function RuntimeEnv:invoke_hook(path, ...)
    local registrations = self.hooks[path]
    assert_true(type(registrations) == "table" and #registrations > 0,
        "hook registered: " .. tostring(path))
    for _, registration in ipairs(registrations) do
        if registration.pre ~= nil then
            registration.pre(...)
        end
        if registration.post ~= nil then
            registration.post(...)
        end
    end
end

function RuntimeEnv:invoke_hook_around(path, native_callback, ...)
    local registrations = self.hooks[path]
    assert_true(type(registrations) == "table" and #registrations > 0,
        "hook registered: " .. tostring(path))
    for _, registration in ipairs(registrations) do
        if registration.pre ~= nil then registration.pre(...) end
    end
    native_callback()
    for _, registration in ipairs(registrations) do
        if registration.post ~= nil then registration.post(...) end
    end
end

function RuntimeEnv:notify(class_name, object)
    local callbacks = self.notifications[class_name]
    assert_true(type(callbacks) == "table" and #callbacks > 0,
        "notification registered: " .. tostring(class_name))
    for _, callback in ipairs(callbacks) do
        callback(object)
    end
end

function RuntimeEnv:press(key_name)
    local callbacks = self.keybinds[string.upper(key_name)]
    assert_true(type(callbacks) == "table" and #callbacks > 0,
        "key registered: " .. tostring(key_name))
    for _, callback in ipairs(callbacks) do
        assert_equal(type(callback), "function",
            "key callback " .. tostring(key_name))
        callback()
    end
end

local function flush_callback_list(callbacks)
    while #callbacks > 0 do
        local batch = callbacks
        callbacks = {}
        for _, callback in ipairs(batch) do
            callback()
        end
    end
    return callbacks
end

function RuntimeEnv:flush_game_thread()
    while #self.game_thread_callbacks > 0 do
        local callbacks = self.game_thread_callbacks
        self.game_thread_callbacks = {}
        for _, callback in ipairs(callbacks) do
            callback()
        end
    end
end

function RuntimeEnv:flush_delayed()
    while #self.delayed_callbacks > 0 do
        local delayed = self.delayed_callbacks
        self.delayed_callbacks = {}
        table.sort(delayed, function(left, right)
            return (left.delay or 0) < (right.delay or 0)
        end)
        for _, entry in ipairs(delayed) do
            entry.callback()
        end
    end
end

function RuntimeEnv:load_map()
    assert_true(#self.map_pre_hooks > 0, "map pre hook registered")
    for _, callback in ipairs(self.map_pre_hooks) do
        callback()
    end
end

local function player_ability_identity(suffix)
    return "GameplayAbilityBlockingInteraction "
        .. "/Game/Maps/Main.Main:PersistentLevel.G1RPlayerState_1."
        .. "GameplayAbilityBlockingInteraction_" .. tostring(suffix)
end

local function npc_ability_identity(suffix)
    return "GameplayAbilityBlockingInteraction "
        .. "/Game/Maps/Main.Main:PersistentLevel.State_OC_NPC_1."
        .. "GameplayAbilityBlockingInteraction_" .. tostring(suffix)
end

local function mining_ability_identity(suffix)
    return "GameplayAbilityMining "
        .. "/Game/Maps/Main.Main:PersistentLevel.G1RPlayerState_1."
        .. "GameplayAbilityMining_" .. tostring(suffix)
end

local function player_freepoint_identity(suffix)
    return "GameplayAbilityInteractFreePoint "
        .. "/Game/Maps/Main.Main:PersistentLevel.G1RPlayerState_1."
        .. "GameplayAbilityInteractFreePoint_" .. tostring(suffix)
end

local function npc_freepoint_identity(suffix)
    return "GameplayAbilityInteractFreePoint "
        .. "/Game/Maps/Main.Main:PersistentLevel.State_OC_NPC_1."
        .. "GameplayAbilityInteractFreePoint_" .. tostring(suffix)
end

local function freepoint_move_task_identity(suffix)
    return "AbilityTask_MoveIntoPositionForInteraction "
        .. "/Game/Maps/Main.Main:PersistentLevel."
        .. "AbilityTask_MoveIntoPositionForInteraction_" .. tostring(suffix)
end

local function interaction_actor_identity(suffix)
    return "GothicInteractiveObject /Game/Maps/Main.Main:"
        .. "PersistentLevel.InteractiveObject_" .. tostring(suffix)
end

local function mining_actor_identity(suffix)
    return "GothicMiningInteractiveObject /Game/Maps/Main.Main:"
        .. "PersistentLevel.MiningObject_" .. tostring(suffix)
end

local function player_state_identity(suffix)
    return "G1RPlayerState /Game/Maps/Main.Main:PersistentLevel."
        .. "G1RPlayerState_" .. tostring(suffix)
end

local function npc_state_identity(suffix)
    return "GothicNPCState /Game/Maps/Main.Main:PersistentLevel."
        .. "State_OC_NPC_" .. tostring(suffix)
end

local function add_runtime_test(name, config_text, setup, callback)
    test(name, function()
        local env = RuntimeEnv.new()
        local ok, runtime_error = xpcall(function()
            env.config_text = config_text
            if setup ~= nil then setup(env) end
            env:install()
            env:load_main()
            callback(env)
        end, debug.traceback)
        env:restore()
        if not ok then
            error(runtime_error, 0)
        end
    end)
end

local function runtime_test(name, callback)
    add_runtime_test(name, nil, nil, callback)
end

local function configured_runtime_test(name, config_text, callback)
    add_runtime_test(name, config_text, nil, callback)
end

local function configured_runtime_setup_test(name, config_text,
        setup, callback)
    add_runtime_test(name, config_text, setup, callback)
end

local function observe_freepoint_factory(env, task)
    env:invoke_hook(HOOK_FREEPOINT_FACTORY,
        env:wrap(env.generic_function),
        env:wrap(env:new_object("Vector /Script/CoreUObject.MockVector")),
        env:wrap(task))
end

local function new_mining_freepoint(env, suffix)
    local actor = env:new_object(mining_actor_identity(suffix))
    local ability = env:new_freepoint_ability(
        player_freepoint_identity(suffix), actor)
    local task = env:new_freepoint_move_task(
        freepoint_move_task_identity(suffix), ability)
    return ability, task
end

runtime_test("main registers lean lifecycle hooks and default inputs",
    function(env)
        assert_true(env:has_hook(HOOK_SET_MOVE),
            "SetMoveToTask hook")
        assert_true(env:has_hook(HOOK_MOVE_ENDED),
            "OnMoveToTaskEnded hook")
        assert_true(env:has_hook(HOOK_FREEPOINT_FACTORY),
            "FreePoint factory hook")
        assert_equal(type(env.hooks[HOOK_FREEPOINT_FACTORY][1].post),
            "function", "FreePoint factory uses a post hook")
        assert_true(env:has_hook(HOOK_FREEPOINT_ALIGNMENT),
            "FreePoint alignment hook")
        assert_true(env:has_hook(HOOK_FREEPOINT_ENDED),
            "FreePoint interaction-end hook")
        assert_true(env:has_hook(HOOK_CONVERSATION_UI),
            "ClientShowConversationUI hook")
        assert_true(env:has_hook(HOOK_ITEM_ADDED_FOR_HUD),
            "OnItemAddedForHUD hook")
        assert_true(type(env.notifications[FREEPOINT_MOVE_TASK_CLASS])
                == "table"
                and #env.notifications[FREEPOINT_MOVE_TASK_CLASS] > 0,
            "FreePoint task notification")
        assert_true(type(env.notifications[CONVERSATION_GROUP_CLASS])
                == "table"
                and #env.notifications[CONVERSATION_GROUP_CLASS] > 0,
            "ConversationGroup notification")
        assert_true(#env.map_pre_hooks > 0, "map lifecycle hook")
        assert_true(contains(env.lookup_names, FREEPOINT_QUICK_END_PATH),
            "FreePoint quick-end UFunction lookup")
        for _, path in ipairs({
            K2_HAS_AUTHORITY_PATH,
            GET_AVATAR_ACTOR_PATH,
            GET_CHARACTER_INVENTORY_PATH,
            GAMEPLAY_STATICS_CDO_PATH,
            GET_GAME_STATE_PATH,
            GET_CHARACTER_ORE_PATH,
            REMOVE_CHARACTER_ORE_PATH,
        }) do
            assert_true(contains(env.lookup_names, path),
                "mining ore rollback lookup " .. path)
        end

        for _, key_name in ipairs(DEFAULT_CANCEL_KEYS) do
            assert_true(type(env.keybinds[key_name]) == "table"
                    and #env.keybinds[key_name] > 0,
                "default keybind " .. key_name)
        end
    end)

runtime_test("main registers four persistent localized native settings",
    function(env)
        local expected_ids = {
            NATIVE_BENCH_SETTING_ID,
            NATIVE_CONVERSATION_SETTING_ID,
            NATIVE_WASD_SETTING_ID,
            NATIVE_MINING_SETTING_ID,
        }
        local expected_defaults = {
            [NATIVE_BENCH_SETTING_ID] = true,
            [NATIVE_CONVERSATION_SETTING_ID] = true,
            [NATIVE_WASD_SETTING_ID] = true,
            [NATIVE_MINING_SETTING_ID] = false,
        }
        local persist_keys = {
            [NATIVE_BENCH_SETTING_ID] =
                "EnableBenchAndLadderCancellation",
            [NATIVE_CONVERSATION_SETTING_ID] =
                "EnableConversationCancellation",
            [NATIVE_WASD_SETTING_ID] = "EnableWASDCancellation",
            [NATIVE_MINING_SETTING_ID] =
                "KeepOreOnMiningCancellation",
        }

        assert_table_values(env.native_bool_setting_order, expected_ids,
            "native bool setting order")
        for _, id in ipairs(expected_ids) do
            local setting = env.native_bool_settings[id]
            assert_equal(type(setting), "table",
                "native setting " .. id)
            assert_equal(setting.section, "G1R Cancel Interaction",
                "native setting section " .. id)
            assert_equal(setting.default, expected_defaults[id],
                "native setting default " .. id)
            assert_equal(type(setting.get), "function",
                "native setting getter " .. id)
            assert_equal(type(setting.set), "function",
                "native setting setter " .. id)
            assert_equal(setting.get(), expected_defaults[id],
                "native setting initial value " .. id)

            for _, language in ipairs({ "en", "de" }) do
                local translation =
                    setting.translations and setting.translations[language]
                assert_equal(type(translation), "table",
                    "native setting translation " .. id .. " " .. language)
                assert_true(type(translation.name) == "string"
                        and translation.name ~= "",
                    "native setting name " .. id .. " " .. language)
                assert_true(type(translation.description) == "string"
                        and translation.description ~= "",
                    "native setting description " .. id .. " " .. language)
            end

            assert_equal(type(setting.persist), "table",
                "native setting persistence " .. id)
            assert_equal(type(setting.persist.path), "function",
                "native setting persistence path " .. id)
            assert_equal(setting.persist.path(), EXPECTED_CONFIG_PATH,
                "native setting persisted path " .. id)
            assert_equal(setting.persist.key, persist_keys[id],
                "native setting persisted key " .. id)
        end

        local mining_setting =
            env.native_bool_settings[NATIVE_MINING_SETTING_ID]
        assert_equal(mining_setting.translations.en.name,
            "Keep ore when cancelling mining",
            "English mining setting name")
        assert_equal(mining_setting.translations.de.name,
            "Erz bei Abbruch behalten",
            "German mining setting name")
        assert_equal(mining_setting.translations.en.description,
            "You can always cancel mining. On: You get the ore even when "
                .. "cancelling. Off: Cancelling gives no ore and no ore "
                .. "notification. Default: Off.",
            "English mining description states simple on/off behavior")
        assert_equal(mining_setting.translations.de.description,
            "Du kannst den Erzabbau immer abbrechen. An: Auch bei Abbruch "
                .. "bekommst du das Erz. Aus: Bei Abbruch bekommst du kein "
                .. "Erz und keine Erz-Meldung. Standard: Aus.",
            "German mining description states simple on/off behavior")
    end)

configured_runtime_test(
    "mining reward setting toggles live between retained and rolled-back ore",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local setting =
            env.native_bool_settings[NATIVE_MINING_SETTING_ID]
        assert_false(setting.get(), "mining ore retention starts disabled")

        local retained = env:new_ability(mining_ability_identity(88))
        retained.avatar_character.ore = 20
        retained.mining_reward_amount = 3
        retained.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(88), retained)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(retained))
        env:press("F")
        assert_true(env:set_native_bool(NATIVE_MINING_SETTING_ID, true),
            "ore retention live enable accepted")
        env:flush_game_thread()

        assert_true(setting.get(), "mining ore retention live enabled")
        assert_equal(retained.cancel_count, 1,
            "live-enabled mining still uses K2 cancellation")
        assert_false(retained.m_ApplyCooldown,
            "live-enabled mining disables cooldown before K2")
        assert_equal(retained.avatar_character.ore, 23,
            "live-enabled setting keeps the synchronous ore reward")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 3,
            "live-enabled setting keeps the mining reward HUD message")
        assert_equal(#env.ore_remove_observations, 0,
            "live-enabled setting schedules no rollback")

        local rolled_back = env:new_ability(mining_ability_identity(89))
        rolled_back.avatar_character.ore = 40
        rolled_back.mining_reward_amount = 2
        rolled_back.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(89), rolled_back)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(rolled_back))
        env:press("F")
        assert_true(env:set_native_bool(NATIVE_MINING_SETTING_ID, false),
            "ore retention live disable accepted")
        env:flush_game_thread()

        assert_false(setting.get(), "mining ore retention live disabled")
        assert_equal(rolled_back.cancel_count, 1,
            "live-disabled mining still uses K2 cancellation")
        assert_false(rolled_back.m_ApplyCooldown,
            "live-disabled mining disables cooldown before K2")
        assert_equal(rolled_back.avatar_character.ore, 40,
            "live-disabled setting removes only the new reward")
        assert_equal(env.ore_reward_observations[2].displayed_amount, 0,
            "live-disabled setting suppresses the mining reward HUD message")
        assert_equal(#env.ore_remove_observations, 1,
            "live-disabled setting requests one immediate rollback")
        assert_equal(env.ore_remove_observations[1].amount, 2,
            "live-disabled rollback amount")
        env:flush_delayed()
        assert_equal(rolled_back.avatar_character.ore, 40,
            "later checks preserve the original ore balance")

        local retained_in_flight =
            env:new_ability(mining_ability_identity(890))
        retained_in_flight.avatar_character.ore = 60
        retained_in_flight.mining_reward_amount = 4
        retained_in_flight.mining_reward_delay_ms = 125
        retained_in_flight.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(890), retained_in_flight)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(retained_in_flight))
        env:press("F")
        env:flush_game_thread()
        assert_equal(retained_in_flight.avatar_character.ore, 60,
            "in-flight reward is not credited before its delay")

        assert_true(env:set_native_bool(NATIVE_MINING_SETTING_ID, true),
            "ore retention can be enabled during the rollback window")
        env:flush_delayed()

        assert_equal(retained_in_flight.avatar_character.ore, 64,
            "live enable retains an in-flight delayed reward")
        assert_equal(env.ore_reward_observations[3].displayed_amount, 4,
            "live enable restores the in-flight reward HUD message")
        assert_equal(#env.ore_remove_observations, 1,
            "closed rollback window performs no later removal")
    end)

configured_runtime_test(
    "F cancellation rolls back synchronous mining reward against SetMove baseline",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(901))
        local character = ability.avatar_character
        local unrelated_character = env:new_object(
            "GothicCharacter /Game/Maps/Main.UnrelatedCharacter_901", {
                ore = 99,
            })
        character.ore = 37
        ability.mining_reward_amount = 4
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(901), ability)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        assert_equal(#env.ore_read_observations, 1,
            "SetMove captures one ore baseline")
        assert_equal(env.ore_read_observations[1].ore, 37,
            "SetMove baseline value")
        assert_equal(#env.ore_remove_observations, 0,
            "baseline capture does not mutate ore")

        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 1,
            "F dispatches one K2 mining cancellation")
        assert_equal(env.cancel_observations[1].ability, ability,
            "K2 targets the exact tracked mining ability")
        assert_false(env.cancel_observations[1].cooldown,
            "K2 observes cooldown disabled")
        assert_false(ability.m_ApplyCooldown,
            "mining cooldown remains disabled after cancellation")
        assert_equal(character.ore, 37,
            "immediate check restores the SetMove baseline")
        assert_equal(unrelated_character.ore, 99,
            "rollback never touches an unrelated character")
        assert_equal(#env.ore_remove_observations, 1,
            "synchronous reward produces one rollback request")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 0,
            "rolled-back synchronous reward is hidden from the HUD")
        assert_equal(#env.inventory_observations, 1,
            "SetMove resolves the exact player inventory once")
        assert_equal(env.inventory_observations[1], character,
            "GetInventory targets the mining avatar")

        local removal = env.ore_remove_observations[1]
        assert_equal(removal.manager, env.trader_manager,
            "RemoveCharacterOre targets GameState.m_TraderManager")
        assert_equal(removal.character, character,
            "RemoveCharacterOre targets the ability avatar")
        assert_equal(removal.amount, 4,
            "rollback removes only reward delta over baseline")
        assert_equal(env.avatar_observations[1], ability,
            "GetAvatarActorFromActorInfo targets the tracked ability")
        assert_equal(env.game_state_observations[1].cdo,
            env.gameplay_statics_cdo,
            "GetGameState targets Default__GameplayStatics")
        assert_equal(env.game_state_observations[1].world_context, character,
            "GetGameState uses the exact avatar as world context")
        assert_equal(env.ore_read_observations[1].manager,
            env.trader_manager,
            "GetCharacterOre uses GameState.m_TraderManager")
        assert_equal(env.ore_read_observations[1].character, character,
            "GetCharacterOre uses the exact avatar")
        assert_equal(#env.authority_observations, 1,
            "authority is captured with the SetMove baseline")
        for _, target in ipairs(env.authority_observations) do
            assert_equal(target, ability,
                "K2_HasAuthority targets only the tracked ability")
        end

        local rollback_delays = {}
        for _, entry in ipairs(env.delayed_callbacks) do
            rollback_delays[#rollback_delays + 1] = entry.delay
        end
        table.sort(rollback_delays)
        assert_table_values(rollback_delays, { 1, 50, 250, 1000, 1100 },
            "post-cancel rollback and HUD expiry delays")
        env:flush_delayed()
        assert_equal(character.ore, 37,
            "1/50/250/1000ms checks do not remove baseline ore")
        assert_equal(#env.ore_remove_observations, 1,
            "later checks do not repeat an already-applied rollback")
    end)

configured_runtime_test(
    "synchronous K2 move-end cleanup preserves captured mining baseline",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(908))
        ability.avatar_character.ore = 25
        ability.mining_reward_amount = 4
        ability.k2_move_end_result = 0
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(908), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        assert_equal(env.ore_read_observations[1].ore, 25,
            "baseline is captured before K2 runs")
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 1,
            "K2 executes once")
        assert_equal(ability.k2_move_end_count, 1,
            "K2 synchronously emits one non-directional move-end")
        assert_equal(ability.avatar_character.ore, 25,
            "rollback uses the pre-K2 baseline after pending invalidation")
        assert_equal(#env.ore_remove_observations, 1,
            "synchronous lifecycle cleanup does not suppress rollback")
        assert_equal(env.ore_remove_observations[1].amount, 4,
            "rollback removes the exact synchronous K2 reward")
        assert_equal(#env.delayed_callbacks, 5,
            "post-K2 checks and HUD expiry remain scheduled")
    end)

configured_runtime_test(
    "mining HUD suppression matches only the tracked inventory and ore item",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(910))
        ability.avatar_character.ore = 80
        ability.mining_reward_amount = 3
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(910), ability)
        local unrelated_inventory = env:new_object(
            "InventoryComponent /Game/Maps/Main.Main:PersistentLevel."
            .. "UnrelatedState.InventoryComponent")
        ability.before_mining_reward = function()
            assert_equal(env:emit_item_added_for_hud(
                    ability.avatar_character.inventory_component,
                    env.unrelated_item, 2),
                2, "unrelated item notification remains visible")
            assert_equal(env:emit_item_added_for_hud(
                    unrelated_inventory, env.mining_ore_item, 3),
                3, "unrelated inventory ore notification remains visible")
        end

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.avatar_character.ore, 80,
            "tracked reward is rolled back")
        assert_equal(#env.hud_item_observations, 3,
            "two unrelated and one tracked HUD event observed")
        assert_equal(env.hud_item_observations[1].displayed_amount, 2,
            "unrelated item remains visible")
        assert_equal(env.hud_item_observations[2].displayed_amount, 3,
            "other inventory remains visible")
        assert_equal(env.hud_item_observations[3].displayed_amount, 0,
            "tracked mining ore notification is single-use suppressed")
    end)

configured_runtime_test(
    "unwritable HUD count fails visibly without affecting ore rollback",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(916))
        ability.avatar_character.ore = 44
        ability.mining_reward_amount = 3
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(916), ability)
        ability.before_mining_reward = function()
            local immutable_count = {
                value = 3,
                get = function(self_value)
                    return self_value.value
                end,
                type = function()
                    return "RemoteUnrealParam"
                end,
            }
            env:invoke_hook(HOOK_ITEM_ADDED_FOR_HUD,
                env:wrap(ability.avatar_character.inventory_component),
                env:wrap(env.mining_ore_item),
                immutable_count)
            assert_equal(immutable_count.value, 3,
                "unsupported hook parameter remains unchanged")
        end

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.avatar_character.ore, 44,
            "ore rollback remains independent from HUD mutation")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 3,
            "real reward notification remains visible after safe failure")
        assert_true(contains(env.logs,
                "Could not suppress cancelled mining reward HUD "
                .. "notification"),
            "parameter mutation failure is logged")
    end)

runtime_test("normal mining reward remains visible without cancellation",
    function(env)
        local ability = env:new_ability(mining_ability_identity(911))
        ability.avatar_character.ore = 10
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(911), ability)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:credit_mining_reward(ability, 3, "normal-completion")

        assert_equal(ability.avatar_character.ore, 13,
            "normal mining reward remains credited")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 3,
            "normal mining reward remains visible")
    end)

configured_runtime_setup_test(
    "missing mining HUD hook never blocks cancellation or ore rollback",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        env.failed_hook_paths[HOOK_ITEM_ADDED_FOR_HUD] = true
    end,
    function(env)
        local ability = env:new_ability(mining_ability_identity(912))
        ability.avatar_character.ore = 14
        ability.mining_reward_amount = 3
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(912), ability)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 1,
            "missing HUD hook still cancels mining")
        assert_equal(ability.avatar_character.ore, 14,
            "missing HUD hook still rolls back ore")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 3,
            "notification remains as the safe fallback")
        assert_true(contains(env.logs,
                "OnItemAddedForHUD hook was not installed; cancelled mining "
                .. "reward notifications cannot be suppressed"),
            "missing HUD hook capability is logged")
    end)

configured_runtime_setup_test(
    "missing player inventory never blocks cancellation or ore rollback",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        env.get_character_inventory_available = false
    end,
    function(env)
        local ability = env:new_ability(mining_ability_identity(913))
        ability.avatar_character.ore = 18
        ability.mining_reward_amount = 3
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(913), ability)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 1,
            "missing inventory resolution still cancels mining")
        assert_equal(ability.avatar_character.ore, 18,
            "missing inventory resolution still rolls back ore")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 3,
            "unverified inventory notification remains visible")
        assert_true(contains(env.logs,
                "GothicCharacter:GetInventory was not found; cancelled "
                .. "mining reward notifications cannot be suppressed"),
            "missing inventory capability is logged")
    end)

configured_runtime_test(
    "delayed mining reward is removed by the bounded rollback checks",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(902))
        ability.avatar_character.ore = 12
        ability.mining_reward_amount = 5
        ability.mining_reward_delay_ms = 125
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(902), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        env:press("F")
        env:flush_game_thread()
        assert_equal(ability.cancel_count, 1,
            "delayed-reward mining still cancels through K2")
        assert_equal(ability.avatar_character.ore, 12,
            "immediate check sees no premature reward")
        assert_equal(#env.ore_remove_observations, 0,
            "immediate check removes no baseline ore")

        env:flush_delayed()
        assert_equal(#env.ore_reward_observations, 1,
            "mock engine posts one delayed mining reward")
        assert_equal(env.ore_reward_observations[1].source, "delayed",
            "reward was delivered after K2 returned")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 0,
            "delayed rolled-back reward is hidden from the HUD")
        assert_equal(ability.avatar_character.ore, 12,
            "250ms check removes the delayed reward delta")
        assert_equal(#env.ore_remove_observations, 1,
            "delayed reward produces one rollback request")
        assert_equal(env.ore_remove_observations[1].amount, 5,
            "delayed rollback removes the exact reward delta")
    end)

configured_runtime_test(
    "new FreePoint releases an older mining rollback and HUD window together",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local mining = env:new_ability(mining_ability_identity(914))
        mining.avatar_character.ore = 31
        mining.mining_reward_amount = 3
        mining.mining_reward_delay_ms = 125
        mining.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(914), mining)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(mining))
        env:press("F")
        env:flush_game_thread()

        local actor = env:new_object(interaction_actor_identity(914))
        local freepoint = env:new_freepoint_ability(
            player_freepoint_identity(914), actor)
        local freepoint_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(915), freepoint)
        observe_freepoint_factory(env, freepoint_task)
        env:flush_delayed()

        assert_equal(mining.avatar_character.ore, 34,
            "replacement leaves the delayed reward untouched")
        assert_equal(#env.ore_remove_observations, 0,
            "replacement closes the older rollback callbacks")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 3,
            "replacement also releases the older HUD suppression")
    end)

configured_runtime_test(
    "WASD never double-cancels a native move cancellation in either ore mode",
    "KeepOreOnMiningCancellation=false\nCancelKeys=W",
    function(env)
        local rolled_back = env:new_ability(mining_ability_identity(903))
        rolled_back.avatar_character.ore = 70
        rolled_back.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(903), rolled_back)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(rolled_back))

        env:credit_mining_reward(rolled_back, 3, "native-before-key")
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(rolled_back), nil,
            env:wrap("EGenericTaskResult::Cancelled"))
        assert_false(rolled_back.m_AbilityEnded,
            "native move cancellation can precede ability-ended state")
        env:press("W")
        env:flush_game_thread()

        assert_equal(rolled_back.cancel_count, 0,
            "OFF path does not dispatch a second K2 cancel")
        assert_true(rolled_back.m_ApplyCooldown,
            "OFF move-cancelled path does not mutate cooldown")
        assert_equal(rolled_back.avatar_character.ore, 70,
            "OFF path restores the pre-interaction baseline")
        assert_equal(#env.ore_remove_observations, 1,
            "OFF path removes one pre-key reward delta")
        assert_equal(env.ore_remove_observations[1].amount, 3,
            "OFF WASD rollback amount")

        assert_true(env:set_native_bool(NATIVE_MINING_SETTING_ID, true),
            "ore retention enables live for the second WASD case")
        local retained = env:new_ability(mining_ability_identity(909))
        retained.avatar_character.ore = 30
        retained.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(909), retained)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(retained))
        env:credit_mining_reward(retained, 2, "native-before-key")
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(retained), nil,
            env:wrap("EGenericTaskResult::Cancelled"))
        assert_false(retained.m_AbilityEnded,
            "ON case also remains active at the key callback")
        env:press("W")
        env:flush_game_thread()

        assert_equal(retained.cancel_count, 0,
            "ON path does not dispatch a second K2 cancel")
        assert_true(retained.m_ApplyCooldown,
            "ON move-cancelled path does not mutate cooldown")
        assert_equal(retained.avatar_character.ore, 32,
            "ON path retains the already-granted reward")
        assert_equal(#env.ore_remove_observations, 1,
            "ON path adds no rollback request")
        assert_equal(#env.cancel_observations, 0,
            "neither native move-cancelled case calls K2")
    end)

configured_runtime_test(
    "WASD movement-end reward is hidden before its rollback key edge",
    "KeepOreOnMiningCancellation=false\nCancelKeys=W",
    function(env)
        local ability = env:new_ability(mining_ability_identity(914))
        ability.avatar_character.ore = 60
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(914), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        env:invoke_hook_around(HOOK_MOVE_ENDED, function()
            env:credit_mining_reward(
                ability, 3, "inside-native-move-end")
        end, env:wrap(ability), env:wrap(ability.m_TaskMoveTo),
            env:wrap("EGenericTaskResult::Cancelled"))

        assert_equal(ability.avatar_character.ore, 63,
            "native move-end reward exists until the key callback")
        assert_equal(env.ore_reward_observations[1].displayed_amount, 0,
            "cancelled move-end reward notification is hidden")

        env:press("W")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 0,
            "directional edge does not double-cancel through K2")
        assert_equal(ability.avatar_character.ore, 60,
            "directional edge rolls the hidden reward back")
        assert_equal(#env.ore_remove_observations, 1,
            "directional edge requests one ore removal")
    end)

configured_runtime_test(
    "unused directional mining edge releases HUD suppression",
    "KeepOreOnMiningCancellation=false\nCancelKeys=W",
    function(env)
        local ability = env:new_ability(mining_ability_identity(915))
        ability.avatar_character.ore = 22
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(915), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(ability),
            env:wrap(ability.m_TaskMoveTo),
            env:wrap("EGenericTaskResult::Cancelled"))

        env:flush_delayed()
        assert_equal(env:emit_item_added_for_hud(
                ability.avatar_character.inventory_component,
                env.mining_ore_item, 3),
            3, "expired unconsumed edge leaves later ore visible")
    end)

configured_runtime_test(
    "mining cancellation with no reward delta never removes existing ore",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(904))
        ability.avatar_character.ore = 55
        ability.mining_reward_amount = 0
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(904), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()
        env:flush_delayed()

        assert_equal(ability.cancel_count, 1,
            "no-delta mining still cancels through K2")
        assert_false(ability.m_ApplyCooldown,
            "no-delta mining disables cancellation cooldown")
        assert_equal(ability.avatar_character.ore, 55,
            "existing ore remains unchanged")
        assert_equal(#env.ore_remove_observations, 0,
            "no delta issues no RemoveCharacterOre request")
    end)

configured_runtime_setup_test(
    "missing ore rollback capability never disables mining cancellation",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        env.remove_character_ore_available = false
    end,
    function(env)
        local ability = env:new_ability(mining_ability_identity(905))
        ability.avatar_character.ore = 10
        ability.mining_reward_amount = 2
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(905), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        env:press("F")
        env:flush_game_thread()
        env:flush_delayed()

        assert_equal(ability.cancel_count, 1,
            "missing rollback function still permits K2 cancellation")
        assert_false(ability.m_ApplyCooldown,
            "missing rollback function does not skip cooldown suppression")
        assert_equal(ability.avatar_character.ore, 12,
            "reward remains when RemoveCharacterOre is unavailable")
        assert_equal(#env.ore_remove_observations, 0,
            "missing function cannot mutate character ore")
        assert_true(contains(env.lookup_names, REMOVE_CHARACTER_ORE_PATH),
            "missing rollback UFunction was still looked up")
    end)

configured_runtime_test(
    "ore rollback mutates only authoritative mining ability state",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(906))
        ability.has_authority = false
        ability.avatar_character.ore = 15
        ability.mining_reward_amount = 2
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(906), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        env:press("F")
        env:flush_game_thread()
        env:flush_delayed()

        assert_equal(ability.cancel_count, 1,
            "non-authority client still performs requested K2 cancellation")
        assert_equal(ability.avatar_character.ore, 17,
            "non-authority state is never rolled back locally")
        assert_equal(#env.ore_remove_observations, 0,
            "RemoveCharacterOre is authority-only")
        assert_true(#env.authority_observations >= 1,
            "authority capability was queried")
        for _, target in ipairs(env.authority_observations) do
            assert_equal(target, ability,
                "authority checks target the exact mining ability")
        end
    end)

configured_runtime_test(
    "map generation prevents stale delayed mining rollback",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local ability = env:new_ability(mining_ability_identity(907))
        ability.avatar_character.ore = 8
        ability.mining_reward_amount = 2
        ability.mining_reward_delay_ms = 125
        ability.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(907), ability)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()

        env:load_map()
        env:flush_delayed()

        assert_equal(ability.cancel_count, 1,
            "pre-map mining cancellation already reached K2")
        assert_equal(ability.avatar_character.ore, 10,
            "mock engine reward arrives after the map generation changes")
        assert_equal(#env.ore_remove_observations, 0,
            "stale rollback callbacks cannot mutate post-map state")
    end)

configured_runtime_test(
    "conversation native setting enables live without duplicate lifecycle",
    "EnableConversationCancellation=false\nCancelKeys=F",
    function(env)
        local setting =
            env.native_bool_settings[NATIVE_CONVERSATION_SETTING_ID]
        assert_false(setting.get(), "conversation starts disabled")
        assert_false(env:has_hook(HOOK_CONVERSATION_UI),
            "conversation UI hook starts disabled")
        assert_equal(env.notifications[CONVERSATION_GROUP_CLASS], nil,
            "conversation notification starts disabled")

        assert_true(env:set_native_bool(
            NATIVE_CONVERSATION_SETTING_ID, true),
            "conversation live enable accepted")
        assert_true(setting.get(), "conversation live enabled")
        assert_equal(#env.hooks[HOOK_CONVERSATION_UI], 1,
            "conversation UI hook registered once")
        assert_equal(#env.notifications[CONVERSATION_GROUP_CLASS], 1,
            "conversation notification registered once")

        local initiator = env:new_object(player_state_identity(80))
        local first = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.NativeConversation_80",
            initiator)
        env:notify(CONVERSATION_GROUP_CLASS, first)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(first.request_end_count, 1,
            "live-enabled conversation can be cancelled")

        assert_true(env:set_native_bool(
            NATIVE_CONVERSATION_SETTING_ID, false),
            "conversation live disable accepted")
        assert_false(setting.get(), "conversation live disabled")
        local disabled = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.NativeConversation_81",
            initiator)
        env:notify(CONVERSATION_GROUP_CLASS, disabled)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(disabled.request_end_count, 0,
            "installed notification is inert while disabled")

        assert_true(env:set_native_bool(
            NATIVE_CONVERSATION_SETTING_ID, true),
            "conversation live re-enable accepted")
        assert_equal(#env.hooks[HOOK_CONVERSATION_UI], 1,
            "conversation re-enable does not duplicate UI hook")
        assert_equal(#env.notifications[CONVERSATION_GROUP_CLASS], 1,
            "conversation re-enable does not duplicate notification")

        local second = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.NativeConversation_82",
            initiator)
        env:notify(CONVERSATION_GROUP_CLASS, second)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(second.request_end_count, 1,
            "re-enabled conversation can be cancelled")
    end)

configured_runtime_test(
    "WASD native setting binds once and disables its live callback",
    "EnableWASDCancellation=false\nCancelKeys=F,W",
    function(env)
        local setting = env.native_bool_settings[NATIVE_WASD_SETTING_ID]
        assert_false(setting.get(), "WASD starts disabled")
        assert_equal(env.keybinds.W, nil, "W starts unbound")
        assert_equal(#env.keybinds.F, 1, "F starts bound once")

        assert_true(env:set_native_bool(NATIVE_WASD_SETTING_ID, true),
            "WASD live enable accepted")
        assert_true(setting.get(), "WASD live enabled")
        assert_equal(#env.keybinds.W, 1, "W registered once")
        assert_equal(#env.keybinds.F, 1,
            "WASD enable does not duplicate F")

        local enabled = env:new_ability(player_ability_identity(83))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(enabled))
        env:press("W")
        env:flush_game_thread()
        assert_equal(enabled.cancel_count, 1,
            "live-enabled W cancels interaction")

        assert_true(env:set_native_bool(NATIVE_WASD_SETTING_ID, false),
            "WASD live disable accepted")
        assert_false(setting.get(), "WASD live disabled")
        assert_equal(#env.keybinds.W, 1,
            "disabled W callback remains registered once")

        local disabled = env:new_ability(player_ability_identity(84))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(disabled))
        env:press("W")
        env:flush_game_thread()
        assert_equal(disabled.cancel_count, 0,
            "registered W callback is inert while disabled")
        env:press("F")
        env:flush_game_thread()
        assert_equal(disabled.cancel_count, 1,
            "non-WASD callback remains active")

        assert_true(env:set_native_bool(NATIVE_WASD_SETTING_ID, true),
            "WASD live re-enable accepted")
        assert_equal(#env.keybinds.W, 1,
            "WASD re-enable does not duplicate W")
        assert_equal(#env.keybinds.F, 1,
            "WASD re-enable does not duplicate F")

        local reenabled = env:new_ability(player_ability_identity(85))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(reenabled))
        env:press("W")
        env:flush_game_thread()
        assert_equal(reenabled.cancel_count, 1,
            "re-enabled W cancels interaction")
    end)

configured_runtime_test(
    "bench native setting enables and disables live FreePoint cancellation",
    "EnableBenchAndLadderCancellation=false\nCancelKeys=F",
    function(env)
        local setting =
            env.native_bool_settings[NATIVE_BENCH_SETTING_ID]
        assert_false(setting.get(), "bench cancellation starts disabled")
        assert_false(contains(env.lookup_names, FREEPOINT_QUICK_END_PATH),
            "disabled startup skips quick-end lookup")

        assert_true(env:set_native_bool(NATIVE_BENCH_SETTING_ID, true),
            "bench cancellation live enable accepted")
        assert_true(setting.get(), "bench cancellation live enabled")
        assert_true(contains(env.lookup_names, FREEPOINT_QUICK_END_PATH),
            "live enable resolves quick-end on demand")

        local actor = env:new_object(interaction_actor_identity(86))
        local enabled_blocking =
            env:new_ability(player_ability_identity(86))
        local enabled_freepoint = env:new_freepoint_ability(
            player_freepoint_identity(86), actor)
        local enabled_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(86), enabled_freepoint)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(enabled_blocking))
        observe_freepoint_factory(env, enabled_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(enabled_freepoint.quick_end_count, 1,
            "live-enabled FreePoint quick-ends")
        assert_equal(enabled_blocking.cancel_count, 0,
            "live-enabled FreePoint supersedes blocking")

        assert_true(env:set_native_bool(NATIVE_BENCH_SETTING_ID, false),
            "bench cancellation live disable accepted")
        assert_false(setting.get(), "bench cancellation live disabled")

        local disabled_blocking =
            env:new_ability(player_ability_identity(87))
        local disabled_freepoint = env:new_freepoint_ability(
            player_freepoint_identity(87), actor)
        local disabled_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(87), disabled_freepoint)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(disabled_blocking))
        observe_freepoint_factory(env, disabled_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(disabled_freepoint.quick_end_count, 0,
            "live-disabled FreePoint does not quick-end")
        assert_equal(disabled_blocking.cancel_count, 0,
            "live-disabled FreePoint blocks blocking fallback")
    end)

configured_runtime_test(
    "legacy config keeps safe feature defaults",
    "Debug=false\nCancelKeys=F,W",
    function(env)
        assert_true(type(env.keybinds.F) == "table",
            "legacy F keybind")
        assert_true(type(env.keybinds.W) == "table",
            "legacy W keybind")
        assert_true(env:has_hook(HOOK_FREEPOINT_FACTORY),
            "legacy FreePoint factory hook")
        assert_true(env:has_hook(HOOK_CONVERSATION_UI),
            "legacy conversation UI hook")
        assert_true(contains(env.lookup_names, FREEPOINT_QUICK_END_PATH),
            "legacy FreePoint quick-end lookup")
        assert_false(
            env.native_bool_settings[NATIVE_MINING_SETTING_ID].get(),
            "legacy config keeps mining ore retention disabled")
    end)

configured_runtime_test(
    "WASD setting filters movement keys without disabling other keys",
    "EnableWASDCancellation=false\n"
        .. "CancelKeys=F,W,A,RIGHT_MOUSE_BUTTON",
    function(env)
        assert_equal(env.keybinds.W, nil, "W keybind disabled")
        assert_equal(env.keybinds.A, nil, "A keybind disabled")
        assert_true(type(env.keybinds.F) == "table",
            "F keybind remains enabled")
        assert_true(type(env.keybinds.RIGHT_MOUSE_BUTTON) == "table",
            "right mouse keybind remains enabled")

        local ability = env:new_ability(player_ability_identity(70))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()
        assert_equal(ability.cancel_count, 1,
            "non-WASD key still cancels interaction")

        local native_cancelled =
            env:new_ability(player_ability_identity(71))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(native_cancelled))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(native_cancelled), nil,
            env:wrap(1))
        assert_equal(#env.delayed_callbacks, 0,
            "disabled WASD does not retain a directional input edge")
    end)

configured_runtime_test(
    "conversation setting removes conversation cancellation only",
    "EnableConversationCancellation=false\nCancelKeys=F",
    function(env)
        assert_false(env:has_hook(HOOK_CONVERSATION_UI),
            "conversation UI hook disabled")
        assert_equal(env.notifications[CONVERSATION_GROUP_CLASS], nil,
            "conversation notification disabled")

        local ability = env:new_ability(player_ability_identity(72))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()
        assert_equal(ability.cancel_count, 1,
            "interaction cancellation remains enabled")
    end)

configured_runtime_setup_test(
    "conversation notification requires the UI boundary hook",
    "EnableConversationCancellation=true\nCancelKeys=F",
    function(env)
        env.failed_hook_paths[HOOK_CONVERSATION_UI] = true
    end,
    function(env)
        assert_false(env:has_hook(HOOK_CONVERSATION_UI),
            "failed conversation UI hook stays unavailable")
        assert_equal(env.notifications[CONVERSATION_GROUP_CLASS], nil,
            "conversation notification is not installed without UI hook")
    end)

configured_runtime_setup_test(
    "missing FreePoint quick-end fails closed without blocking fallback",
    "EnableBenchAndLadderCancellation=true\nCancelKeys=F",
    function(env)
        env.freepoint_quick_end_available = false
    end,
    function(env)
        local actor = env:new_object(interaction_actor_identity(78))
        local blocking = env:new_ability(player_ability_identity(78))
        local freepoint = env:new_freepoint_ability(
            player_freepoint_identity(78), actor)
        local task = env:new_freepoint_move_task(
            freepoint_move_task_identity(78), freepoint)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(blocking))
        observe_freepoint_factory(env, task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(blocking.cancel_count, 0,
            "missing quick-end suppresses blocking fallback")
        assert_equal(freepoint.quick_end_count, 0,
            "missing quick-end cannot cancel FreePoint")
    end)

configured_runtime_test(
    "bench and ladder setting suppresses every FreePoint cancel path",
    "EnableBenchAndLadderCancellation=false\nCancelKeys=F,W",
    function(env)
        assert_false(contains(env.lookup_names, FREEPOINT_QUICK_END_PATH),
            "disabled feature skips quick-end lookup")
        assert_true(env:has_hook(HOOK_FREEPOINT_FACTORY),
            "FreePoint detection remains active")

        local actor = env:new_object(interaction_actor_identity(73))
        local blocking = env:new_ability(player_ability_identity(73))
        local freepoint = env:new_freepoint_ability(
            player_freepoint_identity(73), actor)
        local task = env:new_freepoint_move_task(
            freepoint_move_task_identity(73), freepoint)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(blocking))
        observe_freepoint_factory(env, task)
        local conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.FreePointDisabled_73",
            env:new_object(player_state_identity(73)))
        env:notify(CONVERSATION_GROUP_CLASS, conversation)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(blocking.cancel_count, 0,
            "disabled FreePoint supersedes blocking fallback")
        assert_equal(freepoint.quick_end_count, 0,
            "disabled FreePoint does not quick-end")
        assert_equal(conversation.request_end_count, 1,
            "disabled FreePoint does not block conversation cancellation")

        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(task), nil, env:wrap(1))
        assert_equal(#env.delayed_callbacks, 0,
            "disabled FreePoint does not retain a directional edge")
        env:press("W")
        env:flush_game_thread()
        assert_equal(blocking.cancel_count, 0,
            "cancelled alignment cannot reopen blocking fallback")
        assert_equal(freepoint.quick_end_count, 0,
            "cancelled alignment cannot reopen quick-end")

        local queued_blocking =
            env:new_ability(player_ability_identity(74))
        local queued_freepoint = env:new_freepoint_ability(
            player_freepoint_identity(74), actor)
        local queued_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(74), queued_freepoint)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(queued_blocking))
        env:press("F")
        observe_freepoint_factory(env, queued_task)
        env:flush_game_thread()
        assert_equal(queued_blocking.cancel_count, 0,
            "FreePoint detection invalidates a queued blocking cancel")
        assert_equal(queued_freepoint.quick_end_count, 0,
            "queued disabled FreePoint does not quick-end")

        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(queued_task), nil, env:wrap(0))

        local delayed_blocking =
            env:new_ability(player_ability_identity(75))
        local delayed_freepoint = env:new_freepoint_ability(
            player_freepoint_identity(75), actor)
        local delayed_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(75), nil)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(delayed_blocking))
        env:notify(FREEPOINT_MOVE_TASK_CLASS, delayed_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(delayed_blocking.cancel_count, 0,
            "unresolved FreePoint notification closes the race window")

        assert_equal(#env.delayed_callbacks, 1,
            "unresolved task has an initial owner check")
        local initial_owner_check = table.remove(env.delayed_callbacks, 1)
        assert_equal(initial_owner_check.delay, 1,
            "initial owner check uses the narrow delay")
        initial_owner_check.callback()
        assert_equal(#env.delayed_callbacks, 1,
            "still-unresolved task has a bounded final check")
        assert_equal(env.delayed_callbacks[1].delay, 100,
            "final owner check uses the bounded timeout")

        delayed_task.Ability = delayed_freepoint
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(delayed_blocking.cancel_count, 0,
            "notification fallback supersedes blocking")
        assert_equal(delayed_freepoint.quick_end_count, 0,
            "notification fallback remains disabled")
        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(delayed_task), nil, env:wrap(0))

        local stuck_blocking =
            env:new_ability(player_ability_identity(76))
        local stuck_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(76), nil)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(stuck_blocking))
        env:notify(FREEPOINT_MOVE_TASK_CLASS, stuck_task)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(stuck_blocking.cancel_count, 0,
            "owner timeout closes the potential blocking fallback")

        local normal = env:new_ability(player_ability_identity(77))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(normal))
        env:press("F")
        env:flush_game_thread()
        assert_equal(normal.cancel_count, 1,
            "ordinary interaction cancellation remains enabled")
    end)

configured_runtime_test(
    "all native options can be false without disabling ordinary cancellation",
    "EnableBenchAndLadderCancellation=false\n"
        .. "EnableConversationCancellation=false\n"
        .. "EnableWASDCancellation=false\n"
        .. "KeepOreOnMiningCancellation=false\n"
        .. "CancelKeys=F,W",
    function(env)
        assert_true(type(env.keybinds.F) == "table",
            "ordinary cancel key remains registered")
        assert_equal(env.keybinds.W, nil,
            "WASD key is not registered")
        assert_false(env:has_hook(HOOK_CONVERSATION_UI),
            "conversation hook is not registered")
        assert_equal(env.notifications[CONVERSATION_GROUP_CLASS], nil,
            "conversation notification is not registered")

        local ability = env:new_ability(player_ability_identity(76))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()
        assert_equal(ability.cancel_count, 1,
            "ordinary cancellation still works")

        local mining = env:new_ability(mining_ability_identity(79))
        local mining_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(79), mining)
        mining.m_TaskMoveTo = mining_task
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(mining))
        env:press("F")
        env:flush_game_thread()
        assert_equal(mining.cancel_count, 1,
            "false reward option still cancels mining through K2")
        assert_equal(mining.avatar_character.ore, 0,
            "false reward option rolls ore back to its baseline")
        assert_false(mining.m_ApplyCooldown,
            "mining cancellation disables cooldown")
    end)

runtime_test(
    "player interaction tracks while NPC is ignored and mining rolls back "
        .. "ore by default",
    function(env)
        local player = env:new_ability(player_ability_identity(1))
        local npc = env:new_ability(npc_ability_identity(2))

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(player))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(npc))
        env:press("F")
        env:flush_game_thread()

        assert_equal(#env.cancel_observations, 1,
            "NPC event preserves tracked player interaction")
        assert_equal(env.cancel_observations[1].ability, player,
            "player interaction cancelled")
        assert_equal(npc.cancel_count, 0, "NPC interaction not cancelled")

        local next_player = env:new_ability(player_ability_identity(3))
        local mining = env:new_ability(mining_ability_identity(4))
        local mining_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(4), mining)
        mining.m_TaskMoveTo = mining_task
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(next_player))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(mining))
        env:press("R")
        env:flush_game_thread()

        assert_equal(#env.cancel_observations, 2,
            "default mining path adds one K2 cancellation")
        assert_equal(next_player.cancel_count, 0,
            "new mining interaction replaces the earlier player interaction")
        assert_equal(mining.cancel_count, 1,
            "default mining route dispatches K2")
        assert_equal(mining.avatar_character.ore, 0,
            "default mining route removes only its reward delta")
        assert_false(mining.m_ApplyCooldown,
            "default mining route disables cooldown")
    end)

configured_runtime_test(
    "mining FreePoint preserves active pending and recent mining blocking",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F,W",
    function(env)
        local active = env:new_ability(mining_ability_identity(91))
        local active_freepoint, active_task =
            new_mining_freepoint(env, 91)
        active.m_TaskMoveTo = active_task
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(active))
        observe_freepoint_factory(env, active_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(active.cancel_count, 1,
            "active mining record receives K2 cancellation")
        assert_equal(active.avatar_character.ore, 0,
            "active mining reward is rolled back")
        assert_equal(active_freepoint.quick_end_count, 0,
            "active mining FreePoint never quick-ends")

        local pending = env:new_ability(mining_ability_identity(92))
        local pending_freepoint, pending_task =
            new_mining_freepoint(env, 92)
        pending.m_TaskMoveTo = pending_task
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(pending))
        env:press("F")
        observe_freepoint_factory(env, pending_task)
        env:flush_game_thread()
        assert_equal(pending.cancel_count, 1,
            "queued mining record receives K2 cancellation")
        assert_equal(pending.avatar_character.ore, 0,
            "queued mining reward is rolled back")
        assert_equal(pending_freepoint.quick_end_count, 0,
            "pending mining FreePoint never quick-ends")

        local recent = env:new_ability(mining_ability_identity(93))
        local recent_freepoint, recent_task =
            new_mining_freepoint(env, 93)
        recent.m_TaskMoveTo = recent_task
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(recent))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(recent), nil,
            env:wrap("EGenericTaskResult::Cancelled"))
        observe_freepoint_factory(env, recent_task)
        env:press("W")
        env:flush_game_thread()
        assert_equal(recent.cancel_count, 0,
            "directional mining edge does not duplicate native cancellation")
        assert_equal(recent.avatar_character.ore, 0,
            "directional mining edge preserves a zero-delta baseline")
        assert_equal(recent_freepoint.quick_end_count, 0,
            "recent mining FreePoint never quick-ends")
        assert_equal(#env.cancel_observations, 2,
            "only active and queued mining records require K2")
    end)

configured_runtime_test(
    "unresolved FreePoint observation preserves mining blocking",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local during_initialization =
            env:new_ability(mining_ability_identity(991))
        local unresolved_during = env:new_freepoint_move_task(
            freepoint_move_task_identity(991), nil)
        during_initialization.m_TaskMoveTo = unresolved_during
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(during_initialization))
        env:notify(FREEPOINT_MOVE_TASK_CLASS, unresolved_during)
        env:press("F")
        env:flush_game_thread()
        assert_equal(during_initialization.cancel_count, 1,
            "unresolved owner cannot suppress a verified mining record")
        assert_equal(env.cancel_observations[1].ability,
            during_initialization,
            "K2 targets the verified mining ability")

        env:flush_delayed()

        local after_timeout = env:new_ability(mining_ability_identity(992))
        local unresolved_timeout = env:new_freepoint_move_task(
            freepoint_move_task_identity(992), nil)
        after_timeout.m_TaskMoveTo = unresolved_timeout
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(after_timeout))
        env:notify(FREEPOINT_MOVE_TASK_CLASS, unresolved_timeout)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(after_timeout.cancel_count, 1,
            "owner timeout cannot clear a verified mining record")
    end)

configured_runtime_test(
    "verified mining survives an unrelated ownerless FreePoint task",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F",
    function(env)
        local mining = env:new_ability(mining_ability_identity(993))
        mining.m_TaskMoveTo = env:new_freepoint_move_task(
            freepoint_move_task_identity(993), mining)

        local actor = env:new_object(interaction_actor_identity(993))
        local freepoint = env:new_freepoint_ability(
            player_freepoint_identity(993), actor)
        local unrelated_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(994), nil)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(mining))
        env:notify(FREEPOINT_MOVE_TASK_CLASS, unrelated_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(mining.cancel_count, 1,
            "verified mining record survives ownerless task observation")
        assert_equal(env.cancel_observations[1].ability, mining,
            "K2 targets the exact verified mining ability")

        unrelated_task.Ability = freepoint
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(mining.cancel_count, 1,
            "consumed mining record is not cancelled twice")
        assert_equal(freepoint.quick_end_count, 1,
            "resolved normal FreePoint keeps its own quick-end path")
    end)

configured_runtime_test(
    "mining FreePoint clears active pending and recent normal blocking",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F,W",
    function(env)
        local active = env:new_ability(player_ability_identity(94))
        local active_freepoint, active_task =
            new_mining_freepoint(env, 94)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(active))
        observe_freepoint_factory(env, active_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(active.cancel_count, 0,
            "mining FreePoint clears an active normal blocking record")
        assert_equal(active_freepoint.quick_end_count, 0,
            "active foreign case never quick-ends mining FreePoint")

        local pending = env:new_ability(player_ability_identity(95))
        local pending_freepoint, pending_task =
            new_mining_freepoint(env, 95)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(pending))
        env:press("F")
        observe_freepoint_factory(env, pending_task)
        env:flush_game_thread()
        assert_equal(pending.cancel_count, 0,
            "mining FreePoint invalidates queued normal blocking cancel")
        assert_equal(pending_freepoint.quick_end_count, 0,
            "pending foreign case never quick-ends mining FreePoint")

        local recent = env:new_ability(player_ability_identity(96))
        local recent_freepoint, recent_task =
            new_mining_freepoint(env, 96)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(recent))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(recent), nil,
            env:wrap("EGenericTaskResult::Cancelled"))
        observe_freepoint_factory(env, recent_task)
        env:press("W")
        env:flush_game_thread()
        assert_equal(recent.cancel_count, 0,
            "mining FreePoint clears a recent normal blocking edge")
        assert_equal(recent_freepoint.quick_end_count, 0,
            "recent foreign case never quick-ends mining FreePoint")
    end)

configured_runtime_test(
    "mining FreePoint alone remains excluded",
    "KeepOreOnMiningCancellation=false\nCancelKeys=F,W",
    function(env)
        local freepoint, task = new_mining_freepoint(env, 97)
        observe_freepoint_factory(env, task)
        env:press("F")
        env:press("W")
        env:flush_game_thread()
        assert_equal(freepoint.quick_end_count, 0,
            "unpaired mining FreePoint never quick-ends")
        assert_equal(#env.cancel_observations, 0,
            "unpaired mining FreePoint schedules no K2 cancel")
    end)

configured_runtime_test(
    "mining blocking can track after an earlier mining FreePoint",
    "KeepOreOnMiningCancellation=true\nCancelKeys=F",
    function(env)
        local freepoint, task = new_mining_freepoint(env, 98)
        observe_freepoint_factory(env, task)

        local blocking = env:new_ability(mining_ability_identity(98))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(blocking))
        env:press("F")
        env:flush_game_thread()
        assert_equal(blocking.cancel_count, 1,
            "later mining blocking record is cancellable")
        assert_equal(freepoint.quick_end_count, 0,
            "earlier mining FreePoint remains excluded")
    end)

runtime_test("only the exact move-end identity clears the tracked ability",
    function(env)
        local tracked = env:new_ability(player_ability_identity(10))
        local foreign = env:new_ability(player_ability_identity(11))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(tracked))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(foreign))
        env:press("F")
        env:flush_game_thread()
        assert_equal(tracked.cancel_count, 1,
            "foreign end event does not clear tracked ability")

        local second = env:new_ability(player_ability_identity(12))
        local same_identity = env:new_ability(player_ability_identity(12))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(second))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(same_identity))
        env:press("F")
        env:flush_game_thread()
        assert_equal(second.cancel_count, 0,
            "matching end identity clears tracked ability")
        assert_equal(#env.cancel_observations, 1,
            "no cancel scheduled after exact end cleanup")
    end)

runtime_test("move completion invalidates a queued interaction cancel",
    function(env)
        local ability = env:new_ability(player_ability_identity(13))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(ability), nil, 0)
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 0,
            "move completion before game-thread execution blocks K2 cancel")
    end)

runtime_test("W cancels when the native cancelled result arrives first",
    function(env)
        local ability = env:new_ability(player_ability_identity(14))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(ability), nil,
            env:wrap(1))
        assert_equal(#env.delayed_callbacks, 1,
            "cancelled result schedules one bounded edge")
        assert_equal(env.delayed_callbacks[1].delay, 50,
            "directional input edge duration")
        env:press("W")
        env:flush_game_thread()
        env:flush_delayed()

        assert_equal(ability.cancel_count, 1,
            "cancelled move keeps a short directional input edge")
    end)

runtime_test("W survives a native cancelled result after its key callback",
    function(env)
        local ability = env:new_ability(player_ability_identity(15))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))

        env:press("W")
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(ability), nil,
            env:wrap("EGenericTaskResult::Cancelled"))
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 1,
            "pending directional cancel survives the cancelled result")
    end)

runtime_test("successful arrival and an expired edge are not cancellable",
    function(env)
        local arrived = env:new_ability(player_ability_identity(16))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(arrived))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(arrived), nil, 0)
        env:press("W")
        env:flush_game_thread()
        assert_equal(arrived.cancel_count, 0,
            "successful arrival closes the window immediately")

        local expired = env:new_ability(player_ability_identity(17))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(expired))
        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(expired), nil, 1)
        env:flush_delayed()
        env:press("W")
        env:flush_game_thread()
        assert_equal(expired.cancel_count, 0,
            "cancelled-result edge expires before a later movement press")
    end)

runtime_test("later conversation request preserves interaction cleanup",
    function(env)
        local ability = env:new_ability(player_ability_identity(18))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("W")

        local initiator = env:new_object(player_state_identity(18))
        local conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.PendingCategories_1",
            initiator)
        env:notify(CONVERSATION_GROUP_CLASS, conversation)
        env:flush_delayed()
        env:press("F")

        env:invoke_hook(HOOK_MOVE_ENDED, env:wrap(ability), nil, 0)
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 0,
            "move completion still invalidates the older queued cancel")
        assert_equal(conversation.request_end_count, 1,
            "later conversation request remains independent")
    end)

runtime_test("FreePoint factory supersedes blocking with quick end",
    function(env)
        local blocking = env:new_ability(player_ability_identity(50))
        local actor = env:new_object(interaction_actor_identity(50))
        local ability = env:new_freepoint_ability(
            player_freepoint_identity(50), actor)
        local task = env:new_freepoint_move_task(
            freepoint_move_task_identity(50), ability)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(blocking))
        env:notify(FREEPOINT_MOVE_TASK_CLASS, task)
        observe_freepoint_factory(env, task)
        env:press("F")
        env:flush_game_thread()
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.quick_end_count, 1,
            "factory and notification produce one quick end")
        assert_equal(blocking.cancel_count, 0,
            "blocking record cannot reappear after FreePoint cancel")
        assert_equal(#env.freepoint_end_calls, 1,
            "one reflected quick-end call")
    end)

runtime_test("FreePoint WASD works in both lifecycle orders",
    function(env)
        local actor = env:new_object(interaction_actor_identity(51))
        local ended_first = env:new_freepoint_ability(
            player_freepoint_identity(51), actor)
        local ended_first_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(51), ended_first)
        observe_freepoint_factory(env, ended_first_task)

        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(ended_first_task), nil, env:wrap(1))
        local blocking_restart =
            env:new_ability(player_ability_identity(51))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(blocking_restart))
        env:press("W")
        env:flush_game_thread()
        assert_equal(ended_first.quick_end_count, 1,
            "alignment-cancelled-first order quick-ends")
        assert_equal(blocking_restart.cancel_count, 0,
            "blocking restart cannot replace FreePoint input edge")

        local key_first = env:new_freepoint_ability(
            player_freepoint_identity(52), actor)
        local key_first_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(52), key_first)
        observe_freepoint_factory(env, key_first_task)

        env:press("A")
        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(key_first_task), nil,
            env:wrap("EGenericTaskResult::Cancelled"))
        env:flush_game_thread()
        assert_equal(key_first.quick_end_count, 1,
            "key-first order survives cancelled alignment")
        assert_equal(#env.freepoint_end_calls, 2,
            "each FreePoint approach quick-ends once")
    end)

runtime_test("FreePoint arrival and animation handoff are fail-closed",
    function(env)
        local actor = env:new_object(interaction_actor_identity(53))
        local arrived = env:new_freepoint_ability(
            player_freepoint_identity(53), actor)
        local arrived_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(53), arrived)
        observe_freepoint_factory(env, arrived_task)
        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(arrived_task), nil, env:wrap(0))
        env:press("W")
        env:flush_game_thread()
        assert_equal(arrived.quick_end_count, 0,
            "successful alignment closes FreePoint window")

        local queued = env:new_freepoint_ability(
            player_freepoint_identity(61), actor)
        local queued_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(61), queued)
        observe_freepoint_factory(env, queued_task)
        env:press("W")
        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(queued_task), nil, env:wrap(0))
        env:flush_game_thread()
        assert_equal(queued.quick_end_count, 0,
            "successful alignment invalidates queued quick end")

        local ready = env:new_freepoint_ability(
            player_freepoint_identity(54), actor)
        local ready_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(54), ready)
        observe_freepoint_factory(env, ready_task)
        ready_task.bIsReadyToStartAnimation = true
        env:press("W")
        env:flush_game_thread()
        assert_equal(ready.quick_end_count, 0,
            "animation-ready task cannot be mod-cancelled")
        ready_task.bIsReadyToStartAnimation = false
        env:press("W")
        env:flush_game_thread()
        assert_equal(ready.quick_end_count, 0,
            "failed handoff cancel remains consumed")
    end)

runtime_test("FreePoint notification waits for owner and cannot reopen",
    function(env)
        local actor = env:new_object(interaction_actor_identity(55))
        local ability = env:new_freepoint_ability(
            player_freepoint_identity(55), actor)
        local delayed_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(55), nil)
        env:notify(FREEPOINT_MOVE_TASK_CLASS, delayed_task)
        delayed_task.Ability = ability
        env:flush_delayed()
        env:press("D")
        env:flush_game_thread()
        assert_equal(ability.quick_end_count, 1,
            "delayed notification tracks initialized owner")

        local finished_ability = env:new_freepoint_ability(
            player_freepoint_identity(56), actor)
        local finished_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(56), nil)
        env:notify(FREEPOINT_MOVE_TASK_CLASS, finished_task)
        env:invoke_hook(HOOK_FREEPOINT_ALIGNMENT,
            env:wrap(finished_task), nil, env:wrap(0))
        finished_task.Ability = finished_ability
        env:flush_delayed()
        env:press("W")
        env:flush_game_thread()
        assert_equal(finished_ability.quick_end_count, 0,
            "finished tombstone blocks delayed window reopening")
    end)

runtime_test("FreePoint ignores NPCs and preserves mining exclusion",
    function(env)
        local blocking = env:new_ability(player_ability_identity(57))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(blocking))

        local actor = env:new_object(interaction_actor_identity(57))
        local npc = env:new_freepoint_ability(
            npc_freepoint_identity(57), actor)
        local npc_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(57), npc)
        observe_freepoint_factory(env, npc_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(blocking.cancel_count, 1,
            "NPC task does not replace player blocking interaction")
        assert_equal(npc.quick_end_count, 0, "NPC FreePoint ignored")

        local next_blocking = env:new_ability(player_ability_identity(58))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(next_blocking))
        local mining_actor = env:new_object(mining_actor_identity(58))
        local mining = env:new_freepoint_ability(
            player_freepoint_identity(58), mining_actor)
        local mining_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(58), mining)
        observe_freepoint_factory(env, mining_task)
        env:press("F")
        env:flush_game_thread()
        assert_equal(next_blocking.cancel_count, 0,
            "mining FreePoint clears blocking cancel window")
        assert_equal(mining.quick_end_count, 0,
            "mining FreePoint never quick-ends")
    end)

runtime_test("FreePoint final end single-use and map cleanup are exact",
    function(env)
        local actor = env:new_object(interaction_actor_identity(59))
        local ended = env:new_freepoint_ability(
            player_freepoint_identity(59), actor)
        local ended_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(59), ended)
        observe_freepoint_factory(env, ended_task)
        env:invoke_hook(HOOK_FREEPOINT_ENDED, env:wrap(ended),
            env:wrap(ended.RootInteractionTask), env:wrap(0))
        env:press("W")
        env:flush_game_thread()
        assert_equal(ended.quick_end_count, 0,
            "exact final end closes FreePoint window")

        local unrelated = env:new_freepoint_ability(
            player_freepoint_identity(63), actor)
        unrelated.RootInteractionTask = nil
        local unrelated_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(63), unrelated)
        observe_freepoint_factory(env, unrelated_task)
        env:invoke_hook(HOOK_FREEPOINT_ENDED, env:wrap(unrelated),
            env:wrap(env:new_object(
                "AbilityTaskGeneric /Game/Maps/Main.UnrelatedTask_63")),
            env:wrap(0))
        env:press("W")
        env:flush_game_thread()
        assert_equal(unrelated.quick_end_count, 1,
            "unrelated final task cannot clear FreePoint window")

        local pending = env:new_freepoint_ability(
            player_freepoint_identity(60), actor)
        local pending_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(60), pending)
        observe_freepoint_factory(env, pending_task)
        env:press("W")
        env:press("A")

        local delayed = env:new_freepoint_ability(
            player_freepoint_identity(62), actor)
        local delayed_task = env:new_freepoint_move_task(
            freepoint_move_task_identity(62), nil)
        env:notify(FREEPOINT_MOVE_TASK_CLASS, delayed_task)
        env:load_map()
        delayed_task.Ability = delayed
        env:flush_delayed()
        env:flush_game_thread()
        assert_equal(pending.quick_end_count, 0,
            "map reset invalidates queued FreePoint cancel")
        env:press("W")
        env:flush_game_thread()
        assert_equal(delayed.quick_end_count, 0,
            "map reset invalidates delayed FreePoint discovery")
    end)

runtime_test("conversation tracking is delayed player-only and UI-race safe",
    function(env)
        local npc_initiator =
            env:new_object(npc_state_identity(1))
        local npc_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.NPCConversation_1",
            npc_initiator)
        env:notify(CONVERSATION_GROUP_CLASS, npc_conversation)
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(npc_conversation.request_end_count, 0,
            "NPC conversation ignored")

        local player_initiator =
            env:new_object(player_state_identity(1))
        local raced_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.RacedConversation_1",
            player_initiator)
        env:notify(CONVERSATION_GROUP_CLASS, raced_conversation)
        env:invoke_hook(HOOK_CONVERSATION_UI,
            env:wrap(env:new_object("ConversationAbility /Game/UI.Race", {
                ConversationGroup = raced_conversation,
            })))
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(raced_conversation.request_end_count, 0,
            "UI-before-delay race cannot reopen cancel window")

        local unreadable_group_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.UnreadableUIGroup_1",
            player_initiator)
        env:notify(CONVERSATION_GROUP_CLASS, unreadable_group_conversation)
        env:invoke_hook(HOOK_CONVERSATION_UI,
            env:wrap(env:new_object(
                "ConversationAbility /Game/UI.UnreadableGroup")))
        env:flush_delayed()
        env:press("F")
        env:flush_game_thread()
        assert_equal(unreadable_group_conversation.request_end_count, 0,
            "UI event invalidates delayed groups when its group is unreadable")

        local visible_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.VisibleConversation_1",
            player_initiator)
        env:notify(CONVERSATION_GROUP_CLASS, visible_conversation)
        env:flush_delayed()
        env:invoke_hook(HOOK_CONVERSATION_UI,
            env:wrap(env:new_object("ConversationAbility /Game/UI.Visible", {
                ConversationGroup = visible_conversation,
            })))
        env:press("F")
        env:flush_game_thread()
        assert_equal(visible_conversation.request_end_count, 0,
            "visible conversation is no longer cancellable")

        local cancellable_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.CancellableConversation_1",
            player_initiator)
        env:notify(CONVERSATION_GROUP_CLASS, cancellable_conversation)
        env:press("F")
        env:flush_game_thread()
        assert_equal(cancellable_conversation.request_end_count, 0,
            "conversation is not tracked before delayed player check")
        env:flush_delayed()
        env:press("R")
        env:flush_game_thread()
        assert_equal(cancellable_conversation.request_end_count, 1,
            "player conversation requests early end")
    end)

runtime_test("cancel consumes ability and conversation exactly once",
    function(env)
        local ability = env:new_ability(player_ability_identity(20))
        local initiator = env:new_object(player_state_identity(2))
        local conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.SingleShotConversation_1",
            initiator)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:notify(CONVERSATION_GROUP_CLASS, conversation)
        env:flush_delayed()

        env:press("F")
        env:press("R")
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 1,
            "ability cancel is single-shot")
        assert_equal(conversation.request_end_count, 1,
            "conversation end is single-shot")

        env:press("R")
        env:flush_game_thread()
        assert_equal(ability.cancel_count, 1,
            "consumed ability is not cancelled twice")
        assert_equal(conversation.request_end_count, 1,
            "consumed conversation is not ended twice")
    end)

runtime_test("captured objects are revalidated before cancellation",
    function(env)
        local ability = env:new_ability(player_ability_identity(21))
        local initiator = env:new_object(player_state_identity(21))
        local conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.InvalidBeforeCancel_1",
            initiator)

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:notify(CONVERSATION_GROUP_CLASS, conversation)
        env:flush_delayed()
        ability.valid = false
        conversation.valid = false

        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 0,
            "invalid ability is not passed to K2")
        assert_equal(conversation.request_end_count, 0,
            "invalid conversation is not ended")
    end)

runtime_test("ability cooldown is disabled before K2 cancel", function(env)
    local ability = env:new_ability(player_ability_identity(30))
    assert_true(ability.m_ApplyCooldown, "ability starts with cooldown")

    env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
    env:press("ESCAPE")
    env:flush_game_thread()

    assert_equal(#env.cancel_observations, 1, "one K2 cancel call")
    assert_false(env.cancel_observations[1].cooldown,
        "m_ApplyCooldown observed false by K2")
    assert_false(ability.m_ApplyCooldown,
        "m_ApplyCooldown property changed before cancel")
end)

runtime_test("ability cancel fails closed when cooldown cannot be disabled",
    function(env)
        local ability = env:new_ability(player_ability_identity(31))
        ability.m_ApplyCooldown = nil
        setmetatable(ability, {
            __newindex = function(target, key, value)
                if key == "m_ApplyCooldown" then
                    error("property is not writable")
                end
                rawset(target, key, value)
            end,
        })

        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 0,
            "K2 cancel is skipped when cooldown cannot be disabled")
        assert_equal(#env.cancel_observations, 0,
            "no K2 call is observed after property failure")
    end)

runtime_test("player conversation uses RequestEndConversation", function(env)
    local initiator = env:new_object(player_state_identity(3))
    local conversation = env:new_conversation(
        "ConversationGroup /Game/Maps/Main.RequestEndConversation_1",
        initiator)

    env:notify(CONVERSATION_GROUP_CLASS, conversation)
    env:flush_delayed()
    env:press("A")
    env:flush_game_thread()

    assert_equal(conversation.request_end_count, 1,
        "RequestEndConversation call count")
    assert_equal(env.conversation_end_calls[1], conversation,
        "RequestEndConversation target")
end)

runtime_test("map generation invalidates queued and delayed stale work",
    function(env)
        local ability = env:new_ability(player_ability_identity(40))
        local initiator = env:new_object(player_state_identity(4))
        local tracked_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.TrackedBeforeMap_1",
            initiator)
        local pending_conversation = env:new_conversation(
            "ConversationGroup /Game/Maps/Main.PendingBeforeMap_1",
            initiator)

        env:notify(CONVERSATION_GROUP_CLASS, tracked_conversation)
        env:flush_delayed()
        env:notify(CONVERSATION_GROUP_CLASS, pending_conversation)
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(ability))
        env:press("F")

        env:load_map()
        env:flush_delayed()
        env:flush_game_thread()

        assert_equal(ability.cancel_count, 0,
            "queued pre-map ability callback discarded")
        assert_equal(tracked_conversation.request_end_count, 0,
            "queued pre-map conversation callback discarded")

        env:press("F")
        env:flush_game_thread()
        assert_equal(pending_conversation.request_end_count, 0,
            "delayed pre-map conversation cannot become active")

        local current_ability =
            env:new_ability(player_ability_identity(41))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(current_ability))
        env:press("F")
        env:flush_game_thread()
        assert_equal(current_ability.cancel_count, 1,
            "current map callbacks still execute")
    end)

local failures = {}
for _, current_test in ipairs(tests) do
    local ok, test_error =
        xpcall(current_test.callback, debug.traceback)
    if ok then
        io.write("PASS ", current_test.name, "\n")
    else
        failures[#failures + 1] = {
            name = current_test.name,
            message = test_error,
        }
        io.write("FAIL ", current_test.name, "\n")
    end
end

if #failures > 0 then
    io.write("\n")
    for _, failure in ipairs(failures) do
        io.write(failure.name, "\n", tostring(failure.message), "\n\n")
    end
    error(string.format("%d/%d tests failed", #failures, #tests))
end

print(string.format(
    "g1r_cancel_interaction_core.test.lua: PASS (%d tests)", #tests))
