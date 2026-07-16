local PlayerAsc = {}
PlayerAsc.__index = PlayerAsc

local function noop() end

function PlayerAsc.new(dependencies)
    dependencies = dependencies or {}
    local self = setmetatable({
        runtime = assert(dependencies.runtime, "runtime is required"),
        core = assert(dependencies.core, "core is required"),
        debug_log = dependencies.debug_log or noop,
        debug_enabled = dependencies.debug_enabled or function() return false end,
        player_state = dependencies.player_state or function() return nil end,
    }, PlayerAsc)
    self:reset()
    return self
end

function PlayerAsc:reset()
    self.cached_context = nil
    self.cached_freepoint_ability = nil
    self.cached_freepoint_ability_identity = ""
end

function PlayerAsc:current_context()
    local player_state = self.player_state()
    local cached = self.cached_context
    if cached ~= nil
        and player_state == cached.player_state
        and self.runtime:is_usable_object(player_state)
        and self.runtime:is_usable_object(cached.ability_system)
    then
        return cached
    end

    self:reset()
    local player_state_identity =
        self.runtime:property_identity_text(player_state)
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
    local ability_system_read = self.runtime:read_object_property(
        player_state, "AbilitySystemComponent")
    local ability_system = self.runtime:resolve_object_reference(
        ability_system_read.value) or ability_system_read.value
    local ability_system_identity =
        self.runtime:property_identity_text(ability_system)
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
    local context = {
        ok = true,
        reason = "player-asc",
        player_state = player_state,
        player_state_identity = player_state_identity,
        ability_system = ability_system,
        ability_system_identity = ability_system_identity,
        ability_system_read = ability_system_read,
    }
    self.cached_context = context
    return context
end

function PlayerAsc:find_freepoint_ability()
    local context = self:current_context()
    if context.ok ~= true then
        self.debug_log(function()
            return "[movement-freepoint-lookup] skipped reason="
                .. tostring(context.reason)
                .. " playerState=" .. tostring(context.player_state_identity)
                .. " abilitySystemProbe="
                .. self.runtime:property_probe_text("AbilitySystemComponent",
                    context.ability_system_read)
        end)
        return nil, ""
    end
    if self.runtime:is_usable_object(self.cached_freepoint_ability)
        and self.core.freepoint_ability_is_cancelable(
            self.cached_freepoint_ability_identity)
        and self.core.object_identity_belongs_to_owner_path(
            self.cached_freepoint_ability_identity,
            context.player_state_identity)
    then
        return self.cached_freepoint_ability,
            self.cached_freepoint_ability_identity
    end
    self.cached_freepoint_ability = nil
    self.cached_freepoint_ability_identity = ""

    local ability_array_read = self.runtime:read_object_property(
        context.ability_system, "AllReplicatedInstancedAbilities")
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
    local activatable_read = self.runtime:read_object_property(
        context.ability_system, "ActivatableAbilities")
    local activatable_objects =
        self.runtime:gameplay_ability_instances_from_spec_container(
            activatable_read.value, "GameplayAbilityInteractFreePoint", 32)
    for _, object in ipairs(activatable_objects) do check_ability(object) end
    self.debug_log(function()
        return "[movement-freepoint-lookup] playerState="
            .. tostring(context.player_state_identity)
            .. " source=player-asc"
            .. " checked=" .. tostring(checked)
            .. " matches=" .. tostring(matches)
            .. " arrayProbe="
            .. self.runtime:property_probe_text(
                "AllReplicatedInstancedAbilities", ability_array_read)
            .. " activatableProbe="
            .. self.runtime:property_probe_text("ActivatableAbilities",
                activatable_read)
            .. " result=" .. tostring(result_identity)
    end)
    if self.runtime:is_usable_object(result) then
        self.cached_freepoint_ability = result
        self.cached_freepoint_ability_identity = result_identity
    end
    return result, result_identity
end

function PlayerAsc:find_movement_task(key_name)
    local context = self:current_context()
    if context.ok ~= true then
        self.debug_log(function()
            return "[player-asc-task-lookup] key=" .. tostring(key_name)
                .. " skipped reason=" .. tostring(context.reason)
                .. " playerState=" .. tostring(context.player_state_identity)
                .. " abilitySystemProbe="
                .. self.runtime:property_probe_text("AbilitySystemComponent",
                    context.ability_system_read)
        end)
        return nil, "", "player-asc:" .. tostring(context.reason)
    end

    local known_tasks_read = self.runtime:read_object_property(
        context.ability_system, "KnownTasks")
    local known_tasks_checked = 0
    for _, object in ipairs(
        self.runtime:array_items(known_tasks_read.value, 32))
    do
        if self.runtime:is_usable_object(object) then
            known_tasks_checked = known_tasks_checked + 1
            local identity = self.runtime:object_identity_text(object)
            if self.core.movement_task_is_cancelable(identity) then
                self.debug_log(function()
                    return "[player-asc-task-lookup] key="
                        .. tostring(key_name)
                        .. " playerState="
                        .. tostring(context.player_state_identity)
                        .. " abilitySystem="
                        .. tostring(context.ability_system_identity)
                        .. " checked=" .. tostring(known_tasks_checked)
                        .. " moveMatches=1"
                        .. " result=" .. tostring(identity)
                        .. " resultSource=KnownTasks"
                end)
                return object, identity, "player-asc:KnownTasks"
            end
        end
    end

    local entries = self.runtime:ability_system_task_entries(
        context.ability_system, "AbilityTask", 32)
    local move_matches = 0
    local result, result_identity, result_source = nil, "", ""
    local parts = self.debug_enabled() and {} or nil
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
        if parts ~= nil and index <= 12 then
            table.insert(parts,
                tostring(entry.source) .. "=" .. tostring(identity))
        end
    end
    if parts ~= nil and #entries > 12 then
        table.insert(parts, "truncated=" .. tostring(#entries - 12))
    end
    self.debug_log(function()
        return "[player-asc-task-lookup] key=" .. tostring(key_name)
            .. " playerState=" .. tostring(context.player_state_identity)
            .. " abilitySystem=" .. tostring(context.ability_system_identity)
            .. " checked=" .. tostring(#entries)
            .. " moveMatches=" .. tostring(move_matches)
            .. " result=" .. tostring(result_identity)
            .. " resultSource=" .. tostring(result_source)
            .. " abilitySystemProbe="
            .. self.runtime:property_probe_text("AbilitySystemComponent",
                context.ability_system_read)
            .. " tasks=" .. table.concat(parts or {}, " | ")
    end)
    if self.runtime:is_usable_object(result) then
        return result, result_identity, "player-asc:" .. result_source
    end
    return nil, "", "player-asc:no-move-task"
end

return PlayerAsc
