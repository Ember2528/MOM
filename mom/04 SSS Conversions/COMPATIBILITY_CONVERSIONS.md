# Compatibility example conversions

All **twelve** SSS compatibility fixtures now have native MOM configurations.
Structured selectors retain their plugin/reference-number or provenance
conditions, and the Elayne example uses the NPC's MWScript instead of guessing
its record ID. The earlier nine target-identity blockers are resolved; original
starting coordinates and recovered base-record names are no longer necessary
for reference-number selection.

These are adaptations of the SSS examples' **permanent placement intent**.
They do not reproduce SSS's current-cell activation timing, module priority
ordering, or unrelated changes made by the original plugin patches. The
specific differences and validation limits below remain important.

SSS sources are pinned to
[`5e16c717f9524a9ab049e3557ccf04ab4cca9a86`](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/tree/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility).
The earlier reference-to-record research used MOMW Patches snapshot
[`a94a195914414cac541459ce06406bc957383597`](https://gitlab.com/modding-openmw/momw-patches/-/tree/a94a195914414cac541459ce06406bc957383597).
Original compatibility research belongs to the MOMW contributors, alvazir,
S3ctor and the respective mod authors.

## Shared selection and lifecycle rules

The compact target `{ref: ["Mod.esp", 123]}` identifies that plugin's local
reference number. A list of numbers selects those references as alternatives.
It does not broadcast to every copy of a shared base record. This is useful
for the repeated cave cliffs, Mournhold towers, terrain and encounter records
that could not safely be selected by base record alone.

`contentFile` tests per-reference provenance; `requires` tests installed
content. The Populated Vvardenfell, Fara's chest and Elayne files now use both
where the SSS source requires provenance. Imperial Skirt keeps its exact
reference, NPC type and record-ID restrictions. The Elayne query combines NPC
type, content provenance and `mwscript: ElayneUSebaonard`, preserving the
source's selection without a guessed NPC ID.

All supplied cell restrictions follow MOM's **origin-cell** semantics. SSS
checks the object's current cell when its activation rule runs. On an unmodified
installation they identify the intended placements; after another mod moves a
reference across cells, their eligibility can differ. Exact-reference lookup
does not guarantee immediate mutation of every unavailable object or preload
the world.

The native configurations use ordinary variant `actions`, because these are
permanent fixes rather than temporary world-state appearances. MOM records
completion; an authored `once` flag is unnecessary. Removing the file does not
undo completed static work. MOM can combine the intended position, rotation,
scale or disable in compact `modify` tuples. Cross-cell moves use `relocate`
with the transform inside its destination; scale remains a sibling patch.

All twelve SSS fixtures declare the `cleanup` priority tier. The native files
do not invent an equivalent tier: MOM uses its own claims, arbitration and
saved-operation ownership. Results against competing edits therefore need
review. These fixed absolute SSS edits already avoid random retries, so no
random-roll improvement is claimed. Neither runtime can promise that an
outside script will never move the same object afterward.

## Complete fixture inventory

Every native file is under `scripts/mom/config/` in this data directory. The
three historical `_intent.yaml` filenames are retained so existing file links
and VFS overrides remain usable; their selectors are no longer the earlier
provenance-relaxed approximations.

| SSS source | Native configuration | Preserved placement behavior and installation gates |
| --- | --- | --- |
| [Alvazir/PopulatedVvardenfell_BalmoraWaterworks.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/Alvazir/PopulatedVvardenfell_BalmoraWaterworks.yaml) | [Populated Vvardenfell](scripts/mom/config/sss_compat_populated_vvardenfell_intent.yaml) | Select NPC `1hlaalunpc35` from `PopulatedVvardenfell 1.5.esp` in `(-3,-2)`; set position `[-18275,-15960,275]`, preserving rotation and scale. Requires that plugin plus either documented original Waterworks filename. |
| [Alvazir/ValitysBitterCoast_TwinLamps.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/Alvazir/ValitysBitterCoast_TwinLamps.yaml) | [Vality / Twin Lamps](scripts/mom/config/sss_compat_vality_twin_lamps.yaml) | Disable `Valitys_Bitter_Coast_Addon.esp` reference `361` in `(-6,-7)`. Requires that target plugin; no unverified Twin Lamps plugin filename is guessed. |
| [MOMW/BCOM_ImmersiveImperialSkirt.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/BCOM_ImmersiveImperialSkirt.yaml) | [Imperial Skirt](scripts/mom/config/sss_compat_imperial_skirt_intent.yaml) | Move NPC `dmb_skirt_arnard`, exact `Clean_imperial_skirt.esp` reference `1`, in Madach Tradehouse; preserve the source position and pure yaw. Requires that plugin and `Beautiful cities of Morrowind.ESP`. |
| [MOMW/BCOM_QCVL_Elayne.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/BCOM_QCVL_Elayne.yaml) | [Elayne](scripts/mom/config/sss_compat_qcvl_elayne.yaml) | Select the NPC by QCVL provenance and `ElayneUSebaonard` in Black Shalk Cornerclub; move to `[322,-4,-63]` with zero rotation. Requires QCVL and the verified BCoM filename. |
| [MOMW/BitterCoastWaterway_CliffFix.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/BitterCoastWaterway_CliffFix.yaml) | [Waterway cliffs](scripts/mom/config/sss_compat_bitter_coast_waterway_cliffs.yaml) | Move references `114`, `165`, `187`; disable `204`, in the source exterior cells. All plugin-local identities and scales are retained; mixed-axis `114` is converted below. Requires `Bitter Coast Waterway.esp`. |
| [MOMW/CuttingRoomFloor_BCOM_FarasChest.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/CuttingRoomFloor_BCOM_FarasChest.yaml) | [Fara's chest](scripts/mom/config/sss_compat_faras_chest_intent.yaml) | Select the Container `de_p_chest_02_fara1` with Jobs provenance in Fara's Hole in the Wall; move to `[-120,-355,395]` and yaw `325`, zeroing the other axes. Requires Jobs and BCoM. |
| [MOMW/DungeonDetails_GrottoSeamFix.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/DungeonDetails_GrottoSeamFix.yaml) | [Grotto seams](scripts/mom/config/sss_compat_dungeon_details_grotto_seams.yaml) | Four exact Malmus references (`4`, `118`, `120`, `124`) and Nimawia reference `295` keep their separate transforms. Two independently gated variants work when either corresponding source plugin is installed. |
| [MOMW/ImmersiveMournhold_CornerTowers.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/ImmersiveMournhold_CornerTowers.yaml) | [Mournhold towers](scripts/mom/config/sss_compat_immersive_mournhold_towers.yaml) | Three compact reference-number lists disable exactly the source's twenty references in Godsreach, Great Bazaar and Temple Courtyard. Requires `Immersive Mournhold.esp`. |
| [MOMW/LittleLandscape_FoyadaSharpTeeth.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/LittleLandscape_FoyadaSharpTeeth.yaml) | [Foyada rocks](scripts/mom/config/sss_compat_little_landscape_foyada.yaml) | Preserve all five exact references, including the three vanilla references. Mod reference `29` relocates from `(-7,18)` into `(-6,18)` with its source position, scale and rotation. The Foyada plugin gates the whole fix so vanilla edits cannot run on its absence. |
| [MOMW/LittleLandscape_PathToPelagiad.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/LittleLandscape_PathToPelagiad.yaml) | [Pelagiad rock](scripts/mom/config/sss_compat_little_landscape_pelagiad.yaml) | Relocate exact reference `242` from `(-1,-9)` into `(0,-9)` with source position and scale; convert its mixed-axis orientation. Requires `Little Landscape - Path to Pelagiad.esp`. |
| [MOMW/OdaiRiverUpper_StatueRemover.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/OdaiRiverUpper_StatueRemover.yaml) | [Odai statues](scripts/mom/config/sss_compat_odai_river_statues.yaml) | Disable exact references `[244,245]` from `Odai River Upper Overhaul.esp` in `(-4,-4)`, leaving other copies of the shared statue record alone. Requires that plugin. |
| [MOMW/RepopulatedMorrowind_WolverineHall.yaml](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/Compatibility/MOMW/RepopulatedMorrowind_WolverineHall.yaml) | [Wolverine Hall](scripts/mom/config/sss_compat_repopulated_wolverine_hall.yaml) | Disable `RepopulatedMorrowind.ESM` reference `771` in the Imperial Shrine; apply distinct position/yaw changes to references `14` and `18` at Wolverine Hall. Requires that plugin. |

The original [Waterworks readme](https://www.nexusmods.com/morrowind/mods/51327?tab=docs)
documents `Balmora Waterworks.esp` / `balmora_waterworks.esp`; the BCoM fork is
not assumed equivalent. For other combinations whose second plugin filename
was not verified, only the source target plugin is gated. Install those files
only for the named compatibility combination; the target plugin's presence
alone does not establish a geometry conflict.

## Mixed-axis orientation conversion

SSS's
[`getRotationValue`](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Scripts/staticSwitcher/actionHandlers.lua)
uses `Rx(x) * Ry(y) * Rz(z)` for an absolute rotation. MOM's
[`rotationTransform`](<../00 OpenMW/scripts/mom/openmw/ref_ops.lua>)
uses `Rz(yaw) * Ry(pitch) * Rx(roll)`. The converted files preserve the
**literal SSS orientation**, rather than silently treating its X/Y/Z numbers
as equivalent MOM roll/pitch/yaw or as the intended orientation of the original
MOMW plugin patch. If the SSS fixture itself copied plugin Euler angles with a
different composition convention, preserving its literal result also preserves
that source discrepancy.

| Source reference | SSS X/Y/Z, degrees | Equivalent MOM yaw/pitch/roll, degrees |
| --- | --- | --- |
| Waterway `114` | `[348.540867,11.459157,18.152119]` | `[16.044459760,14.294888732,-7.597638103]` |
| Malmus `120` | `[270.000001,74.484502,180.000112]` | `[105.515498000,-0.000112964,89.999999733]` |
| Malmus `124` | `[90,88.366193,0.000126]` | `[88.366193000,-0.000126000,90]` |
| Pelagiad `242` | `[330.899989,353.999991,149.099999]` | `[154.606010231,19.154951831,23.086044369]` |

Pure-yaw rotations keep the source yaw. Every supplied absolute rotation writes
all three axes, including zeros: an omitted axis in a MOM `modify.rotation`
would preserve its starting value. Conversely, the Populated Vvardenfell rule
has no rotation action, so its native patch leaves rotation untouched.

The conversion used direct 3x3 matrix multiplication and ZYX decomposition,
including a gimbal-lock branch. Matrix round trips were asserted for **10,036**
deterministically sampled and boundary rotations. The rounded shipped values
reconstruct the four source matrices with maximum absolute element error below
`1e-8`. That verifies the orientation calculation, not collision placement or
visual seam quality in game.

## Original plugin patches and saves

All twelve conversions keep the same ordinary actions and compact tuples.
Their transforms, disables, relocations and provenance restrictions select
particular placements, so MOM handles them at runtime automatically. Authors
do not choose that layer. Promotion eligibility does not justify changing the
intended targets or broadening a fix to a shared definition.

These files implement the SSS fixtures, not every change in the original MOMW
plugin patches. The original Imperial Skirt patch also changes an NPC base
record. Fara's original plugin patch replaces `de_p_chest_02_fara1_sc` and a
Container base record; the native conversion keeps the existing reference,
inventory and MWScript. Elayne's original patch replaces a script; this native
file selects by that script and changes placement without rewriting dialogue
variables or script code. The original Grotto patch also edits a cave door that
is absent from the SSS example. None of those extra edits is silently added.

Begin from a save without the overlapping SSS or older native placement fixes.
Changing an earlier positional/broadcast selector to an exact reference changes
its semantic action identity. Keeping the historical filename does not adopt
SSS once markers or guarantee replacement of old completed MOM work. Conflicting
old work can be retained and block a changed edit. Removing these static files
is not an uninstall/undo operation.

## Verification boundary

All twelve YAML files parse, their source rules and predicates were checked
against the pinned fixtures, and the rotation calculations were checked as
above. All 27 source-rule actions also pass native authoring validation and
`modify` family lowering with a synthetic cell catalog. That checks the grammar
and payloads, not the absent mods. The target mod plugins are not installed in
the available workspace.
Compilation of inactive prerequisite-gated variants does not validate their
records, script behavior, target availability or geometry. Runtime checking
with the actual plugin versions and final load order remains necessary,
especially the two cross-cell moves and the existing scripted NPC/chest edits.
The recovered Wolverine Hall base IDs (`GVRM_ImpC_S+E_Rb_Imp`, `GVRM_ImpForts`,
`GVRM_Mage`) describe encounter placements. Their actual live types and exact
reference availability must be verified with Repopulated Morrowind; direct
selection must still respect MOM's supported live-reference types. No broad
actor query or guessed spawn-point replacement is substituted if those
references are unavailable.
