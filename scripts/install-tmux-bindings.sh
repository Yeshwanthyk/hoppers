#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_PATH="${HOPPERS_TMUX_LOG:-/tmp/hoppers-tmux.log}"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\''/g")"
}

toggle_script="$(shell_quote "$CURRENT_DIR/scripts/toggle.sh")"
jump_script="$(shell_quote "$CURRENT_DIR/scripts/jump.sh")"
jump_relative_script="$(shell_quote "$CURRENT_DIR/scripts/jump-relative.sh")"
jump_project_script="$(shell_quote "$CURRENT_DIR/scripts/jump-project.sh")"
log_path="$(shell_quote "$LOG_PATH")"

hoppers_prefix_key="$(tmux show-option -gqv @hoppers-prefix-key)"
hoppers_prefix_key="${hoppers_prefix_key:-Space}"
hoppers_focus_keys="$(tmux show-option -gqv @hoppers-focus-global-keys)"
legacy_focus_key="$(tmux show-option -gqv @hoppers-focus-global-key)"
hoppers_focus_keys="${hoppers_focus_keys:-$legacy_focus_key}"
hoppers_index_keys="$(tmux show-option -gqv @hoppers-index-keys)"

tmux bind-key "$hoppers_prefix_key" switch-client -T hoppers \; display-message 'hoppers: s sidebar · j/k agent · S-Up/S-Down project · 1..9 rank'

tmux bind-key -T hoppers s run-shell -b "$toggle_script >$log_path 2>&1"
tmux bind-key -T hoppers j run-shell -b "$jump_relative_script next >$log_path 2>&1"
tmux bind-key -T hoppers k run-shell -b "$jump_relative_script prev >$log_path 2>&1"
tmux bind-key -T hoppers S-Up run-shell -b "$jump_project_script prev >$log_path 2>&1"
tmux bind-key -T hoppers S-Down run-shell -b "$jump_project_script next >$log_path 2>&1"
tmux bind-key -n S-Up run-shell -b "$jump_project_script prev >$log_path 2>&1"
tmux bind-key -n S-Down run-shell -b "$jump_project_script next >$log_path 2>&1"
tmux bind-key -T hoppers q switch-client -T root
tmux bind-key -T hoppers Escape switch-client -T root

for idx in 1 2 3 4 5 6 7 8 9; do
  tmux bind-key -T hoppers "$idx" run-shell -b "$jump_script $idx >$log_path 2>&1"
done

for key in $hoppers_focus_keys; do
  tmux bind-key -n "$key" run-shell -b "$toggle_script >$log_path 2>&1"
done

idx=1
for key in $hoppers_index_keys; do
  tmux bind-key -n "$key" run-shell -b "$jump_script $idx >$log_path 2>&1"
  idx=$((idx + 1))
done
