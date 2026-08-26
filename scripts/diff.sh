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

if ! helm plugin list 2>/dev/null | grep -q '^diff'; then
  echo "helm-diff plugin not installed. Install: helm plugin install https://github.com/databus23/helm-diff" >&2
  echo "Or preview with: helmfile template $*" >&2
  exit 1
fi

# ./scripts/diff.sh -e kind  →  helmfile -e kind diff
exec helmfile "$@" diff
