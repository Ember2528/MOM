local M = {}

local DEEP_OPERATIONS = 128
local DEEP_CHILDREN = 32
local WIDE_OPERATIONS = 64
local WIDE_CHILDREN = 256

local function sourceFields(label, index, children)
  return {
    family = 'modify_ref',
    diagnosticId = 'performance.' .. tostring(label) .. '.' .. tostring(index),
    source = {
      adapterId = 'native',
      file = 'performance/source_ir_children.yaml',
      variant = 'performance',
      path = {label, index},
    },
    children = children,
  }
end

local function deepSourceTree(source_ir)
  local child = nil
  for depth = DEEP_CHILDREN, 1, -1 do
    child = source_ir.sourceAction({
      modify = {scale = {to = depth / DEEP_CHILDREN}},
    }, sourceFields('deep', depth, child and {child} or nil))
  end
  return child
end

local function wideSourceTree(source_ir)
  local children = {}
  for i = 1, WIDE_CHILDREN do
    children[i] = source_ir.sourceAction({
      modify = {enabled = i % 2 == 0},
    }, sourceFields('wide', i))
  end
  return source_ir.sourceAction({
    place = {{'Balmora', 'misc_de_pot_green_01', {0, 0, 0}, {}}},
  }, {
    family = 'place_ref',
    diagnosticId = 'performance.wide.parent',
    source = {
      adapterId = 'native',
      file = 'performance/source_ir_children.yaml',
      variant = 'performance',
      path = {'wide', 'parent'},
    },
    children = children,
  })
end

local function sssConfig()
  return {
    replace_names = {'Balmora'},
    exterior_cells = {{x = -3, y = -2}},
    replace_meshes = {
      ['f\\Furn_DE_signpost_02.nif'] = 'f\\Furn_De_Tapestry_04.NIF',
      ['f\\Furn_DE_signpost_04.nif'] = 'f\\Furn_De_Tapestry_03.NIF',
    },
    ignore_records = {'furn_de_signpost_02'},
  }
end

local function dorConfig()
  return {
    objectToReplace1 = {
      oldObject = 'furn_de_rug_01',
      newObjects = {
        newObject1 = {
          newObject = 'furn_de_rug_02',
          replaceChance = 0.75,
          specificCell = {{cellName = 'Balmora, Eight Plates'}},
        },
        newObject2 = {
          newObject = 'furn_de_rug_big_01',
          replaceChance = 1,
          excludedCell = {{cellName = 'Balmora, Eight Plates'}},
        },
      },
    },
  }
end

local function compileFailure(result)
  local messages = {}
  local fatal = result and result.fatal or nil
  if fatal and fatal.message then messages[#messages + 1] = fatal.message end
  for i = 1, #(fatal and fatal.errors or {}) do
    messages[#messages + 1] = fatal.errors[i]
  end
  local diagnostics = result and result.diagnostics
      and result.diagnostics.summary
      and result.diagnostics.summary.diagnostics or nil
  for i = 1, #(diagnostics and diagnostics.samples or {}) do
    local sample = diagnostics.samples[i]
    messages[#messages + 1] = sample.message or sample.code
  end
  return #messages > 0 and table.concat(messages, ' | ')
    or 'compat compile was rejected'
end

local function compileCompat(path, config)
  local compat_registry = require('scripts.mom.compat.registry')
  local compiler = require('scripts.mom.compiler.compile_sources')
  local extension_catalog = require('scripts.mom.compiler.discover_extensions')
  local plain_data = require('scripts.mom.contracts.plain_data')

  local catalog = extension_catalog.discover()
  local pathClaim, pathError = compat_registry.pathClaim(path, catalog.compat)
  assert(pathError == nil, pathError and pathError.message)
  local actions, translated, translateError, adapterId =
    compat_registry.translateSource({
      path = path,
      config = config,
    }, catalog.compat, pathClaim)
  assert(actions and translated == true and translateError == nil,
    translateError and translateError.message or 'compat source was not translated')
  local admitted, admissionErrors = plain_data.detach(actions, {
    path = 'sourceAttempt.actions',
  })
  assert(admitted, table.concat(admissionErrors or {}, ' | '))
  local yaml = path:lower():match('%.ya?ml$') ~= nil
  local result = compiler.compile({
    sourceAttempts = {{
      adapterId = adapterId,
      path = path,
      sourcePath = path,
      kind = 'compat',
      native = yaml,
      compat = true,
      explicit = true,
      status = 'resolved',
      actions = admitted,
    }},
  }, catalog)
  assert(result and result.status == 'accepted' and result.manifest,
    compileFailure(result))
  return result.manifest, #admitted
end

local function registerKeyedCompile(define, family, verb, tupleCount)
  define('cold_authored_' .. verb .. '_compile_' .. tostring(tupleCount) .. '_tuples', {
    category = 'compiler', operations = 1, minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive', semantics = 'cold_start', modes = {embedded = true},
    detail = {family = family, authoredTuples = tupleCount, pipeline = 'variant_resolution_through_final_manifest'},
  }, function(measure)
    local compiler = require('scripts.mom.compiler.compile_sources')
    local extension_catalog = require('scripts.mom.compiler.discover_extensions')
    local variants = require('scripts.mom.compiler.variant_resolver')
    local tuples = {}
    for i = 1, tupleCount do
      tuples[i] = {'Balmora', 'ajira, (' .. i .. ', 0, 0)', verb == 'modify' and {enabled = false} or {}}
    end
    local config = {version = 0, variants = {performance = {actions = {{[verb] = tuples}}}}}
    local path = 'performance/authored_' .. verb .. '_tuples.yaml'
    return measure(function()
      local source = assert(variants.resolve(config, {activeContent = {}, sourcePath = path, adapterId = 'native'}))
      local catalog = extension_catalog.discover()
      local result = compiler.compile({sourceAttempts = {{
        adapterId = 'native', path = path, sourcePath = path, kind = 'native',
        native = true, compat = false, explicit = true, status = 'resolved', actions = source.actions,
      }}}, catalog)
      local manifest = assert(result and result.manifest, 'keyed compile rejected')
      assert(#manifest.actionIds == 1, 'keyed compile changed action cardinality')
      local program = manifest.actionsById[manifest.actionIds[1]].program
      assert(program.matchPlan.entryCount == tupleCount, 'keyed compile lost target tuples')
      return manifest.contentHash
    end)
  end)
end

function M.register(define)
  registerKeyedCompile(define, 'modify_ref', 'modify', 1024)
  registerKeyedCompile(define, 'modify_ref', 'modify', 4096)
  registerKeyedCompile(define, 'kill_actor', 'kill', 1024)
  registerKeyedCompile(define, 'kill_actor', 'kill', 4096)
  define('source_ir_deep_children_32', {
    category = 'compiler_scaling',
    operations = DEEP_OPERATIONS,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {
      shape = 'single_child_chain',
      childDepth = DEEP_CHILDREN,
      boundary = 'source-construction-and-admission',
    },
  }, function(measure)
    local plain_data = require('scripts.mom.contracts.plain_data')
    local source_ir = require('scripts.mom.compiler.source_ir')
    return measure(function()
      local checksum = 0
      for _ = 1, DEEP_OPERATIONS do
        local admitted = assert(plain_data.detach({
          actions = {deepSourceTree(source_ir)},
        }, {path = 'sourceAttempt'}))
        local cursor = admitted.actions[1]
        while cursor do
          checksum = checksum + 1
          cursor = cursor.children[1]
        end
      end
      assert(checksum == DEEP_OPERATIONS * DEEP_CHILDREN,
        'deep source IR benchmark changed child cardinality')
      return checksum, {
        nodesPerOperation = DEEP_CHILDREN,
        totalNodes = checksum,
      }
    end)
  end)

  define('source_ir_wide_children_256', {
    category = 'compiler_scaling',
    operations = WIDE_OPERATIONS,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {
      shape = 'one_parent_many_children',
      childCount = WIDE_CHILDREN,
      boundary = 'source-construction-and-admission',
    },
  }, function(measure)
    local plain_data = require('scripts.mom.contracts.plain_data')
    local source_ir = require('scripts.mom.compiler.source_ir')
    return measure(function()
      local checksum = 0
      for _ = 1, WIDE_OPERATIONS do
        local admitted = assert(plain_data.detach({
          actions = {wideSourceTree(source_ir)},
        }, {path = 'sourceAttempt'}))
        checksum = checksum + #(admitted.actions[1].children or {})
      end
      assert(checksum == WIDE_OPERATIONS * WIDE_CHILDREN,
        'wide source IR benchmark changed child cardinality')
      return checksum, {
        childrenPerOperation = WIDE_CHILDREN,
        totalChildren = checksum,
      }
    end)
  end)

  define('cold_compat_sss_compile', {
    category = 'compiler',
    operations = 1,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {embedded = true},
    detail = {
      adapter = 'sss',
      ownership = 'content',
      pipeline = 'translation-through-final-manifest',
    },
  }, function(measure)
    return measure(function()
      local manifest, translatedActions = compileCompat(
        'scripts/staticSwitcher/data/performance.yaml',
        sssConfig()
      )
      assert(#manifest.actionIds > 0,
        'cold SSS compile emitted no manifest actions')
      return manifest.contentHash, {
        translatedActions = translatedActions,
        manifestActions = #manifest.actionIds,
      }
    end)
  end)

  define('cold_compat_dor_compile', {
    category = 'compiler',
    operations = 1,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {embedded = true},
    detail = {
      adapter = 'dor',
      ownership = 'path',
      pipeline = 'translation-through-final-manifest',
    },
  }, function(measure)
    return measure(function()
      local manifest, translatedActions = compileCompat(
        'MWSE/mods/_OR_/_OR_performance.lua',
        dorConfig()
      )
      assert(#manifest.actionIds == translatedActions,
        'cold DOR compile changed translated action cardinality')
      return manifest.contentHash, {
        translatedActions = translatedActions,
        manifestActions = #manifest.actionIds,
      }
    end)
  end)
end

return M
