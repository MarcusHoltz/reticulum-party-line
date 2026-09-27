#!/bin/sh
# Validates Dockerfile pins: each pip ==version pin must exist on PyPI.
#
# Read-only: reports findings, never modifies anything.
#
# Requires: curl, jq
#   Alpine:  apk add --no-cache curl jq
#   Ubuntu:  pre-installed on GitHub Actions runners
#
# exit 0  all pins valid and resolvable
# exit 1  missing pip version or missing prerequisite

set -eu

ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
DOCKERFILE="${DOCKERFILE:-$ROOT/Dockerfile}"

log() { echo "audit-pins: $*" >&2; }

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { log "required: $cmd"; exit 1; }
done

if [ ! -f "$DOCKERFILE" ]; then
    log "no Dockerfile at $DOCKERFILE"
    exit 1
fi

log "checking $DOCKERFILE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0

# ── Check pip version pins ──────────────────────────────────────────

grep -oE '[a-zA-Z][a-zA-Z0-9_-]*==[0-9][0-9a-zA-Z._]*' "$DOCKERFILE" \
    > "$WORK/pippins" 2>/dev/null || true

while IFS= read -r pin; do
    [ -z "$pin" ] && continue
    pkg="${pin%%==*}"
    ver="${pin#*==}"

    code=$(curl -sS -o /dev/null -w '%{http_code}' \
        "https://pypi.org/pypi/$pkg/$ver/json" 2>/dev/null) || code="000"

    if [ "$code" = "200" ]; then
        log "OK: $pkg==$ver on PyPI"
    else
        log "FAIL: $pkg==$ver not found on PyPI (HTTP $code)"
        fail=1
    fi
done < "$WORK/pippins"

# ── Result ──────────────────────────────────────────────────────────

if [ "$fail" -ne 0 ]; then
    log "validation failed; see findings above"
    exit 1
fi

log "all pins valid"
