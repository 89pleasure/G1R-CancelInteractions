package.path = "Scripts/?.lua;" .. package.path

local core = require("cancel_core")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s expected=%s actual=%s", label, tostring(expected), tostring(actual)))
    end
end

local function assert_true(value, label)
    if value ~= true then
        error(label .. " expected true")
    end
end

local function assert_false(value, label)
    if value ~= false then
        error(label .. " expected false")
    end
end

local parsed = core.parse_ini([[
Debug=true
DiscoveryMode=false
CancelKeys=F, ESCAPE
CooldownMs=300
AllowMontageFallback=true
RuntimeFunctionScan=true
RuntimeFunctionScanLimit=12
]])

local config = core.config_from_ini(parsed)
assert_true(config.debug, "debug")
assert_false(config.discovery_mode, "discovery")
assert_equal(config.cancel_keys[1], "F", "first cancel key")
assert_equal(config.cancel_keys[2], "ESCAPE", "second cancel key")
assert_equal(config.cooldown_ms, 300, "cooldown")
assert_true(config.allow_montage_fallback, "montage fallback")
assert_true(config.runtime_function_scan, "runtime function scan")
assert_equal(config.runtime_function_scan_limit, 12, "runtime function scan limit")

local defaults = core.config_from_ini({})
assert_false(defaults.debug, "default debug")
assert_false(defaults.discovery_mode, "default discovery")
assert_equal(defaults.cancel_keys[1], "F", "default first cancel key")
assert_equal(defaults.cancel_keys[2], "ESCAPE", "default second cancel key")
assert_equal(defaults.cancel_keys[3], "A", "default third cancel key")
assert_equal(defaults.cancel_keys[4], "W", "default fourth cancel key")
assert_equal(defaults.cancel_keys[5], "S", "default fifth cancel key")
assert_equal(defaults.cancel_keys[6], "D", "default sixth cancel key")
assert_equal(defaults.cooldown_ms, 250, "default cooldown")
assert_false(defaults.allow_montage_fallback, "default montage fallback")
assert_false(defaults.runtime_function_scan, "default runtime function scan")
assert_equal(defaults.runtime_function_scan_limit, 80, "default runtime function scan limit")

local flags = core.new_timed_flags()
flags:open("busy", 1000, 100)
assert_true(flags:active("busy", 500), "flag active")
assert_false(flags:active("busy", 1200), "flag expired")

local blocked = core.classify_cancel_safety({
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(blocked.allowed, "unsafe transition blocked")
assert_equal(blocked.reason, "unsafe transition", "unsafe reason")

local allowed = core.classify_cancel_safety({
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(allowed.allowed, "ambient interaction allowed")
assert_equal(allowed.reason, "ok", "allowed reason")

local crafting_allowed = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 0,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(crafting_allowed.allowed, "active crafting movement allowed")
assert_equal(crafting_allowed.reason, "crafting active", "crafting allowed reason")

local crafting_cancel_lockout = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_cancel_lockout = true,
    crafting_state = 0,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_cancel_lockout.allowed, "crafting cancel lockout blocked")
assert_equal(crafting_cancel_lockout.reason, "crafting cancel cooldown",
    "crafting cancel lockout reason")

local crafting_action_started = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 1,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_action_started.allowed, "started crafting action blocked")
assert_equal(crafting_action_started.reason, "crafting action started",
    "started crafting action reason")

local crafting_requested_only = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 0,
    movement_action = 0,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_requested_only.allowed, "requested-only crafting movement blocked")
assert_equal(crafting_requested_only.reason, "crafting idle",
    "requested-only crafting movement reason")

local crafting_idle = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 0,
    movement_action = 0,
    requested_movement_action = 0,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_idle.allowed, "idle crafting click blocked")
assert_equal(crafting_idle.reason, "crafting idle", "crafting idle reason")

local crafting_finished = core.classify_crafting_cancel({
    player_ready = true,
    crafting_recent = true,
    crafting_state = 8,
    movement_action = 7,
    requested_movement_action = 7,
    alive = true,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(crafting_finished.allowed, "finished crafting blocked")
assert_equal(crafting_finished.reason, "crafting finished", "crafting finished reason")

local crafting_cancel_methods = core.crafting_cancel_method_names()
assert_equal(crafting_cancel_methods[1], "K2_CancelAbility", "first crafting cancel method")
assert_equal(crafting_cancel_methods[2], "K2_EndAbility", "second crafting cancel method")
assert_equal(crafting_cancel_methods[3], "ButtonCraftingMenuExit_Bind",
    "third crafting cancel method")
assert_equal(crafting_cancel_methods[4], "OnCraftFinished", "fourth crafting cancel method")

local reflected_modes = core.reflected_call_modes(nil)
assert_equal(reflected_modes[1], "call", "first reflected call mode")
assert_equal(reflected_modes[2], "self", "second reflected call mode")
assert_equal(reflected_modes[3], "bare", "third reflected call mode")

local candidates = core.discovery_hook_candidates()
local expected_candidates = {
    "/Script/G1R.GothicCharacter:GetInventory",
    "/Script/G1R.GothicCharacter:GetCarryComponent",
    "/Script/G1R.InventoryComponent:EquipItem",
    "/Script/G1R.InventoryComponent:UnEquipItem",
    "/Script/G1R.InventoryComponent:TakeOutTorch",
    "/Script/G1R.GameplayAbilityCrafting:EventPlayAction",
    "/Script/G1R.GameplayAbilityCrafting:EventAnimIdleEnd",
    "/Script/G1R.GameplayAbilityCrafting:EventAnimStartHud",
    "/Script/G1R.GameplayAbilityCrafting:OnCraftFinished",
    "/Script/G1R.GameplayAbilityCrafting:Multicast_StartCrafting",
    "/Script/G1R.GameplayAbilityCrafting:Multicast_SetCraftingState",
    "/Script/G1R.GameplayAbilityCrafting:Server_StartCrafting",
    "/Script/G1R.GameplayAbilityCrafting:Server_SetCraftingState",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithNavLink",
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotIgnoreOwner",
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions",
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions_Implementation",
    "/Script/Angelscript.UAbilityTask_Interaction_Human_Cook_Pan:SetupTransitions",
    "/Script/Angelscript.UAbilityTask_Interaction_Human_Cook_Pan:SetupTransitions_Implementation",
    "/Script/Angelscript.UAbilityTask_Interaction_Player_Cook_Cauldron:SetupTransitions",
    "/Script/Angelscript.UAbilityTask_Interaction_Player_Cook_Cauldron:SetupTransitions_Implementation",
    "/Script/G1R.AbilityTask_EndEquip:DoEndEquip",
    "/Script/G1R.AbilityTask_DrawWeapon:TaskDrawTorch",
    "/Script/Engine.PlayerController:ClientRestart",
    "/Script/Engine.Character:PlayAnimMontage",
    "/Script/Engine.AnimInstance:Montage_Play",
    "/Script/Engine.AnimInstance:Montage_Stop",
}
assert_equal(#candidates, #expected_candidates, "candidate count")
for index, expected in ipairs(expected_candidates) do
    assert_equal(candidates[index], expected, "candidate " .. tostring(index))
end

local saw_end_equip = false
local saw_interact_with = false
local saw_cook_pan = false
local saw_crafting = false
local saw_client_restart = false
for _, candidate in ipairs(core.discovery_hook_candidates()) do
    if candidate == "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithNavLink" then
        saw_interact_with = true
    elseif candidate == "/Script/G1R.GameplayAbilityCrafting:EventPlayAction" then
        saw_crafting = true
    elseif candidate == "/Script/Angelscript.UAbilityTask_Interaction_Human_Cook_Pan:SetupTransitions" then
        saw_cook_pan = true
    elseif candidate == "/Script/G1R.AbilityTask_EndEquip:DoEndEquip" then
        saw_end_equip = true
    elseif candidate == "/Script/Engine.PlayerController:ClientRestart" then
        saw_client_restart = true
    end
end
assert_true(saw_interact_with, "candidate includes AbilityTask_InteractWith")
assert_true(saw_crafting, "candidate includes GameplayAbilityCrafting")
assert_true(saw_cook_pan, "candidate includes cook pan task")
assert_true(saw_end_equip, "candidate includes AbilityTask_EndEquip")
assert_true(saw_client_restart, "candidate includes ClientRestart")

local instance_scan_classes = core.runtime_instance_scan_classes()
assert_equal(instance_scan_classes[1], "AbilityTask_Interaction_Human_Cook_Pan",
    "first runtime instance scan class")

local saw_pan_scan_class = false
local saw_cauldron_scan_class = false
local saw_base_task_scan_class = false
local saw_crafting_scan_class = false
for _, class_name in ipairs(instance_scan_classes) do
    if class_name == "AbilityTask_Interaction_Human_Cook_Pan" then
        saw_pan_scan_class = true
    elseif class_name == "AbilityTask_Interaction_Player_Cook_Cauldron" then
        saw_cauldron_scan_class = true
    elseif class_name == "AbilityTask_InteractionSpot_Montage" then
        saw_base_task_scan_class = true
    elseif class_name == "GameplayAbilityCrafting" then
        saw_crafting_scan_class = true
    end
end
assert_true(saw_pan_scan_class, "runtime instance scan includes cook pan")
assert_true(saw_cauldron_scan_class, "runtime instance scan includes player cook cauldron")
assert_true(saw_base_task_scan_class, "runtime instance scan includes base montage task")
assert_true(saw_crafting_scan_class, "runtime instance scan includes crafting ability")

local instance_scan_match_terms = core.runtime_instance_scan_match_terms()
assert_equal(instance_scan_match_terms[1], "cook", "first runtime instance scan match term")

local saw_pan_scan_term = false
local saw_cauldron_scan_term = false
local saw_craft_scan_term = false
for _, term in ipairs(instance_scan_match_terms) do
    if term == "pan" then
        saw_pan_scan_term = true
    elseif term == "cauldron" then
        saw_cauldron_scan_term = true
    elseif term == "craft" then
        saw_craft_scan_term = true
    end
end
assert_true(saw_pan_scan_term, "runtime instance scan match terms include pan")
assert_true(saw_cauldron_scan_term, "runtime instance scan match terms include cauldron")
assert_true(saw_craft_scan_term, "runtime instance scan match terms include craft")

local keys = core.parse_cancel_keys(" f , escape , t ")
assert_equal(keys[1], "F", "normalized key 1")
assert_equal(keys[2], "ESCAPE", "normalized key 2")
assert_equal(keys[3], "T", "normalized key 3")

local empty_keys = core.parse_cancel_keys("")
assert_equal(empty_keys[1], "F", "empty keys default 1")
assert_equal(empty_keys[2], "ESCAPE", "empty keys default 2")

print("g1r_cancel_interaction_core.test.lua: PASS")
