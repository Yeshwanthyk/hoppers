# Harness/plugin review

## Critical

None found.

## Warnings

- `scripts/toggle.sh:19` builds a shell command by interpolating `tmux_socket`, `tmux_env`, and `ROOT/scripts/start.sh` inside single quotes without escaping embedded single quotes. A checkout path containing `'` (or a socket path with `'`) will break sidebar startup and can become shell injection because tmux executes this string through the shell. Reuse the `shell_quote` helper pattern from `scripts/install-tmux-bindings.sh` or avoid shell-string composition.
- `src/tmux.zig:54-57` catches every `switch-client` failure and treats `has-session` success as equivalent. This is useful for detached harness servers, but it also masks real attached-client failures (bad socket/client state, permission errors, incompatible tmux behavior) and continues to `selectPane`, potentially reporting a successful jump when the client did not switch sessions. Prefer only falling back for the known detached/no-client failure mode, or gate the fallback on an explicit harness/non-client condition.

## Suggestions

- `scripts/test-tmux-harness.sh:99` hard-codes prefix key `h` when validating plugin bindings. If the harness later sets `@hoppers-prefix-key`, this assertion will give a false negative; derive it from the option/default as the installer does.
- `src/tmux.zig:100-109` still uses an in-band separator (`‹HOP›`) before sanitizing fields. This is acceptable for current fake-agent coverage, but tmux titles/commands containing that literal can corrupt parsing. Consider tmux format escaping or a more robust record encoding before relying on arbitrary pane metadata.

## Summary

The tmux harness, plugin sourcing/install path, socket injection, pane metadata sanitation, and docs/AGENTS updates are broadly sound. The main actionable defect is unsafe shell-string construction in `scripts/toggle.sh`; the main behavior risk is over-broad `switch-client` error masking.

## Verification

Ran successfully:

```sh
zig build test
zig build lint
zig build
scripts/test-tmux-harness.sh
```

Harness output: `ok 1` through `ok 14`, including build, snapshot, plugin binding, sidebar liveness/rendering, no replacement characters, and jump selection.
