# Architecture Review

## Critical

- `src/tmux.zig:32-38`, `src/main.zig:62-65`: `jump` addresses only the session and pane, never the target window. A pane id is unique server-wide for `select-pane`, but `switch-client -t <session>` chooses the session's current window first; selecting a pane in another window from that state is unreliable across tmux versions/usages and can fail or leave the client on the wrong window. Use a full target such as `{session_name}:{window_id}.{pane_id}` or switch/select by window+pane atomically.

## Warnings

- `src/tmux.zig:4-5`, `src/tmux.zig:60-68`: tmux fields are serialized with raw `|` delimiters, then parsed with `splitScalar`. `pane_title` and `pane_current_path` can contain `|`, so discovery can misparse titles/paths and then jump to the wrong ranked item or drop panes. Use a delimiter tmux can escape/encode, NUL-separated output if possible, or length/JSON-safe formatting.
- `src/discovery.zig:23-36`, `src/discovery.zig:49-51`: `CockpitItem.agent` stores borrowed slices from `TmuxPane` (`session_name`, `window_id`, `pane_id`, `title`) while `project`/`id` are owned. This lifetime coupling is implicit and fragile: returning/storing cockpit items beyond the pane slice lifetime would become use-after-free. Either make `CockpitItem` fully owned or document/enforce the borrowed lifetime in the type/API.
- `src/projects.zig:20-28`: project inference spawns `git rev-parse` once per agent pane. In the v1 cockpit this can block snapshot/sidebar rendering linearly with pane count, especially on slow/missing paths or network mounts. Add caching per cwd/root during one scan and/or an inexpensive upward `.git` search fallback.
- `src/main.zig:28-30`, `scripts/toggle.sh:17`: `sidebar` is a one-shot snapshot process. The tmux sidebar pane exits immediately, so toggle does not create a persistent monitor/cockpit. This misses the v1 “monitor” direction unless the current milestone intentionally limits sidebar to a placeholder.
- `src/model.zig:75-80` (not shown in line batch) detects `pi` via substring matching. This will classify unrelated commands/titles containing `pi` (e.g. `python`, `pip`, `vim plugin`) as agents. Token-boundary matching or an explicit command allowlist is needed before ranking/jump bindings are trustworthy.

## Suggestions

- `hoppers.tmux:10-15`: hard-coded jump menu entries stop at ranks 1-3 while `@hoppers-index-keys` supports arbitrary rank keys. Generate menu entries from configured keys or keep the menu to snapshot/sidebar only.
- `src/tui.zig:17-25`: status icon is printed twice per row. Consider replacing the second icon with priority/project metadata or removing it.
- Consider introducing a small repository/cockpit service boundary: `TmuxSource -> PaneParser -> AgentDetector -> ProjectResolver(cache) -> Ranker -> Presenter/Commands`. The current modules mostly align, but ownership and target identity should be made explicit at the boundary between discovery and tmux commands.

## Summary

The shape is aligned with a fresh TPM-compatible tmux cockpit and avoids launch/worktree mutation, but the jump target identity, raw tmux parsing, and borrowed ownership model are the main architectural risks. The current sidebar is snapshot-only, so it does not yet satisfy a persistent monitor experience.
