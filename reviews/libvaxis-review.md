# libvaxis wiring review

## Critical

None found. `zig build test`, `zig build lint`, and `zig build` all pass.

## Warnings

- `src/main.zig:57-69` changes `sidebar` from a 3s polling snapshot loop to a one-time cockpit snapshot rendered for the lifetime of the vaxis app. Any tmux pane/session/status/title changes after startup will not appear until the sidebar is closed and reopened. For a tmux cockpit this is likely a functional regression unless refresh is intentionally deferred. Add a vxfw timer/event path that rebuilds/free/replaces `items`, or keep polling outside vxfw until live refresh exists.
- `src/tui.zig:84-85` advertises `Enter/Alt-1..9 jump via tmux`, but `src/tui.zig:44-55` only handles `q` and `Ctrl-C`. The sidebar currently cannot jump or select, so the footer is misleading and can regress the TPM/sidebar UX. Either implement the key handlers against tmux jump actions or remove the hint until supported.

## Suggestions

- `build.zig.zon:9-12`: the dependency is pinned by tarball hash and Zig package hash. The locally fetched `libvaxis` package for this pin has dependencies only on `zigimg` and `uucode`; no `zg` dependency appears in its `build.zig.zon`, which supports the stated rationale. Consider leaving a short comment or commit note explaining the exact libvaxis commit rationale because the URL itself does not reveal why this non-tag commit is required.
- `src/tui.zig:101-108`: `writeText` iterates UTF-8 codepoints but names them `grapheme` and writes each codepoint as a cell with implicit width. This is acceptable for the current mostly-ASCII UI, but it can misrender combining marks/wide emoji in pane titles. Prefer vaxis text/RichText helpers or libvaxis grapheme/width iteration before relying on arbitrary tmux titles.

## Summary

Build wiring is correct and the selected libvaxis pin compiles on Zig 0.15.2 without `zg`. No memory lifetime issue was found for the current draw path: cockpit item storage outlives `app.run`, and vxfw surfaces allocate from the draw arena. Main risks are behavioral: sidebar data is static after launch, and advertised jump keys are not implemented.

## Verification

- `zig build test` — pass
- `zig build lint` — pass
- `zig build` — pass
