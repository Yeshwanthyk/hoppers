#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/hoppers"

needs_build=false
if [ ! -x "$BIN" ]; then
  needs_build=true
elif find "$ROOT/src" "$ROOT/build.zig" "$ROOT/build.zig.zon" -newer "$BIN" -print -quit | grep -q .; then
  needs_build=true
fi

if [ "$needs_build" = true ]; then
  if command -v zig >/dev/null 2>&1; then
    echo "building hoppers..." >&2
    (cd "$ROOT" && zig build -Doptimize=ReleaseSafe)
  else
    echo "hoppers requires a prebuilt binary or zig on PATH" >&2
    exit 127
  fi
fi

if [ "$#" -eq 0 ]; then
  set -- sidebar
fi

export HOPPERS_ROOT="$ROOT"
exec "$BIN" "$@"
