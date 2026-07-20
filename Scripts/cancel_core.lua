local core = {}

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

local KEY_ALIASES = {
    ESC = "ESCAPE",
    RIGHTMOUSEBUTTON = "RIGHT_MOUSE_BUTTON",
}

local DIRECTIONAL_CANCEL_KEYS = {
    A = true,
    W = true,
    S = true,
    D = true,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(trim(value))
end

local function copy_array(values)
    local result = {}
    for _, value in ipairs(values or {}) do
        table.insert(result, value)
    end
    return result
end

local function bool_from_string(value, default_value)
    local normalized = upper(value)
    if normalized == "" then return default_value end
    if normalized == "1" or normalized == "TRUE"
        or normalized == "YES" or normalized == "ON"
    then
        return true
    end
    if normalized == "0" or normalized == "FALSE"
        or normalized == "NO" or normalized == "OFF"
    then
        return false
    end
    return default_value
end

function core.default_cancel_keys()
    return copy_array(DEFAULT_CANCEL_KEYS)
end

function core.parse_cancel_keys(value)
    local result = {}
    local seen = {}
    for part in string.gmatch(tostring(value or ""), "([^,]+)") do
        local normalized = upper(part)
        normalized = KEY_ALIASES[normalized] or normalized
        if normalized ~= "" and seen[normalized] ~= true then
            seen[normalized] = true
            table.insert(result, normalized)
        end
    end
    if #result == 0 then
        return core.default_cancel_keys()
    end
    return result
end

function core.config_from_ini(ini)
    ini = ini or {}
    local keep_ore_on_mining_cancellation =
        ini.KEEPOREONMININGCANCELLATION
    if keep_ore_on_mining_cancellation == nil then
        keep_ore_on_mining_cancellation =
            ini.ENABLEMININGCANCELLATION
    end
    return {
        debug = bool_from_string(ini.DEBUG, false),
        enable_bench_and_ladder_cancellation = bool_from_string(
            ini.ENABLEBENCHANDLADDERCANCELLATION, true),
        enable_conversation_cancellation = bool_from_string(
            ini.ENABLECONVERSATIONCANCELLATION, true),
        enable_wasd_cancellation = bool_from_string(
            ini.ENABLEWASDCANCELLATION, true),
        keep_ore_on_mining_cancellation = bool_from_string(
            keep_ore_on_mining_cancellation, false),
        cancel_keys = core.parse_cancel_keys(ini.CANCELKEYS),
    }
end

function core.cancel_key_lookup_candidates(key_name)
    local normalized = upper(key_name)
    normalized = KEY_ALIASES[normalized] or normalized
    if normalized == "" then return {} end
    return { normalized }
end

function core.is_directional_cancel_key(key_name)
    local normalized = upper(key_name)
    normalized = KEY_ALIASES[normalized] or normalized
    return DIRECTIONAL_CANCEL_KEYS[normalized] == true
end

function core.config_allows_cancel_key(config, key_name)
    config = config or {}
    return config.enable_wasd_cancellation ~= false
        or not core.is_directional_cancel_key(key_name)
end

function core.generic_task_result_is_cancelled(value)
    local normalized = upper(value)
    local numeric = tonumber(normalized)
    if numeric ~= nil then return numeric == 1 end

    return normalized == "CANCELLED"
        or normalized == "EGENERICTASKRESULT::CANCELLED"
        or string.find(normalized, "::CANCELLED", 1, true) ~= nil
        or string.find(normalized, ".CANCELLED", 1, true) ~= nil
end

function core.is_player_identity(identity)
    return string.find(tostring(identity or ""), "G1RPlayerState", 1, true)
        ~= nil
end

function core.is_freepoint_ability_identity(identity)
    return string.find(tostring(identity or ""),
        "GameplayAbilityInteractFreePoint", 1, true) ~= nil
end

function core.is_move_to_interaction_task_identity(identity)
    return string.find(tostring(identity or ""),
        "AbilityTask_MoveIntoPositionForInteraction", 1, true) ~= nil
end

function core.is_mining_identity(identity)
    return string.find(tostring(identity or ""), "Mining", 1, true) ~= nil
end

function core.is_mining_ore_item_identity(identity)
    return string.find(tostring(identity or ""),
        "ItMi_Orenugget", 1, true) ~= nil
end

function core.classify_blocking_interaction(identity)
    local text = tostring(identity or "")
    if text == "" then
        return { action = "ignore", reason = "missing identity" }
    end
    if not core.is_player_identity(text) then
        return { action = "ignore", reason = "not player owned" }
    end
    if core.is_mining_identity(text) then
        return {
            action = "track",
            reason = "player mining interaction",
            mining = true,
        }
    end
    return { action = "track", reason = "player blocking interaction" }
end

function core.identities_match(left, right)
    local left_text = tostring(left or "")
    local right_text = tostring(right or "")
    return left_text ~= "" and left_text == right_text
end

return core
