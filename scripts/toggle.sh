#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WIDTH="$(tmux show-option -gqv @hoppers-width || true)"
WIDTH="${WIDTH:-38}"
TITLE="hoppers-sidebar"

current_window="$(tmux display-message -p '#{window_id}')"
existing="$(tmux list-panes -t "$current_window" -F '#{pane_id} #{pane_title}' | awk -v title="$TITLE" '$2 == title { print $1; exit }')"

if [ -n "$existing" ]; then
  tmux kill-pane -t "$existing"
  exit 0
fi

pane="$(tmux split-window -h -b -l "$WIDTH" -P -F '#{pane_id}' "$ROOT/scripts/start.sh sidebar")"
tmux select-pane -t "$pane" -T "$TITLE"
