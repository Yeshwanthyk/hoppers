# hoppers tmux end-to-end harness

`hoppers` includes an isolated tmux harness so agents can test tmux/plugin behavior programmatically without touching a human tmux server.

## Run everything

```sh
scripts/test-tmux-harness.sh
```

The harness creates a private tmux server with `tmux -L hoppers-test-<pid> -f /dev/null`, builds hoppers, creates fake agent sessions, sources the plugin, opens/captures the sidebar, and validates jump behavior.

## Run one case

```sh
scripts/test-tmux-harness.sh --case build
scripts/test-tmux-harness.sh --case snapshot
scripts/test-tmux-harness.sh --case plugin
scripts/test-tmux-harness.sh --case sidebar
scripts/test-tmux-harness.sh --case jump
```

## Keep failed tmux session for debugging

```sh
HOPPERS_TEST_KEEP=1 scripts/test-tmux-harness.sh --case sidebar
```

The harness prints the socket name and temp directory when kept. Attach with:

```sh
tmux -L <socket-name> attach
```

## What the harness covers

- `zig build`
- fake agent sessions using deterministic start commands (`claude`, `codex`, `pi`, `marvin`)
- `hoppers snapshot` textual output against the isolated tmux socket
- plugin sourcing via `hoppers.tmux`
- installed tmux menu and global bindings via `list-keys`
- sidebar toggle with an explicit target window for detached test servers
- sidebar liveness after multiple seconds
- sidebar visual output via `capture-pane` including header, agents, status icons, footer, and raw escape-text checks
- jump behavior by asserting active pane changes to the ranked agent pane
- mojibake/replacement-character checks (`�` must not appear)

## Agent testing rule

If a behavior can be done by a human in tmux, it must have a programmatic harness path. Prefer direct tmux commands and structural assertions over visual/manual inspection. If a behavior is not yet accessible programmatically, create a task to add harness coverage before relying on manual testing.

## Failure output

Harness output is TAP-like:

```text
ok 1 build
not ok 2 sidebar opens
# <diagnostic dump>
```

On failure, use `HOPPERS_TEST_KEEP=1` and rerun the failing case. Add missing diagnostics to the harness before fixing the product bug.
