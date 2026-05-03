# Zig review fix1

Critical:
- `src/discovery.zig:13-16`: `errdefer freeCockpitItem(allocator, item)` is registered for every successfully built item and remains active until `buildCockpit` returns. If a later `append`/`toOwnedSlice` fails, the outer `errdefer` at `src/discovery.zig:8-10` frees all appended items, then each per-iteration `errdefer` also frees its captured item. This is a double-free/use-after-free under allocation failure. Transfer ownership explicitly after append, e.g. use `var item`, append, then null/flag the local cleanup, or append with a local `errdefer` scoped in a block that is disarmed after successful append.

Warnings:
- `src/discovery.zig:39-48` / `src/main.zig:42-46,65-69`: `CockpitItem.agent.{session_name,window_id,pane_id,title}` borrow slices from `TmuxPane`, while `freeCockpitItems` only frees project/id. The current `main` defer order keeps panes alive longer than items, but the ownership contract is implicit and easy to violate by other callers/tests. Either duplicate these fields into the cockpit item or document/enforce that panes must outlive cockpit items.
- `src/tmux.zig:65-73`: pane parsing uses `|` as an unescaped delimiter for tmux fields. `pane_title` and paths can contain `|`; title is partially handled via `parts.rest()`, but earlier fields containing `|` will corrupt parsing. Prefer a tmux format with a delimiter unlikely/impossible in fields plus escaping, or emit JSON if available.

Suggestions:
- Add an allocation-failure test for `buildCockpit` (e.g. `std.testing.FailingAllocator`) to cover the ownership transfer path.

Summary:
- `zig build test`, `zig build lint`, and `zig build` all pass. One allocation-failure double-free remains in discovery; fix before relying on DebugAllocator/general-purpose allocator safety.
