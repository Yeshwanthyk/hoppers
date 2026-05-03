#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_PATH="${HOPPERS_TMUX_LOG:-/tmp/hoppers-tmux.log}"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

start_script="$(shell_quote "$CURRENT_DIR/scripts/start.sh")"
toggle_script="$(shell_quote "$CURRENT_DIR/scripts/toggle.sh")"
jump_script="$(shell_quote "$CURRENT_DIR/scripts/jump.sh")"
log_path="$(shell_quote "$LOG_PATH")"

hoppers_prefix_key="$(tmux show-option -gqv @hoppers-prefix-key)"
hoppers_prefix_key="${hoppers_prefix_key:-h}"
hoppers_focus_key="$(tmux show-option -gqv @hoppers-focus-global-key)"
hoppers_index_keys="$(tmux show-option -gqv @hoppers-index-keys)"

tmux bind-key "$hoppers_prefix_key" display-menu \
  "Hoppers sidebar" s "run-shell -b \"$toggle_script >$log_path 2>&1\"" \
  "Hoppers snapshot" p "display-popup -E \"$start_script snapshot; printf '\\\\nPress enter...'; read -r dummy\"" \
  "Hoppers jump 1" 1 "run-shell -b \"$jump_script 1 >$log_path 2>&1\"" \
  "Hoppers jump 2" 2 "run-shell -b \"$jump_script 2 >$log_path 2>&1\"" \
  "Hoppers jump 3" 3 "run-shell -b \"$jump_script 3 >$log_path 2>&1\""

if [ -n "$hoppers_focus_key" ]; then
  tmux bind-key -n "$hoppers_focus_key" run-shell -b "$toggle_script >$log_path 2>&1"
fi

idx=1
for key in $hoppers_index_keys; do
  tmux bind-key -n "$key" run-shell -b "$jump_script $idx >$log_path 2>&1"
  idx=$((idx + 1))
done
