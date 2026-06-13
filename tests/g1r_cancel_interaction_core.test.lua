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
assert_false(core.startup_runtime_scan_allowed(config),
    "runtime scan alone does not allow startup scan")

local discovery_scan_config = core.config_from_ini(core.parse_ini([[
DiscoveryMode=true
RuntimeFunctionScan=true
]]))
assert_true(core.startup_runtime_scan_allowed(discovery_scan_config),
    "discovery plus runtime scan allows startup scan")

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

local repeated_ready_hook_cache_update = core.classify_cached_hero_update({
    previous_identity = "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PlayerCharacterBP_C_1",
    next_identity = "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PlayerCharacterBP_C_1",
    source = "GothicCharacter:BP_IsGameplayReady",
})
assert_false(repeated_ready_hook_cache_update.changed,
    "same hero identity is not a cache change")
assert_false(repeated_ready_hook_cache_update.refresh_runtime_refs,
    "readiness poll does not refresh runtime refs for same hero")
assert_false(repeated_ready_hook_cache_update.should_log,
    "readiness poll does not log same hero")

local new_hero_cache_update = core.classify_cached_hero_update({
    previous_identity = "PlayerCharacterBP_C old",
    next_identity = "PlayerCharacterBP_C new",
    source = "GothicCharacter:BP_IsGameplayReady",
})
assert_true(new_hero_cache_update.changed, "new hero identity changes cache")
assert_true(new_hero_cache_update.refresh_runtime_refs,
    "new hero identity refreshes runtime refs")
assert_true(new_hero_cache_update.should_log, "new hero identity logs once")

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

assert_true(core.is_movement_cancel_key("A"), "A is movement cancel key")
assert_true(core.is_movement_cancel_key("w"), "W is movement cancel key")
assert_true(core.is_movement_cancel_key("S"), "S is movement cancel key")
assert_true(core.is_movement_cancel_key("d"), "D is movement cancel key")
assert_true(core.is_movement_cancel_key("F"), "F is movement-phase cancel key")
assert_true(core.is_movement_cancel_key("ESCAPE"),
    "ESCAPE is movement-phase cancel key")

local movement_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(movement_interaction_allowed.allowed,
    "movement key active interaction cancel allowed")
assert_equal(movement_interaction_allowed.reason, "movement interaction active",
    "movement interaction allowed reason")

local movement_action_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "D",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(movement_action_interaction_allowed.allowed,
    "movement action 7 cancel allowed without tracked interaction")
assert_equal(movement_action_interaction_allowed.reason, "movement action interaction active",
    "movement action interaction allowed reason")

local sleep_movement_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    sleep_movement_active = true,
    movement_action = 0,
    requested_movement_action = 0,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(sleep_movement_interaction_allowed.allowed,
    "sleep movement interaction cancel allowed without movement action 7")
assert_equal(sleep_movement_interaction_allowed.reason, "sleep movement interaction active",
    "sleep movement interaction allowed reason")

local requested_only_interaction_blocked = core.classify_movement_interaction_cancel({
    key_name = "W",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 0,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(requested_only_interaction_blocked.allowed,
    "requested-only movement interaction blocked")
assert_equal(requested_only_interaction_blocked.reason, "movement action inactive",
    "requested-only movement interaction blocked reason")

local action_key_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "F",
    player_ready = true,
    interaction_active = true,
    interaction_kind = "ambient",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(action_key_interaction_allowed.allowed,
    "action key movement interaction cancel allowed")
assert_equal(action_key_interaction_allowed.reason, "movement interaction active",
    "action key movement interaction allowed reason")

local escape_key_interaction_allowed = core.classify_movement_interaction_cancel({
    key_name = "ESCAPE",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_true(escape_key_interaction_allowed.allowed,
    "escape movement action cancel allowed")
assert_equal(escape_key_interaction_allowed.reason, "movement action interaction active",
    "escape movement action allowed reason")

local action_key_menu_open_blocked = core.classify_movement_interaction_cancel({
    key_name = "F",
    player_ready = true,
    interaction_active = false,
    interaction_kind = "none",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = true,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(action_key_menu_open_blocked.allowed,
    "action key movement cancel blocked while menu is open")
assert_equal(action_key_menu_open_blocked.reason, "menu open",
    "action key menu-open blocked reason")

local movement_interaction_lockout = core.classify_movement_interaction_cancel({
    key_name = "A",
    player_ready = true,
    interaction_active = true,
    interaction_cancel_lockout = true,
    interaction_kind = "ambient",
    movement_action = 7,
    requested_movement_action = 7,
    paused = false,
    menu_open = false,
    console_open = false,
    dialogue_or_cutscene = false,
    alive = true,
    unsafe_transition = false,
    airborne = false,
    combat_or_finisher = false,
})
assert_false(movement_interaction_lockout.allowed,
    "movement interaction lockout blocked")
assert_equal(movement_interaction_lockout.reason, "interaction cancel cooldown",
    "movement interaction lockout reason")

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

local interaction_cancel_methods = core.interaction_cancel_method_names()
assert_equal(interaction_cancel_methods[1], "K2_CancelAbility",
    "first interaction cancel method")
assert_equal(interaction_cancel_methods[2], "K2_EndAbility",
    "second interaction cancel method")
assert_equal(interaction_cancel_methods[3], "RequestEndAnyOngoingInteraction",
    "third interaction cancel method")
assert_equal(interaction_cancel_methods[#interaction_cancel_methods],
    "CancelAllCurrentActionsAndMovement", "last interaction cancel method")

local movement_action_cancel_methods = core.movement_action_cancel_method_names()
assert_equal(movement_action_cancel_methods[1], "RequestEndAnyOngoingInteraction",
    "first movement action cancel method")
assert_equal(movement_action_cancel_methods[2], "EndAnyOngoingInteraction",
    "second movement action cancel method")
assert_equal(movement_action_cancel_methods[#movement_action_cancel_methods],
    "CancelAllCurrentActionsAndMovement", "last movement action cancel method")

assert_equal(#core.movement_action_task_cancel_method_names(), 0,
    "movement-only cancel does not call task cancel methods without player context")
assert_equal(#core.movement_action_task_class_names(), 0,
    "movement-only cancel does not scan global interaction tasks")

local player_state_identity =
    "G1RPlayerState /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_1"
local player_ability_name =
    "GameplayAbilityInteractFreePoint /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_1.GameplayAbilityInteractFreePoint_2"
local player_sleep_ability_name =
    "GA_Human_Sleep_Bed_Low /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_1.GA_Human_Sleep_Bed_Low_4"
local sleep_task_name =
    "AbilityTask_Interaction_Human_Sleep_Seated /Engine/Transient.AbilityTask_Interaction_Human_Sleep_Seated_1"
local player_sleep_task_name =
    "AbilityTask_Interaction_Player_SitAndSleep /Engine/Transient.AbilityTask_Interaction_Player_SitAndSleep_1"
local player_container_ability_name =
    "GA_Human_OpenContainer /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.G1RPlayerState_1.GA_Human_OpenContainer_5"
local player_container_task_name =
    "AbilityTask_Interaction_Player_OpenContainer /Engine/Transient.AbilityTask_Interaction_Player_OpenContainer_1"
local npc_ability_name =
    "GameplayAbilityInteractFreePoint /Game/Maps/MainMap/MainMap.MainMap:PersistentLevel.State_SC_NOV_Novice_1.GameplayAbilityInteractFreePoint_3"
assert_true(core.object_name_belongs_to_owner(player_ability_name, player_state_identity),
    "player ability belongs to player state")
assert_true(core.object_name_belongs_to_owner(player_sleep_ability_name, player_state_identity),
    "player sleep ability belongs to player state")
assert_false(core.object_name_belongs_to_owner(npc_ability_name, player_state_identity),
    "npc ability does not belong to player state")
assert_true(core.object_name_is_sleep_bed_ability(player_sleep_ability_name),
    "sleep bed ability name detected")
assert_false(core.object_name_is_sleep_bed_ability(player_ability_name),
    "free point ability is not sleep bed ability")
assert_true(core.object_name_can_use_gameplay_ability_method(player_sleep_ability_name),
    "sleep ability can use gameplay ability reflected methods")
assert_true(core.object_name_can_use_gameplay_ability_method(player_ability_name),
    "free point ability can use gameplay ability reflected methods")
assert_false(core.object_name_can_use_gameplay_ability_method(
        "PlayerCharacterBP_C /Game/Maps/MainMap.MainMap:PersistentLevel.PlayerCharacterBP_C_1"),
    "player character cannot use gameplay ability reflected methods")
assert_true(core.object_name_is_sleep_interaction_task(sleep_task_name),
    "sleep interaction task name detected")
assert_false(core.object_name_is_sleep_interaction_task(player_sleep_ability_name),
    "sleep bed ability is not sleep interaction task")
assert_true(core.object_name_is_player_sleep_interaction_task(player_sleep_task_name),
    "player sleep interaction task name detected")
assert_false(core.object_name_is_player_sleep_interaction_task(sleep_task_name),
    "human sleep interaction task is not the player sleep task")
assert_true(core.object_name_is_container_ability(player_container_ability_name),
    "container ability name detected")
assert_false(core.object_name_is_container_ability(player_sleep_ability_name),
    "sleep bed ability is not container ability")
assert_true(core.object_name_is_player_container_interaction_task(
        player_container_task_name),
    "player container interaction task name detected")
assert_false(core.object_name_is_player_container_interaction_task(
        player_sleep_task_name),
    "player sleep task is not container task")
assert_true(core.interaction_cancel_should_continue_after_success(player_sleep_ability_name),
    "sleep bed ability cancel success continues to next target")
assert_true(core.interaction_cancel_should_continue_after_success(sleep_task_name),
    "sleep task cancel success continues to next target")
assert_true(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        sleep_interaction_context = true,
    }),
    "free point success continues in sleep interaction context")
assert_true(core.interaction_cancel_should_continue_after_success(player_ability_name, {
        container_interaction_context = true,
    }),
    "free point success continues in container interaction context")
assert_false(core.interaction_cancel_should_continue_after_success(player_ability_name),
    "free point ability cancel success is terminal")

assert_false(core.container_ability_fallback_allowed({
        container_task_count = 0,
        active_ability_is_container = true,
        tracked_object_is_container = false,
        tracked_animation_is_container = false,
    }),
    "container ability fallback requires current container context")
assert_true(core.container_ability_fallback_allowed({
        container_task_count = 1,
        active_ability_is_container = false,
        tracked_object_is_container = false,
        tracked_animation_is_container = false,
    }),
    "container task enables container fallback")
assert_true(core.container_ability_fallback_allowed({
        container_task_count = 0,
        active_ability_is_container = false,
        tracked_object_is_container = false,
        tracked_animation_is_container = true,
    }),
    "tracked container animation enables container fallback")

local main_source = assert(io.open("Scripts/main.lua", "r")):read("*a")
assert_true(string.find(main_source, "try_cancel_movement_action_without_context", 1, true) == nil,
    "movement-only cancel avoids direct Character/Controller method fallback")
assert_true(string.find(main_source, "movement-task-cancel", 1, true) == nil,
    "movement-only cancel avoids global task EndTask fallback")
assert_true(
    string.find(main_source, "active ability found; skipped generic interaction cancel", 1, true)
        ~= nil,
    "container ability detection skips generic interaction fallback")

local interaction_task_cancel_methods = core.interaction_task_cancel_method_names()
assert_equal(interaction_task_cancel_methods[1], "TransitionExit",
    "first task cancel method")
assert_equal(interaction_task_cancel_methods[2], "EndState_Cancel",
    "second task cancel method")

local sleep_ability_cancel_methods = core.interaction_sleep_ability_cancel_method_names()
assert_equal(sleep_ability_cancel_methods[1], "K2_CancelAbility",
    "first sleep ability cleanup method")
assert_equal(sleep_ability_cancel_methods[2], "K2_EndAbility",
    "second sleep ability cleanup method")

local sleep_montage_cancel_methods = core.sleep_montage_cancel_method_names()
assert_equal(sleep_montage_cancel_methods[1], "StopAnimMontage",
    "first sleep montage cancel method")
assert_equal(sleep_montage_cancel_methods[2], "Montage_Stop",
    "second sleep montage cancel method")

local sleep_root_task_cancel_methods = core.sleep_root_task_cancel_method_names()
assert_equal(sleep_root_task_cancel_methods[1], "EndTask",
    "first sleep root task cancel method")
assert_equal(sleep_root_task_cancel_methods[2], "EndTaskAsCancelled",
    "second sleep root task cancel method")

local sleep_interaction_task_cancel_methods =
    core.sleep_interaction_task_cancel_method_names()
assert_equal(sleep_interaction_task_cancel_methods[1], "EndTask",
    "first sleep interaction task cancel method")
assert_equal(#sleep_interaction_task_cancel_methods, 1,
    "sleep interaction task cancel uses the stable task end only")

local container_interaction_task_cancel_methods =
    core.container_interaction_task_cancel_method_names()
assert_equal(container_interaction_task_cancel_methods[1], "EndTask",
    "first container interaction task cancel method")
assert_equal(#container_interaction_task_cancel_methods, 1,
    "container interaction task cancel uses the stable task end only")

local container_ability_cancel_methods =
    core.interaction_container_ability_cancel_method_names()
assert_equal(container_ability_cancel_methods[1], "K2_CancelAbility",
    "first container ability cleanup method")
assert_equal(#container_ability_cancel_methods, 1,
    "container ability cleanup avoids direct K2_EndAbility")

local interaction_input_ability_class_paths = core.interaction_input_ability_class_paths()
assert_equal(#interaction_input_ability_class_paths, 0,
    "interaction input ability activation disabled")

local move_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_InteractWith:TaskInteractWithSpotIgnoreOwner")
assert_true(move_tracking.track, "interact-with hook tracked")
assert_equal(move_tracking.kind, "use-object", "interact-with hook kind")
assert_equal(move_tracking.phase, "move", "interact-with hook phase")

local montage_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.AbilityTask_InteractionSpot_Montage:SetupTransitions")
assert_true(montage_tracking.track, "montage hook tracked")
assert_equal(montage_tracking.kind, "ambient", "montage hook kind")
assert_equal(montage_tracking.phase, "animation", "montage hook phase")

local crafting_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.GameplayAbilityCrafting:EventPlayAction")
assert_false(crafting_tracking.track, "crafting hook not tracked as generic interaction")

local interact_free_point_tracking = core.interaction_tracking_from_hook(
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility")
assert_true(interact_free_point_tracking.track, "interact free point activation tracked")
assert_equal(interact_free_point_tracking.kind, "ambient", "interact free point kind")
assert_equal(interact_free_point_tracking.phase, "ability", "interact free point phase")

local bench_montage_tracking = core.interaction_tracking_from_montage_name(
    "AnimMontage /Game/Characters/Human/Animations/AM_Human_Sit_Bench_Enter")
assert_true(bench_montage_tracking.track, "bench sit montage tracked")
assert_equal(bench_montage_tracking.kind, "ambient", "bench sit montage kind")
assert_equal(bench_montage_tracking.phase, "animation", "bench sit montage phase")

local chair_montage_tracking = core.interaction_tracking_from_montage_name(
    "AM_Player_Chair_Sit_Down")
assert_true(chair_montage_tracking.track, "chair sit montage tracked")
assert_equal(chair_montage_tracking.kind, "ambient", "chair sit montage kind")

local sleep_bed_montage_tracking = core.interaction_tracking_from_montage_name(
    "AM_Human_Sleep_Bed_Low_Enter")
assert_true(sleep_bed_montage_tracking.track, "sleep bed montage tracked")
assert_equal(sleep_bed_montage_tracking.kind, "ambient", "sleep bed montage kind")

local unrelated_montage_tracking = core.interaction_tracking_from_montage_name(
    "AM_Human_DrawWeapon")
assert_false(unrelated_montage_tracking.track, "unrelated montage not tracked")

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
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility",
    "/Script/G1R.GameplayAbilityInteractFreePoint:K2_OnEndAbility",
    "/Script/G1R.GameplayAbilityInteract:K2_ActivateAbility",
    "/Script/G1R.GameplayAbilityInteract:K2_OnEndAbility",
    "/Script/G1R.GameplayAbilityInteractionBase:K2_ActivateAbility",
    "/Script/G1R.GameplayAbilityInteractionBase:K2_OnEndAbility",
    "/Script/G1R.AbilityTask_EndEquip:DoEndEquip",
    "/Script/G1R.AbilityTask_DrawWeapon:TaskDrawTorch",
    "/Script/Engine.PlayerController:ClientRestart",
    "/Script/Engine.PlayerController:InputKey",
    "/Script/Engine.PlayerInput:InputKey",
    "/Script/EnhancedInput.EnhancedPlayerInput:InputKey",
    "/Script/EnhancedInput.EnhancedPlayerInput:InjectInputForAction",
    "/Script/G1R.GameplayAbilitySleep:OnSleepUICloseButtonClicked",
    "/Script/G1R.GameplayAbilitySleep:Server_OnSleepUICloseButtonClicked",
    "/Script/G1R.GameplayAbilitySleep:OnPlayerGoToSleep",
    "/Script/G1R.GameplayAbilitySleep:OnGoToSleepAnimationFinished",
    "/Script/G1R.GameplayAbilitySleep:Client_StopAllMagicAbilitiesMontages",
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
local saw_player_input_key = false
local saw_interact_free_point = false
local saw_sleep_close = false
local saw_sleep_start = false
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
    elseif candidate == "/Script/Engine.PlayerController:InputKey" then
        saw_player_input_key = true
    elseif candidate == "/Script/G1R.GameplayAbilityInteractFreePoint:K2_ActivateAbility" then
        saw_interact_free_point = true
    elseif candidate == "/Script/G1R.GameplayAbilitySleep:OnSleepUICloseButtonClicked" then
        saw_sleep_close = true
    elseif candidate == "/Script/G1R.GameplayAbilitySleep:OnPlayerGoToSleep" then
        saw_sleep_start = true
    end
end
assert_true(saw_interact_with, "candidate includes AbilityTask_InteractWith")
assert_true(saw_crafting, "candidate includes GameplayAbilityCrafting")
assert_true(saw_cook_pan, "candidate includes cook pan task")
assert_true(saw_end_equip, "candidate includes AbilityTask_EndEquip")
assert_true(saw_client_restart, "candidate includes ClientRestart")
assert_true(saw_player_input_key, "candidate includes PlayerController InputKey")
assert_true(saw_interact_free_point, "candidate includes InteractFreePoint activation")
assert_true(saw_sleep_close, "candidate includes GameplayAbilitySleep close")
assert_true(saw_sleep_start, "candidate includes GameplayAbilitySleep start")

local instance_scan_classes = core.runtime_instance_scan_classes()
assert_equal(instance_scan_classes[1], "AbilityTask_Interaction_Human_Cook_Pan",
    "first runtime instance scan class")

local saw_pan_scan_class = false
local saw_cauldron_scan_class = false
local saw_base_task_scan_class = false
local saw_player_sleep_task_scan_class = false
local saw_crafting_scan_class = false
local saw_sleep_ability_scan_class = false
local saw_interact_free_point_scan_class = false
local saw_interaction_base_scan_class = false
local saw_container_scan_class = false
local saw_player_container_task_scan_class = false
for _, class_name in ipairs(instance_scan_classes) do
    if class_name == "AbilityTask_Interaction_Human_Cook_Pan" then
        saw_pan_scan_class = true
    elseif class_name == "AbilityTask_Interaction_Player_Cook_Cauldron" then
        saw_cauldron_scan_class = true
    elseif class_name == "AbilityTask_Interaction_Player_SitAndSleep" then
        saw_player_sleep_task_scan_class = true
    elseif class_name == "AbilityTask_InteractionSpot_Montage" then
        saw_base_task_scan_class = true
    elseif class_name == "GameplayAbilityCrafting" then
        saw_crafting_scan_class = true
    elseif class_name == "GameplayAbilitySleep" then
        saw_sleep_ability_scan_class = true
    elseif class_name == "GameplayAbilityInteractFreePoint" then
        saw_interact_free_point_scan_class = true
    elseif class_name == "GameplayAbilityInteractionBase" then
        saw_interaction_base_scan_class = true
    elseif class_name == "GA_Human_OpenContainer" then
        saw_container_scan_class = true
    elseif class_name == "AbilityTask_Interaction_Player_OpenContainer" then
        saw_player_container_task_scan_class = true
    end
end
assert_true(saw_pan_scan_class, "runtime instance scan includes cook pan")
assert_true(saw_cauldron_scan_class, "runtime instance scan includes player cook cauldron")
assert_true(saw_base_task_scan_class, "runtime instance scan includes base montage task")
assert_true(saw_player_sleep_task_scan_class,
    "runtime instance scan includes player sleep task")
assert_true(saw_crafting_scan_class, "runtime instance scan includes crafting ability")
assert_true(saw_sleep_ability_scan_class,
    "runtime instance scan includes sleep ability")
assert_true(saw_interact_free_point_scan_class,
    "runtime instance scan includes InteractFreePoint ability")
assert_true(saw_interaction_base_scan_class,
    "runtime instance scan includes interaction base ability")
assert_true(saw_container_scan_class,
    "runtime instance scan includes open container ability")
assert_true(saw_player_container_task_scan_class,
    "runtime instance scan includes player container task")

local instance_scan_match_terms = core.runtime_instance_scan_match_terms()
assert_equal(instance_scan_match_terms[1], "interact", "first runtime instance scan match term")

local saw_pan_scan_term = false
local saw_cauldron_scan_term = false
local saw_craft_scan_term = false
local saw_interact_scan_term = false
local saw_sleep_scan_term = false
local saw_bed_scan_term = false
local saw_container_scan_term = false
local saw_chest_scan_term = false
for _, term in ipairs(instance_scan_match_terms) do
    if term == "pan" then
        saw_pan_scan_term = true
    elseif term == "cauldron" then
        saw_cauldron_scan_term = true
    elseif term == "craft" then
        saw_craft_scan_term = true
    elseif term == "interact" then
        saw_interact_scan_term = true
    elseif term == "sleep" then
        saw_sleep_scan_term = true
    elseif term == "bed" then
        saw_bed_scan_term = true
    elseif term == "container" then
        saw_container_scan_term = true
    elseif term == "chest" then
        saw_chest_scan_term = true
    end
end
assert_true(saw_pan_scan_term, "runtime instance scan match terms include pan")
assert_true(saw_cauldron_scan_term, "runtime instance scan match terms include cauldron")
assert_true(saw_craft_scan_term, "runtime instance scan match terms include craft")
assert_true(saw_interact_scan_term, "runtime instance scan match terms include interact")
assert_true(saw_sleep_scan_term, "runtime instance scan match terms include sleep")
assert_true(saw_bed_scan_term, "runtime instance scan match terms include bed")
assert_true(saw_container_scan_term,
    "runtime instance scan match terms include container")
assert_true(saw_chest_scan_term, "runtime instance scan match terms include chest")

local keys = core.parse_cancel_keys(" f , escape , t ")
assert_equal(keys[1], "F", "normalized key 1")
assert_equal(keys[2], "ESCAPE", "normalized key 2")
assert_equal(keys[3], "T", "normalized key 3")

local empty_keys = core.parse_cancel_keys("")
assert_equal(empty_keys[1], "F", "empty keys default 1")
assert_equal(empty_keys[2], "ESCAPE", "empty keys default 2")

print("g1r_cancel_interaction_core.test.lua: PASS")
