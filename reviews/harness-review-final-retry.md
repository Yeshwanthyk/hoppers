# Harness final retry review

Critical: none.

Warnings: none.

Suggestions:
- `scripts/toggle.sh:5,13-17,28-29`: direct `tmux` calls still rely on ambient `TMUX`/default socket rather than adding `-S "$HOPPERS_TMUX_SOCKET"`. Current harness path sets `TMUX` and passes, so not a blocker; consider centralizing tmux invocation if supporting non-attached/test-socket calls with only `HOPPERS_TMUX_SOCKET`.

Summary:
- `scripts/toggle.sh:9-26` shell quoting handles single quotes safely for the shell command passed to `split-window`.
- `src/tmux.zig:54-60` no longer masks broad `switch-client` failures; detached/no-client mode only validates session existence with `has-session`.
- Verification passed: `zig build test`, `zig build lint`, `zig build`, `scripts/test-tmux-harness.sh`.
