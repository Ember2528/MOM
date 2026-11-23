# MOM — Modular Object Manipulator

MOM is an OpenMW mod for changing objects through YAML configurations. It can
place or replace objects, change their properties and inventories, and apply
rules as time, weather, or quest state changes. It also imports supported data
from other object replacement frameworks.

Start with the [installation guide](mom/README.md). To create a patch, follow the
[mod author guide](mom/docs/MOD_AUTHOR_GUIDE.md), then use the
[configuration reference](mom/docs/AUTHORED_CONFIG_REFERENCE.md) for exact syntax.

| Directory | Contents |
| --- | --- |
| `mom/00 OpenMW/` | The production mod |
| `mom/01 Mod Patches/` | Optional patches for particular mods |
| `mom/02 Examples/` | Optional example configurations |
| `mom/04 SSS Conversions/` | Native adaptations of SSS examples and a source-by-source comparison |
| `mom/docs/` | Documentation included in releases |
| `mom/99 mom_test_orchestrator/` | Tests, fixtures, engine build support, and benchmarks |
| `docs/mom/` | Development, architecture, extensions, and release instructions |
| `tools/` | Release packaging and ordinary-profile log checks |

For development, see [the developer guide](docs/mom/README.md). For a release,
follow [the release procedure](docs/mom/RELEASE.md). Large engine builds, saves,
logs, and measurement artifacts belong outside the repository.
