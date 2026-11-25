# SSS experiments: intent, conversions, and limits

These seven assessments use S3ctor's examples at source commit
[`5e16c717f9524a9ab049e3557ccf04ab4cca9a86`](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/tree/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples).
The one installable conversion is a full adaptation of a schedule's practical
intent. It deliberately changes lifecycle behavior, as explained below. None
of the six unsupported experiments is shipped as an executable subset that
silently omits its defining behavior.

Automatic promotion adds no complete experiment conversion. The weekend
schedule uses the same relocation action and guard; MOM handles it at runtime
without an author-selected layer. The missing event-time player state and
permanent-effect policies remain separate capabilities. A base-record edit
would affect every use of that record and cannot preserve these conditions.

| SSS source example | Native MOM outcome | Complexity and main difference |
| --- | --- | --- |
| `InstanceModifier_CaiusTakesWeekendsOff.yaml` | Practical schedule adaptation; optional data directory | Simpler: one guard and one relocation replace two opposed activation rules. Reversal supplies the return trip. |
| `InstanceModifier_BadWeatherHasConsequences.yaml` | Cannot fully adapt with current built-ins | Weather exists, but regional desired state cannot stand in for a one-time, player-weather-conditioned permanent scar; random transforms and scatter ranges are absent. |
| `InstanceModifier_DoorKnowsWhatYoureWearing.yaml` | Cannot fully adapt | Equipment, existing owner, and locked-state predicates plus lock/key/trap writes are absent. |
| `InstanceModifier_HouseMoves.yaml` | Cannot fully adapt | Accumulating a new random displacement on each activation batch is different from applying a stable offset from the starting transform. |
| `InstanceModifier_LowHealthMakesVvardenfellWorse.yaml` | Cannot fully adapt | No player-health predicate, persistent conditional latch, or random scatter ranges. |
| `InstanceModifier_NecromanticCompoundInterest.yaml` | Cannot fully adapt | No generated/dead/undead query or recursive death-dependent spawn program. |
| `InstanceModifier_YouProbablyWantLua.yaml` | Cannot fully adapt | Several unavailable predicate, mutation, randomization, sound, and feedback features are essential to all four rules. |

## Caius Takes Weekends Off

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_CaiusTakesWeekendsOff.yaml)
· [native YAML](<options/Caius Weekends/scripts/mom/config/sss_experiment_caius_weekends.yaml>)

**Intent:** Caius spends Loredas and Sundas at South Wall and returns home on
weekdays. SSS's two rules have no explicit trigger, so they run on activation.
The house must activate him before the outward rule can move him; at South
Wall the weekday rule needs another opportunity to process him. Waiting through
a weekday boundary while he stays active does not run either rule by itself.

MOM expresses the excursion with `[time, flags.isWeekend, true]` and one
`modify.relocate`. MOM's weekend flag means day 1 or 7, corresponding to Sundas
and Loredas in the supported calendar. A day change wakes the guard. Closing
it reverses the relocation, so a separate weekday return rule is unnecessary.
The exact home origin selection continues to identify Caius after he moves;
there is no need to match his temporary destination cell.

**Intentional differences:** reversal returns him to his OpenMW starting cell
and position, not the SSS fixture's hard-coded home point `[163, -228, 192]`.
This respects a content mod's starting placement, but it is not a promise to
restore the position where his AI happened to leave him immediately before the
excursion. The destination remains `[291, 537, 261]`. MOM has no `onGround`
setting; the destination is used as authored and must suit the installed
interior. No walking routine or AI schedule is created. This is guarded
teleportation.

**Where MOM works better:** the schedule is reconsidered when the weekday
changes, rather than requiring another activation. It also establishes the
current guard state on startup instead of relying on a fresh weekday-change
event. Managed origin identity permits recovery after cross-cell movement.
The benefit is a more reliable expression of the schedule, subject to target
discovery, recoverable object state, and the engine allowing the operation;
it is not a claim that MOM can inspect every unloaded actor immediately.

**Install:** add `04 SSS Conversions/options/Caius Weekends` as its own OpenMW
data directory, with MOM's `00 OpenMW` enabled. Use only one of the supplied
Caius relocation options in a save. Begin with a save that has not already run
a competing SSS or MOM schedule. Loading only the common `04 SSS Conversions`
directory does not recursively enable this option.

## Bad Weather Has Consequences

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_BadWeatherHasConsequences.yaml)

**Intent and literal behavior:** seven statue/shrine record IDs are twisted
by a random Z rotation from -12 to 12, and get a 40% chance of a pool creating
one or two bones at random X/Y offsets from -80 to 80. The condition checks the
**player's current weather**, requiring both storm status and the name
substring `ash`. It runs on activation and uses `once: true`. A successful
transform consumes the rule's one-time opportunity even when the bone pool
misses. Clearing the storm does not undo the damage.

MOM can target these IDs and change rotation, and its weather guards can
reconsider desired state as a region's weather changes. Those facilities do
not reproduce this fixture. Native YAML supplies explicit regional weather
script IDs rather than a player-relative storm/name predicate; it has no
random transform, random count, or offset-range syntax. A reversible weather
guard would also remove the weather-dependent effect when the storm ends,
where the SSS source intentionally leaves a scar. Enumerating regions and
fixed offsets would produce a redesigned temporary storm decoration, not a
full conversion. No such subset is installed here.

**Potential MOM improvement for a different intent:** a temporary, explicitly
regional storm decoration can use a weather guard and fixed `attach`/`modify`
actions. It would react to the condition and restore managed state. That is
more predictable for a temporary weather effect, but it does not implement
this example's permanent damage.

## The Door Knows What You're Wearing

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_DoorKnowsWhatYoureWearing.yaml)

**Intent:** a uniform grants access through locked Imperial Legion doors.
**Intended effect:** activation while wearing `imperial cuirass_armor` unlocks
the door and clears its key and trap. **Pinned executable behavior:** unlocking
runs, but `key: false` and `trap: false` are skipped by truthy dispatcher checks,
despite their handlers supporting clear operations. The unlock persists;
removing the armor does not close access, and equipping it beside an already
active door does not re-evaluate the default activation rule.

MOM can modify a selected door's transform, enabled state, or ownership. It
cannot natively select every door by its existing faction owner, check the
player's equipment or existing lock state, or write lock level, key, and trap.
Its `owner` patch is a write, not an ownership condition. Container replacement
preserving locks is also not an API for authoring these lock changes (and on
Luau OpenMW, `Lockable` key/trap setters currently reject supplied value
arguments). A true live disguise check and a faithful permanent unlock both
require additional code.
There is no full YAML adaptation and no supported mechanism here whose
extra complexity could be counted as an equivalent MOM config.

The new `record` path can edit a Door's model, name, MWScript and open/close
sound IDs. Lock level, key and trap belong to the reference state and are not
admitted Door definition fields. Setting a shared door sound or model is useful
unconditional authoring, but does not close this experiment's access-control
gap.

## The House Moves When You're Not Looking

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_HouseMoves.yaml)

**Intent:** tomb clutter drifts a little farther each time it wakes up. Five
specific bone/hook records in cells containing `tomb` get random X/Y offsets
from -4 to 4 and a random Z rotation from -3 to 3. SSS's `once: per_cell`
means an activation-batch marker, not a durable marker keyed to the cell. A
later batch can roll again and accumulate on the current transform.

MOM can express the substring boundary as `select.cell: {match: '*tomb*'}` and
target the same record IDs. A native `position: {by: [...]}` or
`rotation: {by: {...}}` uses the OpenMW **starting** transform. Reconciliation
or save recovery does not deliberately add the displacement again. There is
no activation-batch repetition option or random component range in native
YAML. A single fixed rearrangement would lose the experiment's central drift
behavior, so it is not shipped as a conversion.

**Where MOM is more deterministic:** for a compatibility fix whose intent is
"move this furnishing four units from its designed placement," MOM's
starting-transform calculation avoids cumulative drift through reactivation
or reassertion. This experiment deliberately wants the accumulation; that
advantage therefore cannot be described as support for its original effect.

## Low Health Makes Vvardenfell Worse

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_LowHealthMakesVvardenfellWorse.yaml)

Three independent activation rules layer persistent damage in tomb cells:
random clutter shifts at current health at most 50, a 25% pool of one or two
bones at health at most 25, and a 5% chance for two types of bone clutter to
become a bonewalker at health at most 10. These are **absolute health values**,
not percentages. Every rule is `once: true`; an unsuccessful probabilistic-only
action stays eligible for a later opportunity. Healing does not reverse
successful effects.

Native MOM lacks player-health guards and the condition-latched permanent
mutation lifecycle, and random transform/count/offset ranges. An `attach`
from a supported Static source can create an existing Creature record relative
to it and disable the original. Creature sources now support model-only
recreation, but arbitrary actor substitution and live-state transfer remain
unsupported. That supported replacement component does not supply the missing
health predicate or persistence policy. Merely substituting three ordinary
guard blocks would both invent a missing predicate family and change healing
from permanent scarring into reversal.

A deterministic MOM `chance` would be useful for a fixed population fraction:
the same semantic action and target keep the same selection decision. It
would **change** this source's retry-until-success behavior. Keeping the number
`0.05` alone does not preserve the probability over repeated visits. There is
no full conversion using the current built-in YAML model.

## Necromantic Compound Interest

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_NecromanticCompoundInterest.yaml)

**Intent:** generated undead that are dead at processing time can create a new
generation of skeletons nearby. The 35% creation pool samples one or two
children at random offsets. `once: true` limits each corpse after a success;
it does not limit the family tree. A missed pool can retry when the corpse is
processed again. The fixture does not use the newer `death` trigger: an actor
dying while it remains active is not itself the selected trigger.

MOM's built-in guards have no generated-object, dead-state, or undead-category
predicate. Native `place` uses explicit destinations and does not define a
recursive spawn-on-corpse population program. Parent/child `actions` are a
finite authored dependency tree for known parent outputs, not a recursive rule
that every later deceased descendant inherits. `kill` only kills; it is
irreversible and supplies no replacement/resurrection behavior. Replacing the
35% roll with deterministic `chance` would also remove future retries. This
cannot be fully adapted without implementing additional logic.

## You Probably Want Lua

[SSS source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/InstanceModifier_YouProbablyWantLua.yaml)

The fixture intentionally combines four separate programs. Each has essential
gaps in current native MOM:

1. Original bone statics require player-relative ash-storm weather, three
   resources, attributes, skills, faction rank, and equipped armor. They can
   turn into bonewalkers, receive random transforms, scatter three different
   object pools, and play a probabilistic sound. MOM lacks the player/state
   predicate intersection, random ranges, and sound action. A supported Static
   anchor can attach an existing Creature record, but this supplies only the
   replacement component.
2. Generated dead undead can replace themselves, relocate, spawn greater
   bonewalkers and skulls, play sound, and remove the original corpse after
   successful fresh replacement. MOM has relocation but no generated/dead/undead
   predicate, fresh-base self replacement, random transform/destination/count
   ranges, sound, or delete action. `enabled: false` would leave an object in the world and is not a
   faithful substitute for deletion.
3. Tomb doors/containers with particular lock/key/trap state and carried gold
   are selected using player level/health/security/equipment. The rule changes
   locks, chooses keys and traps, writes ownership, scatters bones, and plays
   sound. MOM supports an ownership write to explicitly selected objects;
   the other predicates and lock/key/trap operations are unavailable. A
   coin-count selector cannot be expressed by an `inventory` action.
4. Injured Imperial Legion warrior NPCs are filtered by their faction/class,
   strength/longblade, player fatigue, and equipment. The inventory mutations
   use separate chances to unequip/remove/add/equip a sword and shield. MOM
   supports inventory verbs for named actors and valid item IDs, but not
   this predicate set or the source's independent nested action chances.
   Native action-level `chance` gates its whole semantic action and cannot
   be assumed to reproduce this ordered mutation program.

No executable fragment is installed: reducing this to ownership or inventory
changes would broaden its targets while discarding the conditions that define
when the source is supposed to run. Writing the missing behavior as a Lua
feature could be practical, but is new implementation work, not a native YAML
conversion already supported by MOM.

## Determinism claims and their boundaries

The comparisons above follow the current implementation:

- [MOM time guards](<../00 OpenMW/scripts/mom/guards/time.lua>) subscribe to
  day/hour changes. [Weather guards](<../00 OpenMW/scripts/mom/guards/weather.lua>)
  read a named region's weather script ID. Unavailable capabilities yield
  `unknown`, allowing existing managed state to be held rather than treating
  missing truth as false.
- [MOM target selection](<../00 OpenMW/scripts/mom/runtime/selection_matcher.lua>)
  checks origin cells. This makes a fixed original selector usable after
  relocation; copying SSS's current-cell return predicate mechanically is
  unnecessary and can change who is selected.
- [MOM modify runtime](<../00 OpenMW/scripts/mom/actions/modify_ref/runtime.lua>)
  computes managed relative position/rotation and their reversal from the
  starting transform. Reversal is not a universal snapshot rollback. The
  door-origin caveat in the [public guide](<../docs/MOD_AUTHOR_GUIDE.md#4-working-with-existing-saves>)
  still applies if another mod moved a door before MOM could observe it.
- [MOM semantic action identity](<../00 OpenMW/scripts/mom/contracts/plan_identity.lua>)
  includes the program, selection, guard, chance, and lifecycle rather than
  source filename or array position. Rearranging equivalent source does not
  intentionally reroll an unchanged rule. Changing its meaning can change
  its identity; deterministic selection is not a promise that every edit
  preserves the old choice.
- SSS's current source also has world and interaction triggers. See its
  [trigger documentation](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/docs/concepts/triggers.md).
  The seven fixtures discussed here omit `trigger`, so default activation
  semantics apply to them. A broad claim that SSS can never react to time,
  weather, or journal changes would be incorrect for this source snapshot.

These are semantic comparisons, not comparative performance measurements or
claims that either runtime prevents interference by every other mod.
