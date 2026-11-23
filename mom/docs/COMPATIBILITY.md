# Use compatibility data with MOM

MOM can read supported Static Switcher (SSS), Dynamic Object Replacer (DOR)
and Variation Framework (VFR) data in their original folders. You do not need
to convert those files to native MOM YAML. The importers cover the subsets
below; they do not provide every feature of the original runtimes.

## Install an imported patch

Keep the original module's data directory, meshes, textures and any plugins
that supply its records. Enable `mom.omwscripts`. Disable another OpenMW
replacement runtime acting on the same objects; for VFR this means leaving
`variationFramework.omwscripts` disabled. DOR's MWSE runtime is not needed by
OpenMW. MOM reads DOR's static table data without executing its Lua code.

Start from a save that has not run the original replacement runtime. MOM does
not adopt objects already replaced and managed by it. Fully restart OpenMW
after changing imported files.

| Format | Data path inside an enabled directory |
| --- | --- |
| SSS | `scripts/staticSwitcher/data/` |
| DOR | `MWSE/mods/_OR_/_OR_*.lua` |
| VFR replacements | `scripts/variationframework/{plants,containers,clutter,banners}/data/` |
| VFR decorations | `scripts/variationframework/placements/data/` |
| VFR leveled creatures | `scripts/variationframework/leveled_creatures/data/` |

YAML imports use `.yaml` or `.yml`. VFR example files named `EXAMPLE.yaml` or
`EXAMPLE.yml` are ignored. OpenMW's usual same-path file overrides apply.

Native and imported configurations become ordinary MOM actions in one shared
frontend. Selectors, predicates, choices and conditions are normalized before
MOM analyzes competing replacements and automatically promotes eligible actions.
Adapters translate foreign spelling and defaults; they do not choose an
execution layer or provide a separate placement/list compiler.

A fatal import error can prevent runtime patches from starting. Run
`I.MOM.compileReport()` in the global Lua console (`luag`) and check the OpenMW
log for source diagnostics. VFR leveled-list imports produce ordinary `leveled`
actions, and their detailed diagnostics also go to the log. Their supported
malformed-source/rule skip policies are retained as explicit source/admission
policies rather than hidden catalog work inside the adapter.

## Static Switcher

MOM reads SSS static configurations with `replace_meshes`. Location fields are
optional:

- `replace_meshes` maps source meshes to replacement meshes.
- `replace_names` selects cell names by substring.
- `exterior_cells` supplies exterior grid coordinates as `{x, y}` objects.
- `replace_regions` selects region IDs without regard to case.
- `ignore_records` excludes record IDs.

Name substrings, regions and explicit coordinates are alternative ways to
include cells. An overlap produces one replacement, not duplicate attachments.
Omitting every location list, or supplying only valid empty lists, means global
scope over cells MOM processes. Malformed scopes are errors and never become
global. Unknown regions contribute no matching cells.

Explicit exterior coordinates retain MOM's previsit behavior, including when a
listed grid also belongs to a selected region. Region-only and global coverage
do not automatically preload their entire scope. MOM turns the result into
ordinary attachments with the original objects disabled. Replacement meshes
must remain installed and the source objects must meet the attachment
restrictions below.

`log_name` is diagnostic metadata. Omitted or `standard` priority is accepted;
other SSS priorities are rejected because SSS chain order is not equivalent to
MOM conflict priority. Instance rules, mixed static/instance modules and static
`once` are unsupported and diagnosed. Unknown fields are rejected rather than
silently discarding a possible restriction. Invalid meshes and conflicting
source aliases after path normalization are also diagnosed.

This imports declarative mesh replacement data. It does not run SSS scripts or
interpret additional script behavior. Native MOM `variants`/`actions` files
are not treated as SSS files merely because they contain similar keys.

## Dynamic Object Replacer

MOM recognizes `.lua` files under `MWSE/mods/_OR_/` whose filenames begin with
`_OR_`, ignoring case. The file must return static table data with indexed
`objectToReplaceN` entries. Each entry has `oldObject` and indexed
`newObjects.newObjectN` candidates containing `newObject`.

Supported candidate controls are:

| Field | Meaning |
| --- | --- |
| `replaceChance` | Number from `0` to `1`, default `1`; deterministic per-target selection. |
| `specificCell` | Array of cell-name strings or objects with `cellName`, matched as substrings. |
| `excludedCell` | The same cell descriptors, excluded from the selection. |

Candidates for the same source are considered together. More specifically
scoped candidates take precedence, followed by excluded-cell specificity,
higher chance and source order. MOM coordinates competing candidates rather
than creating every replacement for one source. The resulting replacements
use ordinary MOM attachments and disable the originals.

The reader accepts literal tables, strings, numbers, booleans, comments, and
simple local literal definitions referenced by the returned table. It is not
a Lua interpreter: functions, calls, arithmetic and MWSE-dependent expressions
are unsupported. A DOR module that computes its returned data must be rewritten
as static data or as native MOM configuration.

## Variation Framework replacements

MOM imports `plants`, `containers`, `clutter` and `banners` category modules.
The supported replacement data includes:

- mesh sources in `variants` and record sources in `record_variants`;
- mesh or record alternatives, with matching alternative counts across a module;
- `ignore_records` and supported `kinds`;
- seeded spatial choices, category clustering defaults, region and climate
  weights, latitude/longitude and climate gradients, cell and point weights,
  and interior overrides;
- native respawning Container replacement, preserving contents and locks.

Record-specific `KEEP` stops replacement for that record. Mesh `KEEP` can fall
through to another matching rule. Unavailable alternatives retain their
weighted positions instead of renumbering the remaining choices. The winning
choice is checked again when capture starts and then retained through partial
work and recovery.

SSS takes precedence over VFR replacement modules by default. A VFR module with
`supersede_static_switcher: true` takes precedence over SSS instead. These
choices still pass through MOM's ordinary conflict handling.

An unrestricted choice proven to select one model can be promoted by the same
planner as a native `attach`. This includes a supported Ingredient definition
change when its declared type and competing rules permit. Variable Ingredient
replacement still needs an unavailable per-reference item-transfer contract.
An overlapping runtime or KEEP-dependent replacement group can prevent
promotion even when one member would qualify alone.

MOM rejects or diagnoses unsupported selected-backend behavior for:

- Ingredient replacement requiring runtime item transfer;
- `contents` conversions to another inventory item record; empty or `keep`
  entries are allowed;
- Container replacement with `transfer_contents: false`;
- unsupported source types;
- source names or spatial overrides that become ambiguous after normalization,
  and duplicate gradient anchors.

Runtime replacement must also pass MOM's script and restocking safeguards
before mutation. Promoted model changes retain the existing records and
references rather than transferring live state to clones. The importer reads
data; it does not execute VFR's Lua scripts. Saved choices
and outputs follow MOM's save and replacement behavior, so editing a module is
not a promise of the original framework's exact update behavior.

## Variation Framework decorations

Decoration modules can place existing Static or Activator records. They support
permanent placement IDs, exact transforms, positive scale, seeded weighted
record alternatives, chance, and required/excluded content conditions.

A module has `name`, optional `seed`, and a `placements` array. Each placement
uses exactly one location (`cell`, `interior` or `exterior`) and an existing
`record` or weighted `alternatives`. A string location identifies an interior;
an exterior location can be `true` to derive its grid from position, or integer
coordinates. An explicit grid must contain the supplied position. Rotation is
three degree angles in roll, pitch, yaw order; the default is zero.

A placement uses either `conditions` or `condition`, with `chance`,
`require_content` and/or `exclude_content`. `enabled: false` skips it.
Other placements are structurally validated before shared admission, including
ones whose chance or content conditions make them inactive. Missing or
unsupported resolved targets are checked only for admitted placements.
Inventory-bearing objects, actors, `record_draft`, and `spawn: true` native
spawn points are unsupported.

Keep each placement `id` unique across active imports. Within one file,
duplicate IDs are invalid even for disabled entries; across files, inactive
placements do not reserve an ID. IDs ignore case. Distinct IDs may deliberately
place separate objects at the same transform. Reordering entries or moving
files does not change their native instance identities. Other edits follow
MOM's output replacement rules; the importer does not promise VFR's in-place
updates or item relinquishment behavior.

## Variation Framework leveled creatures

Additive list modules are translated into ordinary `leveled` actions and use
MOM's common normalization, admission, ordering and content planning. Their
definition edits run in OpenMW's LOAD script before the MOM runtime.
They require the engine API `openmw.content.levelledCreatures.records`.
If unavailable, MOM logs that injection was skipped; it does not invent a
runtime substitute. Fully restart OpenMW after changing these modules.

A module can contain `name`, `enabled`, integer `priority`, `require_content`,
`exclude_content` and an `injections` array. Each injection names `list` and an
`add` array of `{id, level}` entries. Levels are integers from 0 through 65535.

Modules apply in ascending priority, then path order, followed by rule and entry
order. Later additions for the same creature/list pair replace earlier added
levels. Existing unrelated entries, duplicate multiplicity, flags and chance
are preserved; an addition for an existing creature updates its level rather
than adding another copy. Invalid modules or whole invalid rules are logged and
skipped. Unavailable target lists are skipped with a message.

These LOAD edits are independent of runtime compilation. A later runtime
configuration error does not undo a successfully edited list. Existing actors
and encounters already recorded in a save remain subject to native engine
behavior. VFR additions merge with native list edits in the current content
plan, preserving native additions/removals instead of replacing the plan with
a pre-edit list snapshot. Read `[ MOM VFR ]` messages for detailed module/rule
diagnostics; `compileReport().startup` summarizes the combined LOAD outcome.

## Shared replacement limits

Native and imported replacements share the same action semantics and promotion
planner. Eligible uniform model changes edit definitions automatically, as
described in the
[configuration reference](AUTHORED_CONFIG_REFERENCE.md#uniform-model-replacements).
The current conservative planner retains untyped or interacting runtime
replacements rather than inferring different ownership from changing catalogs.
For runtime attachments, Static sources are supported; Activator and Container sources must be safe to
replace without losing scripted state. Container replacement transfers to one
Container output with the original disabled, preserving inventory and lock
state. A source cannot transfer into several outputs. Creature sources can use
one-for-one mesh replacement with the original disabled. This creates a fresh
actor from the source base record; it does not transfer live actor state.
Dead and summoned sources are skipped. NPCs, doors, lights and other unsupported
item-bearing source types are not cloned through this replacement path.
Absolute native `place` is a different operation and has its own record rules.

Changes persist under MOM's save rules. Removing a module does not generally
undo completed static changes. Use the
[author guide](MOD_AUTHOR_GUIDE.md#changes-and-existing-saves) when developing
or changing compatibility patches for an existing save.
