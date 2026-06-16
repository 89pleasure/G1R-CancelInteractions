local ModRuntime = {}
ModRuntime.__index = ModRuntime

local DEFAULT_REFLECTED_METHOD_PATHS = {
    EndTaskAsCancelled = {
        "/Script/G1R.AbilityTaskGeneric:EndTaskAsCancelled",
    },
    BP_ExternalCancel = {
        "/Script/G1R.AbilityTaskGeneric:BP_ExternalCancel",
    },
    EndTaskWithResult = {
        "/Script/G1R.AbilityTaskGeneric:EndTaskWithResult",
    },
    EndTask = {
        "/Script/GameplayTasks.GameplayTask:EndTask",
    },
    OnRequestEndQuick = {
        "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndQuick",
    },
    OnRequestEndNormal = {
        "/Script/G1R.GameplayAbilityInteractFreePoint:OnRequestEndNormal",
    },
    K2_CancelAbility = {
        "/Script/GameplayAbilities.GameplayAbility:K2_CancelAbility",
    },
    SetRequestedMovementAction = {
        "/Script/G1R.DataModule_Locomotion:SetRequestedMovementAction",
    },
    Server_SetRequestedMovementAction = {
        "/Script/G1R.DataModule_Locomotion:Server_SetRequestedMovementAction",
    },
    BP_IsFinished = {
        "/Script/G1R.AbilityTaskBase:BP_IsFinished",
    },
    StopMovement = {
        "/Script/Engine.Controller:StopMovement",
    },
    GetPlayerController = {
        "/Script/Engine.PlayerState:GetPlayerController",
    },
}

local GOTHIC_INPUT_CONFIG_ACTION_PROPERTIES = {
    "NativeInputActions",
    "AbilityInputActionsPress",
    "AbilityInputActionsRelease",
    "AbilityInputActionsToggle",
    "GameplayEventInputActions",
    "AddInputContextActions",
}
local GOTHIC_INPUT_CONFIG_ACTION_NEEDLES = {
    "Jump", "Fly", "Cancel", "Back", "Menu", "Interact",
}

local function noop()
end

local function copy_table(values)
    local copy = {}
    for key, value in pairs(values or {}) do
        copy[key] = value
    end
    return copy
end

local function compact_diagnostic_text(value, max_length)
    local text = tostring(value or "")
    max_length = math.max(16, math.floor(tonumber(max_length) or 160))
    if #text <= max_length then
        return text
    end
    return text:sub(1, max_length - 3) .. "..."
end

function ModRuntime.new(dependencies)
    dependencies = dependencies or {}
    local ue_helpers = dependencies.ue_helpers
    if ue_helpers == nil then
        pcall(function()
            ue_helpers = require("UEHelpers")
        end)
    end

    return setmetatable({
        core = dependencies.core,
        log = dependencies.log or noop,
        debug_log = dependencies.debug_log or noop,
        ue_helpers = ue_helpers,
        reflected_method_paths =
            dependencies.reflected_method_paths
            or DEFAULT_REFLECTED_METHOD_PATHS,
        reflected_function_cache = {},
        reflected_function_path_cache = {},
        reflected_function_mode_cache = {},
        static_find_object_impl = dependencies.static_find_object,
        find_all_of_impl = dependencies.find_all_of,
        cached_player_controller = nil,
    }, ModRuntime)
end

function ModRuntime:log_value(value)
    if self.core and self.core.safe_to_string then
        return self.core.safe_to_string(value)
    end
    local ok, text = pcall(function()
        return tostring(value)
    end)
    if ok and text ~= nil then
        return text
    end
    return "<unprintable " .. type(value) .. ">"
end

function ModRuntime:trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function ModRuntime:required_lua_api_available()
    local missing = {}
    for _, name in ipairs({
        "ExecuteInGameThread",
        "RegisterHook",
        "RegisterKeyBind",
        "StaticFindObject",
    }) do
        if type(_G and _G[name]) ~= "function" then
            table.insert(missing, name)
        end
    end
    if #missing > 0 then
        self.log("Required UE4SS Lua API missing: "
            .. table.concat(missing, ", "))
        return false
    end
    return true
end

function ModRuntime:is_usable_object(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    if ok then
        local valid = self:get_param_value(value)
        if valid == true then
            return true
        end
        if valid == false then
            return false
        end
    end
    ok = pcall(function()
        local _ = object:GetFullName()
    end)
    return ok
end

function ModRuntime:get_full_name(object)
    if not self:is_usable_object(object) then
        return ""
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    if ok and value then
        return self:log_value(value)
    end
    ok, value = pcall(function()
        return object:GetName()
    end)
    if ok and value then
        return self:log_value(value)
    end
    return ""
end

function ModRuntime:ue4ss_type_name(value)
    if value == nil then
        return ""
    end
    local ok, value_type = pcall(function()
        if type(value.type) == "function" then
            return value:type()
        end
        return nil
    end)
    if ok and value_type ~= nil then
        return self:log_value(value_type)
    end
    return ""
end

function ModRuntime:is_unreal_param(value)
    local value_type = self:ue4ss_type_name(value)
    return value_type == "RemoteUnrealParam"
        or value_type == "LocalUnrealParam"
        or value_type == "FWeakObjectPtr"
end

function ModRuntime:is_ue4ss_object_value(value)
    local value_type = self:ue4ss_type_name(value)
    if value_type == "" then
        return false
    end
    if value_type == "RemoteUnrealParam"
        or value_type == "LocalUnrealParam"
        or value_type == "FWeakObjectPtr"
    then
        return false
    end
    return string.find(value_type, "Object", 1, true) ~= nil
        or string.find(value_type, "Actor", 1, true) ~= nil
        or string.find(value_type, "Component", 1, true) ~= nil
        or value_type == "UClass"
        or value_type == "UStruct"
        or value_type == "UFunction"
end

function ModRuntime:call_value_method(value, method_name, ...)
    if value == nil then
        return false, "value nil"
    end
    local ok, method = pcall(function()
        return value[method_name]
    end)
    if not ok then
        return false, method
    end
    if type(method) ~= "function" then
        return false, "method missing"
    end
    local args = { ... }
    args.n = select("#", ...)
    local unpack_args = table.unpack or unpack
    if not unpack_args then
        return false, "unpack unavailable"
    end
    local result
    ok, result = pcall(function()
        return method(value, unpack_args(args, 1, args.n))
    end)
    if ok then
        return true, result
    end
    return false, result
end

function ModRuntime:ue4ss_value_diagnostics(value)
    local parts = { "luaType=" .. type(value) }
    local lua_type = type(value)
    if lua_type ~= "userdata" and lua_type ~= "table" then
        return table.concat(parts, ",")
    end
    local ue4ss_type = self:ue4ss_type_name(value)
    if ue4ss_type ~= "" then
        table.insert(parts, "ue4ssType=" .. ue4ss_type)
    end
    for _, method_name in ipairs({
        "get",
        "Get",
        "IsValid",
        "GetFullName",
        "GetAddress",
    }) do
        local ok, result = self:call_value_method(value, method_name)
        if ok then
            table.insert(parts, method_name .. "=" .. self:log_value(result))
        else
            table.insert(parts, method_name .. "=unavailable:"
                .. self:log_value(result))
        end
    end
    local tostring_ok, tostring_result =
        self:call_value_method(value, "ToString")
    if tostring_ok and tostring_result ~= nil then
        table.insert(parts, "ToString=" .. self:log_value(tostring_result))
    end
    return table.concat(parts, ",")
end

function ModRuntime:array_method_number(value, method_name)
    local ok, result = self:call_value_method(value, method_name)
    if not ok then
        return nil, "unavailable:" .. self:log_value(result)
    end
    local resolved = self:get_param_value(result)
    local text = self:log_value(resolved)
    return tonumber(text), text
end

function ModRuntime:array_element_value(element)
    local value = self:get_param_value(element)
    local object = self:resolve_object_reference(value)
    if object then
        return object
    end
    for _, method_name in ipairs({ "get", "Get" }) do
        local ok, unwrapped = self:call_value_method(value, method_name)
        if ok and unwrapped ~= nil and unwrapped ~= value then
            local resolved = self:get_param_value(unwrapped)
            return self:resolve_object_reference(resolved) or resolved
        end
    end
    return value
end

function ModRuntime:array_items(value, max_items)
    value = self:get_param_value(value)
    local items = {}
    if value == nil then
        return items
    end
    max_items = math.max(0, math.floor(tonumber(max_items) or 128))
    local function add_item(element)
        if #items < max_items then
            table.insert(items, self:array_element_value(element))
        end
    end
    local for_each_ok = self:call_value_method(value, "ForEach",
        function(_, element)
            add_item(element)
        end)
    if for_each_ok then
        return items
    end
    local count = self:array_method_number(value, "GetArrayNum")
    if count == nil and type(value) == "table" then
        count = #value
    end
    if count ~= nil then
        for index = 0, math.min(count - 1, max_items - 1) do
            local ok, element = pcall(function() return value[index + 1] end)
            if (not ok or element == nil) then
                ok, element = pcall(function() return value[index] end)
            end
            if ok and element ~= nil then
                add_item(element)
            end
        end
    end
    return items
end

function ModRuntime:map_items(value, max_items)
    value = self:get_param_value(value)
    local items = {}
    if value == nil then
        return items
    end
    max_items = math.max(0, math.floor(tonumber(max_items) or 128))
    local function add_item(key, map_value)
        if #items < max_items then
            table.insert(items, {
                key = self:array_element_value(key),
                value = self:array_element_value(map_value),
            })
        end
    end
    local for_each_ok = self:call_value_method(value, "ForEach",
        function(key, map_value)
            add_item(key, map_value)
        end)
    if for_each_ok then
        return items
    end
    if type(value) == "table" then
        for key, map_value in pairs(value) do
            add_item(key, map_value)
            if #items >= max_items then
                break
            end
        end
    end
    return items
end

function ModRuntime:value_field(value, field_name)
    value = self:get_param_value(value)
    if value == nil then
        return nil
    end
    local ok, result = pcall(function()
        return value[field_name]
    end)
    if ok and result ~= nil then
        return self:get_param_value(result)
    end
    ok, result = self:call_value_method(value, "GetPropertyValue",
        field_name)
    if ok and result ~= nil then
        return self:get_param_value(result)
    end
    return nil
end

function ModRuntime:gameplay_ability_instances_from_spec_container(
    container, name_hint, max_items)
    local objects = {}
    local seen = {}
    local hint = tostring(name_hint or "")
    max_items = math.max(0, math.floor(tonumber(max_items) or 32))
    local function add(object)
        if #objects >= max_items then return end
        object = self:resolve_object_reference(object)
            or self:get_param_value(object)
        if not self:is_usable_object(object) then return end
        local identity = self:object_identity_text(object)
        if identity == "" or seen[identity] == true then return end
        if hint ~= "" and not self:contains(identity, hint) then return end
        seen[identity] = true
        table.insert(objects, object)
    end
    for _, object in ipairs(
        self:resolve_object_references_from_text(container, hint, max_items))
    do
        add(object)
    end
    local specs = self:array_items(self:value_field(container, "Items"), 256)
    for _, spec in ipairs(specs) do
        for _, field_name in ipairs({
            "NonReplicatedInstances",
            "ReplicatedInstances",
        }) do
            for _, object in ipairs(
                self:array_items(self:value_field(spec, field_name),
                    max_items))
            do
                add(object)
            end
        end
    end
    return objects
end

function ModRuntime:ability_system_task_entries(
    ability_system, name_hint, max_items)
    local entries = {}
    local seen = {}
    local hint = tostring(name_hint or "")
    max_items = math.max(0, math.floor(tonumber(max_items) or 32))
    local function add(object, source)
        if #entries >= max_items then return end
        object = self:resolve_object_reference(object)
            or self:get_param_value(object)
        if not self:is_usable_object(object) then return end
        local identity = self:object_identity_text(object)
        if identity == "" or seen[identity] == true then return end
        if hint ~= "" and not self:contains(identity, hint) then return end
        seen[identity] = true
        table.insert(entries, {
            object = object,
            identity = identity,
            source = source,
        })
    end
    for _, field_name in ipairs({
        "KnownTasks",
        "TickingTasks",
        "SimulatedTasks",
        "TaskPriorityQueue",
    }) do
        local value = self:value_field(ability_system, field_name)
        for _, object in ipairs(self:array_items(value, max_items)) do
            add(object, field_name)
        end
        for _, object in ipairs(
            self:resolve_object_references_from_text(value, hint, max_items))
        do
            add(object, field_name .. ":text")
        end
    end
    return entries
end

function ModRuntime:array_diagnostics(value, max_items)
    value = self:get_param_value(value)
    if value == nil then
        return "nil"
    end
    max_items = math.max(0, math.floor(tonumber(max_items) or 8))
    local parts = { "luaType=" .. type(value) }
    local value_type = self:ue4ss_type_name(value)
    if value_type ~= "" then
        table.insert(parts, "ue4ssType=" .. value_type)
    end
    local num, num_text = self:array_method_number(value, "GetArrayNum")
    local max, max_text = self:array_method_number(value, "GetArrayMax")
    table.insert(parts, "num=" .. tostring(num or num_text))
    table.insert(parts, "max=" .. tostring(max or max_text))

    local items = {}
    local function add_item(index, element)
        if #items >= max_items then
            return
        end
        local display_index = tonumber(index) or index
        if type(display_index) == "number" then
            display_index = display_index - 1
        end
        table.insert(items, "[" .. self:log_value(display_index) .. "]="
            .. self:param_to_log_string(self:array_element_value(element)))
    end

    local for_each_ok, for_each_error = self:call_value_method(value,
        "ForEach", function(index, element)
            add_item(index, element)
        end)
    if for_each_ok then
        table.insert(parts, "forEach=ok")
    else
        table.insert(parts, "forEach=unavailable:"
            .. self:log_value(for_each_error))
        local count = num
        if count == nil and type(value) == "table" then
            count = #value
        end
        if count ~= nil then
            for index = 0, math.min(count - 1, max_items - 1) do
                local ok, element = pcall(function()
                    return value[index + 1]
                end)
                if (not ok or element == nil) then
                    ok, element = pcall(function()
                        return value[index]
                    end)
                end
                if ok and element ~= nil then
                    add_item(index + 1, element)
                end
            end
        end
    end
    if #items > 0 then
        table.insert(parts, "items=" .. table.concat(items, ";"))
    elseif num == 0 then
        table.insert(parts, "items=empty")
    else
        table.insert(parts, "items=none")
    end
    if num ~= nil and num > #items then
        table.insert(parts, "truncated=" .. tostring(num - #items))
    end
    return table.concat(parts, ",")
end

function ModRuntime:get_param_value(param)
    if param == nil then
        return nil
    end
    local param_type = type(param)
    if param_type == "boolean" or param_type == "number"
        or param_type == "string"
    then
        return param
    end
    if self:is_ue4ss_object_value(param) then
        return param
    end
    local ok, value = pcall(function()
        if self:is_unreal_param(param) then
            return param:get()
        end
        error("not an unreal param")
    end)
    if ok then
        return value
    end
    ok, value = pcall(function()
        if self:is_unreal_param(param) then
            return param:Get()
        end
        error("not an unreal param")
    end)
    if ok then
        return value
    end
    return param
end

function ModRuntime:get_param_object(param)
    local value = self:get_param_value(param)
    if self:is_usable_object(value) then
        return value
    end
    return nil
end

function ModRuntime:contains(haystack, needle)
    local ok, matched = pcall(function()
        local haystack_text = self:log_value(haystack or "")
        local needle_text = self:log_value(needle or "")
        return string.find(string.lower(haystack_text),
            string.lower(needle_text), 1, true) ~= nil
    end)
    return ok and matched == true
end

function ModRuntime:set_player_controller(controller)
    self.cached_player_controller = controller
end

function ModRuntime:resolve_player_controller()
    if self:is_usable_object(self.cached_player_controller) then
        return self.cached_player_controller
    end
    if self.ue_helpers
        and type(self.ue_helpers.GetPlayerController) == "function"
    then
        local ok, pc = pcall(self.ue_helpers.GetPlayerController)
        if ok and self:is_usable_object(pc) then
            self.cached_player_controller = pc
            return pc
        end
    end
    local ok, pc = pcall(function()
        return FindFirstOf("PlayerController")
    end)
    if ok and self:is_usable_object(pc) then
        self.cached_player_controller = pc
        return pc
    end
    return nil
end

function ModRuntime:read_resolved_property(object, property_name)
    local read = self:read_object_property(object, property_name)
    local value = self:resolve_object_reference(read.value) or read.value
    return value, read
end

function ModRuntime:player_controller_input_snapshot()
    local player_controller = self:resolve_player_controller()
    local snapshot = {
        player_controller = player_controller,
        input_component = nil,
        player_input = nil,
        input_config = nil,
        input_context_controller = nil,
        diagnostics = "",
    }
    if not self:is_usable_object(player_controller) then
        snapshot.diagnostics = "PlayerController=missing"
        return snapshot
    end

    local parts = {
        "PlayerController=" .. self:property_identity_text(player_controller),
    }
    local property_specs = {
        { "InputComponent", "input_component" },
        { "PlayerInput", "player_input" },
        { "m_GothicInputConfig", "input_config" },
        { "m_GothicInputContextController", "input_context_controller" },
    }
    for _, spec in ipairs(property_specs) do
        local property_name = spec[1]
        local field_name = spec[2]
        local value, read =
            self:read_resolved_property(player_controller, property_name)
        snapshot[field_name] = value
        table.insert(parts, tostring(property_name) .. "="
            .. self:property_identity_text(value)
            .. "(" .. tostring(read.source or "unknown") .. ":"
            .. self:property_read_status(read.ok, read.value) .. ")")
    end
    snapshot.diagnostics = table.concat(parts, " ")
    return snapshot
end

function ModRuntime:key_values_from_name(key_name)
    local values = {}
    local seen = {}
    local normalized = string.upper(self:trim(key_name))
    for _, candidate in ipairs(
        self.core.cancel_key_lookup_candidates(normalized))
    do
        if not seen[candidate] then
            seen[candidate] = true
            local ok, value = pcall(function()
                return Key[candidate]
            end)
            if ok and value ~= nil then
                table.insert(values, {
                    name = candidate,
                    value = value,
                })
            end
        end
    end
    return values
end

function ModRuntime:fname_from_string(name)
    local text = self:trim(name)
    if text == "" then
        return nil
    end
    if self.ue_helpers and type(self.ue_helpers.FindOrAddFName) == "function" then
        local ok, value = pcall(function()
            return self.ue_helpers.FindOrAddFName(text)
        end)
        if ok and value ~= nil then
            return value
        end
    end
    if type(FName) == "function" then
        local ok, value = pcall(function()
            if type(EFindName) == "table" and EFindName.FNAME_Add ~= nil then
                return FName(text, EFindName.FNAME_Add)
            end
            return FName(text)
        end)
        if ok and value ~= nil then
            return value
        end
    end
    return nil
end

function ModRuntime:fkey_from_name(key_name)
    local key_name_value = self:fname_from_string(key_name)
    if key_name_value == nil then
        return nil
    end
    return {
        KeyName = key_name_value,
    }
end

function ModRuntime:controller_input_key_values_from_name(key_name)
    local values = {}
    local seen = {}
    local function add(name, value, source)
        if name == nil or value == nil or seen[name] == true then
            return
        end
        seen[name] = true
        table.insert(values, {
            name = name,
            value = value,
            source = source,
        })
    end

    for _, key in ipairs(self:key_values_from_name(key_name)) do
        add(key.name, key.value, "Key")
    end

    local normalized = string.upper(self:trim(key_name))
    for _, candidate in ipairs(
        self.core.cancel_key_lookup_candidates(normalized))
    do
        local value = self:fkey_from_name(candidate)
        add(candidate, value, "FKey")
    end
    return values
end

function ModRuntime:available_key_names(patterns, max_items)
    local names = {}
    local matches = {}
    for _, pattern in ipairs(patterns or {}) do
        local normalized = string.lower(self:trim(pattern))
        if normalized ~= "" then
            table.insert(matches, normalized)
        end
    end
    if #matches == 0 then
        return names, nil
    end

    local pairs_ok, iterator, state, initial = pcall(function()
        return pairs(Key)
    end)
    if not pairs_ok then
        return names, "Key table not iterable: " .. self:log_value(iterator)
    end

    local seen = {}
    local scan_ok, scan_err = pcall(function()
        for key_name, _ in iterator, state, initial do
            local name = self:log_value(key_name)
            local lower_name = string.lower(name)
            for _, pattern in ipairs(matches) do
                if string.find(lower_name, pattern, 1, true) ~= nil then
                    if seen[name] ~= true then
                        seen[name] = true
                        table.insert(names, name)
                    end
                    break
                end
            end
        end
    end)
    if not scan_ok then
        return names, "Key table scan failed: " .. self:log_value(scan_err)
    end

    table.sort(names)
    local limit = math.floor(tonumber(max_items) or #names)
    if limit >= 0 and #names > limit then
        local limited = {}
        for index = 1, limit do
            limited[index] = names[index]
        end
        names = limited
    end
    return names, nil
end

function ModRuntime:static_find_object(name)
    local finder = self.static_find_object_impl or StaticFindObject
    if type(finder) ~= "function" then
        return nil
    end
    local ok, object = pcall(function()
        return finder(name)
    end)
    if ok and self:is_usable_object(object) then
        return object
    end
    return nil
end

function ModRuntime:find_all_of(class_name)
    local finder = self.find_all_of_impl or FindAllOf
    if type(finder) ~= "function" then
        return {}
    end
    local ok, objects = pcall(function()
        return finder(class_name)
    end)
    if ok and type(objects) == "table" then
        return objects
    end
    self.debug_log("FindAllOf failed " .. tostring(class_name) .. ": "
        .. self:log_value(objects))
    return {}
end

function ModRuntime:object_reference_candidates(value)
    local candidates = {}
    local seen = {}
    local function add(candidate)
        candidate = self:trim(candidate)
        if candidate == ""
            or candidate == "None"
            or candidate == "<userdata>"
            or seen[candidate] == true
        then
            return
        end
        seen[candidate] = true
        table.insert(candidates, candidate)
    end

    local resolved = self:get_param_value(value)
    if type(resolved) == "string" then
        add(resolved)
    end

    local tostring_ok, tostring_value =
        self:call_value_method(resolved, "ToString")
    if tostring_ok and tostring_value ~= nil then
        add(self:log_value(tostring_value))
    end

    return candidates
end

function ModRuntime:object_reference_candidates_from_text(value, name_hint)
    local text = self:log_value(self:get_param_value(value) or "")
    local candidates = {}
    local seen = {}
    local hint = tostring(name_hint or "")
    local function add(candidate)
        candidate = self:trim(candidate)
        if candidate == "" or seen[candidate] == true then return end
        if hint ~= "" and not self:contains(candidate, hint) then return end
        seen[candidate] = true
        table.insert(candidates, candidate)
        local path = string.match(candidate, "'(/[^']+)'")
        if path and seen[path] ~= true then
            seen[path] = true
            table.insert(candidates, path)
        end
    end
    for candidate in string.gmatch(text, "\"([^\"]+)\"") do
        add(candidate)
    end
    for candidate in string.gmatch(text, "([^,%(%s]+/[^,%)]*)") do
        add(candidate)
    end
    return candidates
end

function ModRuntime:resolve_object_references_from_text(
    value, name_hint, max_items)
    local objects = {}
    local seen = {}
    max_items = math.max(0, math.floor(tonumber(max_items) or 32))
    for _, candidate in ipairs(
        self:object_reference_candidates_from_text(value, name_hint))
    do
        if #objects >= max_items then break end
        local object = self:static_find_object(candidate)
        local identity = self:object_identity_text(object)
        if identity ~= "" and seen[identity] ~= true then
            seen[identity] = true
            table.insert(objects, object)
        end
    end
    return objects
end

function ModRuntime:resolve_object_reference(value)
    local resolved = self:get_param_value(value)
    if self:is_usable_object(resolved) then
        return resolved
    end
    for _, candidate in ipairs(self:object_reference_candidates(resolved)) do
        local object = self:static_find_object(candidate)
        if self:is_usable_object(object) then
            return object
        end
    end
    return nil
end

function ModRuntime:function_exists(name)
    local dotted_name = string.gsub(name, ":([^:]+)$", ".%1")
    return self:static_find_object("Function " .. name)
        or self:static_find_object(name)
        or self:static_find_object("Function " .. dotted_name)
        or self:static_find_object(dotted_name)
end

function ModRuntime:register_hook(name, pre, post, required)
    local exists = self:function_exists(name)
    if not exists then
        local message = "Hook missing " .. tostring(name)
        if required then
            self.log(message)
        else
            self.debug_log(message)
        end
        return false
    end
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(name, pre, post)
    end)
    if ok then
        self.debug_log("Hook registered " .. tostring(name))
        return true, pre_id, post_id
    end
    local message = "Hook failed " .. tostring(name) .. ": "
        .. self:log_value(pre_id)
    if required then
        self.log(message)
    else
        self.debug_log(message)
    end
    return false
end

function ModRuntime:get_class_full_name(object)
    if not self:is_usable_object(object) then
        return ""
    end
    local ok, class = pcall(function()
        return object:GetClass()
    end)
    if ok and self:is_usable_object(class) then
        return self:get_full_name(class)
    end
    return ""
end

function ModRuntime:object_identity_text(object)
    return self:get_full_name(object) .. " " .. self:get_class_full_name(object)
end

function ModRuntime:find_reflected_function(object, method_name)
    local candidates = {}
    local class_name = ""
    local ok, class = pcall(function()
        return object:GetClass()
    end)
    if ok and self:is_usable_object(class) then
        class_name = self:get_full_name(class):match("^Class%s+(.+)$") or ""
        if class_name ~= "" then
            table.insert(candidates, class_name .. ":" .. method_name)
            table.insert(candidates, class_name .. "." .. method_name)
        end
    end

    local cache_key = tostring(method_name) .. "|"
        .. tostring(class_name ~= "" and class_name or self:get_full_name(object))
    local cached = self.reflected_function_cache[cache_key]
    if cached then
        return cached, self.reflected_function_path_cache[cache_key]
            or method_name
    end

    for _, path in ipairs(self.reflected_method_paths[method_name] or {}) do
        table.insert(candidates, path)
        local dotted_path = string.gsub(path, ":([^:]+)$", ".%1")
        table.insert(candidates, dotted_path)
    end

    for _, candidate in ipairs(candidates) do
        local found = self:static_find_object("Function " .. candidate)
            or self:static_find_object(candidate)
        if found then
            self.reflected_function_cache[cache_key] = found
            self.reflected_function_path_cache[cache_key] = candidate
            return found, candidate
        end
    end
    return nil, nil
end

function ModRuntime:call_reflected_function(
    object, method_name, args, unpack_args, previous_error)
    local ufunction, path = self:find_reflected_function(object, method_name)
    if not ufunction then
        return false, path or previous_error or "method not found"
    end

    local first_error = previous_error
    for _, mode in ipairs(self.core.reflected_call_modes(
        self.reflected_function_mode_cache[path])) do
        local ok, value = pcall(function()
            if mode == "self" then
                return ufunction(object, unpack_args(args, 1, args.n))
            end
            return object:CallFunction(ufunction, unpack_args(args, 1, args.n))
        end)
        if ok then
            self.reflected_function_mode_cache[path] = mode
            return true, value, tostring(mode) .. ":" .. tostring(path)
        end
        if first_error == nil then
            first_error = value
        end
    end
    return false, first_error or "reflected call failed"
end

function ModRuntime:direct_method_matches_request(method, method_name)
    local full_name = self:get_full_name(method)
    if full_name == "" then
        return true
    end
    local requested = tostring(method_name or "")
    if requested == "" then
        return true
    end
    if string.find(full_name, ":" .. requested, 1, true) ~= nil
        or string.find(full_name, "." .. requested, 1, true) ~= nil
    then
        return true
    end
    return false
end

function ModRuntime:call_method(object, method_name, ...)
    if not self:is_usable_object(object) then
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
        return self:call_reflected_function(object, method_name, args,
            unpack_args, "method not found")
    end
    if not self:direct_method_matches_request(method, method_name) then
        return self:call_reflected_function(object, method_name, args,
            unpack_args, "direct method mismatch")
    end

    local value
    ok, value = pcall(function()
        return method(object, unpack_args(args, 1, args.n))
    end)
    if ok then
        return true, value, "direct-self"
    end
    return self:call_reflected_function(object, method_name, args, unpack_args,
        value)
end

function ModRuntime:param_to_log_string(param)
    local value = self:get_param_value(param)
    if value == nil then
        return ""
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number"
        or value_type == "boolean"
    then
        return self:log_value(value)
    end
    if self:is_usable_object(value) then
        return self:get_full_name(value)
    end
    return "<" .. value_type .. ">"
end

function ModRuntime:key_value_from_name(key_name)
    local normalized = string.upper(self:trim(key_name))
    local values = self:key_values_from_name(normalized)
    if values[1] ~= nil then
        return values[1].value, values[1].name
    end
    return nil, normalized
end

function ModRuntime:register_key_bind(key_name, handler)
    local key_value, normalized = self:key_value_from_name(key_name)
    if key_value == nil then
        return false, normalized, "unknown key"
    end
    local ok, err = pcall(function()
        RegisterKeyBind(key_value, function()
            handler(normalized)
        end)
    end)
    if ok then
        return true, normalized, nil
    end
    return false, normalized, err
end

function ModRuntime:pack_args(...)
    local args = { ... }
    args.n = select("#", ...)
    return args
end

function ModRuntime:call_method_with_arg_pack(object, method_name, args)
    local unpack_args = table.unpack or unpack
    if not unpack_args then
        return false, "unpack unavailable"
    end
    args = args or { n = 0 }
    return self:call_method(object, method_name,
        unpack_args(args, 1, args.n or #args))
end

function ModRuntime:pack_array_args(values)
    local args = copy_table(values or {})
    args.n = #(values or {})
    return args
end

function ModRuntime:set_object_property(object, property_name, value)
    if not self:is_usable_object(object) then
        return false, "object invalid"
    end
    local ok, err = pcall(function()
        object[property_name] = value
    end)
    if ok then
        return true, value
    end
    return false, err
end

function ModRuntime:get_object_property(object, property_name)
    if not self:is_usable_object(object) then
        return false, "object invalid"
    end
    local ok, value = pcall(function()
        return object[property_name]
    end)
    if ok then
        return true, self:get_param_value(value), "direct"
    end
    return false, value, "direct"
end

function ModRuntime:get_object_property_value_method(object, property_name)
    if not self:is_usable_object(object) then
        return false, "object invalid", "GetPropertyValue"
    end
    local ok, value = self:call_value_method(object, "GetPropertyValue",
        property_name)
    if ok then
        return true, self:get_param_value(value), "GetPropertyValue"
    end
    return false, value, "GetPropertyValue"
end

function ModRuntime:property_read_status(ok, value)
    if ok ~= true or value == nil then
        return "missing"
    end
    if self:is_usable_object(value) then
        return "object"
    end
    return type(value)
end

function ModRuntime:property_identity_text(value)
    if self:is_usable_object(value) then
        return self:object_identity_text(value)
    end
    local value_type = type(value)
    if value == nil then
        return ""
    end
    if value_type == "string" or value_type == "number"
        or value_type == "boolean"
    then
        return self:log_value(value)
    end
    local tostring_ok, tostring_value =
        self:call_value_method(value, "ToString")
    if tostring_ok and tostring_value ~= nil then
        local text = self:log_value(tostring_value)
        if text ~= "" and text ~= "None" then
            return text
        end
    end
    return self:param_to_log_string(value)
end

function ModRuntime:property_value_is_informative(value)
    if self:is_usable_object(value) then
        return true
    end
    if value == nil then
        return false
    end
    local text = self:property_identity_text(value)
    return text ~= "" and text ~= "None" and text ~= "<userdata>"
end

function ModRuntime:read_object_property(object, property_name)
    local direct_ok, direct_value =
        self:get_object_property(object, property_name)
    local method_ok, method_value =
        self:get_object_property_value_method(object, property_name)
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
            or (self:property_value_is_informative(method_value)
                and not self:property_value_is_informative(direct_value)))
    then
        read.ok = method_ok
        read.value = method_value
        read.source = "GetPropertyValue"
    end
    return read
end

function ModRuntime:property_probe_text(property_name, read)
    read = read or {}
    return tostring(property_name) .. "=" .. tostring(read.source or "unknown")
        .. ":" .. self:property_read_status(read.ok, read.value)
        .. "(direct=" .. self:property_read_status(read.direct_ok,
            read.direct_value)
        .. ",GetPropertyValue." .. tostring(property_name) .. "="
        .. self:property_read_status(read.method_ok, read.method_value)
        .. ")"
end

function ModRuntime:property_text(object, property_name)
    local read = self:read_object_property(object, property_name)
    local value = self:resolve_object_reference(read.value) or read.value
    return tostring(property_name) .. "=" .. self:property_identity_text(value)
        .. "(" .. tostring(read.source or "unknown")
        .. ":" .. self:property_read_status(read.ok, read.value) .. ")"
end

function ModRuntime:gameplay_tag_text(tag)
    local tag_text = self:property_identity_text(tag)
    local tag_name_text = self:property_identity_text(
        self:value_field(tag, "TagName"))
    if tag_name_text ~= "" then
        return tag_name_text
    end
    return tag_text
end

function ModRuntime:enhanced_action_instance_triggered_action(
        player_input, action_needles, event_predicate)
    if not self:is_usable_object(player_input) then
        return { matched = false, detail = "playerInput=missing" }
    end
    local read = self:read_object_property(player_input,
        "ActionInstanceData")
    local value = self:resolve_object_reference(read.value) or read.value
    local checked = 0
    for _, item in ipairs(self:map_items(value, 80)) do
        checked = checked + 1
        local instance = item.value
        local action_text = self:property_identity_text(item.key)
        local source_text = self:property_identity_text(
            self:value_field(instance, "SourceAction"))
        local event_text = self:property_identity_text(
            self:value_field(instance, "TriggerEvent"))
        local search_text = action_text .. " " .. source_text
        for _, needle in ipairs(action_needles or {}) do
            if self:contains(search_text, needle)
                and type(event_predicate) == "function"
                and event_predicate(event_text)
            then
                return {
                    matched = true,
                    detail = "action="
                        .. compact_diagnostic_text(action_text, 130)
                        .. " event="
                        .. compact_diagnostic_text(event_text, 40)
                        .. " source="
                        .. compact_diagnostic_text(source_text, 130)
                        .. " checked=" .. tostring(checked),
                }
            end
        end
    end
    return {
        matched = false,
        detail = self:property_probe_text("ActionInstanceData", read)
            .. " checked=" .. tostring(checked),
    }
end

function ModRuntime:enhanced_action_mapping_key_text(mapping)
    local key_value = self:value_field(mapping, "Key")
    local parts = { self:property_identity_text(key_value) }
    for _, field_name in ipairs({
        "KeyName",
        "Name",
        "DisplayName",
        "DisplayNameText",
    }) do
        local text = self:property_identity_text(
            self:value_field(key_value, field_name))
        if text ~= "" then
            table.insert(parts, text)
        end
    end
    for _, method_name in ipairs({
        "GetFName",
        "GetDisplayName",
        "ToString",
    }) do
        local ok, result = self:call_value_method(key_value, method_name)
        local text = ok and self:property_identity_text(
            self:get_param_value(result)) or ""
        if text ~= "" then
            table.insert(parts, text)
        end
    end
    return table.concat(parts, " ")
end

function ModRuntime:enhanced_action_mapping_actions_for_keys(
        player_input, key_needles, max_actions)
    if not self:is_usable_object(player_input) then
        return { actions = {}, detail = "playerInput=missing" }
    end
    max_actions = math.max(0, math.floor(tonumber(max_actions) or 32))
    local read = self:read_object_property(player_input,
        "EnhancedActionMappings")
    local value = self:resolve_object_reference(read.value) or read.value
    local mappings = self:array_items(value, 512)
    local actions = {}
    local seen = {}
    local checked = 0
    for _, mapping in ipairs(mappings) do
        if #actions >= max_actions then
            break
        end
        checked = checked + 1
        local key_text = self:enhanced_action_mapping_key_text(mapping)
        local matched_key = false
        for _, needle in ipairs(key_needles or {}) do
            if self:contains(key_text, needle) then
                matched_key = true
                break
            end
        end
        if matched_key then
            local action_text = self:property_identity_text(
                self:value_field(mapping, "Action"))
            if action_text ~= "" and seen[action_text] ~= true then
                seen[action_text] = true
                table.insert(actions, action_text)
            end
        end
    end
    return {
        actions = actions,
        detail = self:property_probe_text("EnhancedActionMappings", read)
            .. " mappings=" .. tostring(#mappings)
            .. " checked=" .. tostring(checked)
            .. " actions=" .. tostring(#actions),
    }
end

function ModRuntime:gothic_input_config_summary(input_config)
    if not self:is_usable_object(input_config) then
        return "inputConfig=missing"
    end
    local function matches(text)
        for _, needle in ipairs(GOTHIC_INPUT_CONFIG_ACTION_NEEDLES) do
            if self:contains(text, needle) then
                return true
            end
        end
        return false
    end
    local parts = {}
    for _, property_name in ipairs(GOTHIC_INPUT_CONFIG_ACTION_PROPERTIES) do
        local read = self:read_object_property(input_config, property_name)
        local value = self:resolve_object_reference(read.value) or read.value
        local items = self:array_items(value, 128)
        local entries = {}
        for _, item in ipairs(items) do
            local action_text = self:property_identity_text(
                self:value_field(item, "InputAction"))
            local tag_text = self:gameplay_tag_text(
                self:value_field(item, "InputTag"))
            if #entries < 12 and matches(action_text .. " " .. tag_text) then
                table.insert(entries, "action="
                    .. compact_diagnostic_text(action_text, 140)
                    .. " tag=" .. compact_diagnostic_text(tag_text, 120))
            end
        end
        table.insert(parts, tostring(property_name)
            .. "=" .. self:property_probe_text(property_name, read)
            .. " count=" .. tostring(#items)
            .. " entries=" .. (#entries > 0 and table.concat(entries, " || ")
                or "none"))
    end
    return table.concat(parts, " ")
end

return ModRuntime
