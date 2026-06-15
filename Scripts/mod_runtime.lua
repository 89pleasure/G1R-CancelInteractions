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

local function noop()
end

local function copy_table(values)
    local copy = {}
    for key, value in pairs(values or {}) do
        copy[key] = value
    end
    return copy
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
    for _, candidate in ipairs(
        self.core.cancel_key_lookup_candidates(normalized))
    do
        local ok, value = pcall(function()
            return Key[candidate]
        end)
        if ok and value ~= nil then
            return value, candidate
        end
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

return ModRuntime
