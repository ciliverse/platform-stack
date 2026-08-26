#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing '$1' in PATH. Install it first." >&2
    exit 1
  fi
}

need helm
need helmfile
# ./scripts/apply.sh -e kind  →  helmfile -e kind apply
exec helmfile "$@" apply
