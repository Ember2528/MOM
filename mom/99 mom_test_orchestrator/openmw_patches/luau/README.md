The build selects this directory for Luau source trees. Its patch adds a
default-off `unsafe stdlib access` setting that exposes real Luau collector
control through `select("sandbox.bypass").collectgarbage` and real atomic result
publication through `.writeAtomic(path, bytes)`. This lets ownership tests
collect unreachable values, measure the VM heap, and publish performance
results through a temporary-file write and rename. Ordinary mod execution does
not receive this authority.

An explicit `MOM_HARNESS_OPENMW_PATCH_DIR` can select another directory. An empty
patch directory is valid. Luau profiling must use facilities provided by Luau;
the LuaJIT patch's `io`, `ffi`, and `jit` libraries are unavailable there.
