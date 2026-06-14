local diagnostics = {}

local RUNTIME_INSTANCE_SCAN_COOLDOWN_MS = 750

local runtime_scan_terms = {
    "AbilityTask_Interaction_Human_Cook_Pan",
    "AbilityTask_Interaction_Player_Cook_Cauldron",
    "AbilityTask_Interaction_Human_Cook_Cauldron",
    "AbilityTask_InteractionSpot_Montage",
    "AbilityTask_CraftItems",
    "BeginInteractionWithoutSpot",
    "CancelAbilitiesWithTag",
    "CancelAllCurrentActionsAndMovement",
    "CancelTasksOfClass",
    "EndAnyOngoingInteraction",
    "EndState_Cancel",
    "RequestEndAnyOngoingInteraction",
    "StartInteractingWith",
    "StopInteractingWith",
    "TryEndInteraction",
    "TryInteractionWithoutSpot",
    "GameplayAbilityCrafting",
    "AllowInstantCancelInteractions",
    "bAllowInterruptAtAnyTime",
    "bAllowInterruptLoopOnCancel",
    "m_IsDoingInteractAction",
    "State_Interact",
    "Action_Crafting_Cook_Pan",
    "Action_Crafting_Cook_Cauldron",
    "Action_Ambient_Cook_Cauldron",
}

local DiagnosticRuntime = {}
DiagnosticRuntime.__index = DiagnosticRuntime

local function noop()
end

local function default_get_config()
    return {}
end

local function runtime_scan_matches(contains, full_name)
    for _, term in ipairs(runtime_scan_terms) do
        if contains(full_name, term) then
            return true
        end
    end
    return false
end

function diagnostics.format_snapshot(snapshot)
    snapshot = snapshot or {}
    return "rotationMode=" .. tostring(snapshot.rotation_mode)
        .. " movementState=" .. tostring(snapshot.movement_state)
        .. " movementAction=" .. tostring(snapshot.movement_action)
        .. " requestedMovementAction=" .. tostring(snapshot.requested_movement_action)
        .. " animCombat=" .. tostring(snapshot.anim_is_in_combat)
        .. " animAlive=" .. tostring(snapshot.anim_is_alive)
        .. " animConversation=" .. tostring(snapshot.anim_is_conversation)
        .. " animCinematic=" .. tostring(snapshot.anim_is_cinematic)
end

function diagnostics.new(dependencies)
    dependencies = dependencies or {}
    return setmetatable({
        core = dependencies.core,
        get_config = dependencies.get_config or default_get_config,
        log = dependencies.log or noop,
        contains = dependencies.contains,
        now_ms = dependencies.now_ms,
        find_all_of = dependencies.find_all_of,
        find_all_of_available = dependencies.find_all_of_available,
        is_usable_object = dependencies.is_usable_object,
        get_full_name = dependencies.get_full_name,
        get_class_full_name = dependencies.get_class_full_name,
        get_param_object = dependencies.get_param_object,
        param_to_log_string = dependencies.param_to_log_string,
        locomotion_snapshot = dependencies.locomotion_snapshot,
        last_runtime_instance_scan_ms = -1000000,
    }, DiagnosticRuntime)
end

function DiagnosticRuntime:find_all_available()
    if type(self.find_all_of_available) == "function" then
        return self.find_all_of_available() == true
    end
    return type(self.find_all_of) == "function"
end

function DiagnosticRuntime:scan_runtime_objects(kind, limit)
    local ok, objects = pcall(self.find_all_of, kind)
    if not ok then
        self.log("[runtime-scan] " .. tostring(kind) .. " failed: " .. tostring(objects))
        return 0
    end
    if type(objects) ~= "table" then
        self.log("[runtime-scan] " .. tostring(kind) .. " returned " .. tostring(type(objects)))
        return 0
    end

    local matches = 0
    local logged = 0
    for _, object in ipairs(objects) do
        local full_name = self.get_full_name(object)
        if runtime_scan_matches(self.contains, full_name) then
            matches = matches + 1
            if logged < limit then
                logged = logged + 1
                self.log("[runtime-scan] " .. tostring(kind) .. " " .. tostring(logged)
                    .. " " .. full_name)
            end
        end
    end
    self.log("[runtime-scan] " .. tostring(kind) .. " matches=" .. tostring(matches)
        .. " logged=" .. tostring(logged))
    return matches
end

function DiagnosticRuntime:run_runtime_function_scan()
    local config = self.get_config()
    if self.core.startup_runtime_scan_allowed(config) ~= true then
        return
    end
    if not self:find_all_available() then
        self.log("[runtime-scan] FindAllOf is unavailable.")
        return
    end
    local limit = tonumber(config.runtime_function_scan_limit) or 80
    self.log("[runtime-scan] Starting targeted Class/Function scan.")
    self:scan_runtime_objects("Class", limit)
    self:scan_runtime_objects("Function", limit)
end

function DiagnosticRuntime:matches_runtime_instance_scan_terms(object_name, class_name)
    local haystack = string.lower(tostring(object_name) .. " " .. tostring(class_name))
    for _, term in ipairs(self.core.runtime_instance_scan_match_terms()) do
        if string.find(haystack, term, 1, true) ~= nil then
            return true
        end
    end
    return false
end

function DiagnosticRuntime:log_runtime_instance_scan(source, snapshot)
    local config = self.get_config()
    if config.runtime_function_scan ~= true or not self:find_all_available() then
        return
    end
    local now = self.now_ms()
    if now - self.last_runtime_instance_scan_ms < RUNTIME_INSTANCE_SCAN_COOLDOWN_MS then
        return
    end
    self.last_runtime_instance_scan_ms = now

    self.log("[runtime-instance-scan] source=" .. tostring(source)
        .. " " .. diagnostics.format_snapshot(snapshot or self.locomotion_snapshot()))
    for _, class_name in ipairs(self.core.runtime_instance_scan_classes()) do
        local ok, objects = pcall(self.find_all_of, class_name)
        if not ok then
            self.log("[runtime-instance-scan] class=" .. tostring(class_name)
                .. " failed=" .. tostring(objects))
        elseif type(objects) ~= "table" then
            self.log("[runtime-instance-scan] class=" .. tostring(class_name)
                .. " returned=" .. tostring(type(objects)))
        else
            local logged = 0
            local match_count = 0
            local match_logged = 0
            for _, object in ipairs(objects) do
                if self.is_usable_object(object) then
                    logged = logged + 1
                    local object_name = self.get_full_name(object)
                    local class_full_name = self.get_class_full_name(object)
                    if logged <= 4 then
                        self.log("[runtime-instance-scan] class=" .. tostring(class_name)
                            .. " index=" .. tostring(logged)
                            .. " object=" .. object_name
                            .. " objectClass=" .. class_full_name)
                    end
                    if self:matches_runtime_instance_scan_terms(object_name, class_full_name) then
                        match_count = match_count + 1
                        if match_logged < 12 then
                            match_logged = match_logged + 1
                            self.log("[runtime-instance-scan-match] class="
                                .. tostring(class_name)
                                .. " matchIndex=" .. tostring(match_count)
                                .. " object=" .. object_name
                                .. " objectClass=" .. class_full_name)
                        end
                    end
                end
            end
            self.log("[runtime-instance-scan] class=" .. tostring(class_name)
                .. " count=" .. tostring(logged))
            if logged > 0 then
                self.log("[runtime-instance-scan-match] class=" .. tostring(class_name)
                    .. " matchCount=" .. tostring(match_count))
            end
        end
    end
end

function DiagnosticRuntime:log_discovery_event(source, context, ...)
    local config = self.get_config()
    if not config.discovery_mode and not config.debug then
        return
    end
    local params = {}
    local count = select("#", ...)
    for index = 1, count do
        params[index] = self.param_to_log_string(select(index, ...))
    end
    local context_name = self.get_full_name(self.get_param_object(context) or context)
    local snapshot = self.locomotion_snapshot()
    self.log("[discover] source=" .. tostring(source)
        .. " context=" .. tostring(context_name)
        .. " params=[" .. table.concat(params, " | ") .. "]"
        .. " " .. diagnostics.format_snapshot(snapshot))
end

return diagnostics
