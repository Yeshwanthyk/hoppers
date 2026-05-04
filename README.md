# hoppers

A Zig/libvaxis tmux cockpit for monitoring and jumping between agent panes.

## Install with TPM

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'Yeshwanthyk/hoppers'
```

Install with TPM:

```text
prefix I
```

Build once from the plugin directory:

```sh
cd ~/.tmux/plugins/hoppers
zig build
```

Source tmux config or restart tmux:

```sh
tmux source-file ~/.tmux.conf
```

## Keys

Default tmux prefix in your config may differ. Use your tmux prefix before `Space`.

```text
prefix Space s      toggle sidebar
prefix Space j      jump next ranked agent
prefix Space k      jump previous ranked agent
prefix Space 1..9   jump exact ranked agent
prefix Space q      cancel
Shift-Up            jump previous project
Shift-Down          jump next project
```

Inside the sidebar:

```text
j      jump next agent
k      jump previous agent
r      refresh
q      close sidebar
```

## Development

```sh
zig build test
zig build lint
zig build
scripts/test-tmux-harness.sh
```
