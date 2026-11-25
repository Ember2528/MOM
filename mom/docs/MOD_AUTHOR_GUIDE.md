# Mod Author Guide

A MOM patch is a plain YAML file placed under `scripts/mom/config/` inside an enabled OpenMW data directory. You declare what should change; MOM handles targeting, startup record edits, save persistence, and reversal automatically — no Lua needed.

This guide gets your first patch running in a couple of minutes, then walks through the most common patterns. For every field and edge case, see the [Configuration Reference](AUTHORED_CONFIG_REFERENCE.md). For SSS, DOR, or VFR files, see the [Compatibility Guide](COMPATIBILITY.md).

---

## 1. Quick Start: Your First Patch

Start with a test save from before your patch runs. Create a new mod folder with this layout:

```text
My MOM Patch/
└── scripts/
    └── mom/
        └── config/
            └── my_tapestry.yaml
```

Add `My MOM Patch` as an OpenMW data directory alongside MOM's `00 OpenMW`, and paste this into `my_tapestry.yaml` (also shipped as [`mom_tutorial.yaml`](<../02 Examples/scripts/mom/config/mom_tutorial.yaml>)):

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

Each `place` row takes `[cell, recordId, [x, y, z], rotation]`. Coordinates are OpenMW world units; rotation angles (`yaw`, `pitch`, `roll`) are in degrees and default to `0`.

Restart OpenMW, load your test save, and walk into Balmora's Eight Plates. Your tapestry will be on the wall. To confirm in console (`luag`):

```lua
I.MOM.selfcheck()
I.MOM.compileReport()
```

Reloading the save will not duplicate the tapestry — MOM remembers completed placements in the save.

---

## 2. Gating Patches by Installed Mods

Every config file starts with `version: 0` and a `variants` map. Variant names can be anything you like. Every variant whose plugin requirements are met becomes active.

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

- `requires`: every listed plugin must be active.
- `requiresAny`: at least one listed plugin must be active.
- `requiresNot`: none of the listed plugins may be active.

Filenames are case-insensitive. Always give your YAML file a unique filename under `scripts/mom/config/` so it never collides with another mod's file in OpenMW's virtual filesystem.

---

## 3. Common Patch Recipes

### Choose the Right Action Verb

| Verb | What it does |
| --- | --- |
| `record` | Edit fields on a base record (or create a new named record from a template) at startup. |
| `leveled` | Add, merge, replace, or remove entries in a creature or item leveled list at startup. |
| `place` | Spawn a record at an exact cell and transform. |
| `attach` | Replace or attach objects relative to existing world objects (uniform global model swaps auto-promote to startup record edits). |
| `modify` | Change an existing object's `enabled`, `position`, `rotation`, `scale`, `owner`, or `relocate` it to another cell. |
| `inventory` | Add, ensure, remove, replace, equip, or unequip items on NPCs, creatures, or containers. |
| `kill` | Permanently kill selected actors. |

Never add an action-level `id` or `type` field — MOM identifies actions by what they do, so renaming files or reordering entries never replays finished work.

---

### Edit a Base Record or Leveled List (`record`, `leveled`)

Use `record` when you want to change a base definition (such as a book's text, an item's weight/value, a light's color/radius, or a door's sound) across the whole game without cloning placed objects:

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

Use `leveled` to edit `CreatureLevelledList` or `ItemLevelledList` records cleanly alongside other mods (`append`, `add_if_absent`, `merge_by_id`, `remove`, `replace`, `set`). Add `onMissingTarget: skip` on optional `record` or `leveled` patches if you want missing targets to warn and skip instead of failing compilation.

MOM runs `record`, `leveled`, and eligible global model swaps once during OpenMW's LOAD phase before the main menu — always restart OpenMW to pick up edits.

---

### Replace Meshes and Add Weighted Variety (`attach`)

Replace a mesh or record everywhere or in specific cells. If an unguarded `attach` with `disableOriginal: true` replaces a model globally (`"*"`) with zero offset and no rotation, MOM automatically promotes all 12 LOAD-writable record types (`Static`, `Activator`, `Door`, `Light`, `Book`, `Miscellaneous`, `Ingredient`, `Potion`, `Apparatus`, `Lockpick`, `Probe`, `Repair`) to zero-overhead base-record edits while handling `Container` and `Creature` references safely at runtime.

To pick deterministically between several replacement meshes, put a `{choose: ...}` expression in the replacement column:

```yaml
- select: {type: Static}
  attach:
    - ["Balmora, Eight Plates", furn_de_tapestry_04, {choose: [[f/Furn_De_Tapestry_02.NIF, 1], [f/Furn_De_Tapestry_03.NIF, 3]]}]
  disableOriginal: true
```

That creates **one** replacement per matching tapestry with a 1:3 relative weight ratio (rather than rolling two independent `chance` checks). For spatial clustering, regions, gradients, and `KEEP` weights, see [Replacement choices](AUTHORED_CONFIG_REFERENCE.md#replacement-choices).

---

### Target Specific World Objects (`modify`)

You can target objects in three ways depending on how specific you need to be:

**1. Every copy of a record in a cell (or region/world):**
```yaml
- modify:
    - ["Balmora, Eight Plates", "urn_01", {scale: {to: 0.9}}]
```

Or using a `select` block when sharing selection across fields:
```yaml
- select:
    cell: "Balmora, Eight Plates"
    recordId: urn_01
  modify:
    scale: {to: 0.9}
```

**2. One specific copy by its original starting coordinates:**
```yaml
- modify:
    - ["Balmora, Eight Plates", "misc_com_bottle_05, (-294.999, 484.871, -101.713)", {enabled: false}]
```
*(Always use the object's original starting position from the editor/plugin, not where it moved during play.)*

**3. One exact plugin reference (immune to load-order shifts and moves):**
```yaml
version: 0
variants:
  tiny_caius:
    actions:
      - modify:
          - ["*", {ref: [Morrowind.esm, 67647]}, {scale: 0.1}]
```
The number (`67647`) is the plugin-local reference number inside `Morrowind.esm`, not a load-order FormID. Structured selectors also support `type`, `contentFile`, `mwscript`, and wildcard `recordId: {match: "*glass*"}`.

Add `filters` to narrow by orientation or exclusions — e.g. `filters: [upright, 25]` skips objects tilted more than 25°, and `filters: [exclude, crate_01]` skips specific records.

---

### Give or Equip Items (`inventory`)

Use `[ensure, 1, equip]` when you want an NPC to wear an item without stacking duplicates if they already own one:

```yaml
- select:
    cell: "Balmora, Guild of Mages"
    recordId: ajira
  inventory:
    gold_001: [add, 100]
    common_shirt_01: [ensure, 1, equip]
```

`ensure` counts existing copies (including equipped or damaged ones) and adds only the missing amount. It runs once when applied rather than endlessly restocking consumed items.

---

### React to Time, Weather, or Quest Progress (`guards`)

Put conditional rules inside a variant's `guards` array. Every condition in `when` must be true for the block to stay active; when any condition becomes false, MOM automatically reverses reversible actions (`place`, `attach`, `modify`, and best-effort `inventory`):

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

Other `when` condition examples:

```yaml
- [weather, "Bitter Coast Region", eq, 1]
- [quest_stage, "A1_1_FindSpymaster", min, 10]
```

If a condition cannot be read yet (for example, an external provider is unavailable), MOM holds current state instead of assuming false.

---

### Follow Up on Newly Placed Objects (Child `actions`)

Attach child `actions` under a `place` or `attach` action to modify or decorate *only* the objects just spawned — without affecting other copies of the same record in the cell:

```yaml
- place:
    - ["Balmora, Eight Plates", "furn_de_tapestry_04", [1900, 960, -311], {yaw: 0}]
  actions:
    - modify:
        scale: {to: 0.8}
```

A child `attach` can omit the cell and source selector and operate directly on each parent output:

```yaml
- attach:
    - ['f\Furn_De_Tapestry_03.NIF', [0, 0, 32]]
```

*(Note: a child `place` still takes absolute coordinates and spawns once per parent output.)*

---

## 4. Working with Existing Saves

Keep these practical rules in mind when iterating on a patch or advising users:

- **Unguarded actions are permanent once saved.** Moving a YAML file or reordering entries will not replay them, and deleting the file will not undo them. Always test config edits against a clean save from before the patch ran.
- **Keyed placements (`key: ...`) update in place.** Editing a keyed placement's position, rotation, record, cell, or scale updates its managed object cleanly without creating duplicates.
- **Relative transforms use OpenMW's starting transform.** `position: {by: ...}` and `rotation: {by: ...}` always offset from the original starting transform rather than drifting on every reload, and reversing restores that starting transform. *(Door caveat: OpenMW overwrites a door's starting transform when another mod teleports it; MOM snapshots finite door selections early, but cannot recover a transform already overwritten before MOM saw the door.)*
- **Fatal config errors are atomic.** If any native YAML has a syntax or validation error, MOM refuses to activate the broken runtime set so it never leaves a half-applied save. Check `I.MOM.compileReport()` and `openmw.log` after restarting.
- **Definition patches (`record` / `leveled`) run at startup.** Removing one and restarting stops the override, except that patches using `create: true` to define brand-new record IDs must stay installed while saves reference those records.

---

## 5. Packaging Your Patch for Release

1. Ship your YAML under a unique filename in `scripts/mom/config/` inside your mod's data directory.
2. List MOM (`00 OpenMW` / `mom.omwscripts`) and any required content plugins/assets in your mod description.
3. Note whether your patch is safe to add mid-save or works best on a fresh/pre-visit save.
4. Do not `require()` internal `scripts.mom.*` Lua modules from your mod — stick to YAML or the documented [extension API](../../docs/mom/EXTENSIONS.md).

For real-world examples with plugin gates, exact references, and guarded NPC edits, browse [`01 Mod Patches`](<../01 Mod Patches/scripts/mom/config/>) and [`02 Examples`](<../02 Examples/scripts/mom/config/>).
