#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE="all"
KEEP="${HOPPERS_TEST_KEEP:-0}"
if [ "${1:-}" = "--case" ]; then
  CASE="${2:?missing case name}"
fi

SOCK="hoppers-test-$$"
SESSION="hoppers-test"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hoppers-test.XXXXXX")"
LOG="$TMP/hoppers-tmux.log"
TMUX_ENV=""
TMUX_SOCKET=""
COUNT=0
FAILED=0
SIDEBAR_PORT1=""
SIDEBAR_PORT2=""

cleanup() {
  if [ "$KEEP" != "1" ]; then
    tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP"
  else
    echo "# keeping tmux socket $SOCK and tmp $TMP"
  fi
}
trap cleanup EXIT

ok() { COUNT=$((COUNT + 1)); echo "ok $COUNT $1"; }
not_ok() { COUNT=$((COUNT + 1)); FAILED=1; echo "not ok $COUNT $1"; shift; for line in "$@"; do echo "# $line"; done; }
contains() { printf '%s' "$1" | grep -Fq "$2"; }
not_contains() { ! printf '%s' "$1" | grep -Fq "$2"; }

run_checked() {
  local label="$1"; shift
  if "$@" >"$TMP/$label.out" 2>"$TMP/$label.err"; then
    ok "$label"
  else
    not_ok "$label" "$(cat "$TMP/$label.err")"
  fi
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

build() {
  run_checked build zig build
}

start_tmux() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  : > "$TMP/panes.env"
  tmux -L "$SOCK" -f /dev/null new-session -d -s "$SESSION" -n main -c "$ROOT" 'exec zsh'
  tmux -L "$SOCK" new-session -d -s hoppers-other -n main -c "$ROOT" 'exec zsh'
  TMUX_SOCKET="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
  TMUX_ENV="$TMUX_SOCKET,0,0"
  tmux -L "$SOCK" set-environment -g HOPPERS_TMUX_LOG "$LOG"
}

spawn_agent() {
  local name="$1"
  local title="$2"
  local dir="${3:-$TMP/$name-project}"
  local port="${4:-}"
  local agent_session="hoppers-$name"
  mkdir -p "$dir"
  if [ ! -d "$dir/.git" ] && ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$dir" init -q
  fi
  git -C "$dir" checkout -B "${name}-branch" >/dev/null 2>&1 || true
  printf '%s\n' "$name dirty" > "$dir/hoppers-dirty.txt"
  if [ -n "$port" ]; then
    tmux -L "$SOCK" new-session -d -s "$agent_session" -c "$dir" "exec bash -lc 'exec -a $name python3 -c '\''import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"127.0.0.1\", $port)); s.listen(); time.sleep(600)'\'''"
    local attempt
    for attempt in {1..50}; do
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && break
      sleep 0.1
    done
  else
    tmux -L "$SOCK" new-session -d -s "$agent_session" -c "$dir" "exec bash -lc 'exec -a $name sleep 600'"
  fi
  local pane
  pane="$(tmux -L "$SOCK" display-message -p -t "$agent_session":0.0 '#{pane_id}')"
  tmux -L "$SOCK" select-pane -t "$pane" -T "$title"
  printf '%s=%s\n' "$name" "$pane" >> "$TMP/panes.env"
}

setup_shared_worktrees() {
  local shared="$TMP/shared-project"
  mkdir -p "$shared"
  git -C "$shared" init -q
  git -C "$shared" checkout -B shared-main >/dev/null 2>&1
  git -C "$shared" config user.email hoppers@example.test
  git -C "$shared" config user.name hoppers
  printf 'base\n' > "$shared/README.md"
  git -C "$shared" add README.md
  git -C "$shared" commit -qm base
  local worktree="$TMP/shared-worktree"
  git -C "$shared" worktree add -q -b shared-worktree "$worktree"
  printf '%s\n%s\n' "$shared" "$worktree"
}

setup_agents() {
  start_tmux
  spawn_agent claude 'Claude task'
  spawn_agent codex 'Codex task'
  spawn_agent opencode 'opencode task'
  spawn_agent pi 'Pi task'
  spawn_agent marvin 'Marvin task'
}

setup_sidebar_agents() {
  start_tmux
  local paths shared worktree
  paths="$(setup_shared_worktrees)"
  shared="$(printf '%s\n' "$paths" | sed -n '1p')"
  worktree="$(printf '%s\n' "$paths" | sed -n '2p')"
  SIDEBAR_PORT1="$(free_port)"
  SIDEBAR_PORT2="$(free_port)"
  spawn_agent pi 'Pi task' "$shared" "$SIDEBAR_PORT1"
  spawn_agent codex 'Codex task' "$worktree" "$SIDEBAR_PORT2"
}

snapshot_case() {
  setup_agents
  local output
  output="$(HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" $ROOT/scripts/start.sh snapshot)"
  contains "$output" 'hoppers · project cockpit' && ok 'snapshot header' || not_ok 'snapshot header' "$output"
  contains "$output" 'claude' && ok 'snapshot detects claude' || not_ok 'snapshot detects claude' "$output"
  contains "$output" 'codex' && ok 'snapshot detects codex' || not_ok 'snapshot detects codex' "$output"
  contains "$output" 'opencode' && ok 'snapshot detects opencode' || not_ok 'snapshot detects opencode' "$output"
  not_contains "$output" '�' && ok 'snapshot has no replacement chars' || not_ok 'snapshot has no replacement chars' "$output"
}

plugin_case() {
  start_tmux
  if TMUX="$TMUX_ENV" "$ROOT/hoppers.tmux" >"$TMP/source.out" 2>"$TMP/source.err"; then
    ok 'plugin sources'
  else
    not_ok 'plugin sources' "$(cat "$TMP/source.err")"
    return
  fi
  local keys
  sleep 1
  keys="$(tmux -L "$SOCK" list-keys -T prefix Space 2>/dev/null || true)"
  contains "$keys" 'sidebar.sh' && contains "$keys" 'open-focus' && ok 'plugin binds sidebar focus' || not_ok 'plugin binds sidebar focus' "$keys" "$(cat "$LOG" 2>/dev/null || true)"
  HOPPERS_TARGET_WINDOW="$(tmux -L "$SOCK" display-message -p -t "$SESSION":main '#{window_id}')" HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" "$ROOT/scripts/sidebar.sh" open-focus >"$LOG" 2>&1
  local active_pane
  active_pane="$(tmux -L "$SOCK" display-message -p -t "$SESSION":main '#{pane_title}|#{pane_start_command}')"
  contains "$active_pane" 'hoppers-sidebar' && ok 'sidebar focus command selects sidebar' || not_ok 'sidebar focus command selects sidebar' "$active_pane" "$(cat "$LOG" 2>/dev/null || true)"
  keys="$(tmux -L "$SOCK" list-keys -T root S-Down 2>/dev/null || true)"
  contains "$keys" 'jump-relative.sh' && ok 'plugin binds agent jump keys' || not_ok 'plugin binds agent jump keys' "$keys"
}

sidebar_case() {
  setup_sidebar_agents
  tmux -L "$SOCK" switch-client -t "$SESSION" 2>/dev/null || true
  TMUX="$TMUX_ENV" "$ROOT/hoppers.tmux"
  local target_window
  target_window="$(tmux -L "$SOCK" display-message -p -t "$SESSION":main '#{window_id}')"
  HOPPERS_TARGET_WINDOW="$target_window" HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" "$ROOT/scripts/toggle.sh" >"$LOG" 2>&1
  sleep 2
  local panes sidebar
  panes="$(tmux -L "$SOCK" list-panes -t "$SESSION":main -F '#{pane_id}|#{pane_title}|#{pane_current_command}|#{pane_start_command}')"
  sidebar="$(printf '%s\n' "$panes" | awk -F'|' '$2 == "hoppers-sidebar" || ($4 ~ /start\.sh/ && $4 ~ /sidebar/) { print $1; exit }')"
  [ -n "$sidebar" ] && ok 'sidebar opens' || { not_ok 'sidebar opens' "$panes" "$(cat "$LOG" 2>/dev/null || true)"; return; }
  sleep 4
  tmux -L "$SOCK" list-panes -t "$SESSION":main -F '#{pane_id}' | grep -Fq "$sidebar" && ok 'sidebar stays alive' || not_ok 'sidebar stays alive' "$(cat "$LOG" 2>/dev/null || true)"
  local capture
  capture="$(tmux -L "$SOCK" capture-pane -p -t "$sidebar" -S -80)"
  not_contains "$capture" 'project cockpit' && ok 'sidebar omits header chrome' || not_ok 'sidebar omits header chrome' "$capture"
  contains "$capture" 'codex' && ok 'sidebar detects codex' || not_ok 'sidebar detects codex' "$capture"
  contains "$capture" 'idle' && not_contains "$capture" '|>' && ok 'sidebar shows idle without active glyphs' || not_ok 'sidebar shows idle without active glyphs' "$capture"
  contains "$capture" '1 pi' && ok 'sidebar shows selection row' || not_ok 'sidebar shows selection row' "$capture"
  contains "$capture" 'enter jump' && ok 'sidebar footer visible' || not_ok 'sidebar footer visible' "$capture"
  contains "$capture" 'shared-project' && not_contains "$capture" 'shared-worktree' && ok 'sidebar groups worktrees by project' || not_ok 'sidebar groups worktrees by project' "$capture"
  contains "$capture" 'pi-branch*' && ok 'sidebar shows dirty branch subgroup' || not_ok 'sidebar shows dirty branch subgroup' "$capture"
  contains "$capture" 'codex-branch* wt' && ok 'sidebar shows worktree subgroup' || not_ok 'sidebar shows worktree subgroup' "$capture"
  contains "$capture" ":$SIDEBAR_PORT1" && contains "$capture" ":$SIDEBAR_PORT2" && ok 'sidebar shows subgroup ports' || not_ok 'sidebar shows subgroup ports' "$capture"
  target_window="$(tmux -L "$SOCK" display-message -p -t hoppers-other:main '#{window_id}')"
  HOPPERS_TARGET_WINDOW="$target_window" HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" "$ROOT/scripts/sidebar.sh" sync >"$LOG" 2>&1
  sleep 1
  tmux -L "$SOCK" list-panes -t hoppers-other:main -F '#{pane_title}|#{pane_start_command}' | grep -Eq 'hoppers-sidebar|start\.sh.*sidebar' && ok 'sidebar follows session' || not_ok 'sidebar follows session' "$(tmux -L "$SOCK" list-panes -t hoppers-other:main -F '#{pane_title}|#{pane_start_command}')" "$(cat "$LOG" 2>/dev/null || true)"
  not_contains "$capture" '�' && ok 'sidebar has no replacement chars' || not_ok 'sidebar has no replacement chars' "$capture"
  not_contains "$capture" '^[' && ok 'sidebar has no raw escape text' || not_ok 'sidebar has no raw escape text' "$capture"
}

daemon_case() {
  setup_agents
  local sock="$TMP/hoppersd.sock"
  HOPPERSD_SOCKET="$sock" HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" $ROOT/scripts/start.sh daemon start
  local attempt
  for attempt in {1..50}; do
    [ -S "$sock" ] && break
    sleep 0.1
  done
  local pong output
  pong="$(HOPPERSD_SOCKET="$sock" $ROOT/scripts/start.sh daemon ping)"
  [ "$pong" = 'pong' ] && ok 'daemon ping' || not_ok 'daemon ping' "$pong"
  output="$(HOPPERSD_SOCKET="$sock" HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" $ROOT/scripts/start.sh daemon snapshot)"
  contains "$output" 'hoppers · project cockpit' && contains "$output" 'claude' && contains "$output" 'codex' && ok 'daemon snapshot includes harness panes' || not_ok 'daemon snapshot includes harness panes' "$output"
  HOPPERSD_SOCKET="$sock" $ROOT/scripts/start.sh notify refresh && ok 'notify refresh' || not_ok 'notify refresh'
  HOPPERSD_SOCKET="$sock" $ROOT/scripts/start.sh daemon stop || true
  output="$(HOPPERSD_SOCKET="$sock" HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" $ROOT/scripts/start.sh snapshot)"
  not_contains "$output" 'running' && not_contains "$output" 'failed' && not_contains "$output" 'done' && ok 'daemon down fallback does not guess status' || not_ok 'daemon down fallback does not guess status' "$output"
}

daemon_isolation_case() {
  start_tmux
  local path_one path_two
  path_one="$(HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" $ROOT/scripts/start.sh daemon path)"
  local sock2="hoppers-test-other-$$"
  tmux -L "$sock2" -f /dev/null new-session -d -s other -n main -c "$ROOT" 'exec zsh'
  local tmux_socket2 tmux_env2
  tmux_socket2="$(tmux -L "$sock2" display-message -p '#{socket_path}')"
  tmux_env2="$tmux_socket2,0,0"
  path_two="$(HOPPERS_TMUX_SOCKET="$tmux_socket2" TMUX="$tmux_env2" $ROOT/scripts/start.sh daemon path)"
  tmux -L "$sock2" kill-server >/dev/null 2>&1 || true
  [ "$path_one" != "$path_two" ] && ok 'daemon socket path is tmux isolated' || not_ok 'daemon socket path is tmux isolated' "one=$path_one two=$path_two"
}

raw_text_no_status_case() {
  setup_agents
  tmux -L "$SOCK" select-pane -t "$(awk -F= '$1 == "claude" { print $2 }' "$TMP/panes.env")" -T 'running failed done complete error executing waiting ready'
  tmux -L "$SOCK" send-keys -t "$(awk -F= '$1 == "codex" { print $2 }' "$TMP/panes.env")" 'printf "failed done running\\n"' Enter
  sleep 1
  local output
  output="$(HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" $ROOT/scripts/start.sh snapshot)"
  not_contains "$output" 'running' && not_contains "$output" 'failed' && not_contains "$output" 'done' && ok 'raw text does not infer active or terminal status' || not_ok 'raw text does not infer active or terminal status' "$output"
}

jump_case() {
  setup_agents
  local target
  target="$(awk -F= '$1 == "marvin" { print $2 }' "$TMP/panes.env")"
  if HOPPERS_TMUX_SOCKET="$TMUX_SOCKET" TMUX="$TMUX_ENV" "$ROOT/scripts/start.sh" jump 1 >"$TMP/jump.out" 2>"$TMP/jump.err"; then
    ok 'jump exits successfully'
  else
    not_ok 'jump exits successfully' "$(cat "$TMP/jump.err")"
    return
  fi
  local active
  active="$(tmux -L "$SOCK" display-message -p '#{pane_id}')"
  [ "$active" = "$target" ] && ok 'jump selects ranked pane' || not_ok 'jump selects ranked pane' "active=$active target=$target"
}

case "$CASE" in
  all) build; snapshot_case; plugin_case; sidebar_case; daemon_case; daemon_isolation_case; raw_text_no_status_case; jump_case ;;
  build) build ;;
  snapshot) build; snapshot_case ;;
  plugin) plugin_case ;;
  sidebar) build; sidebar_case ;;
  daemon) build; daemon_case ;;
  daemon-isolation) build; daemon_isolation_case ;;
  raw-text-no-status) build; raw_text_no_status_case ;;
  jump) build; jump_case ;;
  *) echo "unknown case: $CASE" >&2; exit 2 ;;
esac

if [ "$FAILED" -ne 0 ]; then
  echo "# failed; tmp=$TMP"
  exit 1
fi
