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
jump_relative_script="$(shell_quote "$CURRENT_DIR/scripts/jump-relative.sh")"
log_path="$(shell_quote "$LOG_PATH")"

hoppers_prefix_key="$(tmux show-option -gqv @hoppers-prefix-key)"
hoppers_prefix_key="${hoppers_prefix_key:-Space}"
hoppers_focus_keys="$(tmux show-option -gqv @hoppers-focus-global-keys)"
legacy_focus_key="$(tmux show-option -gqv @hoppers-focus-global-key)"
hoppers_focus_keys="${hoppers_focus_keys:-$legacy_focus_key}"
hoppers_index_keys="$(tmux show-option -gqv @hoppers-index-keys)"
hoppers_agent_prev_key="$(tmux show-option -gqv @hoppers-agent-prev-key)"
legacy_project_prev_key="$(tmux show-option -gqv @hoppers-project-prev-key)"
hoppers_agent_prev_key="${hoppers_agent_prev_key:-$legacy_project_prev_key}"
hoppers_agent_prev_key="${hoppers_agent_prev_key:-S-Up}"
hoppers_agent_next_key="$(tmux show-option -gqv @hoppers-agent-next-key)"
legacy_project_next_key="$(tmux show-option -gqv @hoppers-project-next-key)"
hoppers_agent_next_key="${hoppers_agent_next_key:-$legacy_project_next_key}"
hoppers_agent_next_key="${hoppers_agent_next_key:-S-Down}"

tmux bind-key "$hoppers_prefix_key" run-shell -b "$sidebar_script open-focus >$log_path 2>&1"

if [ -n "$hoppers_agent_prev_key" ]; then
  tmux bind-key -n "$hoppers_agent_prev_key" run-shell -b "$jump_relative_script prev >$log_path 2>&1"
fi
if [ -n "$hoppers_agent_next_key" ]; then
  tmux bind-key -n "$hoppers_agent_next_key" run-shell -b "$jump_relative_script next >$log_path 2>&1"
fi
tmux set-hook -g client-session-changed "run-shell -b \"$sidebar_script sync >$log_path 2>&1\""

for key in $hoppers_focus_keys; do
  tmux bind-key -n "$key" run-shell -b "$toggle_script >$log_path 2>&1"
done

idx=1
for key in $hoppers_index_keys; do
  tmux bind-key -n "$key" run-shell -b "$jump_script $idx >$log_path 2>&1"
  idx=$((idx + 1))
done
