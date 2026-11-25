# Compatibility Guide (SSS, DOR & Variation Framework)

MOM natively reads supported data files from **Static Switcher (SSS)**, **Dynamic Object Replacer (DOR)**, and **Variation Framework (VFR)** straight from their original folder paths — no conversion to native MOM YAML required.

---

## Quick Setup

1. Install the mod's data directory normally so its meshes, textures, plugins, and config files are in OpenMW's virtual filesystem.
2. Keep `mom.omwscripts` enabled.
3. **Disable the original OpenMW replacement script** so two frameworks do not fight over the same objects:
   - For **VFR** packs: disable `variationFramework.omwscripts`.
   - For **SSS** packs: disable the SSS OpenMW script for overlapping configs.
   - For **DOR** packs: MWSE scripts do not run in OpenMW; MOM reads the Lua table files safely without executing Lua code.
4. Start from a save that has not been modified by the original replacement runtime (MOM does not adopt replacement chains created by another mod).
5. Fully restart OpenMW after adding or editing imported files.

### Discovered Paths

| Format | Folder inside any enabled data directory |
| --- | --- |
| **SSS** | `scripts/staticSwitcher/data/` (`.yaml`, `.yml`) |
| **DOR** | `MWSE/mods/_OR_/_OR_*.lua` |
| **VFR replacements** | `scripts/variationframework/{plants,containers,clutter,banners}/data/` |
| **VFR decorations** | `scripts/variationframework/placements/data/` |
| **VFR leveled creatures** | `scripts/variationframework/leveled_creatures/data/` |

VFR example templates named `EXAMPLE.yaml` or `EXAMPLE.yml` (any casing) are automatically ignored. Normal OpenMW virtual-filesystem override order applies when two data directories share a path.

---

## Precedence Order

When native MOM rules, VFR packs, and SSS packs target the same object, MOM resolves them in a consistent, non-inverting priority hierarchy:

| Tier | Source | Priority |
| --- | --- | ---: |
| 1 (highest) | Native MOM YAML (`scripts/mom/config/`) | `0` |
| 2 | VFR module with `supersede_static_switcher: true` | `-1` |
| 3 | Static Switcher (SSS) | `-2` |
| 4 (lowest) | Default VFR module | `-3` |

Within the same VFR tier:
1. Higher module `priority` runs before lower `priority`.
2. Exact `record_variants` rules run before `variants` mesh rules.
3. Record-specific `KEEP` stops replacement for that record; mesh `KEEP` falls through to lower-priority matching rules.

---

## Static Switcher (SSS)

MOM imports declarative SSS static mesh replacement modules containing `replace_meshes`.

**Supported:**
- `replace_meshes` (source mesh → replacement mesh)
- Optional location scopes combined as a union: `replace_names` (case-insensitive substring), `replace_regions` (case-insensitive region ID), and `exterior_cells` (`{x, y}` grid objects, with previsit enabled for listed grids)
- Omitting all location fields (or supplying empty lists) applies globally
- `ignore_records` (record ID exclusions)
- `log_name` metadata and `priority: standard` (or omitted)

**Not supported (diagnosed as errors):**
- Instance rules, mixed static/instance modules, and static `once`
- Non-`standard` SSS priorities
- Unknown fields, invalid mesh paths, or conflicting mesh aliases after path normalization
- Custom SSS Lua scripts

---

## Dynamic Object Replacer (DOR)

MOM reads static Lua data tables from `MWSE/mods/_OR_/_OR_*.lua` (case-insensitive prefix) containing `objectToReplaceN` entries with `oldObject` and `newObjects.newObjectN` candidates.

| Field | Behavior |
| --- | --- |
| `newObject` | Replacement record ID (original object is disabled). |
| `replaceChance` | Deterministic per-target probability (`0`–`1`, default `1`). |
| `specificCell` | Cell-name substrings (strings or `{cellName: ...}` objects) restricting where the candidate applies. |
| `excludedCell` | Same format, excluding matching cells. |

Candidates for the same `oldObject` compete through MOM's conflict arbitration so only one wins (scoped candidates > excluded-cell specificity > higher chance > source order).

**Not supported:** Dynamic Lua logic (functions, calls, arithmetic, or MWSE API calls). Only static tables, primitives, comments, and local literal tables referenced by the return value are parsed.

---

## Variation Framework (VFR)

### 1. Category Replacements (`plants`, `containers`, `clutter`, `banners`)

**Supported:**
- `variants` (mesh sources) and `record_variants` (record sources), using `meshes` or `records` targets with consistent variant counts across the module
- Module headers: `name`, `enabled`, integer `priority`, `require_content`, `exclude_content`, `supersede_static_switcher`
- `ignore_records` and `kinds` (`Static`, `Activator`, `Container`, `Ingredient`)
- Full spatial weighting: `seed`, `clustering` (with category defaults), `weights.default`, `interior_default`, `regions`, `cells`, `points`, `interiors`, `latitude`/`longitude` + offset curves, climate gradients (`wetness`, `warmth`, `snow`, `ash`), and `climate_overrides`
- Respawning `Container` replacement preserving live inventory, player deposits, locks, and ownership (including `records:` replacements)
- Automatic startup (LOAD) promotion for unrestricted constant model swaps (including supported `Ingredient` definitions) when no competing runtime rules interfere

**Not supported (diagnosed as errors):**
- Runtime `Ingredient` variation (requires per-reference item transfer)
- `contents` inventory conversions to different item records (empty entries and `keep` are allowed)
- `Container` replacement with `transfer_contents: false`
- Unsupported source types (e.g. `Door`, `NPC`), unknown schema keys, duplicate normalized names, or duplicate gradient anchors

### 2. Decorations (`placements`)

**Supported:**
- Module headers: `name`, `enabled`, integer `priority`, `require_content`, `exclude_content`, `seed`, and `placements` array (module content gates merge with per-placement `conditions`)
- Existing `Static` and `Activator` records via `record` or weighted `alternatives`
- Exact locations via `cell`, `interior`, or `exterior` (`true` to derive grid from position, or integer `{x, y}` containing the position)
- `position`, `rotation` (roll, pitch, yaw in degrees; defaults to `0`), positive `scale`
- Per-placement `enabled: false` and `conditions` / `condition` (`chance`, `require_content`, `exclude_content`)
- Case-insensitive permanent `id`s (unique across active files; distinct IDs can share identical coordinates)
- **In-place updates:** Editing a keyed placement's position, rotation, record, cell, or scale updates its managed object in place without duplicating it (resetting `scale` back to `1` reverts the scale cleanly)

**Not supported:**
- `record_draft` (runtime draft creation) and `spawn: true` native spawn points
- Actors and inventory-bearing placed objects
- Auto-deleting already-placed objects when an entry is deleted/disabled, and item relinquishment

### 3. Leveled Creatures (`leveled_creatures`)

VFR leveled-creature modules run as ordinary MOM `leveled` edits during OpenMW's LOAD phase (requiring `openmw.content.levelledCreatures.records`). Always restart OpenMW after changes.

**Supported:**
- Module headers: `name`, `enabled`, integer `priority`, `require_content`, `exclude_content`, and `injections` array
- Each injection takes `list` and `add` (`{id, level}`, with integer levels `0`–`65535`)
- Deterministic merge order: ascending module `priority` → path → rule → entry order; updating an existing creature refreshes its level without duplicating it, while preserving existing flags, chance, and unrelated entries
- Composes cleanly alongside native MOM `leveled` edits
- Malformed modules, invalid rules, and missing target lists are logged and skipped cleanly without failing startup

---

## Shared Runtime Limits & Diagnostics

- **Supported runtime replacement sources:** `Static`, scriptless `Activator`, non-restocking `Container` (one-for-one with `disableOriginal: true`), and living non-summoned `Creature` (one-for-one mesh replacement creating a fresh base-record copy without live inventory/health/AI transfer). `NPC`, `Door`, `Light`, and other item-bearing sources are not cloned at runtime; eligible uniform global model swaps across all 12 LOAD-writable record types edit base definitions directly at startup instead.
- **Diagnostics:** Run `I.MOM.compileReport()` in global console (`luag`) and inspect `[MOM]` lines in `openmw.log` (`[MOM][WARN][compat]` / `[MOM][ERROR][bootstrap]`). By default, a fatal import error blocks runtime activation atomically so partial packs never corrupt a save; developers/test harnesses can opt into per-file compat quarantine via `compatErrorPolicy = 'skip'`, which skips failing compat files with `compat_source_skipped` warnings while keeping native MOM configs strictly atomic.
- **Save behavior:** Imported static replacements follow MOM's normal save rules — see [Working with Existing Saves](MOD_AUTHOR_GUIDE.md#4-working-with-existing-saves).
