# Architecture Review (fix1)

## Critical

- `src/tmux.zig:32-38`, `src/main.zig:71-75`: `jump` still targets only session then pane. The model carries `window_id`, but command execution ignores it; `switch-client -t <session>` lands on that session's current window and `select-pane -t <pane_id>` is not a coherent full target for a ranked cockpit item. This can jump to the wrong visible window or fail depending on tmux state/version. Add one controller operation that targets the exact pane/window, e.g. by full target/session+window+pane, and test target construction.
- `src/tmux.zig:4-5`, `src/tmux.zig:65-73`: pane discovery still serializes tmux fields with raw `|` separators and parses with `splitScalar`. Session names, titles, commands, and paths can contain `|`; corruption before ranking means `jump <rank>` can target the wrong pane. This should be fixed before first commit because it defines the core boundary contract. Use escaped/control-delimited output or another unambiguous encoding, with regression tests.

## Warnings

- `src/discovery.zig:39-52`, `src/discovery.zig:55-58`: `CockpitItem` is partially owned: project/id are owned, but session/window/pane/title slices are borrowed from `TmuxPane`. Current `snapshot`/`jump` lifetimes happen to be safe because panes outlive items, but the architecture does not encode that constraint. Before adding persistence/evented TUI state, either make cockpit items fully owned or introduce a view type whose borrowed lifetime is explicit.
- `src/projects.zig:20-33`: project resolution forks `git rev-parse` once per pane. The persistent sidebar now loops every three seconds (`src/main.zig:54-60`), so this cost repeats indefinitely and can hang on slow/network paths. Add per-scan caching and consider a cheap upward `.git` search before shelling out.
- `src/model.zig:75-80`: agent detection remains substring-based. `pi` will match unrelated commands/titles such as `pip`, `python`, or `vim plugin`, polluting ranks and jump bindings. Use command allowlists or token/path-boundary matching.
- `src/main.zig:54-60`: the sidebar is persistent now, but it is still a polling ANSI snapshot, not libvaxis. Coherent for a bootstrap skeleton, but first-commit messaging should mark this as placeholder rather than implying the final TUI loop exists.

## Suggestions

- `src/tui.zig:17-25`: each row prints the status icon twice. Replace one with priority/window/session metadata or remove it.
- `hoppers.tmux:10-15`: the menu hard-codes rank jumps 1-3 while `@hoppers-index-keys` can bind more ranks. Either generate menu entries from the configured keys or keep the menu to sidebar/snapshot.
- `scripts/start.sh:16`: replace `exec "$BIN" "${@:-sidebar}"` with an explicit argc branch. It is easier to reason about and avoids subtle shell-specific argument behavior.

## Summary

Fix1 addressed the earlier stdout leak and made the sidebar persistent. The skeleton is otherwise coherent for TPM v1 monitor/jump/prioritize, with clean module boundaries (`tmux -> discovery/projects/ranking -> tui`). Before first commit, fix exact tmux target identity and unambiguous pane serialization; those are the two boundary issues most likely to create wrong jumps. Ownership and project-resolution caching can follow immediately after but should be settled before the TUI becomes stateful.
