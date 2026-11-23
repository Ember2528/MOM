# MOM configuration reference

This reference describes native MOM YAML, `version: 0`. For a complete first
patch and testing steps, read the [author guide](MOD_AUTHOR_GUIDE.md). Imported
SSS, DOR and Variation Framework files keep their own formats; see
[compatibility](COMPATIBILITY.md).

Examples below are fragments unless they include `version` and `variants`.
Put action fragments inside a variant's `actions` or a guard's `actions`.

## Files and variants

MOM reads `.yaml` and `.yml` files visible under `scripts/mom/config/` in
OpenMW's virtual filesystem. Use distinct relative paths for independent files;
OpenMW data-directory overrides still apply. Restart OpenMW after edits.

A complete file has this shape:

```yaml
version: 0
name: Optional patch name
description: Optional description
variants:
  patch_name:
    description: Optional variant description
    requires: [SomeMod.esm]
    requiresAny: [OneMod.esp, AnotherMod.esp]
    requiresNot: [ConflictingMod.esp]
    actions: []
    guards: []
```

| Field | Accepted value |
| --- | --- |
| `version` | Required number `0`. |
| `name`, `description` | Optional strings. |
| `variants` | Required map keyed by non-empty variant names. |

A variant accepts only `description`, `requires`, `requiresAny`, `requiresNot`,
`actions` and `guards`. Each content condition is an array of filenames, matched
without regard to case: `requires` needs all, `requiresAny` needs at least one,
and `requiresNot` needs none. An omitted condition imposes no restriction.
`actions` and `guards` are arrays. Top-level `actions` and `guards` are invalid.

Every satisfied variant contributes work, in lexicographic variant-name order.
The arrays within it preserve authored order. This ordering does not replace
MOM's dependency and conflict handling.

## Action structure

An action has exactly one verb: `record`, `leveled`, `place`, `attach`, `modify`,
`inventory` or `kill`. Reference actions can also have these shared fields,
where supported by that action:

| Field | Meaning |
| --- | --- |
| `select` | Narrow targets with `cell` and the reference/record query fields below. |
| `filters` | One predicate tuple or an array of predicate tuples. |
| `chance` | Deterministic per-target probability from `0` to `1`, default `1`. Nontrivial probability requires a ref-targeting action. |
| `previsit` | Boolean request to plan static work for known exterior cells before a player visit. |
| `actions` | Child actions, supported on `place` and `attach`. |
| `requires`, `requiresAny`, `requiresNot` | Compile-time content conditions on one action; each accepts a filename or array, with the same all/any/none meaning as variants. |
| `admission` | Optional deterministic declaration-level admission, described below; distinct from per-target `chance`. |
| `key` | Stable semantic identity for one absolute placement tuple. |
| `targetTypes` | Non-empty array restricting an absolute placement's resolved record type. |
| `onMissingTarget` | `skip` on a `record` or `leveled` action when its existing target or store is unavailable. |

`attach` additionally accepts `disableOriginal` and `transferContents`. Do not write action `id`,
action-level `type`, action-level `match`, or `__`-prefixed internal fields.
The `type` inside a `record` or `leveled` payload names its record domain.
MOM derives action identity from meaning, rather than filename, array position
or labels. Moving or reordering an equivalent action does not reset saved work.

Reference actions express targets in three ways:

- **Full tuples:** each row starts with its cell, followed by the action's
  selector and payload. One action can contain several cells.
- **Select blocks:** `modify`, `inventory` and `kill` can use `select` alongside
  a direct payload object.
- **Children:** an action under a parent's `actions` inherits its output
  objects. Supported forms can omit the ordinary cell and target selector.

The grammar limits fields within a row and some combinations of rows, as
specified below. MOM does not impose an aggregate limit on valid actions,
tuples, selection entries or outputs; large runtime work advances over several frames.

## Definition changes and reference actions

Authors use the same action grammar, tuples and `scripts/mom/config/` files
throughout. Describe the intended targets, scope, conditions and effects; MOM
automatically promotes eligible actions to LOAD and handles other supported
actions in GLOBAL. Authors do not select an execution layer or rewrite an
action into a separate promoted form.

Native and supported imported sources first become ordinary action declarations.
Shared code normalizes tuples, selectors, predicates, conditions and replacement
choices, then analyzes dependencies and competing replacements before deciding
where actions run. The same frontend runs independently in LOAD and GLOBAL.
There is no separate content directory or context-selection field.

`record` and `leveled` edit definitions in LOAD, once per OpenMW process.
Ordinary placements, reference modifications, live inventory, death and
guarded work execute through the runtime. An eligible unrestricted, typed
uniform mesh replacement is automatically promoted, as described below.

Record and asset lookup follows the common semantic placement decision. A
missing record or asset, unsupported field, unavailable API or conflicting
resolved match is handled by that backend's validation policy; it does not
redirect an action into another context. GLOBAL reference
queries observe the final record catalog, including later LOAD mods.

### Declaration admission

`admission` accepts `requires`, `requiresAny`, `requiresNot`, `chance`, `seed`,
`key` and `salt`. Its content conditions accept a filename or array. `chance`
is a probability from `0` to `1`, default `1`; seed is finite and rounded down
to an integer. The shared compiler makes one deterministic admission decision
for the declaration before either execution plan is produced. This is not a
new runtime guard or a roll for each selected reference.

Use a stable non-empty sampling `key` when the draw needs an explicit identity.
Otherwise admission uses the action's placement `key`, then its semantic
description. `salt` separates independent draws and defaults to `condition`.
Changing the key, seed or salt can change the result.
Admission is a compile-time decision; a later failed admission does not withdraw
an already completed static edit from a save.

### `record`

`record` needs a record `type`, exact `id`, and nonempty `patch`. IDs ignore case.
Only admitted fields may be changed; untouched fields retain their original
values. A record action is top-level and cannot have guards, reference selection,
filters, chance, previsit or children.

This complete mixed example edits a book definition and places an existing
tapestry through the runtime:

```yaml
version: 0
name: Book text and tapestry example
variants:
  mixed_example:
    actions:
      - record:
          type: Book
          id: bk_lustyargonianmaid
          patch:
            text: "A replacement text supplied by this MOM patch."
      - place:
          - ["Balmora, Eight Plates", furn_de_tapestry_04, [1900, 960, -311], {yaw: 0}]
```

| Type | Admitted patch fields |
| --- | --- |
| `Static` | `model` |
| `Activator` | `model`, `name`, `mwscript` |
| `Door` | `model`, `name`, `mwscript`, `openSound`, `closeSound` |
| `Book`, `Light`, `Miscellaneous`, `Ingredient`, `Potion`, `Apparatus`, `Lockpick`, `Probe`, `Repair` | Common fields: `model`, `name`, `mwscript`, `icon`, `weight`, `value` |
| `Book` additionally | `text`, `isScroll`, `enchant`, `enchantCapacity`, `skill` |
| `Light` additionally | `duration`, `radius`, `color`, `isCarriable`, `isDynamic`, `isFire`, `isFlicker`, `isFlickerSlow`, `isNegative`, `isOffByDefault`, `isPulse`, `isPulseSlow` |
| `Potion` additionally | `isAutocalc` |
| `Apparatus` additionally | `quality` |
| `Lockpick`, `Probe`, `Repair` additionally | `quality`, `maxCondition` |

Availability depends on the engine's existing bindings. A missing store produces
a capability error. NPC, Creature, Container, Armor, Clothing and Weapon
definition edits and default inventory changes are unavailable in the checked
API. Use the existing reference actions for supported live changes.

Weight and quality are nonnegative finite values. Book enchantment capacity
rounds to tenths and must be within `0` through `214748352`, the checked parsers'
safe shared range. Value, radius and condition are nonnegative integers; Light
duration is an integer of at least `-1`, where `-1` means unlimited. Light color
is a packed RGB integer with red in the low byte, then green and blue. Flags
are booleans. String/ID fields remain strings; model and icon paths normalize
case and separators. Target meshes must exist in the VFS.

Add `create: true` and `template: installed_record_id` inside `record` to create
a named definition under its new `id`. The installed template must exist and
the new ID must be unused; templates created by the same plan are rejected.
IDs beginning `mom__content_` are reserved. A definition does not place an
object. Runtime `place` can use its named ID after LOAD, and the defining patch
must stay installed while a save depends on it.

Conflicting equal-priority assignments to the same record field reject the
content plan; edits to different fields compose. Draft staging verifies native
normalization before public writes. A failed commit reports restoration and
cleanup accurately; the existing engine APIs do not provide a multi-record
transaction.

Add action-level `onMissingTarget: skip` to a `record` or `leveled` edit when
an unavailable existing target or content store should contribute a warning
and no work. Omit it for the normal strict policy. This does not select another
execution layer or recover from failed writes. Named creation still needs a
valid installed template and unused ID.

### `leveled`

`leveled` targets `CreatureLevelledList` or `ItemLevelledList` by exact `id`.
Its optional `patch` accepts `chanceNone` and `calculateFromAllLevels`; item
lists also accept `calculateForEach`. Chance is a probability from `0` to `1`,
truncated to decimal hundredths (`0.335` becomes `0.33`). Entry-only edits
preserve untouched flags and the original chance byte.

```yaml
version: 0
variants:
  creature_list:
    actions:
      - leveled:
          type: CreatureLevelledList
          id: ex_westgash_lev+0
          operations:
            - op: add_if_absent
              entries:
                - {id: rat, level: 1}
```

Each entry has a string `id` and integer `level` from `0` through `65535`.
Operations compose in source and authored order:

| `op` | Behavior |
| --- | --- |
| `append` | Append `entries`, preserving weighting duplicates. |
| `add_if_absent` | Append ID-and-level pairs that are absent; preserve existing duplicates. |
| `merge_by_id` | Set every occurrence of each supplied ID to its supplied level; append missing IDs once. Later supplied levels win. |
| `remove` | Remove all matches for `match: {id: ..., level: ...}`; omit level to match all levels for that ID. |
| `replace` | Remove all matches and insert `entries` once at the first match position. |
| `set` | Replace the complete entry array with `entries`. |

LOAD does not expose every possible member record domain. MOM validates the
available list graph and syntax, and reports symbolic members whose existence
or type could not be verified. Item-list support is absent on some otherwise
supported engine builds; those builds reject explicit item-list patches.

### Uniform model replacements

An unguarded, unrestricted `attach` with an explicit supported model-bearing
type and one replacement model per source is eligible for automatic promotion.
Write an ordinary attachment; MOM applies the change through base definitions:

```yaml
version: 0
variants:
  uniform_tapestry_model:
    actions:
      - select:
          type: Static
        attach:
          - ["*", furn_de_tapestry_04, meshes/f/furn_de_tapestry_03.nif]
        disableOriginal: true
```

The type describes which records the action targets; it is not a layer switch.
The original records and reference identities remain in use. Eligible rows use
unrestricted cells: `"*"`, `{}` and `{match: "*"}` have the same meaning.
Offsets must be absent or exactly zero. Any supplied rotation is an override,
including `{}` or zero angles. Record-ID-only `exclude` filters, in compact,
nested or tuple-local form, subtract base records in LOAD; excluding every
match is a valid no-op. Empty
filters/children, `chance: 1` and `previsit: false` do not change definition
intent. Guards, nonempty children, orientation filters, chance below one,
`previsit: true`, restricted cell scopes and reference provenance keep an
attachment in the runtime automatically, using the same action grammar.
Type intersections are resolved before writability is checked. Base-record
ID/MWScript restrictions can narrow the definition population; reference
provenance and exact reference numbers cannot. An unrestricted choice proven
to have one constant model can qualify too. Untyped attachments remain runtime
actions; MOM does not guess their domains from different context catalogs.

Promotion is conservative across interacting replacements. If a model write
could change a runtime selector or participate in unresolved choice competition,
MOM keeps the affected replacement group together at runtime. This preserves
selection and precedence rather than promoting one action in isolation. Record
matching and content-write validation follow that shared placement decision;
a lookup failure never supplies a fallback to another execution layer.

Definition edits finish before runtime reference queries. Another LOAD mod may
override them later; MOM does not reassert its values over that mod. Restart
OpenMW when definition declarations change. Resetting a game, loading a save or
using `reloadlua` does not execute LOAD again. The bounded `startup` summary in
`compileReport()` and `selfcheck()` reports the LOAD outcome separately.

## Cell selectors

A cell selector is an exact string or an object with the following keys:

| Key | Value |
| --- | --- |
| `exact` | One cell string or an array of exact cell strings. |
| `match` | One name pattern or an array of patterns. |
| `kind` | `interior` or `exterior`. |
| `worldspace` | One worldspace ID or an array. |
| `region` | One region ID or an array. |
| `coords` | Exterior grid integers: `[x, y]`, `{x: x, y: y}`, or an array of such pairs. |
| `exclude` | One nested cell selector, without another `exclude`. |

Common cell values (each line is a separate example):

```text
"Balmora, Eight Plates"
"*"
{exact: ["Balmora, Eight Plates", "Balmora, Guild of Mages"]}
{match: "Balmora, *"}
{kind: exterior}
{kind: interior}
{kind: exterior, region: "West Gash"}
{worldspace: "sys::default"}
{coords: [-3, -2]}
{kind: exterior, exclude: {match: "*Balmora*"}}
```

`exact`, `coords` and `match` add alternative ways to include a cell. The cell
must also satisfy every supplied `kind`, `worldspace` and `region` restriction.
Values within an array are alternatives. With none of the three include keys,
the restrictions apply to all candidate cells. Finally, `exclude` removes cells
matching its query. An exclusion needs at least one of `exact`, `match`,
`coords`, `worldspace` or `region`; `kind` alone is insufficient.

Matching ignores case. A `match` pattern supports a leading and/or trailing
`*`: prefix, suffix or substring matching. It is not a general regular
expression. Coordinates refer to grid cells, not world positions, and default
to worldspace `sys::default` unless another is selected. `coords` cannot be
combined with `kind: interior`.

Exact cells and coordinates resolve to known cells. Region and worldspace
queries resolve known exterior cells. `"*"`, name patterns and kind-only
queries operate on cells MOM is processing; they do not preload the whole
world. `previsit: true` is meaningful only for static actions resolving known
exterior cells: exact exterior cells, coordinates, regions or worldspaces.

Absolute `place` destinations are stricter: use an exact cell string, an
`exact` object or a `coords` object. Wildcards, `match`, broad include keys and
`exclude` are rejected, including when mixed with an exact destination.

## Record and keyed selectors

`select.recordId` accepts one exact record-ID string, a nonempty array of exact
IDs, or the explicit match object below. It narrows an action's targets; it
does not name a record to create. Plain strings never become patterns merely
because they contain punctuation.

Full tuples can use a keyed selector to distinguish objects with the same
record or model:

```text
record_id
record_id, (x, y, z)
meshes/foo/bar.nif
meshes/foo/bar.nif, (x, y, z)
```

The optional suffix must contain exactly three finite coordinates and matches
the object's starting position. Mesh selectors are supported by `attach`,
keyed `modify` and `kill`; inventory owners do not accept them. A `kill` mesh
selector must resolve to actor types.

For child selection against a mesh-generated parent output, record selection
and `[exclude, ...]` use its source record ID. You do not need the generated
record ID. Other predicates still read the properties they require from the
actual object.

### Structured reference and record selectors

The target column of a full `modify`, `inventory`, `kill` or `attach` row may
contain a selector object instead of a string. Action-level `select` accepts
the same query fields plus `cell`:

| Field | Accepted value and meaning |
| --- | --- |
| `ref` | `[contentFilename, localReferenceNumber]` or `[contentFilename, [numbers...]]`. Select exact references from that plugin. |
| `contentFile` | One filename or an array; restrict the reference's own engine-reported content provenance. |
| `type` | One OpenMW reference type or an array, such as `Creature`, `NPC`, `Static` or `[Weapon, Armor]`. |
| `recordId` | One exact ID, an array of exact IDs, or `{match: patternOrPatterns}`. |
| `mwscript` | One base-record MWScript ID or an array of IDs. This does not select attached Lua scripts. |

All supplied fields must match. Values within one field are alternatives.
Action selection, row selection and filters narrow one another; children keep
working only on inherited outputs. Empty arrays and unknown fields are errors.
Strings used for IDs and filenames match without regard to case.

```yaml
- modify:
    - ["*", {ref: [Morrowind.esm, 67647]}, {scale: 0.1}]
    - ["*", {ref: [SomeMod.esp, [1017, 1018, 1019]]}, {enabled: false}]
```

Reference numbers are nonnegative integers through `16777215` (`0xffffff`),
local to the named plugin. Do not supply a load-order-dependent full FormID or
a hexadecimal string. Reordering plugins does not change this identity. A
missing or unavailable exact reference never falls back to a record broadcast.
An action-level exact-reference selector can omit `cell`; it does not request
a world scan or make unavailable objects immediately writable. If supplied,
the cell restriction still matches the origin cell. Exact-reference `modify`
supports `relocate`; position-keyed string selectors retain their restriction.

```yaml
- select:
    ref: [Morrowind.esm, 67647]
  modify:
    scale: 0.1
```

`contentFile` describes the reference, not the plugin defining its base record
or the last plugin overriding that record. It is not interchangeable with a
variant's `requires`. Newly generated references have no content provenance.

```yaml
- modify:
    - ["*", {type: [Weapon, Armor], recordId: {match: ["*glass*", "*ebony*"]}}, {enabled: false}]
- modify:
    - ["Vivec, Black Shalk Cornerclub", {type: NPC, mwscript: ElayneUSebaonard}, {position: [322, -4, -63]}]
```

Record `match` uses the same leading/trailing `*` vocabulary as cell matching:
prefix, suffix, substring or exact matching. It is not a general glob, regular
expression or Lua pattern. Record-pattern and MWScript queries resolve the
installed record catalog at startup; they do not automatically include records
created later. A type-only query has no startup record-membership restriction;
it follows ordinary target-discovery and lifecycle rules. Neither form makes
a completed static cell a continuous watcher for every later added reference.
New query identity follows the normalized authored query. Changed startup
record-query membership requests another static discovery pass while retaining
completed operations for old targets. Adding another matching installed record
therefore does not reset completed work for its old targets.

Structured attachment selectors additionally require one exact `recordId` as
a source hint. The actual source must match that ID and every other supplied
restriction; the hint does not bypass transfer safeguards. Existing bare mesh
selectors remain available. Inventory selectors still require an actual NPC,
Creature or Container owner, and `kill` still requires an actor.

The record column of absolute `place`, replacement columns of `attach`, and
inventory item-map keys remain literal records/models under their existing
rules. They do not accept these target-query objects.

## Filters and tuple predicates

`filters` accepts one predicate tuple or an array of them:

| Tuple | Effect |
| --- | --- |
| `[upright]` | Maximum tilt 25 degrees. |
| `[upright, maxTilt]` | Set the maximum tilt in degrees. |
| `[facing, direction]` | Face the direction within 45 degrees. |
| `[facing, direction, tolerance]` | Set the tolerance in degrees. |
| `[exclude, recordId1, recordId2, ...]` | Exclude at least one listed record ID. |

`direction` is a number in degrees or `north`, `northeast`, `east`, `southeast`,
`south`, `southwest`, `west` or `northwest`. North is 0 and east is 90.

Append row-specific predicates after the row's ordinary fields:

```yaml
- modify:
    - ["Balmora, Eight Plates", "urn_01", {scale: 0.9}, [upright, 25]]
  filters:
    - [exclude, crate_01]
```

Sibling filters apply to the action; trailing predicates narrow their row.
Absolute `place` accepts neither sibling filters nor trailing predicates.

## Guard blocks

A variant's `guards` array contains objects with only `when` and `actions`:

```yaml
guards:
  - when:
      - [time, hour, range, 18, 6, inclusive]
    actions:
      - place:
          - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

`when` is an array of compact tuples. All conditions must hold. Object-form
guards and guard-block `select`, `scope`, `on_enter` and `on_exit` are invalid.
The built-in families are `time`, `weather` and `quest_stage`.

If a condition is unavailable, MOM holds existing work rather than interpreting
it as false. Closing a guard reverses only actions that support reversal.

### Numeric operators

Time scalar fields and quest stages use these tuple endings. Values are
integers; `any` and `not` need non-empty arrays.

| Ending | Match |
| --- | --- |
| `eq, value` | Equal to the value. |
| `min, value` | Greater than or equal to the value. |
| `max, value` | Less than or equal to the value. |
| `any, [values...]` | Any listed value. |
| `not, [values...]` | No listed value. |
| `range, start, end` | Both endpoints included. |
| `range, start, end, inclusive` | Both endpoints included. |
| `range, start, end, exclusive` | Start included, end excluded. |

### Time

Scalar fields are `hour`, `month`, `day`, `dayOfWeek` and `yearDay`:

```yaml
- [time, hour, eq, 12]
- [time, hour, range, 18, 6, inclusive]
- [time, dayOfWeek, any, [1, 7]]
- [time, yearDay, not, [1, 2, 3]]
```

Time ranges wrap when the start is greater than the end, such as 18 through 6.
There are also season, date and weekend forms:

```yaml
- [time, season, eq, summer]
- [time, season, any, [spring, summer]]
- [time, date, eq, {month: 4, day: 12}]
- [time, date, any, [{month: 4, day: 12}, {month: 4, day: 13}]]
- [time, date, range, {month: 4, day: 1}, {month: 4, day: 30}, inclusive]
- [time, flags.isWeekend, true]
```

Season supports only `eq` and `any`. Date supports `eq`, `any` and `range`.
A date point may contain integer `month` (1–12), `day` (1–31) and `year`; at
least one is required. Date range endpoints require both month and day. A range
without years repeats annually, including windows crossing the year boundary.
A year on only one endpoint bounds that annual window from or through the dated
endpoint. With years on both, the endpoints describe dated bounds. The optional
range flag controls the end, as in numeric ranges. Weekend means day 1 or 7;
its tuple takes a boolean directly, with no operator.

### Weather

Weather matches a region's weather script ID:

```yaml
- [weather, "Bitter Coast Region", eq, 1]
- [weather, "Ascadian Isles Region", any, [1, 2, 3]]
- [weather, "Molag Amur Region", not, [4]]
```

Only `eq`, `any` and `not` are supported. IDs identify weather types and have no
numeric ordering.

### Quest stage

```yaml
- [quest_stage, "A1_1_FindSpymaster", eq, 10]
- [quest_stage, "A1_1_FindSpymaster", min, 50]
- [quest_stage, "A1_1_FindSpymaster", range, 10, 50, inclusive]
```

Quest stages support every numeric operator above.

## `place`

Create objects at absolute destinations:

```yaml
- place:
    - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

Each full row is `[cell, recordId, [x, y, z], rotation]`. The record must exist;
a mesh path cannot be placed directly. Rotation is a required object with
`yaw`, `pitch` and/or `roll` in degrees; omitted angles default to zero, so `{}`
is valid. The destination must satisfy the exact-cell rules above.

`place` does not accept `select.recordId`, sibling filters or trailing
predicates. It can own child actions. As a child it still takes full absolute
rows: each inherited parent output causes one placement at every destination.
Two inherited outputs can therefore create two objects at the same position.

For a deterministic choice between records, replace the second column with
`{choose: [[recordA, weightA], [recordB, weightB]], seed: 7, key: sample_key}`.
Each weight must be positive and finite. Targets are record IDs, optionally
written `{recordId: recordA}`; meshes cannot be placed this way. `seed`, `key`
and `salt` are optional. The choice key defaults to the action's `key`, then
its semantic description; salt defaults to `alternative`. One record is chosen
by the common compiler, rather than once for every runtime target.

An action `key` is a non-empty semantic placement identifier, distinct from a
diagnostic label. It requires exactly one absolute placement row and must be
unique among active keyed declarations. Keep it stable when moving the file
or reordering entries. Distinct keys can deliberately create separate objects
at the same transform. `targetTypes: [Static, Activator]`, for example, rejects
a chosen target of another resolved type; it does not change the record.

```yaml
- key: my_patch:tapestry
  targetTypes: [Static]
  admission: {chance: 0.75, seed: 12}
  place:
    - ["Balmora, Eight Plates", {choose: [[furn_de_tapestry_03, 2], [furn_de_tapestry_04, 1]], seed: 7}, [1900, 960, -311], {yaw: 0}]
```

## `attach`

Create an output relative to each matching source object:

```yaml
- attach:
    - ["Balmora, Eight Plates", "furn_de_tapestry_04", 'f\Furn_De_Tapestry_03.NIF', [0, 0, 32], {yaw: 0}]
  disableOriginal: true
```

Full rows have `[cell, sourceSelector, replacement, offset?, rotation?,
predicates...]`. The source selector and replacement can name a record or mesh.
The offset defaults to zero. Rotation is optional, but if supplied must follow
an offset; use `[0, 0, 0]` for no offset. A supplied rotation is an angle object
as for `place`.

`disableOriginal: true` disables the selected source after replacement. It is
optional for supported Static and Activator attachments. Containers require it
and must transfer into one Container output. MOM preserves their inventory and
lock state, including native respawning containers. `transferContents` is an
optional boolean policy: omission or `true` preserves the required transfer;
`false` rejects a selected Container source. It is harmless for supported
sources without transferable inventory, including promoted model edits. MOM
checks this policy against the selected source capabilities after placement.
Lock-state transfer has a known native limitation on Luau OpenMW builds, where
the `Lockable` key and trap setters reject supplied value arguments; transfers
needing key or trap writes can fail on that runtime. Scripted or restocking
sources that cannot be transferred safely are rejected. Creature sources support
one-for-one mesh replacement only: the target must be a mesh path and
`disableOriginal: true` is required. Multiple output rows that could select the
same Creature are rejected; distinct keyed starting positions can identify
different sources. Dead and summoned sources are skipped.

A Creature mesh replacement creates a fresh actor from a copy of the source
base record, retaining its base stats, inventory definitions, services, AI and
MWScript. It preserves the selected reference's transform, scale and owner,
but does not transfer its current inventory, health, active effects, running AI,
script locals or engine identity. Scripted Creature templates are allowed.
Use a save from before interaction with an affected actor when testing a visual
replacer. Withdrawing a guarded replacement removes its output and restores
the original; changes made to the replacement during play are not transferred
back. The original reference's native spawning/summon ownership is not
transferred to the new actor.

NPCs, doors, lights and other unsupported item-bearing sources are not cloned.

Full rows provide their own source selectors. Legacy string-source rows do not
accept `select.recordId`; structured exact-source rows and replacement-choice
rows can intersect their source with that constraint. Rows may use sibling
filters or trailing predicates. An attachment can own children.

### Replacement choices

The third column can contain a replacement expression in place of a string.
This complete vanilla example chooses between two tapestry models:

```yaml
version: 0
name: Tapestry model choice
variants:
  tapestry_choice:
    actions:
      - select: {type: Static}
        attach:
          - ["Balmora, Eight Plates", furn_de_tapestry_04, {choose: [[f/Furn_De_Tapestry_02.NIF, 1], [f/Furn_De_Tapestry_03.NIF, 3]]}]
        disableOriginal: true
```

`choose` is a non-empty array of `[target, weight]` tuples. Simple weights are
nonnegative finite numbers, with at least one positive weight including any
`keepWeight`. String targets use the ordinary record/mesh distinction. Write
`{recordId: literal_id}` or `{model: f/replacement.nif}` when the kind must be
explicit, including a record whose ID resembles a mesh path.

| Expression field | Meaning |
| --- | --- |
| `choose` | Ordered alternatives; unavailable alternatives retain their slots. |
| `keepWeight` | Weight of keeping the source, default `0`, when no `profile` is supplied. |
| `keep` | `stop` (default) ends choice routing after KEEP; `continue` permits another matching rule. It does not name a target record. |
| `profile` | Optional inline spatial profile, described below. |
| `order` | Optional non-empty semantic ordering string for overlapping choice rows; otherwise authored row order is used. |

Choices use deterministic position/clustering and seed data, so nearby sources
can share a variant. They are not independent admission rolls. Record-specific
choice rules precede mesh rules; within the same source kind, `order` determines
the sequence. KEEP controls whether that sequence continues. A missing chosen
alternative stops that opportunity without shifting its weight to another
slot. The winner is checked at capture and retained during partial work/recovery.

Choice attachments require unguarded static actions, `disableOriginal: true`
and explicit root source rows. Offsets must be omitted or zero, rotations must
be omitted, and tuple-local predicates must be record exclusions. These choices do not add actor transfer,
reference-position sources or inherited-child choice support. Existing simple
string attachments retain their broader transform/child grammar.

An unrestricted constant model choice can be promoted automatically when its
type and competing rules permit. Variable or spatial outcomes stay in the
runtime. Native and imported choices use the same normalization and planning.

### Spatial choice profiles

With `N` targets, each profile weight vector contains `N + 1` entries: KEEP
first, then target 1 through N. A supplied `profile` owns those vectors; the
weights beside `choose` targets and `keepWeight` do not provide its default.
If `profile.default` is omitted, its default is KEEP-only. For example, a
two-target choice with `profile: {seed: 7, default: [0, 1, 3]}` retains the
simple 1-to-3 target weights while supplying an explicit seed.

| Profile field | Accepted shape |
| --- | --- |
| `seed` | Finite number, rounded down; default `0`. |
| `cluster` | Object with `scale`, `detail`, `detailWeight`, `jitter`; scale/detail are positive. |
| `default`, `interiorDefault` | Weight vectors including KEEP. |
| `regions` | Region-ID-to-weight-vector map. |
| `cells` | Array of `{x, y, weights}` for integer exterior grid coordinates. |
| `points` | Array of `{x, y, radius, weights}` with positive radius in world coordinates. |
| `interiors` | Cell-name map to `{weights: [...]}` or `{x: ..., y: ..., region: ...}` virtual facts. |
| `gradients` | Array of `{axis, anchors: [{at, weights}, ...]}`; axis is `x`, `y`, `wetness`, `warmth`, `snow` or `ash`. |
| `climateOverrides` | Region-ID map to optional `wetness`, `warmth`, `snow`, `ash` values. |

Gradients can add `offsetAxis: x` or `y` with
`offsets: [{at: ..., value: ...}, ...]`. Coordinates and weights must be finite;
duplicate normalized names and duplicate gradient anchors are rejected.
Negative profile weights count as zero when selecting. Exterior point overrides
take precedence over grid cells, then region weights, available gradients and
the default. Interior explicit weights take precedence; an unmatched interior
can use `interiorDefault`. Matching interiors can instead supply virtual
coordinate/region facts for the remaining profile rules.

### Inherited child attachment

A child can omit the cell and source selector:

```yaml
- attach:
    - ['f\Furn_De_Tapestry_03.NIF', [0, 0, 32], {yaw: 90}]
    - ['f\Furn_De_Tapestry_02.NIF', [0, 0, 64]]
```

Each abbreviated row is `[replacement, offset?, rotation?, predicates...]`.
Even `[replacement]` is valid. These rows share one attachment operation, and
each row's predicates narrow that row. The inherited source must meet the same
type, script and transfer rules as an ordinary attachment. Multiple abbreviated
rows are rejected for a Container source, including when filters seem mutually
exclusive. A custom output-producing family must supply enough output-type
information for MOM to check the attachment.

Use `select`, sibling filters or trailing predicates to narrow inherited
outputs. A child may instead use full rows to narrow by cell and source. That
cell matches the output's origin cell; a moved output may currently be elsewhere.
A mesh source selector matches its current physical model. Do not mix full and
abbreviated rows in one `attach` action.

## `modify`

Change `enabled`, `owner`, `position`, `rotation`, `scale` or `relocate`.

A broadcast row patches every selected copy:

```yaml
- modify:
    - ["Balmora, Eight Plates", "urn_01", {enabled: false}]
```

A keyed row narrows by starting position:

```yaml
- modify:
    - ["Balmora, Eight Plates", "misc_com_bottle_05, (-294.999, 484.871, -101.713)", {scale: {to: 0.9}}]
```

A direct block uses action-level selection, or inherited parent outputs:

```yaml
- select:
    cell: "Balmora, Eight Plates"
    recordId: urn_01
  modify:
    enabled: false
    scale: {to: 0.9}
```

Legacy string selectors allow only one broadcast tuple per action; do not mix
those broadcast and position-keyed rows. Structured-selector rows may carry
their own independent payloads. A position-keyed patch cannot use `relocate`;
an exact `ref` query can. A standalone direct block needs selection. A child direct block can
inherit its targets. Compact child rows can add predicates to that inherited
payload:

```yaml
- modify:
    - [{scale: {to: 0.9}}, [upright, 25]]
```

`modify` cannot own children.

| Patch field | Accepted form |
| --- | --- |
| `enabled` | Boolean. |
| `position` | Absolute `[x, y, z]`, `{to: [x, y, z]}`, or relative `{by: [x, y, z]}`. |
| `rotation` | Absolute `{yaw: n, pitch: n, roll: n}`, `{to: {...}}`, or relative `{by: {...}}`; at least one angle. |
| `scale` | Absolute number, `{to: n}`, or multiplier `{by: n}`. |
| `owner` | Object with `clear`, `recordId`, `factionId`, `factionRank`. |
| `relocate` | Object with destination `cell`, absolute `position` and optional absolute `rotation`. |

Patch objects reject unknown fields. `by` and `to` cannot be combined, nor can
direct rotation angles be combined with them. Owner `clear` is boolean;
`recordId` must identify an NPC, `factionId` a faction, and `factionRank` a
non-negative integer accompanied by `factionId`. `clear: true` cannot be
combined with other ownership fields.

`relocate.cell` must resolve exactly one destination. Do not combine `relocate`
with sibling position or rotation; put the destination transform inside it.

Relative position and rotation use the object's OpenMW starting transform.
Reversing a managed transform restores that starting value, even if something
else moved the object before MOM applied the action. Position and rotation are
independent. Doors have an engine limitation: moving a door can change its
reported starting transform. MOM captures it early for known finite selections
or before its first edit, but cannot recover an earlier transform already lost
to another mod's move.

## `inventory`

Inventory actions target NPCs, creatures or containers and map item record IDs
to operation tuples. Four forms are supported.

Owners with shared items:

```yaml
- inventory:
    owners:
      - ["Balmora, Guild of Mages", "ajira"]
      - ["Balmora, Guild of Mages", "galbedir"]
    items:
      gold_001: [add, 100]
      iron_dagger: [equip]
```

Direct block:

```yaml
- select:
    cell: "Balmora, Guild of Mages"
    recordId: ajira
  inventory:
    gold_001: [add, 100]
    iron_dagger: [equip]
```

Full tuples:

```yaml
- inventory:
    - ["Balmora, Guild of Mages", "ajira", {gold_001: [add, 100]}]
```

A child may use a direct block without `select`, or compact inherited rows:

```yaml
- inventory:
    - [{gold_001: [add, 100]}, [exclude, urn_01]]
```

Even one owner uses an array containing `[cell, selector]` under `owners`.
Inventory owner selectors accept record IDs, keyed starting positions and
structured reference/record queries, not mesh paths. `inventory` cannot own children.

| Item operation | Meaning |
| --- | --- |
| `[replace, target_record_id]` | Replace the selected item type. |
| `[replace, target_record_id, equip]` | Replace it and equip the result. |
| `[remove]` | Remove the selected item type. |
| `[remove, limit]` | Limit how many are removed. |
| `[add, count]` | Add the given count. |
| `[add, count, equip]` | Add and equip. |
| `[ensure, minimum]` | Add only the deficit needed to possess at least this many copies. |
| `[ensure, minimum, equip]` | Ensure possession and request ordinary automatic equipment. |
| `[equip]` | Equip the item. |
| `[unequip]` | Unequip the item. |

Use positive integer counts and limits. Item keys and replacement targets must
be valid record IDs. IDs that do not resolve to inventory items are diagnosed
and omitted. If no owner or item resolves, MOM diagnoses and omits the action.
Equipment operations accept only Armor, Clothing, Light or Weapon records;
equipping consumables or tools is a compile error. Restocking inventories are
subject to MOM's runtime safeguards; inventory reversal is best effort if play
or another mod has changed the items since the action ran.

`ensure` requires an actual positive integer minimum. Existing copies across
stacks and item-data variants count, including equipped copies. Only missing
copies are created, using default item data. Ensure does not repair existing
equipment, trim excess copies or continuously replenish consumed items after
the operation completes. Its optional `equip` requests the usual equipment
behavior; a minimum of two does not request two equipped slots.

On reversal, MOM attempts to withdraw its own ensured additions while retaining
the captured ordinary baseline and outside additions. It never recreates a
consumed baseline to restore an exact old total. If an interrupted write cannot
be attributed safely, recovery holds instead of guessing. Restocking stock is
not converted into owned additions. Do not combine an ensured record with
another item's replacement target in the same map: that mixes minimum and
exact-total policies for one record. Record-map keys must also be unique after
case normalization.

## `kill`

Kill selected NPCs or creatures:

```yaml
- kill:
    - ["Balmora, Eight Plates", "mudcrab"]
```

The full row is `[cell, selector, options?, predicates...]`. Record IDs,
keyed starting positions and actor-resolving mesh selectors are supported.
`options` can only be an empty object; it has no public keys.

A direct block uses `kill: {}`:

```yaml
- select:
    cell: "Balmora, Eight Plates"
    recordId: mudcrab
  kill: {}
```

A child may inherit parent outputs with `kill: {}` or narrow them by selection.
It can also use compact rows with an empty payload and trailing predicates:

```yaml
- kill:
    - [{}, [exclude, rat]]
```

A standalone direct block needs action-level selection. `kill` cannot own
children, and killing is irreversible even when the guard later closes.

## Saved changes and failure behavior

MOM is unpublished; saves from earlier development implementations may be reset.
The following persistence rules apply to the current design.

Unguarded reference actions are static work. Their completed effects persist in the save,
and equivalent completed work is not repeated. Removing a configuration does
not undo it. Disjoint additions can run; overlapping changes need a supported,
unambiguous replacement of a previous edit or MOM-owned output. Old kill,
inventory, removed or otherwise unsupported work retains its claims and can
block overlapping changes. There is no generic reset command.

Guarded actions can apply, reverse and reapply as conditions change, subject to
the action's reversal support and recoverable object state. Final guarded
changes wait for static work to settle, including static work on other targets.
Children apply after their parents and are removed before their parents.

MOM compiles the installed runtime sources together. A fatal error rejects the
whole set; MOM does not install a partial result or reuse earlier individual
sources. `I.MOM.compileReport()` reports the result and bounded diagnostics.
Definition validation/commit is a separate LOAD result: failed or incomplete
LOAD work blocks runtime activation; a later runtime or save-activation failure
leaves successful definition edits in place. See the bounded `startup` summary.

Removing a definition patch and restarting stops overriding its installed
definition. It does not reroll already realized inventories or encounters.
Keep a named-definition patch installed while saves use its records. Loading
another game or using `reloadlua` recompiles runtime work without rerunning LOAD.

MOM's saved state currently uses schema `0`. Unsupported or malformed state is
preserved for diagnosis and blocks changes; it is not automatically converted.
The YAML `version: 0` is the configuration format, not a save-migration switch.
