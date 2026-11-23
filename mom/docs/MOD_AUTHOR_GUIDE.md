# Write a MOM patch

A MOM patch is a YAML file in `scripts/mom/config/` inside an enabled OpenMW
data directory. It names objects and describes changes; MOM finds the targets
and performs the work. You do not need to write Lua.

This guide walks through a small patch, then explains how to choose targets and
add conditions. The [configuration reference](AUTHORED_CONFIG_REFERENCE.md)
lists every supported form. For SSS, DOR or Variation Framework data, use the
[compatibility guide](COMPATIBILITY.md).

## Make a first patch

Use a test save from before the patch runs. The example below places a vanilla
tapestry in Balmora's Eight Plates and needs no other mod. It is also shipped as
[`mom_tutorial.yaml`](<../02 Examples/scripts/mom/config/mom_tutorial.yaml>).

Create your own data directory with this layout:

```text
My MOM Patch/
└── scripts/
    └── mom/
        └── config/
            └── my_tapestry.yaml
```

Add `My MOM Patch` as an OpenMW data directory, alongside MOM's `00 OpenMW`.
Put this complete configuration in `my_tapestry.yaml`:

```yaml
version: 0
name: Tapestry tutorial
description: Place a tapestry in the Eight Plates.
variants:
  tutorial_tapestry:
    actions:
      - place:
          - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

Each `place` row names a destination cell, a record, a position and a rotation.
Positions use game coordinates; angles use degrees. `yaw` turns the object
around its vertical axis. Omitted `pitch` and `roll` are zero.

Fully restart OpenMW, load your test save, and enter the Eight Plates. The patch
adds one tapestry at the specified position. In the console, enter `luag`, then
run `I.MOM.selfcheck()` and `I.MOM.compileReport()`. The runtime should report
`running`, and the compile report should include the placement. Reloading a save
with the unchanged completed patch should not add another tapestry.

Enable either your copy or the bundled example while following this exercise.
The bundled `02 Examples` directory also contains a book-definition/urn-scale
example and an OAAB-dependent lightning rod replacement. Enabling an examples
directory enables its actual patches.

## Choose when a patch is active

Every file has `version: 0` and a `variants` map. Variant names are labels you
choose. A variant without content requirements is active automatically.

Use plugin filenames to enable a patch only for the intended mod combination:

```yaml
version: 0
variants:
  my_compatibility_patch:
    requires: [SomeMod.esp, AnotherMod.esm]
    requiresNot: [AlternativePatch.esp]
    actions:
      - place:
          - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

`requires` needs every listed content file; `requiresAny` needs at least one;
`requiresNot` needs none. Filename comparisons ignore case. All satisfied
variants contribute their actions, so overlapping variants can both run.
Use separate filenames for independent configuration files: OpenMW overrides
files that share the same virtual path.

## Choose an action

| Action | Use it to |
| --- | --- |
| `record` | Edit a supported base definition or create a named definition from an installed template. |
| `leveled` | Edit the entries and properties of an exposed creature/item list. |
| `place` | Create an object at an absolute cell and transform. |
| `attach` | Create an object relative to selected existing objects; MOM automatically promotes eligible uniform model replacements to base-definition edits. |
| `modify` | Change an existing object's enabled state, owner, transform or scale. |
| `inventory` | Add, remove, replace, equip or unequip inventory items. |
| `kill` | Kill selected actors permanently, including when used under a guard. |

These are the keys written in YAML. Do not add an action-level `type` or `id`.
The `type` inside `record` or `leveled` names its definition domain.
Actions go inside a variant's `actions`, or inside a guard block's `actions`.
Definition operations are top-level and cannot be guarded or have children.

## Change a definition

Use the same actions, tuple forms and `scripts/mom/config/` files for all
supported changes. Describe the intended targets, scope, conditions and effects;
MOM transparently promotes eligible actions to LOAD and handles other supported
actions in GLOBAL. You do not select a layer or write a separate promoted form.
The compiler makes that decision after native and imported data have become
ordinary actions and their selectors, predicates and choices have been
normalized together. There is no context flag or extra configuration directory.

For example, change a book's displayed name and text without replacing its
record or placed copies:

```yaml
version: 0
variants:
  book_definition:
    actions:
      - record:
          type: Book
          id: bk_lustyargonianmaid
          patch:
            name: A Patched Book
            text: "Text supplied by my MOM patch."
```

Restart OpenMW to apply definition edits. They run before the main menu, once
per process. Loading another save or reloading Lua recompiles runtime work but
does not repeat LOAD writes. Inspect the bounded `startup` summary in
`I.MOM.compileReport()` separately from the runtime result.

Use `leveled` for exposed creature/item lists. An unrestricted model-only
`attach` with a supported explicit `select.type` is automatically promoted when
eligible. The type selects intended records; it is not an execution-mode setting.
Compact, nested and tuple-local record exclusions have the same promotion
meaning. A constant replacement choice can qualify too. Empty filters/children,
`chance: 1` and `previsit: false` are neutral. Untyped, guarded, scoped or
output-dependent attachments remain runtime work. Interacting replacements
also stay together when promotion could change another selector or choice
winner. A missing target, asset or API is handled by the selected backend;
it does not redirect the action into another context.
The [definition reference](AUTHORED_CONFIG_REFERENCE.md#definition-changes-and-reference-actions)
lists admitted fields, list operations and complete examples.

Moving placed references, editing live inventories, equipping items and killing
actors use ordinary actions that MOM handles at runtime. NPC, Creature,
Container, Armor, Clothing and Weapon definition edits
are unavailable in the checked content bindings. Their supported reference
operations continue to use the runtime.

## Use deterministic alternatives

An attachment's replacement column can hold a compact weighted choice:

```yaml
- select: {type: Static}
  attach:
    - ["Balmora, Eight Plates", furn_de_tapestry_04, {choose: [[f/Furn_De_Tapestry_02.NIF, 1], [f/Furn_De_Tapestry_03.NIF, 3]]}]
  disableOriginal: true
```

This is one replacement choice, with relative weights 1 and 3. It does not
create both outputs or make two independent `chance` checks. The ordinary
choice mechanism also supports explicit `{recordId: ...}` and `{model: ...}`
targets, spatial profiles and KEEP stop/fallthrough. Read the
[choice reference](AUTHORED_CONFIG_REFERENCE.md#replacement-choices) before using
those controls, particularly the profile's separate KEEP/default weight slot.

Absolute `place` can choose a record in its second column. Add an action `key`
when a placement needs a permanent identity independent of its file, and use
`admission` for one deterministic declaration-level chance. Ordinary `chance`
is a different per-reference gate; a runtime guard is different again, owning
desired state while its condition holds. Compile-time admission becoming false
does not reverse completed static work. The
[placement reference](AUTHORED_CONFIG_REFERENCE.md#place) gives the exact form.

Optional `record` and `leveled` edits can use `onMissingTarget: skip` to warn and
contribute no work when their existing target or content store is unavailable.
They use the same compiler and content planner as ordinary strict edits.

## Select the right objects

A full action row starts with a cell. Its next item selects a record, except
that `place` names the record to create. A plain record selector can match more
than one object. For example, this affects every matching urn in that cell:

```yaml
- modify:
    - ["Balmora, Eight Plates", "urn_01", {scale: {to: 0.9}}]
```

To distinguish copies of a record, add its original starting position:

```yaml
- modify:
    - ["Balmora, Eight Plates", "misc_com_bottle_05, (-294.999, 484.871, -101.713)", {enabled: false}]
```

Use the record ID, not the object's displayed name. The coordinates in a keyed
selector are the object's starting position, not where it happens to be now.
`attach`, keyed `modify` and `kill` can also select by mesh path. Inventory
owners must be selected by record.

An alternative for actions sharing one target selection is a `select` block:

```yaml
- select:
    cell: "Balmora, Eight Plates"
    recordId: urn_01
  modify:
    scale: {to: 0.9}
```

Cell selectors can name an exact cell, several exact cells, an exterior grid
coordinate, a region or a worldspace. `"*"`, name patterns and kind-only queries
work on loaded cells; they do not visit the whole world. Absolute `place` needs
exact destinations. The [reference](AUTHORED_CONFIG_REFERENCE.md#cell-selectors)
explains the combinations and `previsit` option.

Filters narrow a selection by orientation or excluded record IDs. For example,
`filters: [upright, 25]` restricts an attachment to objects tilted no more than
25 degrees. Sibling filters affect the action; trailing predicates affect one
row. `chance` gives a deterministic per-target probability on supported
ref-targeting actions, rather than a fresh roll every frame.

Use a structured selector when placement coordinates are insufficient or you
want a record query. An exact plugin-local reference remains the same target
after plugin load-order changes and after MOM relocates it:

```yaml
version: 0
variants:
  tiny_caius:
    actions:
      - modify:
          - ["*", {ref: [Morrowind.esm, 67647]}, {scale: 0.1}]
```

The reference number is local to `Morrowind.esm`, not a full FormID containing
load-order bits. Other selector fields include `type`, `contentFile`, `mwscript`
and explicit `recordId: {match: "*substring*"}`. All fields restrict the same
target; values within an array are alternatives. The
[reference](AUTHORED_CONFIG_REFERENCE.md#structured-reference-and-record-selectors)
explains availability, source hints for attachments and startup record queries.

Inventory `[ensure, 1, equip]` gives an actor an item only if needed and requests
equipment. Existing copies count, including damaged or equipped ones. Unlike
`[add, 1, equip]`, it does not always add another copy; unlike an exact-count
operation, ensure does not trim excess copies. Completion is still one action,
not an ongoing replenishment service after play consumes the item.

## Add a condition that changes during play

Use a guard for time, weather or quest progress. The following complete patch
places a tapestry from 18:00 through 06:00:

```yaml
version: 0
variants:
  evening_tapestry:
    guards:
      - when:
          - [time, hour, range, 18, 6, inclusive]
        actions:
          - place:
              - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
```

All conditions in one `when` block must hold. A guarded placement can disappear
when its condition closes and return when it opens. If a condition cannot be
read, MOM holds existing work instead of treating missing information as false.
Guarded final changes wait for outstanding static work to settle.

Other examples of conditions are:

```yaml
- [weather, "Bitter Coast Region", eq, 1]
- [quest_stage, "A1_1_FindSpymaster", min, 10]
```

These are individual `when` rows, not complete files. See the
[guard reference](AUTHORED_CONFIG_REFERENCE.md#guard-blocks) for operators,
date ranges and weather IDs.

## Follow a placement with another action

A `place` or `attach` action can contain child `actions`. Children work on the
objects their parent produced, so they can change a new object without
selecting every copy of its record in the cell:

```yaml
- place:
    - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
  actions:
    - modify:
        scale: {to: 0.8}
```

A child `attach` can omit the ordinary cell and source selector:

```yaml
- attach:
    - ['f\Furn_De_Tapestry_03.NIF', [0, 0, 32]]
```

That row attaches to each parent output. A child may narrow inherited targets
with `select`, filters or trailing predicates. A child `place` still uses
absolute destinations and runs once for each inherited output; it does not mean
an offset from the parent. Only output-producing families can own children.

## Changes and existing saves

MOM is unpublished. Saves made by previous development implementations are not
a compatibility target; use a fresh development save when changing compiler
versions. The following rules describe ordinary persistence within this design.

Unguarded reference work is a static patch. Once it completes, MOM remembers it in the
save and skips the unchanged work. Moving a configuration file or reordering an
equivalent action does not reset it. Changing what the action does creates
new work.

Removing an unguarded action does not reverse it. MOM can replace some unique
`modify` edits and placements whose outputs it owns, but old, ambiguous,
inventory or kill work can prevent overlapping replacements. A test save from
before the patch ran gives you a clean way to test an edited configuration.
MOM has no general command to erase this saved history or undo its world effects.

Guarded `modify` and placement changes can reverse when MOM has the evidence
needed to recover the objects. Inventory reversal is best effort because
playing the game or another mod can change the same inventory. `kill` is
permanent even inside a guard.

Position and rotation edits use the object's OpenMW starting transform.
Relative `by` changes are calculated from that transform; reversing an edit
restores its starting value, including when something else moved the object
before MOM applied the patch. Position and rotation are independent changes.
MOM reconciles its edits when work runs; it does not continuously watch every
object for outside changes.

Doors need particular care: OpenMW can change their reported starting transform
when they move. MOM captures that transform early for known finite cell
selections, or before its first change for later targets. If another mod moves
a door before MOM observes it, the earlier transform may no longer be available.

A fatal configuration error prevents the complete runtime configuration set
from starting. Check `I.MOM.compileReport()` and the log after a restart. MOM
preserves unsupported saved state and blocks changes; it does not automatically
migrate that state.

Definition edits have a separate process lifetime. Restarting after removing a
definition patch stops its override; already realized inventories and encounters
retain native persistence. Keep named-definition patches installed while a save
uses their records. A successful LOAD commit remains in place even if a later
runtime compile fails. No conversion of earlier development saves is provided.

## Package the patch

Ship your YAML under a distinct `scripts/mom/config/` filename in your mod's
data directory. Document required plugins and assets, what the patch changes,
and whether it is intended for an existing save. Users need MOM enabled as well
as your directory. Do not depend on internal `scripts.mom` Lua modules.

The bundled [compatibility patches](<../01 Mod Patches/scripts/mom/config/>)
show real plugin requirements, exact targeting and guarded actor changes. Use
the [configuration reference](AUTHORED_CONFIG_REFERENCE.md) when extending the
example to other actions or selectors.
