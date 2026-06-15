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
        return value == true
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
end

function ModRuntime:is_ue4ss_object_value(value)
    local value_type = self:ue4ss_type_name(value)
    if value_type == "" then
        return false
    end
    if value_type == "RemoteUnrealParam"
        or value_type == "LocalUnrealParam"
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
    for _, method_name in ipairs({ "IsValid", "GetFullName", "GetAddress" }) do
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
    local ok, object = pcall(function()
        return StaticFindObject(name)
    end)
    if ok and self:is_usable_object(object) then
        return object
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
