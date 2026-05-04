Critical:
- None found.

Warnings:
- `src/tui.zig:49`, `src/tui.zig:136-151`: selection is persisted by `rank`, but ranks are derived/order-dependent and can change on refresh when status/priority/project grouping changes. Because `refresh()` only repairs the selection when the rank disappears, the highlighted row can silently move to a different pane after a tick. Prefer preserving selection by stable pane identity (`agent.pane_id` or id) and deriving the selected rank/index for rendering.

Suggestions:
- `src/discovery.zig:73-81`: `inferStatus()` only scans the first 256 bytes of the title. Fine as a cheap heuristic, but long shell/start commands with status text after a long prefix will be misclassified as running; consider documenting the tradeoff or scanning suffix/key fields if this matters.
- `src/tui.zig:92-94`: numeric selection is limited to ranks 1-9 while `rankLabel()` renders higher ranks as `+`. Acceptable for MVP, but ambiguous once more than 9 agents are shown.

Summary:
- No correctness or memory-safety blockers in the reviewed changes. The main behavioral risk is rank-based selection becoming unstable across refreshes.
