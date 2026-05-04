# hoppers

A small tmux cockpit for agent panes. It gives you a persistent sidebar, ranked agent selection, and project-to-project navigation without leaving tmux.

Built with Zig and libvaxis.

## Install with TPM

Add hoppers to `~/.tmux.conf` before TPM is initialized:

```tmux
set -g @plugin 'Yeshwanthyk/hoppers'

run '~/.tmux/plugins/tpm/tpm'
```

Install plugins from inside tmux:

```text
prefix I
```

Build the binary in the plugin checkout:

```sh
cd ~/.tmux/plugins/hoppers
zig build
```

Reload tmux so the plugin installs its bindings:

```sh
tmux source-file ~/.tmux.conf
```

After updating hoppers with TPM, rebuild and reload:

```sh
cd ~/.tmux/plugins/hoppers
git pull
zig build
tmux run-shell ~/.tmux/plugins/hoppers/hoppers.tmux
```

## Default keys

`prefix` means your tmux prefix key. For example, if your prefix is `C-a`, press `C-a Space`.

```text
prefix Space        open/focus the sidebar
Shift-Up            jump to previous project
Shift-Down          jump to next project
```

Inside the sidebar:

```text
j / k               move selection
1..9                select ranked agent
Enter               jump to selected agent
r                   refresh
f                   cycle filter: all, hot, active
q                   close sidebar
```

## Configuration

Configure hoppers with tmux options. Put these before TPM initialization in `~/.tmux.conf`.

```tmux
set -g @plugin 'Yeshwanthyk/hoppers'

# Open/focus sidebar with: prefix Space
set -g @hoppers-prefix-key 'Space'

# Sidebar width in columns
set -g @hoppers-width '38'

# Project navigation. Leave empty to disable.
set -g @hoppers-project-prev-key 'S-Up'
set -g @hoppers-project-next-key 'S-Down'

# Optional raw/global sidebar toggle keys. Empty by default.
set -g @hoppers-focus-global-keys ''

# Optional raw/global direct rank keys. Empty by default.
# Example: set -g @hoppers-index-keys 'M-1 M-2 M-3'
set -g @hoppers-index-keys ''

run '~/.tmux/plugins/tpm/tpm'
```

### Examples

Use `prefix g` instead of `prefix Space`:

```tmux
set -g @hoppers-prefix-key 'g'
```

Disable Shift-Up/Shift-Down project jumps:

```tmux
set -g @hoppers-project-prev-key ''
set -g @hoppers-project-next-key ''
```

Use global rank jumps if they do not conflict with your tmux config:

```tmux
set -g @hoppers-index-keys 'M-1 M-2 M-3 M-4 M-5'
```

## Development

```sh
zig build test
zig build lint
zig build
scripts/test-tmux-harness.sh
```
