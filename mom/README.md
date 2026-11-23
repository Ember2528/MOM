# MOM — Modular Object Manipulator

MOM lets OpenMW mods change objects through YAML configuration files. A patch
can edit supported record and leveled-list definitions, place decorations,
replace meshes, move existing objects, edit inventories, or respond to time,
weather and quest progress. The core mod supplies these
operations; installed configuration files decide what changes in your game.

## Requirements and installation

MOM supports OpenMW's LuaJIT runtime and the Luau port from OursCodeur's
`clockwork-alpha` branch. These are the two intended runtime targets. A minimum
numbered OpenMW release has not been established here; check the engine build
used for the release you install. The developer test harness and its engine
patches are not required for normal play.

1. Extract the release archive somewhere you keep your OpenMW mods.
2. Add its `00 OpenMW` directory as an OpenMW data directory.
3. Enable `mom.omwscripts` in the content list.
4. Add the data directories for any MOM patches you want to use. Keep their
   required plugins, meshes and textures installed too.
5. Start OpenMW and load a game.

The other bundled directories are optional:

| Directory | What enabling it does |
| --- | --- |
| `01 Mod Patches` | Enables patches for Imperial Cult Expansion and for Quests for Clans and Vampire Legends with Vivec — God the City, when their required plugins are active. |
| `02 Examples` | Enables a vanilla tapestry tutorial, a mixed book/urn example and, with OAAB Data active, a Dwemer lightning rod replacement. These examples make actual changes. |
| `04 SSS Conversions` | Contains native SSS adaptations, optional alternatives and a comparison of every upstream example. Read its README before choosing data directories. |
| `docs` | Contains the author guide, format reference and compatibility guide. It is not a data directory. |

Configurations belong under `scripts/mom/config/` within an enabled data
directory. Use different relative filenames for independent patches. MOM sees
OpenMW's combined virtual filesystem, so a later data directory can override a
file at the same relative path.

Definition and reference declarations can share one file. The compiler runs in
LOAD and GLOBAL. Native and imported declarations share semantic normalization
and automatic execution planning before either backend lowers its actions. Definition
edits run once before the main menu; reference actions use the selected game's
runtime. No separate content folder or context-selection flag is needed.

MOM also reads supported SSS, DOR and Variation Framework data in their original
folders. Follow the [compatibility guide](docs/COMPATIBILITY.md) when using those
formats, including its instructions for disabling the original replacement
runtime.

## Check that it loaded

Open the in-game console and enter global Lua mode with `luag`. Then run:

```lua
I.MOM.selfcheck()
```

A working runtime logs `status=running` with `ledger=true` and `manifest=true`.
Look for `[MOM][INFO][selfcheck]` in the OpenMW log. A running core with no active
configuration is valid; it does not mean a particular patch was selected.

These helpers are available through `I.MOM`:

| Helper | Use |
| --- | --- |
| `I.MOM.selfcheck()` | Report runtime status, saved-state validity and blocked work. |
| `I.MOM.compileReport()` | Report configuration results and diagnostics. |
| `I.MOM.logLevel('debug')` | Enable more detailed logging for troubleshooting. |
| `I.MOM.logLevel('info')` | Restore the normal logging level. |
| `I.MOM.version` | Read the public interface version, currently `0`. |

The other logging levels are `trace`, `warn`, `error` and `off`. Status reports
are bounded summaries; the log may contain details that do not fit in them.

## Configuration changes and saves

Fully restart OpenMW after changing configuration files. MOM has no live reload
command. The compiler validates definition and runtime work in their assigned
contexts. Failed LOAD work blocks runtime activation; a later runtime error
leaves successfully committed definition changes in place. The `startup` summary
in `compileReport()` and `selfcheck()` reports LOAD separately. Missing bindings
and unsupported fields are errors, rather than requests for another execution
context. See the [reference](docs/AUTHORED_CONFIG_REFERENCE.md#definition-changes-and-reference-actions)
for supported types and engine limitations.

MOM is unpublished; saves from earlier development implementations may be reset.
Ordinary save/load within the current design preserves runtime progress and
does not repeat definition edits when a game loads.

Unguarded patches keep their completed changes in the save. Removing a file does
not undo those changes. MOM can replace some unambiguous edits and its own
placements, but it retains unsupported or conflicting old work instead of
guessing how to undo it. There is no general reset command.

Guarded rules can apply and reverse as their conditions change. Reversal depends
on the action: killing an actor cannot be undone, and inventory changes may be
affected by items used, taken or added during play. See the
[author guide](docs/MOD_AUTHOR_GUIDE.md#changes-and-existing-saves) before editing
patches for an existing save.

## Troubleshooting

- **`I.MOM` is unavailable:** check that you selected global Lua mode, enabled
  `mom.omwscripts`, and added the directory containing that file. Check the log
  for a Lua loading error.
- **The runtime does not reach `running`:** run `I.MOM.compileReport()` and read
  MOM errors in the log. A configuration error can prevent all runtime patches
  from starting. Unsupported saved state is preserved for diagnosis and blocks
  changes rather than being converted automatically.
- **A patch has no visible effect:** check its required plugin filenames and
  selected cell/record IDs. Visit the affected cell. For optional compatibility
  data, check the supported subset in the compatibility guide. Enable debug
  logging, restart, and inspect the new log if the reason is unclear.
- **An edited patch is blocked in an existing save:** old permanent work may
  overlap the new edit. Test the new configuration with a save from before that
  work; deleting saved evidence would not restore the world.

For a bug report, include the OpenMW build and Lua runtime, MOM revision or
release, the relevant configuration, reproduction steps, and the MOM messages
from the log. On Linux the log is commonly
`~/.config/openmw/openmw.log`; use your OpenMW configuration location on other
systems or when you have changed it.

## Write a patch

Start with the [mod author guide](docs/MOD_AUTHOR_GUIDE.md). Use the
[configuration reference](docs/AUTHORED_CONFIG_REFERENCE.md) for exact syntax,
and the [compatibility guide](docs/COMPATIBILITY.md) for imported formats.
