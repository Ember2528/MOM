# SSS examples adapted for MOM

This collection assesses **all 39 YAML fixtures** in S3ctor's SSS `Examples/`
directory, including its compatibility patches. It supplies practical native
adaptations where MOM can carry the intent, and identifies the specific missing
behavior everywhere else. It also converts the documentation's fixed-scale rat
test. Configurations use compact tuple forms wherever the public MOM grammar
permits them. Eighteen upstream fixtures have executable adaptations, plus the
introductory test; most deliberately change some semantics and are labeled
accordingly. The other twenty-one fixtures do not have a complete executable native
conversion in this package.

SSS source snapshot:
[`5e16c717f9524a9ab049e3557ccf04ab4cca9a86`](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/tree/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system),
examined 2026-11-14. [Source inventory](SOURCES.json) records the individual
fixture hashes. The supplied
[documentation site](https://dreamweave-mp.github.io/S3ctors-S3cret-St4sh/static_switching_system/docs/)
is the starting reference; pinned source, implementation and fixture intent
resolve discrepancies with its overview text. These are independent native
MOM configs, not additions to MOM's SSS compatibility importer.

## What to read

| Comparison | Coverage |
| --- | --- |
| [Instance conversions](INSTANCE_CONVERSIONS.md) | All 18 ordinary instance fixtures: placement, daily schedules, equipment, randomization, inventory, traps and event examples |
| [Experiments](EXPERIMENT_CONVERSIONS.md) | All 7 experimental fixtures: weekend schedule, permanent scarring, disguise, drift, undead feedback and combined rules |
| [Compatibility conversions](COMPATIBILITY_CONVERSIONS.md) | All 12 compatibility fixtures, using exact references or provenance/record queries, with source/runtime differences documented |
| [Static conversions](STATIC_CONVERSIONS.md) | Both static fixtures, their reused documentation recipes, the introductory rat test and the external mod catalog boundary |

An **intent adaptation** implements a useful interpretation of the example;
it does not promise identical event timing, sampling, persistence or targeting.
Changes to those properties are called out beside the source. An unsupported
example has no installed fragment that quietly drops the condition defining
its behavior. In particular, the Sixth House alternative is explicitly a
fixed-layout, reversible redesign of a permanent randomized effect.

Authors use the same MOM actions, tuples and config directory throughout.
Describe the intended targets, scope, conditions and effects; MOM automatically
promotes eligible actions to LOAD and handles other supported actions in
GLOBAL. There is no execution-layer setting or separate promoted-action
syntax. Layer details below explain observable behavior and current limits.

## Choose examples to install

Enable MOM's `00 OpenMW` data directory and `mom.omwscripts`. Add only the
conversion data directories you intend to try. None requires SSS's runtime,
H3lp Yours3lf, or FlexTag; content mods supplying selected records remain
necessary. Start from a save without another runtime's changes to the same
objects: MOM does not adopt SSS's saved replacement chains or once markers.

| Data directory, relative to this folder | Effect |
| --- | --- |
| `.` | Twelve plugin-gated compatibility conversions. Read their source and existing-script caveats before enabling. |
| `options/Dremora Cornerclub` | Places one dremora at the source's exact cornerclub destination. |
| `options/Diminutive Caius` | Selects the exact Caius reference, makes him tiny, and ensures/equips the Imperial outfit without duplicate additions. |
| `options/Caius Schedule` | Reconciles roof, cornerclub and home destinations by time of day. |
| `options/Caius Clock Out` | Reconciles the source's evening cornerclub and daytime home destinations. |
| `options/Caius Weekends` | Manages a weekend excursion; weekdays reverse it to the starting location. |
| `options/Sixth House Aftermath` | Replaces ash statues with three fixed bones while the quest stage is at least 50. |
| `options/Rat First Test` | Multiplies each selected rat's scale by 1.25 once. |
| `options/Concept Art Scamps` | Native MOM configuration only; requires separately installed original meshes and animations. No mod assets or SSS configuration are included. |
| `options/Uniform Static Models` | Vanilla-resource adaptation of the basic global replacement recipe: all Static records using tapestry mesh 04 use mesh 03, preserving their reference identities. |

OpenMW does not recursively enable nested data directories. Adding this folder
alone enables its own `scripts/mom/config/` files; it does not enable any option.
BAIN users can select/copy the desired option's `scripts` tree into a separate
data directory. Each YAML has a distinct VFS filename.

Use **one Caius relocation option** in a save. The dremora and the Clock Out /
Weekends examples also share the source destination `[291, 537, 261]`; they
are separate demonstrations and should be tried separately. If you want one
compatibility example, copy only that YAML into a separate enabled data
directory instead of enabling all twelve. The static authoring templates are
outside discovery and end in `.yaml.example`; they supply no real assets.

Fully restart OpenMW after changing YAML. Use `I.MOM.compileReport()` in global
Lua console mode (`luag`) to inspect diagnostics. Removing an unguarded runtime
file does not undo its completed world edits. Definition edits are rebuilt for
each process: removing the Uniform Static Models option and restarting stops
its base-model patch. This does not remove old reference replacement chains.
The
[MOM author guide](../docs/MOD_AUTHOR_GUIDE.md#4-working-with-existing-saves)
explains the relevant save and reversal rules.

## The world-state distinction

SSS evaluates a conditional **mutation** when its trigger runs. Once an effect
succeeds, ordinary world/save state keeps it; a condition becoming false does
not inherently undo it. A rule's `once` setting controls later applications.
A successful one-time rule can also commit only some requested effects;
its failure and retry boundaries matter to any conversion.

MOM guards describe **desired managed state**. They establish the current
condition at startup and reconcile supported actions as it opens or closes.
A `modify` or placement can reverse. An unreadable condition holds existing
state instead of being assumed false. `kill` remains permanent, and inventory
reversal is best effort after items have been used, taken or altered.

Consequently, translating `has_journal` to `quest_stage`, or a weather test
to `weather`, does not by itself preserve intent. A permanent quest aftermath
and an appearance that should exist only while a quest condition holds are
different programs. So are permanent storm damage and a temporary storm prop.
Current built-in MOM YAML does not supply a general "when this condition first
becomes true, permanently apply these arbitrary reversible actions" latch.

Current SSS **does** have `journal`, `hour`, `day`, `weather`, `cell_enter`,
interaction, death and custom triggers. For example, Sixth House Falls and
Caius Clocks Out already respond to journal/hour changes as well as activation.
SSS world sweeps are local to the player and do not include disabled objects.
Some overview/experiment prose still describes the earlier activation-only
model; examples without an explicit `trigger` still use activation. The MOM
comparison is about lifecycle and ownership as well as observation, not a
blanket claim that SSS cannot watch world changes.

## Where MOM is simpler or more predictable

| Intent | MOM difference | Qualification |
| --- | --- | --- |
| Uniform global visual replacement | MOM automatically promotes an eligible ordinary model-only `attach`, retaining reference identity and live state without replacement clones. | Authored type, scope and conditions determine eligibility. Creature/NPC/Container definition domains remain unavailable; later LOAD mods may override the result. |
| Weekend excursion | One guard and relocation also define the return through reversal. | Returns to the starting location, not SSS's fixed home point; no floor projection. |
| Multi-stop daily schedule | Disjoint time windows select the desired destination from the actor's origin. | More explicit guard structure than a single mutation; no walking/AI routine. |
| A fixed placement correction | Compact `modify` tuple expresses position, angles and scale together; exact plugin/refnum selection needs no coordinate reconstruction or `once` flag. | Origin-cell selection and outside scripts still need consideration. |
| Relative placement correction | Position/rotation derive from the starting transform, avoiding activation-driven cumulative drift. | This cannot implement House Moves, which intentionally wants drift. |
| Fixed chance population | Chance is derived from semantic action/target identity instead of a fresh trial on every opportunity. | A permanently failed deterministic selection cannot reproduce repeated rolls until success. |
| Effects on a newly produced object | Child actions target the parent's outputs explicitly. | Finite dependency trees are not arbitrary event feedback or recursive descendants. |
| Renaming/reordering equivalent YAML | Semantic action identity retains completed work across filename/order changes. | Changing action meaning, selection, guard or chance can change identity; removing work is not universal undo. |

SSS already defines deterministic priority tiers and canonical path ordering.
Its replacement candidate maps and ordinary chance/range sampling have other
semantics; it is inaccurate to call all SSS dispatch random or unreliable.
For example, Wildlife Variety calls bottle chances "weighted" in a comment,
but SSS tests candidates until one succeeds. The values are not normalized
weights, and the map's iteration order is not an authoring-order guarantee.
Trap/key arrays instead have explicit order and take the first passing entry.
A deterministic weighted-choice design would be a different probability model.
MOM's conflict handling and saved operation ownership help avoid conflicting
managed claims, but do not guarantee the author's intended winner or prevent
outside mods from modifying the same objects. These comparisons contain no
performance benchmark.

## Where a native conversion becomes harder or impossible

Mixed-axis rotation also requires interpretation. SSS and MOM compose their
angle rotations in different orders. A pure yaw transfers directly, but copying
SSS X/Y/Z into MOM roll/pitch/yaw can change a tilted object's orientation. The
compatibility comparison records equivalent native orientations for the
mixed-axis source transforms.

MOM's public selectors now include exact plugin-local references, reference
provenance, type queries, simple record patterns and base-record MWScript IDs,
alongside exact record IDs, origin cells and optional starting positions.
General Lua patterns, player stats/equipment, dead/generated-state predicates,
ownership queries and FlexTag predicates remain unavailable. A plugin in
`requires` only checks installation; use `contentFile` or `ref` when reference
provenance is part of the intended selection. Startup record-pattern/MWScript
queries do not automatically include records generated later.

MOM supports inventory operations, relocation, ownership writes and actor
killing. That does not imply native lock/key/trap writes, item-use or death
triggers, arbitrary Lua/events/interfaces, sound, actor resurrection or sampled
count/position/rotation/scale ranges. Action-level `chance` is a single stable
gate. Ordinary replacement choices now support one exclusive weighted draw,
including generic spatial profiles and KEEP continuation for ordered static
trials. Event-time rerolls, nested per-effect rolls and unsupported source types
remain separate gaps. Current choices require unguarded static actions.

Relative `attach` now supports **Creature source mesh replacement**: one mesh
output per source, with `disableOriginal: true`. It recreates a base-record
actor rather than transferring live actor state, and skips dead/summoned
sources. It does not support Creature-to-record substitution, nondestructive
spawning from an actor anchor, NPC sources, doors or lights. A supported Static
anchor can produce an existing Creature target; absolute `place` is another
supported route. The advanced static fixture now has a native authoring
template, but its illustrative replacement assets remain absent. Scriptless
Activators and supported Containers have their own safeguards; preserving a
container's lock during transfer is not a general lock-editing action.

Uniform swaps use ordinary `attach` actions. MOM automatically promotes them
when their authored intent is eligible; the author does not choose a definition
path or a reference-recreation mode. Native `record` and `leveled` also support
explicit definition changes and list edits. Those capabilities do not
make a quest-guarded spawner, conditional lock or player event into a base-record
operation.

The per-example documents distinguish missing native features from missing
source assets or recoverable original coordinates. Adding a Lua extension could
close some gaps, but that would be new MOM implementation work rather than a
conversion already expressible in the current public configuration format.
