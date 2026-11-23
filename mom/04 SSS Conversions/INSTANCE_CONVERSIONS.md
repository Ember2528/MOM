# SSS instance examples in native MOM

This review covers all 18 non-experiment instance examples in SSS snapshot
[`5e16c717f9524a9ab049e3557ccf04ab4cca9a86`](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/tree/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples).
The seven named experiments are covered separately. The assessment is of the
bundled MOM version-0 configuration language, rather than what could be added
by writing new Lua action or guard plugins.

There is one direct practical placement conversion, one exact-reference outfit
conversion, and three optional world-state adaptations. Unsupported examples
have no executable placeholder: a partial file would give a misleading account
of the source's behavior.

Automatic promotion adds no complete instance conversion here. Authors keep
the same actions and tuples; MOM handles these placements, movements, reference
scale changes, live equipment and guarded effects at runtime automatically.
Native `record` and `leveled` edits are useful for unconditional definition
changes; their population-wide scope cannot inherit an instance rule's cell,
player-state or event-time restrictions. See the
[definition contract](../docs/AUTHORED_CONFIG_REFERENCE.md#definition-changes-and-reference-actions).

## Important source-version distinction

The fetched SSS source has explicit triggers. Some published recipe prose still
describes activation-only evaluation. `CaiusClocksOut` explicitly uses `hour`
and `active`, and `SixthHouseFalls` explicitly uses `journal` and `active`.
SSS can therefore react while the player remains in the same cell. Its
[trigger specification](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/docs/concepts/triggers.md)
describes nearby-object sweeps, disabled-object exclusions, load baselining,
coalescing, and a runaway-sweep limit. These qualifications matter when comparing
it with MOM. Live response by itself is not a unique MOM advantage.

MOM guards instead describe a state that owns effects while its conditions are
true. A false condition withdraws reversible work; unavailable condition data
holds current work. This is different from SSS's event-time mutation plus
`once` bookkeeping. An SSS rule that leaves permanent consequences after its
condition stops matching cannot be translated simply by putting its action
under a MOM guard.

## Executable conversions and deliberate adaptations

### A Dremora Walks Into a Cornerclub

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_ADremoraWalksIntoACornerclub.yaml)
→ [MOM configuration](<options/Dremora Cornerclub/scripts/mom/config/sss_instance_dremora_cornerclub.yaml>).

The intent is one dremora at a known location, once per save. One native `place`
tuple expresses the whole operation, including the source's absolute position
and 90-degree yaw. MOM records the placement instead of requiring a player
entry event and a player-associated once flag. Both frameworks can preserve
this result without repeated spawning.

The timing is not event-identical: SSS waits for player entry; MOM plans and
executes its placement when it processes the destination cell. It is a static
addition to that cell. This preserves the practical one-newcomer result but
does not provide a reusable `cell_enter` trigger. Absolute placement can create
an actor. Relative `attach` now supports one-for-one Creature mesh recreation,
which is a separate operation from this new placement. The newcomer is an
ordinary hostile dremora; the example does not make it friendly. Its exact
position is shared with the Clock Out and Weekends Caius options, so those
examples are intended to be tried independently.

### Diminutive Armored Caius

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_DiminutiveCaius.yaml)
→ [MOM configuration](<options/Diminutive Caius/scripts/mom/config/sss_instance_diminutive_caius.yaml>).

The full equipment and scale intent is expressible: ensure and equip all ten
source items, then set scale to 0.1. Both tuples select
`{ref: [Morrowind.esm, 67647]}`. A plugin moving Caius's starting placement no
longer defeats a coordinate key, and another copy of his base record is not
selected. The reference identity is independent of plugin load order.

Each item uses `[ensure, 1, equip]`: an existing copy counts, while a missing
copy is created with default item data. Already-owned armor is not duplicated.
Existing damaged or enchanted-state variants count as possession and are not
repaired. Equipment uses MOM's normal automatic equipment behavior rather than
emulating arbitrary item-use event side effects. This preserves the outfit
intent and the source's create-if-missing behavior.

MOM's compact tuples now preserve the source reference predicate directly;
no original-position recovery or uniqueness assumption is needed. Completed
static work remains in the save. Editing an older already-applied version of
this example is not an automatic inventory migration.

### Caius Daily Schedule

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_CaiusSchedule.yaml)
→ [optional MOM configuration](<options/Caius Schedule/scripts/mom/config/sss_instance_caius_schedule.yaml>).

The intended itinerary is the roof, then the cornerclub, then home. MOM gives
each destination a disjoint state window: `[08:00,13:00)`, `[13:00,20:00)`, and
`[20:00,08:00)`. All three select the original home identity; no leg requires
the previous leg to have moved him into the right current cell. Once discovered,
MOM can keep owning the reference after it moves. Evaluation, mutation and
recovery still depend on MOM's normal object availability; this is not an AI
travel package or a guarantee of immediate mutation in every unloaded cell.

This is more deterministic than the source's activation-only, current-location
transition chain: skipped intermediate visits do not strand the itinerary,
relative changes do not accumulate, and exact 13:00 and 20:00 boundaries have
one destination. SSS's fractional-hour inclusive maxima overlap at these
boundaries; MOM's built-in hour is an integer and the half-open windows
deliberately assign the whole following hour to the next destination.

The source's final `teleport.rotation` is applied as a relative rotation in
degrees by its handler, although the numbers resemble radians. Repeating it
can tilt the actor. The adaptation sets a fixed upright yaw of approximately
103.132414 degrees, his vanilla facing, for the home destination. Its result
reflects the itinerary's intent, rather than copying this accumulation.

The native file has three guard blocks and is not dramatically shorter. Its
advantage is explicit, reversible ownership of each schedule state. It replaces
the source's activation/per-cell semantics, rather than reproducing them.
Enable exactly one of the three Caius schedule option directories, including
the separate weekends experiment.

### Caius Clocks Out

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_CaiusClocksOut.yaml)
→ [optional MOM configuration](<options/Caius Clock Out/scripts/mom/config/sss_instance_caius_clocks_out.yaml>).

The source already reacts to `hour` and `active`; MOM's advantage is origin-based
state ownership and reversal, not the existence of an hourly update. Two
nonoverlapping guards select a destination directly. The source's return
condition `max: 20` includes exactly 20:00; the adaptation assigns 20:00 to the
outbound state and all hours before it to home.

Both source teleports specify `onGround: true`. Public MOM `relocate` has no
ground-projection parameter. The file retains the source's literal coordinates
without projecting them: cornerclub `[291,537,261]`, home `[163,-228,192]`.
Their placement needs an in-game check against the installed interior geometry.
This option is an itinerary adaptation with an explicit floor-placement gap,
not an exact teleport conversion. A fixed author-measured floor position can
replace each Z coordinate, but cannot follow arbitrary geometry changes in the
way projection can.

### The Sixth House Falls

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_SixthHouseFalls.yaml)
→ [optional MOM configuration](<options/Sixth House Aftermath/scripts/mom/config/sss_instance_sixth_house_falls.yaml>).

The intent is visible aftermath when Dagoth Ur falls. A quest guard and one
three-row attachment turn an ash statue into three bone pieces and disable the
original. The tuple offsets are fixed and within the source's scatter range.
This binds outputs to the particular statue and makes their ownership explicit.
There is no separate broad search to find which newly created bones to manage.

Two behavior changes are intentional and prevent calling this an exact port:

- SSS draws a count from 1–3 and fresh X/Y offsets from -40 through 40. The
  public MOM syntax has fixed transforms and counts, not sampled ranges. The
  adaptation always uses three fixed offsets and fixed yaw values.
- SSS's `once: true` leaves a permanent scar after the stage first qualifies.
  MOM maintains an appearance while `c3_destroydagoth >= 50`. If the stage is
  deliberately lowered, MOM withdraws its bones and restores the statue when
  it can recover the owned objects. This suits a quest-state appearance, but
  there is no built-in latch that exactly reproduces the permanent event.

On ordinary forward main-quest progress, the visible outcome remains the
aftermath. SSS's explicit `journal` trigger already makes it happen nearby when
the quest advances. MOM additionally expresses reversible state, holds work
when a quest read is unavailable, and uses managed parent/output relationships.
It does not promise to preserve an unrelated mod's later edit to the same
managed property when reversing.

## Examples without a complete native conversion

These rows account for every remaining non-experiment instance example. The
links identify the exact source; no unsupported source is represented by an
empty or silently reduced executable file.

| SSS example | Intent and exact missing pieces | What MOM can usefully do |
| --- | --- | --- |
| [CreatureScale](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_CreatureScale.yaml) | Give every Creature a persistent independent scale multiplier sampled from 0.5–2.0. Creature-only selection is available; the sampled scale range remains unsupported. | Fixed scale and scale multipliers on named records are simple, persistent tuples. `chance` is deterministic per target, but does not choose a numeric scale and is not a replacement for this distribution. |
| [WildlifeVariety](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_WildlifeVariety.yaml) | All four rules require random scales or per-candidate bottle replacement rolls. Type and simple record-pattern selection are available. Sampled scales, activation-time rerolls, and runtime instance replacement of item-bearing bottle/goblet sources remain absent. | Region/interior cell selectors and fixed scale edits are supported. Native scale `by` uses its captured baseline scale; SSS's repeated relative random transform compounds against current scale. LOAD can change a Miscellaneous record's model globally, preserving its reference identity, but that cannot implement Caius-house-only record roulette or per-visit rerolls. Native and imported replacement choices now share one MOM capability. Their weighted draw differs from the source's first-success rolls, and scoped item-bearing source replacement remains unsupported. |
| [GlassEbonyRemoval](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_GlassEbonyRemoval.yaml) | Delete all world Weapon/Armor records matching `glass` or `ebony`, and purge a fixed item list from every Container. MOM can now select these types/record substrings and all Container owners. It still has no delete verb or repeated event-time purge policy. | Named world refs can be disabled and owners can use `[remove]` for an entire item type, once per completed inventory transaction. Native `leveled` removal can suppress entries in explicitly named item lists where the engine exposes them. That is an unconditional distribution redesign affecting all list users, including possible vendors; it does not delete placements or purge existing inventories. Container default-inventory definition edits remain unavailable. |
| [DeadWalkAgain](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_DeadWalkAgain.yaml) | Recreate dead, respawning-marked creatures in FlexTag dungeon cells. Requires dead/respawning predicates, cell tags and fresh actor replacement. | `kill` is irreversible; it cannot resurrect or reset actor state. Absolute actor `place` would create another actor at authored coordinates, rather than create a fresh replacement at this corpse's location. |
| [DynamicDungeonTraps](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_DynamicDungeonTraps.yaml) | Adapt locks, trap choices, keys and loot to player level and existing lock/trap/key state in tagged dungeons. The player-level/property/tag predicates, sampled counts, lock/trap/key mutation and ordered first-passing trap candidates are missing. | Fixed inventory loot with deterministic `chance` on explicitly named owners is supported. Native item-list edits, when available, can rebalance shared loot globally; they cannot condition those definition edits on a particular container's lock or an event-time player-level snapshot. Container default inventories are not exposed. Neither route provides the source's progression, so no loot-only subset is shipped as a conversion. |
| [HarderLocks](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_HarderLocks.yaml) | Select Doors/Containers by current lock band and assign random harder lock levels. Both lock predicates and lock-level writes are absent. | Container attachment can preserve existing lock state during safe replacement; it cannot author a different level. The source's module-level `once` is also broader than a single rule latch. |
| [MudcrabReinforcements](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_MudcrabReinforcements.yaml) | On qualifying live mudcrabs, probabilistically create 5 or 10 nearby mudcrabs with random offsets, gated by player level and repeatable activation batches. Missing level/dead predicates, nondestructive actor anchors, sampled positions and this activation-batch repeat policy. | Absolute actor `place` is supported at fixed destinations. `attach` cannot use a mudcrab as a nondestructive spawning anchor; deterministic chance alone cannot reconstruct the rule. The scalar level `20` means at least 20, not exactly 20. |
| [MudcrabsLikeShinyThings](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_MudcrabsLikeShinyThings.yaml) | Repeated player gold drop/place events outdoors each roll for a nearby mudcrab. Missing interaction events, `by_player`, sampled offsets and nondestructive creation from a gold reference. | A fixed world placement does not express a reaction to dropping gold. This needs Lua event handling in MOM's current feature set. |
| [RatsInTheLockbox](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_RatsInTheLockbox.yaml) | Before a player activates a locked interior Container, roll to create 1–2 nearby rats once. Missing activate/by-player/locked predicates and random relative actor creation. | Container `attach` must disable the source and transfer it into one Container output; it cannot use a chest as a nondestructive rat-spawning anchor. A fixed rat placement would change the timing and trigger. |
| [SoundTheAlarm](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_SoundTheAlarm.yaml) | A custom mod event scales its supplied living NPC by 1.15 once. Missing generic custom-event dispatch and a live-actor predicate in native YAML. | The fixed scale multiplier itself is supported and uses the captured baseline scale. A custom guard/action integration can expose game-specific behavior, but that is Lua development, not a configuration conversion. |
| [StormAtronachsLastWord](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_StormAtronachsLastWord.yaml) | Storm-atronach death sets local-player-region thunderstorm; player skooma use outdoors has a 25% fog chance. Missing death/use events, `used_item`/by-player predicates and weather-changing action. | A MOM weather guard reads a named region's state; it cannot set weather or substitute for a death or consumption event. |
| [TombSpiceUp](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_TombSpiceUp.yaml) | Random transforms, one-time candle disable and loot, probabilistic actor upgrades, quest-dependent LevelledCreature spawner replacement, and diseased rats. Missing sampled transforms, actor/spawner replacement and repeat policies prevent a complete conversion. | Tomb-name cell queries, fixed edits, per-target chance, named-owner loot and both quest guards are expressible. Native `leveled` can now change creature-list entries and flags, beyond VFR additive imports. A global baseline rebalance of `in_tomb_all_lev+0` is practical, but definition edits cannot be tomb-scoped or quest-guarded and do not replace selected spawner references. Source comments cite older quest/stage phases; executable rules use `a1_v_vivecinformants` stage 50 and `c3_destroydagoth` stage 50. |
| [WhileYouWereStandingThere](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_WhileYouWereStandingThere.yaml) | Weather-event statues receive random permanent rotation; midnight resurrects dead respawning interior creatures. Random transforms, the player's-current-weather predicate, dead/respawning predicates and resurrection are absent. | Named-region weather guards and fixed statue rotations support reversible weather appearances, but do not reproduce permanent once-only scarring or actor revival. The source already supplies weather/day triggers; it does not wait for a future cell reload. |

## Why unsupported pieces were not mechanically approximated

Splitting an SSS random choice into several MOM actions with different `chance`
values is not equivalent. Those actions make separate decisions, can overlap,
and may compete for the same property. It does not produce one weighted draw.
Likewise, replacing every generic type/pattern selector with a hardcoded vanilla
record list silently narrows the mod's supported world. No such substitutes are
advertised as complete conversions here.

Native choice ordering and KEEP continuation can now express stable ordered
replacement trials on supported static routes. Overlapping scale rules and
independent inventory-entry rolls still need explicit composition inside the
relevant operation; separate actions compete for the same property claims.

SSS once rules already give persistent successes; MOM is not uniquely persistent.
MOM's deterministic target chance, semantic action identity, starting-transform
relative edits, conflict handling and recovery can make supported intent more
predictable. These do not make random-scale selection, event-time snapshots,
latched consequences or unsupported engine mutations appear in native YAML.

For the MOM contracts behind these assessments, see the
[public reference](../docs/AUTHORED_CONFIG_REFERENCE.md),
[author guide](../docs/MOD_AUTHOR_GUIDE.md), and
[compatibility limits](../docs/COMPATIBILITY.md). In particular, native `chance`
is per-target admission; `attach` requires supported source types; guard closure
reverses only supported actions; and inventory reversal can be affected by play.
