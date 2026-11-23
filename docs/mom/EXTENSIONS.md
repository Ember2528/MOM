# Implementing MOM extensions

MOM discovers action families, guard families, and compatibility translators
through OpenMW's virtual filesystem. These interfaces are for Lua extension
authors. Ordinary patches should use the
[configuration reference](../../mom/docs/AUTHORED_CONFIG_REFERENCE.md).

Use a built-in family as a working implementation and the linked validators
for exact accepted fields. All compiled programs and saved values must be
acyclic plain data: no functions, engine objects, metatables, or live interfaces.
Module tables can contain hooks but should not retain mutable per-runtime state.

## Discovery and versions

| Kind | Discoverable path | Declared ID |
| --- | --- | --- |
| Action | `scripts/mom/actions/example.lua` | `example` |
| Guard | `scripts/mom/guards/example/ready.lua` | `example.ready` |
| Compatibility | `scripts/mom/compat/example/translator.lua` | `example` |

Action discovery uses direct child files; subdirectories can hold implementation
helpers. Guard discovery is recursive, with path segments becoming dotted IDs;
`init.lua` is excluded. Put third-party guards in a namespace directory to avoid
collisions. Compatibility discovery recognizes only `translator.lua` directly
under its ID directory.

IDs use lowercase segments matching `[a-z][a-z0-9_]*`, separated by dots where
the discovery path permits them. The module's `id` must match its path. Every
module declares an ABI version and a non-negative integer `behaviorVersion`.
Action and guard families currently use `abiVersion = 0`; compatibility
translators use `abiVersion = 1`. Actions and guards also require
`programVersion`; actions with capture/reversal
or family storage declare the corresponding `revertTokenVersion` and
`storageVersion`.

| Version | Change it when |
| --- | --- |
| `abiVersion` | Hook signatures or shared result contracts change |
| `behaviorVersion` | The same program would produce a different meaning or effect |
| `programVersion` | Compiled program representation or meaning changes |
| `revertTokenVersion` | A retained capture/reversal token changes |
| `storageVersion` | Family-owned durable storage changes |

The registries validate identities, versions, and required methods. Invalid or
duplicate entries are quarantined and logged; all claimants to a duplicate ID
are excluded. Using an unavailable family fails compilation or saved-state
activation. Runtime binding requires exact supported versions for installed
and saved work. See
[`module_loader.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/module_loader.lua>),
[`extension_registry.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/extension_registry.lua>),
and [`coordinator.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/coordinator.lua>).

## Action families

Native YAML verbs map to families in
[`authored_contract.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/authored_contract.lua>).
Installing a Lua family does not itself add another YAML verb. The shipped
mappings are `place`/`attach` to `place_ref`, `modify` to `modify_ref`, `inventory`
to `modify_inventory`, and `kill` to `kill_actor`.

Native and imported declarations pass through one engine-free semantic frontend
before execution placement. It normalizes selectors, predicates, conditions,
choices, type intersections and dependencies. Promotion then analyzes complete
replacement groups so one promoted model write cannot silently change a
competing runtime selector or KEEP route.

Both invocations discover and translate the same source formats. Action/guard
runtime hooks remain GLOBAL-only, after semantic placement; LOAD does not bind
those registries. `record`, `leveled` and eligible uniform model changes use the
typed content backend. Actual record/cell resolution and backend capability
checks follow the common decision. Conservative unknown/interference cases
remain runtime work rather than independently inferring ownership from the two
catalogs. Validation failures do not create a fallback execution route.

Keep normalization and translator dependencies free of live-world services. A
runtime extension must not depend on promoted work being passed through its
family preparation hook. See the [compiler architecture](ARCHITECTURE.md#from-openmw-callbacks-to-an-active-plan) for the
boundary contract.

An action module supplies these compiler and validation hooks:

| Hook | Responsibility |
| --- | --- |
| `prepareAction(input, queries, context)` | Validate family syntax, prepare its owned input, and collect record/mesh query requirements; return prepared input or `nil, errors` |
| `compileAction(input, context)` | Return an array of final family programs or `nil, errors`; an empty array means the action legitimately contributes no work |
| `validateProgram(program, errors, actionId, helpers)` | Append program validation errors to the supplied array |
| `validateStoredState(kind, value, context)` | Validate the family's retained program, token, state, provenance, or storage value for the requested role |

`publicFields` identifies family-owned authored fields. `behavior`, or
`resolveBehavior(spec)`, describes scope, explicit-cell requirements, parent
and child support, and whether the action changes cell contents. Use
[`kill_actor.lua`](<../../mom/00 OpenMW/scripts/mom/actions/kill_actor.lua>) for a
small family and [`place_ref.lua`](<../../mom/00 OpenMW/scripts/mom/actions/place_ref.lua>)
for dynamic behavior and outputs.

`prepareAction` receives a `MomFamilyInput`, after shared cell and predicate
processing. `compileAction` returns `mom-family-program` envelopes with a final
`spec.program`, declared `claims`, and boolean `reversible`. Optional target
facts describe resolved selection, candidate types, direct targets, and query
cells. The compiler assigns semantic action IDs after lowering. Constructors,
field ownership, and the envelope validator are in
[`source_ir.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/source_ir.lua>).
Compiler contexts supply lazy cell/record access and model checks through
[`compile_context.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/compile_context.lua>).

Declare the complete set of claims before runtime arbitration. Claims cannot
be widened opportunistically after discovering the physical target. Shared
claim names and private `family:<family-id>:<name>` claims are checked by
[`claim_contract.lua`](<../../mom/00 OpenMW/scripts/mom/contracts/claim_contract.lua>).
An output-producing family can supply `outputTypeEnvelope(input, context)` for
child compilation. Optional `prepareTargetFilters(actions)` and
`prepareDiscoveryFilters(actions)` return action-ID-to-predicate maps during
activation. These selection hooks must be read-only and conservative when
they cannot establish a match or output type. Their integration is in
[`coordinator.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/coordinator.lua>)
and [`reconciler.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/reconciler.lua>).

Runtime hooks use these signatures:

```lua
capture(program, target, ctx)
apply(program, target, token, ctx)
revert(token, target, ctx)
advance(op, target, ctx)
onLocalComplete(op, completion, ctx)
reassert(op, target, ctx)
```

`apply` is required for global execution; LOAD-only families declare
`execution = 'load'` and `planLoad`, while split families declare
`execution = 'split'` and both `planLoad` and runtime hooks. Reversible state
operations supply `capture` and `revert`, returning a plain-data revert token.
`apply` and `revert` return a result table with `status` equal to `applied`,
`noop`, `failed`, or `pending` (plus optional `changedClaims`, `outputs`,
`pending`, `recoveryCells`, and `message`). Pending operations carry a plain
`pending` table (`phase`, `nextFrame`, and optional local lease state) resumed
by `advance` or `onLocalComplete`.

The executor ([`runtime/executor.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/executor.lua>))
supplies `frame`, `opId`, `actionId`, `targetId`, `target`, `targetFacts`,
`authoredRecordId`, `ledger`, `world`, `refOps`, `inventoryOps`, `placementOps`,
`actorOps`, `localBroker`, `targetFilter`, and `choicePort`. Treat supplied
programs as immutable. Actions that relocate references return `recoveryCells`
in their capture token or result so cross-cell targets remain discoverable on
subsequent ticks and restarts.

## Guard families

A guard module supplies:

```lua
return {
  id = 'example.ready',
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  providerInterface = 'ExampleState', -- Optional external provider.
  lowerTuple = lowerTuple,
  compileProgram = compileProgram,
  evaluate = evaluate,
}
```

`lowerTuple(tuple, path)` validates its compact tuple and returns a normalized
plain spec with `type = 'example.ready'`, or `nil, error`. `path` is a diagnostic
path string. Include the family type in the returned spec so guard compilation
can resolve its evaluator.

`compileProgram(spec, context)` returns `{program = {...}, subscriptions = {...}}`.
The current compile helper is `context.guardEvent(namespace, eventName, key)`;
it creates a canonical external event name. Subscription strings are sorted
and deduplicated before manifest assembly. For example:

```lua
local function compileProgram(spec, context)
  return {
    program = {key = spec.key, expected = spec.expected},
    subscriptions = {context.guardEvent('example', 'changed', spec.key)},
  }
end
```

`evaluate(program, context)` returns exactly one of:

```lua
{state = 'active'}
{state = 'inactive'}
{state = 'unknown', reason = 'provider unavailable'}
```

A known result has no `reason`; unknown requires a non-empty string reason.
Extra fields, invalid results, and exceptions become unknown. In a conjunction,
inactive takes precedence over unknown. Evaluation may be split across ticks;
a new owner wakeup discards partial evaluation so mixed observations do not
publish truth. Write each hook to do bounded work and keep continuation state
out of the module.

An external guard declares `providerInterface`. During evaluation it reads:

```lua
local provider = context.providers['example.ready']
local value, reason = provider.read(program.key)
if type(value) ~= 'boolean' then
  return {state = 'unknown', reason = tostring(reason or 'provider unavailable')}
end
return {state = value == program.expected and 'active' or 'inactive'}
```

The wrapper resolves `openmw.interfaces.ExampleState.read` on each call and
protects the read from exceptions. The provider's `read` arguments and returned
value are the protocol agreed with that guard. Built-ins instead use
`readTime`, `readWeather`, and `readQuestStage`. Changing a provider name, read
protocol, or truth interpretation changes guard behavior and needs a matching
behavior version.

A provider publishes state before sending a wakeup:

```lua
core.sendGlobalEvent('MOM_GuardEvent', {
  event = 'external:example:changed:some_key',
})
```

External event names have the form `external:<namespace>:<event>[:<key>]`.
Namespace and event use lowercase identifier segments. The optional key is
normalized to lowercase by `guardEvent` and cannot contain a colon. Events
request evaluation of interested owners and may coalesce; evaluation reads
current provider state and does not receive event payloads.

| Truth | New work | Existing work |
| --- | --- | --- |
| `active` | Eligible to apply | Reconcile |
| `inactive` | No application | Revert where the action supports it |
| `unknown` | No application | Retain |

See [`quest_stage.lua`](<../../mom/00 OpenMW/scripts/mom/guards/quest_stage.lua>),
[`guard_program.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/guard_program.lua>),
[`guards.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/guards.lua>),
and [`guard_reads.lua`](<../../mom/00 OpenMW/scripts/mom/openmw/guard_reads.lua>)
for working compiler, runtime, and provider boundaries.

## Compatibility translators

A translator declares `id`, `abiVersion = 1`, `behaviorVersion`, and
`translateSource(source)`. It declares exactly one ownership method:

- `matchesPath(path)` for path-owned data, or
- `claims({path = path, config = decodedConfig})` for content-owned data.

`configDirs` lists additional VFS directories to discover. A path-owned
translator may supply `load(path)` to replace YAML loading for its format;
otherwise the ordinary loader is used. `load` returns a config table or
`nil, error`.

Discovery and translation run in both contexts. A translator may read its
format's static source data and map spelling, defaults and meaningful ordering;
it must not resolve engine records/cells, sample winners, choose an execution
layer or build executor plans. Express plugin conditions and admission choices
as ordinary action data for the shared frontend.

`translateSource` receives source metadata and decoded `source.config`. Return
`actions, true` for translated data; return `nil, false` to decline it; return
`nil, true, error` to reject it. `error` includes a diagnostic `kind` and
`message`. Multiple claiming translators reject the source; load order does not
choose one. Native sources may remain unclaimed.

An optional fourth return value is an array of diagnostic strings. For a format
whose documented decoding policy skips malformed files, optional
`sourcePolicy(path)` can return `{onLoadError = 'skip'}`; omission keeps the
normal fatal load policy. The shared source frontend performs that skip and
reports it. This policy does not authorize hidden catalog reads or alternate
execution.

Returned actions use `mom-source-action` records from
[`source_ir.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/source_ir.lua>), with
diagnostic ID, source provenance and an ordinary action `spec`. The family is
derived from the verb centrally; a supplied family must agree with that verb.
Source children use the record's `children` array. Translator-provided
`familyInput`, compiled profiles and planner nodes are not admitted source
forms. `MomFamilyInput` remains the compiler-owned prepared representation
received by action-family hooks; it is not a translator escape hatch. The shared
[source-action validator](<../../mom/00 OpenMW/scripts/mom/compiler/source_action_contract.lua>)
checks the full returned tree before ordinary lowering. Empty output is accepted
only with `allowEmptySources = true`. Source locations identify diagnostics;
they do not substitute for semantic action identity. A foreign permanent
placement ID or seed that defines behavior must become ordinary semantic data,
such as `spec.key`, `admission` or a replacement expression. Preserve required
priority/conflict metadata and explicit composition ordering rather than
encoding behavior in diagnostic labels.

[`sss/translator.lua`](<../../mom/00 OpenMW/scripts/mom/compat/sss/translator.lua>)
is the smallest shipped translator. DOR adds a specialized loader; VFR handles
multiple data categories through ordinary choices, placements and `leveled`
actions. There is no separate VFR list planner or source stream. Shared MOM
code compiles spatial profiles, evaluates deterministic declaration admission,
resolves targets, composes list operations and places execution. Their
installation behavior is described in the public documentation.

Before distributing an extension, cover malformed inputs, deterministic
compilation, missing providers/targets, exact versions, and saved in-flight
work. Add real-engine or restart coverage for new mutation and recovery behavior.
