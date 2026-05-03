# Zig implementation review

## Critical

- `src/tmux.zig:32-38` leaks successful command stdout for `selectPane` and `switchSession`. `Controller.run` returns an owned `[]u8`; these callers discard it without freeing. The `jump` command calls both (`src/main.zig:64-65`), so every successful jump leaks under the debug allocator and will produce leak diagnostics / fail leak-sensitive runs. Free the returned buffer or add a `runDiscardingOutput` helper.

## Warnings

- `src/tmux.zig:70-78` leaks partially-allocated pane fields on any later error. The struct literal performs multiple `allocator.dupe` calls and `parseInt`; if `parseInt` fails after the first three dupes, or a later dupe returns `OutOfMemory`, earlier allocations are lost because there is no local `errdefer`. Build the pane incrementally with errdefers or parse `pane_pid` before allocating.

- `src/tmux.zig:4-5` / `src/tmux.zig:60-68` use raw `|` as a tmux field delimiter without escaping. tmux session names, commands, paths, and titles can contain `|`; a path/title with that byte corrupts parsing, and a session name containing it can shift fields enough to make `pane_pid` invalid. Use a delimiter tmux cannot emit in paths/titles (or NUL/control char with explicit escaping) and add a regression test.

- `src/discovery.zig:18` and `src/discovery.zig:21` are loop-scoped `errdefer`s that remain active until `buildCockpit` returns. If a later pane fails after one or more successful appends, these errdefers also free `project`/`id` while `items.errdefer` frees the appended items, causing double-free during error unwinding. Convert ownership after append with `errdefer` cancellation pattern (e.g. nullable ownership variables) or append only after all fallible operations complete and ensure exactly one owner.

## Suggestions

- `scripts/start.sh:16` relies on `${@:-sidebar}` inside quotes. This is subtle and shell-dependent; prefer an explicit `if [ "$#" -eq 0 ]; then exec "$BIN" sidebar; else exec "$BIN" "$@"; fi` to preserve arguments portably.

- `src/main.zig:7-9` always uses `DebugAllocator`, including release builds. That is useful while bootstrapping but expensive/noisy for a tmux plugin binary; consider selecting allocator by build mode once leak checks are covered by tests.

## Summary

The code builds and passes the configured checks, but there are real ownership bugs around command output, partial parsing failures, and error unwinding in cockpit construction. Fix those before relying on this as a long-running tmux plugin.
