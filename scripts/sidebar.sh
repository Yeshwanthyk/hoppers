#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIDTH="$(tmux show-option -gqv @hoppers-width || true)"
WIDTH="${WIDTH:-38}"
TITLE="hoppers-sidebar"
STATE_OPTION="@hoppers-sidebar-enabled"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

find_sidebar() {
  local target_window="$1"
  tmux list-panes -t "$target_window" -F '#{pane_id}|#{pane_title}|#{pane_start_command}' \
    | awk -F'|' -v title="$TITLE" '$2 == title || ($3 ~ /start\.sh/ && $3 ~ /sidebar/) { print $1; exit }'
}

open_sidebar() {
  local current_window="$1"
  local existing
  existing="$(find_sidebar "$current_window")"
  [ -n "$existing" ] && return 0

  local tmux_socket tmux_env quoted_socket quoted_tmux quoted_start command pane
  tmux_socket="${HOPPERS_TMUX_SOCKET:-$(tmux display-message -p '#{socket_path}')}"
  tmux_env="$tmux_socket,0,0"
  quoted_socket="$(shell_quote "$tmux_socket")"
  quoted_tmux="$(shell_quote "$tmux_env")"
  quoted_start="$(shell_quote "$ROOT/scripts/start.sh")"
  command="HOPPERS_TMUX_SOCKET=$quoted_socket TMUX=$quoted_tmux exec $quoted_start sidebar"

  pane="$(tmux split-window -t "$current_window" -h -b -l "$WIDTH" -P -F '#{pane_id}' "$command")"
  tmux select-pane -t "$pane" -T "$TITLE"
}

close_sidebar() {
  local current_window="$1"
  local existing
  existing="$(find_sidebar "$current_window")"
  [ -n "$existing" ] && tmux kill-pane -t "$existing"
}

current_window="${HOPPERS_TARGET_WINDOW:-$(tmux display-message -p '#{window_id}')}"
command="${1:-toggle}"

case "$command" in
  open)
    tmux set-option -gq "$STATE_OPTION" on
    open_sidebar "$current_window"
    ;;
  close)
    tmux set-option -gq "$STATE_OPTION" off
    close_sidebar "$current_window"
    ;;
  sync)
    if [ "$(tmux show-option -gqv "$STATE_OPTION")" = "on" ]; then
      open_sidebar "$current_window"
    fi
    ;;
  toggle)
    if [ -n "$(find_sidebar "$current_window")" ]; then
      tmux set-option -gq "$STATE_OPTION" off
      close_sidebar "$current_window"
    else
      tmux set-option -gq "$STATE_OPTION" on
      open_sidebar "$current_window"
    fi
    ;;
  *)
    echo "usage: sidebar.sh [toggle|open|close|sync]" >&2
    exit 2
    ;;
esac
