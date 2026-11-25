# MOM Configuration Reference (`version: 0`)

Complete syntax reference for native MOM YAML files under `scripts/mom/config/`. For a step-by-step introduction, see the [Mod Author Guide](MOD_AUTHOR_GUIDE.md). For SSS, DOR, and VFR files, see the [Compatibility Guide](COMPATIBILITY.md).

Code blocks that omit `version: 0` and `variants:` are action fragments meant to go inside a variant's `actions` or a guard's `actions`.

## Contents

- [Files & Variants](#files--variants)
- [Action Structure](#action-structure)
- [Declaration Admission](#declaration-admission)
- [Startup Definition Actions (`record`, `leveled`, Auto-Promotion)](#startup-definition-actions)
- [Selectors & Filters](#selectors--filters)
  - [Cell Selectors](#cell-selectors)
  - [Record & Keyed Selectors](#record--keyed-selectors)
  - [Structured Selectors (`ref`, `contentFile`, `type`, `recordId`, `mwscript`)](#structured-selectors)
  - [Filters & Row Predicates](#filters--row-predicates)
- [Guard Blocks (`time`, `weather`, `quest_stage`)](#guard-blocks)
- [Reference Actions](#reference-actions)
  - [`place`](#place)
  - [`attach` & Replacement Choices](#attach)
  - [`modify`](#modify)
  - [`inventory`](#inventory)
  - [`kill`](#kill)
- [Persistence & Error Handling](#persistence--error-handling)

---

## Files & Variants

MOM loads every `.yaml` and `.yml` file under `scripts/mom/config/` across enabled OpenMW data directories. Give each patch a unique relative path so OpenMW does not shadow another mod's file. Restart OpenMW after edits.

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

| Top-level field | Requirement |
| --- | --- |
| `version` | Required; must be `0`. |
| `name`, `description` | Optional strings. |
| `variants` | Required map of non-empty variant names to variant objects. |

A variant accepts only `description`, `requires`, `requiresAny`, `requiresNot`, `actions`, and `guards`. Top-level `actions` or `guards` outside `variants` are invalid.

- **Plugin gates** (`requires` = all, `requiresAny` = at least one, `requiresNot` = none) take arrays of plugin filenames matched case-insensitively.
- Every satisfied variant runs, evaluated in lexicographic variant-name order; actions inside each variant preserve authored order.

---

## Action Structure

Every action declares **exactly one verb**: `record`, `leveled`, `place`, `attach`, `modify`, `inventory`, or `kill`.

| Shared field | Supported on | Meaning |
| --- | --- | --- |
| `select` | Reference actions | Action-level target selector (`cell` plus structured query fields). |
| `filters` | Reference actions except `place` | One predicate tuple or an array of predicate tuples. |
| `chance` | Ref-targeting actions | Deterministic per-target probability (`0`–`1`, default `1`). |
| `previsit` | Static ref/cell actions | Boolean; plan static work for known exterior cells before the player visits them. |
| `actions` | `place`, `attach` | Array of child actions operating on this action's spawned outputs. |
| `requires`, `requiresAny`, `requiresNot` | Any action | Compile-time plugin gates (single string or array of filenames). |
| `admission` | Any action | Compile-time deterministic admission decision (see below). |
| `key` | Single-row `place` | Permanent semantic identity for a keyed placement (enables in-place edits). |
| `targetTypes` | `place` | Non-empty array of allowed OpenMW record types for the placed record. |
| `onMissingTarget` | `record`, `leveled` | Set to `skip` to warn and skip when the target record or content store is missing. |
| `disableOriginal` | `attach` | Boolean; disables the matched source reference after replacement. |
| `transferContents` | `attach` | Boolean (default `true` for containers); `false` rejects selected `Container` sources. |

Do not write action-level `id`, `type`, `match`, or `__`-prefixed keys. MOM derives semantic action IDs from meaning rather than filename or array position, so moving or reordering equivalent rules never replays finished work.

Reference actions can target objects in three styles:
1. **Full tuples:** each row begins with its cell, followed by target selector and payload.
2. **Select blocks:** `modify`, `inventory`, and `kill` accept `select` paired with a direct payload object.
3. **Child actions:** nested under a `place` or `attach` action's `actions` array; inherit parent outputs and may omit cell/source selectors.

---

## Declaration Admission

`admission` makes a single compile-time decision for the whole action before execution planning. It is distinct from per-target `chance` and from runtime `guards`.

| Field | Value |
| --- | --- |
| `requires`, `requiresAny`, `requiresNot` | Single plugin filename or array of filenames (case-insensitive). |
| `chance` | Probability `0`–`1` (default `1`). |
| `seed` | Finite number, floored to an integer (default `0`). |
| `key` | Optional explicit sampling key (defaults to action `key`, then normalized action hash). |
| `salt` | Optional salt string (default `condition`). |

Because admission runs at compile time, an admission becoming false on a later startup does not automatically undo already-completed static work in a save.

---

## Startup Definition Actions

MOM runs `record`, `leveled`, and eligible global model replacements once at startup (OpenMW's LOAD phase, before the main menu). Restart OpenMW after changing them; reloading Lua (`reloadlua`) or loading another save does not re-run LOAD.

### `record`

Edits fields on an existing base record, or creates a new named record from an installed template. Must be top-level (no guards, `select`, `filters`, `chance`, `previsit`, or children).

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

| Record `type` | Allowed `patch` fields |
| --- | --- |
| `Static` | `model` |
| `Activator` | `model`, `name`, `mwscript` |
| `Door` | `model`, `name`, `mwscript`, `openSound`, `closeSound` |
| `Book`, `Light`, `Miscellaneous`, `Ingredient`, `Potion`, `Apparatus`, `Lockpick`, `Probe`, `Repair` | Common: `model`, `name`, `mwscript`, `icon`, `weight`, `value` |
| `Book` *(additional)* | `text`, `isScroll`, `enchant`, `enchantCapacity`, `skill` |
| `Light` *(additional)* | `duration`, `radius`, `color`, `isCarriable`, `isDynamic`, `isFire`, `isFlicker`, `isFlickerSlow`, `isNegative`, `isOffByDefault`, `isPulse`, `isPulseSlow` |
| `Potion` *(additional)* | `isAutocalc` |
| `Apparatus` *(additional)* | `quality` |
| `Lockpick`, `Probe`, `Repair` *(additional)* | `quality`, `maxCondition` |

*Field rules:*
- `weight` and `quality`: non-negative finite numbers.
- `enchantCapacity`: `0`–`214748352`, rounded to tenths.
- `value`, `radius`, `maxCondition`: non-negative integers; `duration`: integer ≥ `-1` (`-1` = unlimited).
- `color`: packed RGB integer (red in the low byte, then green, then blue).
- `model` and `icon`: normalized paths; target meshes must exist in the VFS.
- `NPC`, `Creature`, `Container`, `Armor`, `Clothing`, and `Weapon` records are not writable via OpenMW's LOAD API — use runtime actions for those types.

**Creating a named record:** Add `create: true` and `template: existing_record_id` inside `record`. The template must already exist in installed plugins, the new `id` must be unused (and must not start with `mom__content_`), and the patch must stay installed while any save uses that record.

**Conflicts & optional edits:** Edits to different fields of the same record compose; equal-priority writes to the same field fail compilation. Set action-level `onMissingTarget: skip` to warn and skip if the target record or content store is unavailable.

### `leveled`

Edits `CreatureLevelledList` or `ItemLevelledList` records by exact `id` (case-insensitive). Must be top-level.

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

- Optional `patch`: `chanceNone` (`0`–`1`, truncated to hundredths, e.g. `0.335` → `0.33`), `calculateFromAllLevels` (boolean), and `calculateForEach` (boolean, `ItemLevelledList` only).
- Each entry is `{id: string, level: 0..65535}`.
- Note: `ItemLevelledList` write support depends on the OpenMW build (available on Luau `clockwork-alpha`; unavailable on some LuaJIT builds). Use `onMissingTarget: skip` for optional list patches.

| `op` | Behavior |
| --- | --- |
| `append` | Append `entries`, preserving duplicates for weighting. |
| `add_if_absent` | Append `{id, level}` pairs not already present. |
| `merge_by_id` | Update every existing occurrence of each `id` to its new `level`; append missing IDs once. |
| `remove` | Remove entries matching `match: {id, level?}` (omit `level` to remove all levels for `id`). |
| `replace` | Remove all matches and insert `entries` once at the first match position. |
| `set` | Replace the entire entry list with `entries`. |

### Uniform Model Replacements (Automatic LOAD Promotion)

You do not need a separate syntax for global model replacements. Write a normal `attach` action:

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

MOM automatically promotes an `attach` action to LOAD (editing base records directly with zero runtime cloning) when all of the following hold:
- Unguarded, no children, `disableOriginal: true`, `chance` omitted or `1`, `previsit` omitted or `false`.
- Unrestricted cell (`"*"`, `{}`, or `{match: "*"}`), omitted or `[0, 0, 0]` offset, and no rotation override.
- Replacement is a single `.nif` model (or a choice provably resolving to one constant `.nif` model).
- Any `filters` or row predicates are record-ID `exclude` rules only, and any `select` uses only `type`, `recordId`, or `mwscript` (no `ref` or `contentFile`).
- No competing runtime rule or variable choice interferes with the same source records.

For untyped or mixed-domain uniform model swaps, MOM automatically splits across disjoint domains: all **12 LOAD-writable model types** (`Static`, `Activator`, `Door`, `Light`, `Book`, `Miscellaneous`, `Ingredient`, `Potion`, `Apparatus`, `Lockpick`, `Probe`, `Repair`) promote to LOAD, while `Container` and `Creature` stay in GLOBAL.

---

## Selectors & Filters

### Cell Selectors

Use an exact cell name string (or `"*"`), or a selector object:

| Key | Accepted value |
| --- | --- |
| `exact` | Exact cell string or array of exact strings. |
| `match` | Pattern or array of patterns supporting leading and/or trailing `*` (prefix, suffix, or substring; not regex). |
| `kind` | `interior` or `exterior`. |
| `worldspace` | Worldspace ID or array (defaults to `sys::default` for `coords`). |
| `region` | Region ID or array (case-insensitive). |
| `coords` | Exterior grid integers: `[x, y]`, `{x, y}`, or an array of pairs (cannot combine with `kind: interior`). |
| `exclude` | Nested cell selector (cannot nest another `exclude`; needs at least one of `exact`, `match`, `coords`, `worldspace`, or `region`). |

Examples (each line is one selector):

```text
"Balmora, Eight Plates"
"*"
{exact: ["Balmora, Eight Plates", "Balmora, Guild of Mages"]}
{match: "Balmora, *"}
{kind: exterior, region: "West Gash"}
{coords: [-3, -2]}
{kind: exterior, exclude: {match: "*Balmora*"}}
```

- `exact`, `coords`, and `match` union together; `kind`, `worldspace`, and `region` restrict all candidates; `exclude` subtracts matches.
- `previsit: true` applies only to static actions resolving known exterior cells (`exact`, `coords`, `region`, or `worldspace`). `"*"` and `match` only process cells as they load.
- **Absolute `place` destinations** require exact cells only: a string, `{exact: ...}`, or `{coords: ...}`.

### Record & Keyed Selectors

Full tuple rows accept record IDs, mesh paths, or position-keyed selectors matching an object's **starting position**:

```text
record_id
record_id, (x, y, z)
meshes/foo/bar.nif
meshes/foo/bar.nif, (x, y, z)
```

- Mesh selectors work on `attach`, keyed `modify`, and actor-targeting `kill` (not `inventory` owners).
- When a child action inspects a mesh-cloned parent output, `recordId` and `[exclude, ...]` match the original source record ID automatically.

### Structured Selectors

Use an object in `select` (with optional `cell`) or in the target column of a full `modify`, `inventory`, `kill`, or `attach` row:

| Field | Accepted value |
| --- | --- |
| `ref` | `[pluginFilename, localRefNum]` or `[pluginFilename, [num1, num2, ...]]` (plugin-local integers `0`–`16777215`, immune to load-order shifts). |
| `contentFile` | Plugin filename or array matching the reference's own plugin provenance (generated outputs have none). |
| `type` | OpenMW type name or array (e.g. `Static`, `NPC`, `[Weapon, Armor]`). |
| `recordId` | Exact ID, array of IDs, or `{match: patternOrArray}` (leading/trailing `*` only). |
| `mwscript` | Base-record MWScript ID or array (does not match Lua scripts). |

All supplied fields must match (AND); array items within a field are alternatives (OR).

```yaml
- modify:
    - ["*", {ref: [Morrowind.esm, 67647]}, {scale: 0.1}]
    - ["*", {type: [Weapon, Armor], recordId: {match: ["*glass*", "*ebony*"]}}, {enabled: false}]
    - ["Vivec, Black Shalk Cornerclub", {type: NPC, mwscript: ElayneUSebaonard}, {position: [322, -4, -63]}]
```

- An action-level `select: {ref: [...]}` may omit `cell`. Exact `ref` selectors support `relocate` (unlike position-keyed string selectors).
- Structured `attach` selectors must include one exact `recordId` as a source hint.
- `recordId.match` and `mwscript` queries resolve installed records at startup; adding new matching records in a later session triggers rediscovery without resetting already-completed targets.

### Filters & Row Predicates

Use `filters` on an action (single tuple or array of tuples), or append predicate tuples to the end of a full row (not supported on `place`):

| Predicate tuple | Matches when |
| --- | --- |
| `[upright]` | Tilted ≤ 25° from vertical. |
| `[upright, maxTilt]` | Tilted ≤ `maxTilt` degrees. |
| `[facing, direction]` | Facing within 45° of `direction` (degrees or compass name: `north` = `0`, `east` = `90`, `northeast`, etc.). |
| `[facing, direction, tolerance]` | Facing within `tolerance` degrees. |
| `[exclude, id1, id2, ...]` | Reference's record ID is not any of the listed IDs. |

```yaml
- modify:
    - ["Balmora, Eight Plates", "urn_01", {scale: 0.9}, [upright, 25]]
  filters:
    - [exclude, crate_01]
```

---

## Guard Blocks

A variant's `guards` array holds objects containing only `when` (array of condition tuples; all must match) and `actions`:

```yaml
guards:
  - when:
      - [time, hour, range, 18, 6, inclusive]
    actions:
      - place:
          - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

When a condition is temporarily unreadable, MOM holds current state rather than reverting.

### Numeric Operators (`time` scalars & `quest_stage`)

| Operator syntax | Meaning |
| --- | --- |
| `eq, N` | `== N` |
| `min, N` | `>= N` |
| `max, N` | `<= N` |
| `any, [N1, N2, ...]` | Matches any listed integer. |
| `not, [N1, N2, ...]` | Matches none of the listed integers. |
| `range, start, end` / `range, start, end, inclusive` | Both endpoints included. |
| `range, start, end, exclusive` | `start` included, `end` excluded. |

### `time`

Scalar fields: `hour`, `month`, `day`, `dayOfWeek`, `yearDay` (ranges wrap when `start > end`, e.g. `18` to `6`). Also supports `season` (`eq`/`any`), `date` (`eq`/`any`/`range`), and `flags.isWeekend` (boolean directly; days 1 and 7):

```yaml
- [time, hour, range, 18, 6, inclusive]
- [time, dayOfWeek, any, [1, 7]]
- [time, season, any, [spring, summer]]
- [time, date, range, {month: 4, day: 1}, {month: 4, day: 30}, inclusive]
- [time, flags.isWeekend, true]
```

`date` objects accept integer `month` (`1`–`12`), `day` (`1`–`31`), and optional `year` (omitting `year` repeats annually, including across New Year).

### `weather`

Matches a region's weather script ID using `eq`, `any`, or `not`:

```yaml
- [weather, "Bitter Coast Region", eq, 1]
- [weather, "Ascadian Isles Region", any, [1, 2, 3]]
- [weather, "Molag Amur Region", not, [4]]
```

### `quest_stage`

Supports all numeric operators:

```yaml
- [quest_stage, "A1_1_FindSpymaster", min, 10]
- [quest_stage, "A1_1_FindSpymaster", range, 10, 50, inclusive]
```

---

## Reference Actions

### `place`

Spawns records at exact destinations: `[cell, recordOrChoice, [x, y, z], rotation]`.

```yaml
- place:
    - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

- `rotation` is required (`yaw`, `pitch`, `roll` in degrees; `{}` = all zero). Meshes cannot be placed directly.
- Does not accept `select.recordId`, `filters`, or row predicates. Can own child `actions`.
- **Weighted record choice:** Replace the second column with `{choose: [[recordA, weightA], [recordB, weightB]], seed?, key?, salt?}` (positive finite weights; record IDs or `{recordId: ...}`; default salt `alternative`). Chosen once at compile time.
- **Keyed placements:** Add `key: "unique_id"` on a single-row `place` action to give it a permanent identity independent of filename/order (unique across active keyed placements). Distinct keys can place separate objects at identical coordinates, and editing a keyed placement's transform, record, cell, or scale updates the spawned object in place. Add `targetTypes: [Static, Activator]` to enforce allowed record types.

```yaml
- key: my_patch:tapestry
  targetTypes: [Static]
  admission: {chance: 0.75, seed: 12}
  place:
    - ["Balmora, Eight Plates", {choose: [[furn_de_tapestry_03, 2], [furn_de_tapestry_04, 1]], seed: 7}, [1900, 960, -311], {yaw: 0}]
```

### `attach`

Spawns or replaces objects relative to matching sources: `[cell, sourceSelector, replacement, offset?, rotation?, predicates...]`.

```yaml
- attach:
    - ["Balmora, Eight Plates", "furn_de_tapestry_04", 'f\Furn_De_Tapestry_03.NIF', [0, 0, 32], {yaw: 0}]
  disableOriginal: true
```

- `offset` defaults to `[0, 0, 0]`; `rotation` (if given) must follow an offset.
- **Supported source types at runtime:**
  - `Static` and scriptless `Activator`: `disableOriginal` optional.
  - Non-restocking `Container`: requires `disableOriginal: true` and one `Container` output; transfers live inventory, player deposits, lock state, and respawn behavior cleanly. *(Known Luau limitation: Luau's `Lockable` key/trap setters reject supplied values, so container transfers needing key/trap writes can fail on Luau.)*
  - Living, non-summoned `Creature`: one-for-one mesh replacement only with `disableOriginal: true`. Spawns a fresh actor from a copy of the base record (preserving stats, base inventory, services, AI, MWScript, transform, scale, and owner, but not live health/inventory/active effects/script locals).
  - `NPC`, `Door`, `Light`, and other item-bearing sources are not cloned at runtime.
- **Ownership:** Replacements by model path or with `disableOriginal: true` preserve the source reference's owner; non-disabling attachments stay unowned.

#### Replacement Choices

Replace the third column with a weighted choice object (unguarded static `attach`, `disableOriginal: true`, zero/omitted offset, no rotation, record-ID `exclude` predicates only):

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

| Field | Meaning |
| --- | --- |
| `choose` | Non-empty array of `[target, weight]` tuples (`target` = string or `{recordId: ...}` / `{model: ...}`; missing alternatives keep their weighted slot without shifting probabilities). |
| `keepWeight` | Weight for keeping the original (default `0`; ignored when `profile` is provided). |
| `keep` | `stop` (default) ends choice routing on KEEP; `continue` lets lower-priority rules run. |
| `priority` | Optional 32-bit integer for ordering competing choice rules within the same action priority tier (higher runs first). |
| `order` | Optional tie-breaker string (defaults to authored order). |
| `profile` | Optional spatial weighting profile (see below). |

**Spatial profiles (`profile`):** For `N` targets, every weight vector has **`N + 1` entries** (`[keepWeight, target1, ..., targetN]`; omitted `profile.default` defaults to KEEP-only; negative weights count as `0`).

| `profile` field | Shape |
| --- | --- |
| `seed` | Finite number, floored (default `0`). |
| `cluster` | `{scale, detail, detailWeight, jitter}` (`scale` and `detail` > 0). |
| `default`, `interiorDefault` | Weight vectors (`N + 1` numbers). |
| `regions` | Map of region ID → weight vector. |
| `cells` | Array of `{x, y, weights}` (integer grid coords). |
| `points` | Array of `{x, y, radius, weights}` (world coords, `radius > 0`). |
| `interiors` | Map of cell name → `{weights: [...]}` or virtual location `{x?, y?, region?}`. |
| `gradients` | Array of `{axis, anchors: [{at, weights}, ...], offsetAxis?, offsets?: [{at, value}, ...]}` (`axis` = `x`, `y`, `wetness`, `warmth`, `snow`, or `ash`). |
| `climateOverrides` | Map of region ID → `{wetness?, warmth?, snow?, ash?}`. |

Exterior override priority: `points` > `cells` > `regions` > `gradients` > `default`. Interior priority: explicit `interiors[cell].weights` > virtual location rules > `interiorDefault` > `default`.

#### Child Attachments

Under a parent's `actions`, `attach` can omit cell and source: `[replacement, offset?, rotation?, predicates...]`. Do not mix full and abbreviated rows in one `attach` action.

```yaml
- attach:
    - ['f\Furn_De_Tapestry_03.NIF', [0, 0, 32], {yaw: 90}]
    - ['f\Furn_De_Tapestry_02.NIF', [0, 0, 64]]
```

### `modify`

Modifies existing references. Cannot own child actions.

**Forms:**
- Full row: `["Balmora, Eight Plates", "urn_01", {enabled: false}]`
- Position-keyed row: `["Balmora, Eight Plates", "misc_com_bottle_05, (-294.999, 484.871, -101.713)", {scale: {to: 0.9}}]`
- Select + direct block: `select: {cell: ..., recordId: ...}` + `modify: {enabled: false, scale: {to: 0.9}}`
- Compact child row: `modify: [[{scale: {to: 0.9}}, [upright, 25]]]`

*(Note: legacy string selectors allow at most one broadcast row per action and cannot mix broadcast + position-keyed rows; structured-selector rows have no such restriction.)*

| Patch field | Accepted syntax |
| --- | --- |
| `enabled` | Boolean. |
| `position` | `[x, y, z]`, `{to: [x, y, z]}`, or relative `{by: [x, y, z]}` (from starting position). |
| `rotation` | `{yaw?, pitch?, roll?}`, `{to: {...}}`, or relative `{by: {...}}` (at least one angle; from starting rotation). |
| `scale` | Positive number, `{to: n}`, or multiplier `{by: n}`. |
| `owner` | `{clear: true}` or `{recordId?, factionId?, factionRank?}` (`factionRank` requires `factionId`; cannot combine with `clear: true`). |
| `relocate` | `{cell: exactCell, position: [x, y, z], rotation?: {...}}` (cannot combine with sibling `position`/`rotation`, or with position-keyed string selectors; works with `ref` selectors). |

### `inventory`

Modifies inventories on `NPC`, `Creature`, or `Container` owners (record IDs, starting-position keys, or structured selectors; no mesh selectors; cannot own children).

**Forms:**
- Shared items across multiple owners: `inventory: {owners: [[cell, selector], ...], items: {item_id: opTuple}}`
- Select + direct map: `select: {...}` + `inventory: {gold_001: [add, 100]}`
- Full row: `inventory: [["Balmora, Guild of Mages", "ajira", {gold_001: [add, 100]}]]`
- Compact child row: `inventory: [[{gold_001: [add, 100]}, [exclude, urn_01]]]`

| Item operation | Effect |
| --- | --- |
| `[add, count]` / `[add, count, equip]` | Add `count` copies (optionally equip). |
| `[ensure, min]` / `[ensure, min, equip]` | Add only enough copies to reach at least `min` total (counts existing/equipped copies; never trims excess). |
| `[remove]` / `[remove, limit]` | Remove all (or up to `limit`) matching copies. |
| `[replace, new_id]` / `[replace, new_id, equip]` | Replace matching items with `new_id` (optionally equip). |
| `[equip]` / `[unequip]` | Equip or unequip the item. |

`equip` / `unequip` only allow `Armor`, `Clothing`, `Light`, and `Weapon` records. Do not target the same record with both `ensure` and another item's `replace` target in one map. Reversal is best-effort if play modified the inventory.

### `kill`

Permanently kills matching `NPC` or `Creature` targets (cannot own children; never reverses when a guard closes).

```yaml
- kill:
    - ["Balmora, Eight Plates", "mudcrab"]
```

Or with `select` / child inheritance: `kill: {}` (or compact child row `kill: [[{}, [exclude, rat]]]`). Full row syntax is `[cell, selector, {}?, predicates...]`.

---

## Persistence & Error Handling

- **Save schema:** MOM stores runtime state in a compact `schemaVersion = 1` ledger. Pre-release `schemaVersion = 0` payloads reset cleanly on load.
- **Static vs. guarded:** Unguarded reference actions run once per target/cell and persist in the save. Guarded actions apply, reverse (deepest child first), and reapply as guard truth changes, waiting for static cell work to settle first.
- **Atomic compilation:** All native configs compile together; a fatal syntax or validation error rejects the runtime set so partial patches never corrupt a save. LOAD definition failures block runtime activation; a runtime failure after a valid LOAD run leaves committed startup definitions intact. Inspect both via `I.MOM.compileReport()`.
