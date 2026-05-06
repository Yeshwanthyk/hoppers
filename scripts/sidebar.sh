#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIDTH="$(tmux show-option -gqv @hoppers-width || true)"
WIDTH="${WIDTH:-38}"
TITLE="hoppers-sidebar"
STATE_OPTION="@hoppers-sidebar-enabled"
PANE_OPTION="@hoppers-sidebar-pane"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

pane_exists() {
  [ -n "$1" ] && tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

pane_window() {
  tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null || true
}

sidebar_panes() {
  tmux list-panes -a -F '#{pane_id}|#{@hoppers-sidebar-root}|#{pane_title}|#{pane_start_command}' \
    | awk -F'|' -v root="$ROOT" -v title="$TITLE" \
      '$2 == root || ($2 == "" && ($3 == title || ($4 ~ /start\.sh/ && $4 ~ /sidebar/))) { print $1 }'
}

find_sidebar_global() {
  local stored panes
  stored="$(tmux show-option -gqv "$PANE_OPTION" || true)"
  if pane_exists "$stored"; then
    printf '%s\n' "$stored"
    return 0
  fi
  panes="$(sidebar_panes)"
  printf '%s\n' "$panes" | sed '/^$/d' | head -n 1
}

cleanup_extra_sidebars() {
  local keep="$1"
  sidebar_panes | while IFS= read -r pane; do
    [ -n "$pane" ] && [ "$pane" != "$keep" ] && tmux kill-pane -t "$pane" 2>/dev/null || true
  done
}

start_sidebar() {
  local target_window="$1"
  local tmux_socket tmux_env quoted_socket quoted_tmux quoted_start command pane
  tmux_socket="${HOPPERS_TMUX_SOCKET:-$(tmux display-message -p '#{socket_path}')}"
  tmux_env="$tmux_socket,0,0"
  quoted_socket="$(shell_quote "$tmux_socket")"
  quoted_tmux="$(shell_quote "$tmux_env")"
  quoted_start="$(shell_quote "$ROOT/scripts/start.sh")"
  command="HOPPERS_TMUX_SOCKET=$quoted_socket TMUX=$quoted_tmux exec $quoted_start sidebar"

  pane="$(tmux split-window -t "$target_window" -h -b -l "$WIDTH" -P -F '#{pane_id}' "$command")"
  tmux select-pane -t "$pane" -T "$TITLE"
  tmux set-option -pt "$pane" -q @hoppers-sidebar-root "$ROOT"
  tmux set-option -gq "$PANE_OPTION" "$pane"
  printf '%s\n' "$pane"
}

move_sidebar_to_window() {
  local pane="$1"
  local target_window="$2"
  local current_window
  current_window="$(pane_window "$pane")"
  if [ -z "$current_window" ]; then
    return 1
  fi
  if [ "$current_window" != "$target_window" ]; then
    tmux join-pane -h -b -l "$WIDTH" -s "$pane" -t "$target_window"
  fi
  tmux select-pane -t "$pane" -T "$TITLE"
  tmux set-option -pt "$pane" -q @hoppers-sidebar-root "$ROOT"
  tmux set-option -gq "$PANE_OPTION" "$pane"
}

ensure_sidebar() {
  local target_window="$1"
  local pane
  pane="$(find_sidebar_global || true)"
  if pane_exists "$pane"; then
    cleanup_extra_sidebars "$pane"
    move_sidebar_to_window "$pane" "$target_window"
    printf '%s\n' "$pane"
    return 0
  fi
  pane="$(start_sidebar "$target_window")"
  cleanup_extra_sidebars "$pane"
  printf '%s\n' "$pane"
}

close_sidebar() {
  local pane
  pane="$(find_sidebar_global || true)"
  tmux set-option -gq "$STATE_OPTION" off
  tmux set-option -gq -u "$PANE_OPTION" 2>/dev/null || true
  [ -n "$pane" ] && tmux kill-pane -t "$pane" 2>/dev/null || true
  cleanup_extra_sidebars ""
}

current_window="${HOPPERS_TARGET_WINDOW:-$(tmux display-message -p '#{window_id}')}"
command="${1:-toggle}"

lock_name="hoppers-sidebar-$(tmux display-message -p '#{socket_path}' | shasum | awk '{print $1}')"
tmux wait-for -L "$lock_name"
trap 'tmux wait-for -U "$lock_name"' EXIT

case "$command" in
  open)
    active_pane="$(tmux display-message -p -t "$current_window" '#{pane_id}')"
    tmux set-option -gq "$STATE_OPTION" on
    ensure_sidebar "$current_window" >/dev/null
    pane_exists "$active_pane" && tmux select-pane -t "$active_pane" 2>/dev/null || true
    ;;
  open-focus)
    tmux set-option -gq "$STATE_OPTION" on
    sidebar_pane="$(ensure_sidebar "$current_window")"
    [ -n "$sidebar_pane" ] && tmux select-pane -t "$sidebar_pane"
    ;;
  close)
    close_sidebar
    ;;
  pane-exited)
    exited_pane="${2:-}"
    stored="$(tmux show-option -gqv "$PANE_OPTION" || true)"
    if [ -n "$exited_pane" ] && [ "$exited_pane" = "$stored" ]; then
      tmux set-option -gq "$STATE_OPTION" off
      tmux set-option -gq -u "$PANE_OPTION" 2>/dev/null || true
    fi
    ;;
  sync)
    active_pane="$(tmux display-message -p -t "$current_window" '#{pane_id}')"
    if [ "$(tmux show-option -gqv "$STATE_OPTION")" = "on" ]; then
      ensure_sidebar "$current_window" >/dev/null
      pane_exists "$active_pane" && tmux select-pane -t "$active_pane" 2>/dev/null || true
    else
      pane="$(find_sidebar_global || true)"
      [ -n "$pane" ] && cleanup_extra_sidebars "$pane"
    fi
    ;;
  toggle)
    sidebar_pane="$(find_sidebar_global || true)"
    active_pane="$(tmux display-message -p -t "$current_window" '#{pane_id}')"
    if [ -n "$sidebar_pane" ] && [ "$active_pane" = "$sidebar_pane" ]; then
      close_sidebar
      exit 0
    fi
    tmux set-option -gq "$STATE_OPTION" on
    sidebar_pane="$(ensure_sidebar "$current_window")"
    [ -n "$sidebar_pane" ] && tmux select-pane -t "$sidebar_pane"
    ;;
  *)
    echo "usage: sidebar.sh [toggle|open|open-focus|close|sync|pane-exited]" >&2
    exit 2
    ;;
esac
