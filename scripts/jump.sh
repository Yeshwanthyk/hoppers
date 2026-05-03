#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
rank="${1:?rank required}"
exec "$ROOT/scripts/start.sh" jump "$rank"
