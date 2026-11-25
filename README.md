# MOM — Modular Object Manipulator

MOM is an OpenMW Lua framework for modifying Morrowind's world, records, and inventories declaratively using YAML — no Lua scripting required.

With MOM you can:

- **Place, replace, move, scale, hide, or re-own objects** across interiors, exteriors, regions, or exact plugin references.
- **Edit base records and leveled lists** cleanly at startup (LOAD) with automatic promotion for uniform global model swaps.
- **React to game state** with time, weather, and quest-stage guards that apply and cleanly reverse as conditions change.
- **Import existing third-party configs** from Static Switcher (SSS), Dynamic Object Replacer (DOR), and Variation Framework (VFR) directly from their original folders.

## Where to Start

- **Players:** Read the [installation & troubleshooting guide](mom/README.md).
- **Mod authors:** Follow the [mod author guide](mom/docs/MOD_AUTHOR_GUIDE.md), then use the [YAML configuration reference](mom/docs/AUTHORED_CONFIG_REFERENCE.md).
- **Using SSS / DOR / VFR packs:** Read the [compatibility guide](mom/docs/COMPATIBILITY.md).
- **Contributors & extension authors:** See the [developer guide](docs/mom/README.md), [architecture overview](docs/mom/ARCHITECTURE.md), and [extension guide](docs/mom/EXTENSIONS.md).

## Repository Layout

| Path | Contents |
| --- | --- |
| `mom/00 OpenMW/` | Core OpenMW mod (`mom.omwscripts` and Lua sources) |
| `mom/01 Mod Patches/` | Ready-to-use optional compatibility patches for specific mods |
| `mom/02 Examples/` | Working example patches you can enable or copy |
| `mom/04 SSS Conversions/` | Native MOM adaptations of upstream SSS example configs |
| `mom/docs/` | User-facing documentation bundled into release ZIPs |
| `mom/99 mom_test_orchestrator/` | Developer-only test harness, pure tests, world scenarios, restart campaigns, and benchmarks |
| `docs/mom/` | Developer, architecture, extension, and release docs |
| `tools/` | Release ZIP builder/auditor and log smoke checker |

For release packaging, see [docs/mom/RELEASE.md](docs/mom/RELEASE.md). Keep OpenMW builds, saves, logs, and test artifacts outside the repository.
