# Static examples and the introductory test

The source is S3ctor's SSS at
[`5e16c717f9524a9ab049e3557ccf04ab4cca9a86`](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/tree/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system),
examined on 2026-11-14. The term *static module* describes SSS's pipeline;
it does not mean that every selected record is an OpenMW Static.

## Basic Static Replacement recipe: automatic promotion

The documentation's [Basic Static Replacement recipe](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/docs/recipes/basic-static-replacement.md)
asks for a global replacement of one model with another. The optional
[Uniform Static Models configuration](<options/Uniform Static Models/scripts/mom/config/sss_basic_uniform_static.yaml>)
demonstrates that goal with vanilla tapestry meshes: `Furn_De_Tapestry_04.NIF`
becomes `Furn_De_Tapestry_03.NIF`. It is a practical adaptation of the generic
recipe, not a literal conversion of its Cliff Racer/custom-mesh excerpt and
not an additional converted `Examples/` fixture. It supplies no new assets.

This is an ordinary `attach` action using the same compact tuple form as other
attachments. Its row, `select: {type: Static}` and `disableOriginal: true`
describe unrestricted model-only intent. MOM automatically promotes the
eligible action to LOAD; the author supplies no layer setting or alternative
syntax. MOM edits matching Static base records before the runtime starts.
It does not clone each placed tapestry or disable its original
reference. Existing record/reference IDs, positions, scales and reference state
remain in use. All references using an edited base record share the new model,
including disabled or unloaded references and objects created later from it.
The source model is matched against the base catalog at MOM's place in LOAD
order; this does not promise to override a later LOAD mod's changes.

MOM avoids per-reference replacement chains automatically when the authored
change is eligible. The global scope comes from the action's `"*"` selection;
promotion does not widen it. Restricting cells or references, adding guards or
depending on child outputs can make an attachment ineligible for promotion;
MOM handles supported actions with those meanings at runtime using the same
authoring grammar. Creature, NPC and Container model definition bindings remain
unavailable. Once assigned, an action's missing target, asset or capability is
diagnosed rather than silently selecting another execution method.

Enable this option only when that global visual change is intended, and restart
OpenMW after editing it. Switching an existing clone-based save to this option
does not adopt or remove SSS replacement chains or older MOM replacement
outputs. Test from a save without those overlapping changes. The literal
scoped and Creature templates below are handled automatically at runtime.

## `StaticModule.yaml`: structurally convertible, missing assets

[Source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/StaticModule.yaml)
maps `totallyFake1.nif` and `totallyFake2.nif` to illustrative replacement
paths. Its scope is cell name containing `dagoth ur` **OR** Ashlands region
**OR** exterior grid `[0, 0]` or `[0, -1]`. None of the four meshes is supplied.

The compact native [template](templates/sss_static_module.yaml.example)
preserves this union with two disjoint attachment selections. A single MOM
cell query combining `match`, `coords` and `region` would instead require the
region restriction as well. Splitting out the region, then excluding it from
the name/grid selection, also avoids issuing the same replacement twice at
overlapping locations. This is more complicated than SSS's mesh map.
MOM respects these authored cell restrictions and does not promote the action:
a base-definition change would also affect references outside its scope.
The author does not need a different action form for this case.

It remains an authoring template with suffix `.yaml.example`, outside the
discovered config path. To make it executable, provide real source/replacement
meshes whose source records meet MOM's attachment restrictions, rename to
`.yaml`, and put it under an enabled `scripts/mom/config/` directory. It is
not counted as a working conversion or a tested asset replacement.

MOM's SSS importer also accepts region-only and global modules. It preserves
the source's OR scope using disjoint native branches and retains explicit-grid
previsit behavior without preloading all globally or regionally selected cells.
A native rewrite is no longer necessary merely to express those scopes. The
illustrative meshes still have to be supplied.

## `StaticModule_Advanced.yaml`: creature mesh replacement, missing example assets

[Source](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/Examples/StaticModule_Advanced.yaml)
globally replaces the Cliff Racer and Shalk models, excluding
`cliff racer_diseased` and `shalk_blighted`. The custom `my_mod/creatures/`
meshes are illustrative and absent here.

MOM now supports this shape through one-for-one Creature mesh replacement.
The [native template](templates/sss_static_module_advanced.yaml.example) keeps
global mesh selection and the record exclusions. It remains outside discovery
because the illustrative replacement meshes are absent.
Creature model definition bindings are unavailable, so MOM does not promote
this attachment even with its unrestricted scope. The ordinary action remains
a runtime replacement; the author supplies no execution-layer choice.

Both MOM and SSS create a fresh Creature from a copied base record and disable
the original; neither transparently preserves the original actor's current
inventory, health, AI, script locals or engine identity. MOM additionally skips
dead and summoned sources and rejects multiple replacement outputs for one
source. Its withdrawal restores the original actor without transferring the
replacement's changed live state. NPC replacement remains unsupported.

The [Concept Art Scamps MOM configuration](<options/Concept Art Scamps/scripts/mom/config/rv_concept_scamp_visuals.yaml>)
shows this behavior using external resource paths. Install the original mod
resources separately; this repository distributes only the native MOM YAML.

The contextual static recipe and first-module page reuse these examples;
the basic recipe's vanilla-path adaptation is described above. Their source
paths and exclusions are covered here. The nine released mods
listed in “Static Modules in the Wild” are a catalog, not additional example
configuration files. Their downloadable mod assets/configurations have not
been converted or redistributed by this package. Authors describe these visual
changes with ordinary actions; MOM decides whether each is eligible for
promotion. Scoped or guarded changes retain runtime `attach` semantics and its source
safeguards: Static, scriptless Activator and transferable Container sources
are supported there. Creature model replacement has the fresh-instance
contract above. A mod called a static replacer is not automatically a
transparent state transfer, and a definition edit cannot replace a
reference-specific selection.

## Introductory rat test: practical conversion

The [first-module test](https://github.com/DreamWeave-MP/S3ctors-S3cret-St4sh/blob/5e16c717f9524a9ab049e3557ccf04ab4cca9a86/content/static_switching_system/docs/getting-started/first-module.md)
multiplies every rat's scale by `1.25` once. Its native adaptation is
`options/Rat First Test/scripts/mom/config/sss_first_test.yaml`.

Both use the existing rat rather than cloning it. MOM's unguarded action
supplies saved completion without an authored `once` flag. The selection uses
an exact record ID instead of SSS's anchored Lua pattern and type condition.
MOM's `scale: {by: 1.25}` is a multiplier. As with other one-time scale edits,
an outside mod's timing and prior scale changes can affect the value captured;
this is not a promise to recover an untouched vanilla reference.

This test is optional so enabling the shared conversion directory does not
silently enlarge every rat in a game. It is a conversion of the fixed-scale
introductory test, not of the random-scale `CreatureScale` example.
