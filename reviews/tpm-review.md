# TPM/tmux integration review

## Critical

- `scripts/toggle.sh:17` + `src/main.zig:24-28`: the sidebar pane is not persistent. `toggle.sh` creates a split running `start.sh sidebar`, but `sidebar` currently just renders a snapshot and exits. tmux will close the pane as soon as the command exits, so the “Hoppers sidebar” action likely flashes/disappears instead of toggling a sidebar. Fix by keeping the sidebar process alive (real TUI/event loop, or a temporary `display-popup`/`remain-on-exit` style behavior until then).

## Warnings

- `src/tmux.zig:32-38`: `selectPane` and `switchSession` discard the allocated stdout returned by `run`, leaking memory every time jump is used. Capture and free the output:
  `const output = try self.run(...); defer self.allocator.free(output);`.

- `hoppers.tmux:11-15`: tmux command strings interpolate `CURRENT_DIR` inside single-quoted shell snippets. This handles spaces, but a plugin path containing a single quote will break command parsing and can become shell injection. Prefer passing a safely escaped tmux command string, or avoid nested shell quoting by invoking `run-shell` with separately quoted/escaped arguments generated via tmux escaping.

- `hoppers.tmux:22-23`: `@hoppers-index-keys` is split by POSIX shell word splitting. That makes keys containing whitespace impossible and allows surprising glob expansion if the option contains glob metacharacters matching files in the current directory. Disable globbing (`set -f`) and document whitespace-separated simple key names, or parse a delimiter explicitly.

- `scripts/toggle.sh:5-6,17`: `@hoppers-width` is passed directly to `tmux split-window -l`. Invalid values produce a failing toggle with no user-visible context. Validate as a positive number or tmux-compatible size before invoking `split-window`, and emit a clear tmux `display-message` on failure.

## Suggestions

- `scripts/start.sh:9`: auto-building inside tmux hides build failures because stdout is redirected and stderr may vanish depending on tmux invocation. Consider surfacing failures through `tmux display-message`/popup output, especially for TPM first-run UX.

- `hoppers.tmux:12`: the snapshot popup uses Bash-specific `read -n ... -s ...`, while the plugin otherwise targets `/usr/bin/env sh`. tmux normally executes via a shell where this may be `dash` on Linux; `read -n` will fail there. Use `bash -lc` explicitly or a POSIX-compatible pause.

## Summary

The integration is small and mostly shell-quoted correctly for normal paths, but the current sidebar command exits immediately, so the advertised toggle behavior is effectively broken. Fix that first, then address the memory leak and shell/tmux robustness around path escaping, key parsing, and first-run errors.
