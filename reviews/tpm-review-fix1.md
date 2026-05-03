# TPM/tmux re-review fix1

## Critical

- `src/main.zig:73-74`, `src/tmux.zig:36-38`: `jump` only switches the client to the target session, then calls `select-pane -t %pane`. For panes in another window of the same session, this can select the pane in its window without making that window current, so the user may remain on the wrong window. Target the pane/window in the client switch path (for example switch to `session:window` or directly to a target derived from `pane_id`) before/while selecting the pane.

## Warnings

- `scripts/start.sh:7-14`: first-run build is only “binary missing”. After a TPM/plugin update, an existing `zig-out/bin/hoppers` is reused even when `src/`, `build.zig`, or `build.zig.zon` changed. Users can run stale code indefinitely. Rebuild when inputs are newer than the binary, or install/build into a versioned artifact.
- `src/tmux.zig:4-5`, `src/tmux.zig:65-73`: tmux fields are parsed with a raw `|` delimiter. `pane_current_path`, `session_name`, and titles can legally contain `|`/newlines; a path containing `|` shifts fields and can make `pane_pid`/path/title parsing fail or corrupt jump targets. Use tmux escaping formats (or a delimiter/control sequence with escaping) and unescape at the boundary.
- `hoppers.tmux:11-15`: menu commands embed `$CURRENT_DIR` inside single quotes in the tmux command string. Plugin paths containing an apostrophe break command parsing. Less common, but TPM installs under arbitrary paths; prefer `run-shell -b -- "$CURRENT_DIR/scripts/..." ...`-style quoting/escaping.

## Suggestions

- `scripts/start.sh:9`: stdout is suppressed but stderr is not. That is useful for failures, but successful Zig warnings/progress on stderr may appear in the sidebar/popup/log on first build. If “no leakage” is strict, capture build output and print only on failure.
- `scripts/toggle.sh:10`: sidebar detection depends on `pane_title` remaining exactly `hoppers-sidebar`. If a child process or tmux option mutates pane titles, persistence/toggle breaks. A tmux pane option/user option marker would be more robust.

## Summary

Fixes improved redirection and basic toggle behavior, but jump correctness across windows and stale TPM binaries remain actionable regressions. Quoting and tmux field serialization still need hardening for arbitrary user paths/session metadata.
