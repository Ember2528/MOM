# MOM — Modular Object Manipulator

MOM lets OpenMW mods and patches change objects, base records, leveled lists, and actor inventories through YAML configuration files. The core mod provides the engine; installed patch configs decide what changes in your game.

## Requirements

- **OpenMW:** Supports OpenMW's LuaJIT runtime and the Luau `clockwork-alpha` branch.
- **No extra framework needed:** You do not need the developer test harness or engine patches for normal gameplay.

## Installation

1. Extract the release archive into your OpenMW mods folder.
2. Add `00 OpenMW` as a `data=` directory in `openmw.cfg` (or your mod manager).
3. Enable `mom.omwscripts` in your content list.
4. Add data directories for any MOM patches (or supported SSS/DOR/VFR data packs) you want to use, along with any plugins, meshes, or textures they require.
5. Launch OpenMW and load a game.

### Optional Bundled Folders

| Folder | What it does |
| --- | --- |
| `01 Mod Patches` | Optional patches for *Imperial Cult Expansion* and *Quests for Clans and Vampire Legends* + *Vivec — God the City* (activate only when their required plugins are enabled). |
| `02 Examples` | Live example patches: a vanilla Balmora tapestry placement, a book-definition + urn-scale example, and an OAAB Dwemer lightning rod replacement. Only enable if you want to see these examples in-game. |
| `04 SSS Conversions` | Native MOM adaptations of Static Switcher examples. Read its [README](04%20SSS%20Conversions/README.md) before enabling sub-options. |
| `docs` | Mod author guide, YAML reference, and compatibility guide (not an OpenMW data directory). |

> **Tip:** MOM also reads supported SSS, DOR, and Variation Framework data directly from their original folders. See the [compatibility guide](docs/COMPATIBILITY.md) before installing them — in particular, disable `variationFramework.omwscripts` when letting MOM handle VFR packs.

## Verify That MOM Loaded

Open the in-game console, switch to global Lua mode with `luag`, and run:

```lua
I.MOM.selfcheck()
```

Check `openmw.log` for `[MOM][INFO][selfcheck]`: a healthy install reports `status=running`, `ledger=true`, and `manifest=true`.

### Console Commands (`I.MOM`)

| Command | Purpose |
| --- | --- |
| `I.MOM.selfcheck()` | Show runtime status, startup LOAD summary, ledger health, and any blocked work. |
| `I.MOM.compileReport()` | Show active config counts, LOAD summary, and any compile warnings or errors. |
| `I.MOM.logLevel('debug')` | Turn on verbose logging (`trace`, `debug`, `info`, `warn`, `error`, `off`). |
| `I.MOM.logLevel('info')` | Return to normal log verbosity. |
| `I.MOM.version` | Current public interface version (`0`). |

## Adding, Editing, or Removing Patches

- **Always restart OpenMW after editing YAML files.** MOM compiles definition edits once at startup (before the main menu) and does not live-reload configs via `reloadlua`.
- **Unguarded (static) patches persist in your save.** Once MOM applies an unguarded edit or placement, removing the YAML file does not automatically undo what is already baked into the save. Test edits on a backup save from before the patch ran.
- **Guarded patches automatically apply and reverse.** Time, weather, and quest-stage rules turn on and off cleanly as conditions change (except `kill`, which is always permanent, and inventory edits, which reverse best-effort if items were used or taken).
- **Definition edits (`record`, `leveled`, and promoted global model swaps) live per process.** Removing a definition patch and restarting OpenMW stops overriding the base record cleanly (note: keep patches that *create* brand-new named records installed as long as a save uses those records).

## Troubleshooting

| Problem | What to check |
| --- | --- |
| `I.MOM` is `nil` in console | Make sure you switched to `luag` (global mode), added `00 OpenMW` as a data directory, and enabled `mom.omwscripts`. Check `openmw.log` for Lua load errors. |
| Status is not `running` | Run `I.MOM.compileReport()` and inspect `[MOM][ERROR]` lines in `openmw.log`. Any fatal config error blocks the whole runtime set so partial patches never corrupt a save. |
| A patch had no visible effect | Verify required plugin filenames match your load order, visit the affected cell, and check `[MOM][WARN]` entries with `I.MOM.logLevel('debug')` followed by a restart. |
| Edited patch conflicts with old save data | Earlier permanent edits in the save may hold claims on the same object. Test on a save from before the old patch ran. |

On Linux, OpenMW logs are usually at `~/.config/openmw/openmw.log`. When reporting a bug, include your OpenMW build (LuaJIT or Luau), the patch YAML, and the `[MOM]` lines from `openmw.log`.

## Next Steps

- Ready to make your own patch? Start with the [Mod Author Guide](docs/MOD_AUTHOR_GUIDE.md).
- Looking up exact YAML fields? Open the [Configuration Reference](docs/AUTHORED_CONFIG_REFERENCE.md).
- Installing SSS, DOR, or VFR packs? Read the [Compatibility Guide](docs/COMPATIBILITY.md).
