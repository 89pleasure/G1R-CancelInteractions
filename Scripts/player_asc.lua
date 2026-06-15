local PlayerAsc = {}
PlayerAsc.__index = PlayerAsc

local function noop() end

function PlayerAsc.new(dependencies)
    dependencies = dependencies or {}
    return setmetatable({
        runtime = assert(dependencies.runtime, "runtime is required"),
        core = assert(dependencies.core, "core is required"),
        debug_log = dependencies.debug_log or noop,
        player_state = dependencies.player_state or function() return nil end,
        log_value = dependencies.log_value,
    }, PlayerAsc)
end

function PlayerAsc:log_value(value)
    if self.log_value ~= nil then
        return self.log_value(value)
    end
    return self.runtime:log_value(value)
end

function PlayerAsc:owner_property_status(ok, value)
    if ok ~= true or value == nil then
        return "missing"
    end
    if self.runtime:is_usable_object(value) then
        return "object"
    end
    return type(value)
end

function PlayerAsc:property_identity_text(value)
    if self.runtime:is_usable_object(value) then
        return self.runtime:object_identity_text(value)
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
        self.runtime:call_value_method(value, "ToString")
    if tostring_ok and tostring_value ~= nil then
        local text = self:log_value(tostring_value)
        if text ~= "" and text ~= "None" then
            return text
        end
    end
    return self.runtime:param_to_log_string(value)
end

function PlayerAsc:property_value_is_informative(value)
    if self.runtime:is_usable_object(value) then
        return true
    end
    if value == nil then
        return false
    end
    local text = self:property_identity_text(value)
    return text ~= "" and text ~= "None" and text ~= "<userdata>"
end

function PlayerAsc:read_owner_property(object, property_name)
    local direct_ok, direct_value =
        self.runtime:get_object_property(object, property_name)
    local method_ok, method_value =
        self.runtime:get_object_property_value_method(object, property_name)
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

function PlayerAsc:owner_property_probe_text(property_name, read)
    read = read or {}
    return tostring(property_name) .. "=" .. tostring(read.source or "unknown")
        .. ":" .. self:owner_property_status(read.ok, read.value)
        .. "(direct=" .. self:owner_property_status(read.direct_ok,
            read.direct_value)
        .. ",GetPropertyValue." .. tostring(property_name) .. "="
        .. self:owner_property_status(read.method_ok, read.method_value)
        .. ")"
end

function PlayerAsc:property_text(object, property_name)
    local read = self:read_owner_property(object, property_name)
    local value = self.runtime:resolve_object_reference(read.value)
        or read.value
    return tostring(property_name) .. "=" .. self:property_identity_text(value)
        .. "(" .. tostring(read.source or "unknown")
        .. ":" .. self:owner_property_status(read.ok, read.value) .. ")"
end

function PlayerAsc:current_context()
    local player_state = self.player_state()
    local player_state_identity = self:property_identity_text(player_state)
    if player_state_identity == "" then
        return {
            ok = false,
            reason = "no-player-state",
            player_state = player_state,
            player_state_identity = player_state_identity,
            ability_system = nil,
            ability_system_identity = "",
            ability_system_read = nil,
        }
    end
    local ability_system_read =
        self:read_owner_property(player_state, "AbilitySystemComponent")
    local ability_system = self.runtime:resolve_object_reference(
        ability_system_read.value) or ability_system_read.value
    local ability_system_identity =
        self:property_identity_text(ability_system)
    if not self.runtime:is_usable_object(ability_system) then
        return {
            ok = false,
            reason = "no-asc",
            player_state = player_state,
            player_state_identity = player_state_identity,
            ability_system = ability_system,
            ability_system_identity = ability_system_identity,
            ability_system_read = ability_system_read,
        }
    end
    return {
        ok = true,
        reason = "player-asc",
        player_state = player_state,
        player_state_identity = player_state_identity,
        ability_system = ability_system,
        ability_system_identity = ability_system_identity,
        ability_system_read = ability_system_read,
    }
end

function PlayerAsc:find_freepoint_ability()
    local context = self:current_context()
    if context.ok ~= true then
        self.debug_log("[movement-freepoint-lookup] skipped reason="
            .. tostring(context.reason)
            .. " playerState=" .. tostring(context.player_state_identity)
            .. " abilitySystemProbe="
            .. self:owner_property_probe_text("AbilitySystemComponent",
                context.ability_system_read))
        return nil, ""
    end
    local ability_array_read = self:read_owner_property(context.ability_system,
        "AllReplicatedInstancedAbilities")
    local ability_array = ability_array_read.value
    local checked, matches, result, result_identity = 0, 0, nil, ""
    local function check_ability(object)
        if self.runtime:is_usable_object(object) then
            checked = checked + 1
            local identity = self.runtime:object_identity_text(object)
            if self.core.freepoint_ability_is_cancelable(identity)
                and self.core.object_identity_belongs_to_owner_path(identity,
                    context.player_state_identity)
            then
                matches = matches + 1
                if result == nil then
                    result, result_identity = object, identity
                end
            end
        end
    end
    for _, object in ipairs(self.runtime:array_items(ability_array, 128)) do
        check_ability(object)
    end
    local activatable_read = self:read_owner_property(context.ability_system,
        "ActivatableAbilities")
    local activatable_objects =
        self.runtime:gameplay_ability_instances_from_spec_container(
            activatable_read.value, "GameplayAbilityInteractFreePoint", 32)
    for _, object in ipairs(activatable_objects) do check_ability(object) end
    self.debug_log("[movement-freepoint-lookup] playerState="
        .. tostring(context.player_state_identity)
        .. " source=player-asc"
        .. " checked=" .. tostring(checked)
        .. " matches=" .. tostring(matches)
        .. " arrayProbe="
        .. self:owner_property_probe_text("AllReplicatedInstancedAbilities",
            ability_array_read)
        .. " activatableProbe="
        .. self:owner_property_probe_text("ActivatableAbilities",
            activatable_read)
        .. " result=" .. tostring(result_identity))
    return result, result_identity
end

function PlayerAsc:find_movement_task(key_name)
    local context = self:current_context()
    if context.ok ~= true then
        self.debug_log("[player-asc-task-lookup] key=" .. tostring(key_name)
            .. " skipped reason=" .. tostring(context.reason)
            .. " playerState=" .. tostring(context.player_state_identity)
            .. " abilitySystemProbe="
            .. self:owner_property_probe_text("AbilitySystemComponent",
                context.ability_system_read))
        return nil, "", "player-asc:" .. tostring(context.reason)
    end

    local entries = self.runtime:ability_system_task_entries(
        context.ability_system, "AbilityTask", 32)
    local move_matches = 0
    local result, result_identity, result_source = nil, "", ""
    local parts = {}
    for index, entry in ipairs(entries) do
        local identity = entry.identity
            or self.runtime:object_identity_text(entry.object)
        if self.core.movement_task_is_cancelable(identity) then
            move_matches = move_matches + 1
            if result == nil then
                result = entry.object
                result_identity = identity
                result_source = tostring(entry.source)
            end
        end
        if index <= 12 then
            table.insert(parts,
                tostring(entry.source) .. "=" .. tostring(identity))
        end
    end
    if #entries > 12 then
        table.insert(parts, "truncated=" .. tostring(#entries - 12))
    end
    self.debug_log("[player-asc-task-lookup] key=" .. tostring(key_name)
        .. " playerState=" .. tostring(context.player_state_identity)
        .. " abilitySystem=" .. tostring(context.ability_system_identity)
        .. " checked=" .. tostring(#entries)
        .. " moveMatches=" .. tostring(move_matches)
        .. " result=" .. tostring(result_identity)
        .. " resultSource=" .. tostring(result_source)
        .. " abilitySystemProbe="
        .. self:owner_property_probe_text("AbilitySystemComponent",
            context.ability_system_read)
        .. " tasks=" .. table.concat(parts, " | "))
    if self.runtime:is_usable_object(result) then
        return result, result_identity, "player-asc:" .. result_source
    end
    return nil, "", "player-asc:no-move-task"
end

return PlayerAsc
