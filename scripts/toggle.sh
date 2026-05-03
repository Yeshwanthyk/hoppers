#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIDTH="$(tmux show-option -gqv @hoppers-width || true)"
WIDTH="${WIDTH:-38}"
TITLE="hoppers-sidebar"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

current_window="${HOPPERS_TARGET_WINDOW:-$(tmux display-message -p '#{window_id}')}"
existing="$(tmux list-panes -t "$current_window" -F '#{pane_id}|#{pane_title}|#{pane_start_command}' | awk -F'|' -v title="$TITLE" '$2 == title || ($3 ~ /start\.sh/ && $3 ~ /sidebar/) { print $1; exit }')"

if [ -n "$existing" ]; then
  tmux kill-pane -t "$existing"
  exit 0
fi

tmux_socket="${HOPPERS_TMUX_SOCKET:-$(tmux display-message -p '#{socket_path}')}"
tmux_env="$tmux_socket,0,0"
quoted_socket="$(shell_quote "$tmux_socket")"
quoted_tmux="$(shell_quote "$tmux_env")"
quoted_start="$(shell_quote "$ROOT/scripts/start.sh")"
command="HOPPERS_TMUX_SOCKET=$quoted_socket TMUX=$quoted_tmux exec $quoted_start sidebar"

pane="$(tmux split-window -t "$current_window" -h -b -l "$WIDTH" -P -F '#{pane_id}' "$command")"
tmux select-pane -t "$pane" -T "$TITLE"
