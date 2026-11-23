-- Pure-data scenario inventory shared by the engine catalog and host checks.
-- Order is intentional: scenarios can share an evolving test world.
local M = {
  campaign = {
    'campaign_filtered_one_setup',
    'campaign_filtered_one_verify',
    'campaign_nested_attach_setup',
    'campaign_nested_attach_verify',
    'campaign_nested_place_setup',
    'campaign_nested_place_verify',
    'campaign_reversible_setup',
    'campaign_reversible_verify',
    'campaign_provider_setup',
    'campaign_provider_verify',
    'campaign_deferred_setup',
    'campaign_deferred_verify',
    'campaign_logical_move_setup',
    'campaign_logical_move_verify',
    'campaign_starting_door_setup',
    'campaign_starting_door_verify',
    'campaign_retired_move_setup',
    'campaign_retired_move_verify',
    'campaign_actor_local_setup',
    'campaign_actor_local_verify',
    'campaign_creature_mesh_setup',
    'campaign_creature_mesh_verify',
    'campaign_inventory_ensure_setup',
    'campaign_inventory_ensure_verify',
    'campaign_container_apply_boundary',
    'campaign_container_revert_boundary',
    'campaign_container_verify',
    'campaign_respawning_container_setup',
    'campaign_respawning_container_verify',
    'campaign_vfr_setup',
    'campaign_vfr_verify',
    'campaign_plan_change_setup',
    'campaign_plan_change_verify',
    'campaign_static_baseline',
    'campaign_static_initial',
    'campaign_static_extended',
    'campaign_static_removed',
    'campaign_static_history_verify',
    'campaign_content_phase_setup',
    'campaign_content_phase_resave',
    'campaign_content_phase_verify',
    'campaign_content_phase_changed',
  },
  ordinary = {
    -- Boundary contracts run before static fixtures mutate save state.
    'runtime_boundary_contracts',

    'content_phase_mixed',

    -- Irreversible operations run before another scenario opens this quest guard.
    'standalone_kill_actor',

    'balmora_exterior_lamps',
    'cell_exclude',
    'inventory_ops',
    'structured_selectors',
    'inventory_ensure',
    'eight_plates_owner_clear',
    'targeting_duplicates',
    'quest_stage_door_guard',
    'exact_cell_state_reconcile',
    'guild_chest_relocation',
    'starting_transform',
    'starting_door',
    'combined_chest_relocation_disable',
    'mesh_replace_then_state',
    'mesh_child_source_record',
    'creature_mesh_replacement',
    'guard_conflict',
    'scope_cross_cell',
    'child_inventory_parent_annotated',
    'child_inventory_narrowed',
    'child_direct_payloads',
    'nested_place_outputs',
    'nested_attach_outputs',
    'tuple_nested_attach_acceptance',
    'filtered_one_claim',
    'static_nested_attach_outputs',
    'keyed_modify_annotated',
    'external_guard_plugin',
    'weather_guard',
    'dsl_edge_cases',
    'runtime_broad_loaded_cell_scope',
    'time_day_guard',
    'compat_formats',
    'inventory_owner_annotated',
    'inventory_revert',
    'respawning_container_replacement',
    'vfr_compat',
  },
  stress = {
    'guard_boundary_weather_stress',
    'guard_window_boundary_stress',
    'guard_boundary_quest_stress',
    'broad_static_dor_application',
  },
}

-- Files live below fixtures/data until the host stages the selected union at
-- these VFS paths. Mounting the harness code alone discovers no authored work.
M.fixtures = {
  content_phase_mixed = {'scripts/mom/config/content_phase_mixed.yaml'},
  runtime_boundary_contracts = {'scripts/mom/actions/broken_unused_fixture.lua'},
  standalone_kill_actor = {'scripts/mom/config/balmora_standalone_kill_actor_example.yaml'},
  balmora_exterior_lamps = {'scripts/mom/config/balmora_exterior_replacement_example.yaml'},
  cell_exclude = {'scripts/mom/config/balmora_cell_exclude_example.yaml'},
  inventory_ops = {'scripts/mom/config/balmora_inventory_ops_example.yaml'},
  structured_selectors = {'scripts/mom/config/structured_selectors.yaml'},
  inventory_ensure = {'scripts/mom/config/inventory_ensure.yaml'},
  eight_plates_owner_clear = {'scripts/mom/config/balmora_owner_example.yaml'},
  targeting_duplicates = {'scripts/mom/config/balmora_targeting_duplicates_example.yaml'},
  quest_stage_door_guard = {'scripts/mom/config/balmora_quest_stage_guard_example.yaml'},
  exact_cell_state_reconcile = {'scripts/mom/config/balmora_cross_cell_chest_disable_example.yaml'},
  guild_chest_relocation = {'scripts/mom/config/balmora_relocation_example.yaml'},
  starting_transform = {'scripts/mom/config/starting_transform_example.yaml'},
  starting_door = {'scripts/mom/config/starting_door_example.yaml'},
  combined_chest_relocation_disable = {'scripts/mom/config/balmora_combined_relocation_disable_example.yaml'},
  mesh_replace_then_state = {'scripts/mom/config/balmora_mesh_replace_then_state_example.yaml'},
  mesh_child_source_record = {'scripts/mom/config/mesh_child_source_record.yaml'},
  creature_mesh_replacement = {'scripts/mom/config/creature_mesh_replacement.yaml'},
  guard_conflict = {'scripts/mom/config/balmora_guard_conflict_example.yaml'},
  scope_cross_cell = {'scripts/mom/config/balmora_scope_cross_cell_example.yaml'},
  keyed_modify_annotated = {'scripts/mom/config/balmora_scope_cross_cell_example.yaml'},
  child_inventory_parent_annotated = {'scripts/mom/config/balmora_child_actions_example.yaml'},
  child_inventory_narrowed = {'scripts/mom/config/balmora_child_actions_example.yaml'},
  child_direct_payloads = {'scripts/mom/config/balmora_child_direct_payloads_example.yaml'},
  nested_place_outputs = {'scripts/mom/config/balmora_nested_place_example.yaml'},
  nested_attach_outputs = {'scripts/mom/config/balmora_nested_attach_example.yaml'},
  filtered_one_claim = {
    'scripts/mom/compat/fixture_filtered_attach/translator.lua',
    'scripts/fixture_filtered_attach/data/one.yaml',
  },
  tuple_nested_attach_acceptance = {'scripts/mom/config/tuple_nested_attach_acceptance.yaml'},
  static_nested_attach_outputs = {'scripts/mom/config/static_nested_attach_example.yaml'},
  external_guard_plugin = {'scripts/mom/config/balmora_external_guard_example.yaml'},
  weather_guard = {'scripts/mom/config/balmora_weather_guard_example.yaml'},
  dsl_edge_cases = {'scripts/mom/config/balmora_dsl_edge_cases_example.yaml'},
  runtime_broad_loaded_cell_scope = {'scripts/mom/config/runtime_broad_loaded_cell_scope_example.yaml'},
  time_day_guard = {'scripts/mom/config/balmora_time_day_guard_example.yaml'},
  inventory_owner_annotated = {'scripts/mom/config/balmora_inventory_revert_example.yaml'},
  inventory_revert = {'scripts/mom/config/balmora_inventory_revert_example.yaml'},
  respawning_container_replacement = {'scripts/mom/config/respawning_container_replacement.yaml'},
  vfr_compat = {
    'scripts/variationframework/placements/data/mom_vfr_coincident.yaml',
    'scripts/variationframework/plants/data/mom_vfr_plant.yaml',
    'scripts/variationframework/banners/data/mom_vfr_static.yaml',
    'scripts/variationframework/clutter/data/00_mom_vfr_keep.yaml',
    'scripts/variationframework/clutter/data/10_mom_vfr_fallback.yaml',
    'scripts/staticSwitcher/data/mom_vfr_priority.yaml',
  },
  guard_boundary_weather_stress = {'scripts/mom/config/balmora_guard_boundary_weather_stress.yaml'},
  guard_window_boundary_stress = {'scripts/mom/config/balmora_guard_window_boundary_stress.yaml'},
  guard_boundary_quest_stress = {'scripts/mom/config/balmora_guard_boundary_quest_stress.yaml'},
  compat_formats = {
    'scripts/staticSwitcher/data/balmora_sss_compat.yaml',
    'MWSE/mods/_OR_/_OR_balmora_compat.lua',
  },
  broad_static_dor_application = {'MWSE/mods/_OR_/_OR_broad_static.lua'},
}
for _, id in ipairs(M.campaign) do
  M.fixtures[id] = id:match('^campaign_filtered_one_') and M.fixtures.filtered_one_claim
    or id:match('^campaign_content_phase_') and M.fixtures.content_phase_mixed
    or id:match('^campaign_starting_door_') and M.fixtures.starting_door
    or id:match('^campaign_nested_attach_') and {
    'scripts/mom/config/balmora_nested_attach_restart_example.yaml',
  } or id:match('^campaign_nested_place_') and {
    'scripts/mom/config/balmora_nested_place_restart_example.yaml',
  } or id:match('^campaign_retired_move_') and {
    'scripts/mom/actions/modify_ref.lua',
    'scripts/mom/config/process_retired_move_campaign.yaml',
  } or id:match('^campaign_creature_mesh_') and M.fixtures.creature_mesh_replacement
    or id:match('^campaign_inventory_ensure_') and M.fixtures.inventory_ensure
    or id:match('^campaign_vfr_') and M.fixtures.vfr_compat
    or id:match('^campaign_respawning_container_') and {
    'scripts/mom/config/respawning_container_replacement.yaml',
  } or (id:match('^campaign_plan_change_')
      or id:match('^campaign_static_')) and {} or {
    'scripts/mom/config/process_boundary_guard_campaign.yaml',
  }
end
M.suites = {
  ordinary = M.ordinary,
  stress = M.stress,
  all = {},
  smoke = {
    'runtime_boundary_contracts',
    'mesh_replace_then_state',
    'balmora_exterior_lamps',
    'external_guard_plugin',
    'weather_guard',
    'compat_formats',
  },
}
for _, group in ipairs({M.ordinary, M.stress}) do
  for _, id in ipairs(group) do M.suites.all[#M.suites.all + 1] = id end
end
-- Integration benchmarks use this explicit, stable selection; embedded
-- algorithmic workloads construct their own fixtures and stage none.
M.integration = M.suites.all
return M
