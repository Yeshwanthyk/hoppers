#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_PATH="${HOPPERS_TMUX_LOG:-/tmp/hoppers-tmux.log}"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

toggle_script="$(shell_quote "$CURRENT_DIR/scripts/toggle.sh")"
sidebar_script="$(shell_quote "$CURRENT_DIR/scripts/sidebar.sh")"
jump_script="$(shell_quote "$CURRENT_DIR/scripts/jump.sh")"
jump_project_script="$(shell_quote "$CURRENT_DIR/scripts/jump-project.sh")"
log_path="$(shell_quote "$LOG_PATH")"

hoppers_prefix_key="$(tmux show-option -gqv @hoppers-prefix-key)"
hoppers_prefix_key="${hoppers_prefix_key:-Space}"
hoppers_focus_keys="$(tmux show-option -gqv @hoppers-focus-global-keys)"
legacy_focus_key="$(tmux show-option -gqv @hoppers-focus-global-key)"
hoppers_focus_keys="${hoppers_focus_keys:-$legacy_focus_key}"
hoppers_index_keys="$(tmux show-option -gqv @hoppers-index-keys)"

tmux bind-key "$hoppers_prefix_key" run-shell -b "$sidebar_script open-focus >$log_path 2>&1"

tmux bind-key -n S-Up run-shell -b "$jump_project_script prev >$log_path 2>&1"
tmux bind-key -n S-Down run-shell -b "$jump_project_script next >$log_path 2>&1"
tmux set-hook -g client-session-changed "run-shell -b \"$sidebar_script sync >$log_path 2>&1\""

for key in $hoppers_focus_keys; do
  tmux bind-key -n "$key" run-shell -b "$toggle_script >$log_path 2>&1"
done

idx=1
for key in $hoppers_index_keys; do
  tmux bind-key -n "$key" run-shell -b "$jump_script $idx >$log_path 2>&1"
  idx=$((idx + 1))
done
