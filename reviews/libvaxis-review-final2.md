Critical: none.

Warnings:
- `src/main.zig:62-65`: `items` can leak if `vxfw.App.init(allocator)` fails after `discovery.buildCockpit` succeeds. The normal `view.deinit()` path is fine, but the error path before `view` is initialized has no cleanup. Add an `errdefer discovery.freeCockpitItems(allocator, items);` immediately after line 62, then let `view.deinit()` own cleanup after successful initialization.

Suggestions:
- `src/tui.zig:132-139`: `writeText` advances one column per UTF-8 codepoint slice. Status icons / arrows may be width-2 or otherwise ambiguous, so later text can visually overlap/misaligned in some terminals. Consider using vaxis text/segment helpers or a width-aware cursor advance if this becomes visible.

Summary:
- The final refresh fix is directionally correct: refresh builds the replacement before freeing the current cockpit items, preserving the old view on build/list errors. Deinit follows project style, and the footer no longer advertises unhandled Alt bindings. Only actionable defect found is a small allocation cleanup gap in `sidebar`'s `App.init` error path.

Verification:
- `zig build test` passed.
- `zig build lint` passed.
- `zig build` passed.
