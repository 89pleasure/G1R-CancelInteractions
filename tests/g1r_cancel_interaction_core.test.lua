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
    assert_table_values(config.cancel_keys, DEFAULT_CANCEL_KEYS,
        "config default keys")
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
    assert_equal(mining.action, "clear", "mining classification")
    assert_true(type(mining.reason) == "string" and mining.reason ~= "",
        "mining classification reason")

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
local FREEPOINT_MOVE_TASK_CLASS =
    "/Script/G1R.AbilityTask_MoveIntoPositionForInteraction"
local CONVERSATION_GROUP_CLASS = "/Script/G1R.ConversationGroup"
local K2_CANCEL_PATH =
    "/Script/GameplayAbilities.GameplayAbility:K2_CancelAbility"
local FREEPOINT_QUICK_END_PATH =
    "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndQuick"

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
        freepoint_end_calls = {},
        conversation_end_calls = {},
        config_text = nil,
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

    self.k2_cancel_function = setmetatable({
        valid = true,
        IsValid = function()
            return true
        end,
        GetFullName = function()
            return "Function " .. K2_CANCEL_PATH
        end,
    }, {
        __call = function(_, ability)
            return self:record_cancel(self:unwrap(ability))
        end,
    })
    self.k2_cancel_function.Call = function(_, ability)
        return self:record_cancel(self:unwrap(ability))
    end
    self.k2_cancel_function.call = self.k2_cancel_function.Call

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
    return true
end

function RuntimeEnv:record_freepoint_end(ability)
    if ability == nil then return false end
    self.freepoint_end_calls[#self.freepoint_end_calls + 1] = ability
    ability.quick_end_count = (ability.quick_end_count or 0) + 1
    ability.bEndRequested = true
    return true
end

function RuntimeEnv:find_object(name)
    self.lookup_names[#self.lookup_names + 1] = tostring(name)
    if string.find(tostring(name), "K2_CancelAbility", 1, true) ~= nil then
        return self.k2_cancel_function
    end
    if string.find(tostring(name), "OnRequestEndQuick", 1, true) ~= nil then
        return self.freepoint_quick_end_function
    end
    return self.generic_function
end

function RuntimeEnv:capture_hook(path, pre_hook, post_hook)
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
        return pcall(callback,
            unpack_values(callback_args, 1, callback_args.n))
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
    local ability = self:new_object(identity, {
        m_ApplyCooldown = true,
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

local function runtime_test(name, callback)
    test(name, function()
        local env = RuntimeEnv.new()
        local ok, runtime_error = xpcall(function()
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

local function observe_freepoint_factory(env, task)
    env:invoke_hook(HOOK_FREEPOINT_FACTORY,
        env:wrap(env.generic_function),
        env:wrap(env:new_object("Vector /Script/CoreUObject.MockVector")),
        env:wrap(task))
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

        for _, key_name in ipairs(DEFAULT_CANCEL_KEYS) do
            assert_true(type(env.keybinds[key_name]) == "table"
                    and #env.keybinds[key_name] > 0,
                "default keybind " .. key_name)
        end
    end)

runtime_test("player interaction tracks while NPC is ignored and mining clears",
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
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(next_player))
        env:invoke_hook(HOOK_SET_MOVE, env:wrap(mining))
        env:press("R")
        env:flush_game_thread()

        assert_equal(#env.cancel_observations, 1,
            "mining event clears the cancel window")
        assert_equal(next_player.cancel_count, 0,
            "player interaction cleared by mining exclusion")
        assert_equal(mining.cancel_count, 0, "mining never cancelled")
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
