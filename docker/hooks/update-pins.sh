#!/bin/sh
# Updates digest-pinned base images and pip version pins in the
# Dockerfile. Refuses to adopt anything published more recently than
# MIN_AGE_DAYS (default: 7). Snapshots the Dockerfile before any
# changes and restores it on failure.
#
# After updating, runs docker/hooks/audit-pins.sh against the result. If
# the audit fails, the original Dockerfile is restored.
#
# Requires: curl, jq
#   Alpine:  apk add --no-cache curl jq
#   Ubuntu:  pre-installed on GitHub Actions runners
#
# exit 0  Dockerfile passed audit (updated or already current)
# exit 1  something failed; Dockerfile is byte-for-byte what it was

set -eu

MIN_AGE_DAYS="${MIN_AGE_DAYS:-7}"
ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
DOCKERFILE="${DOCKERFILE:-$ROOT/Dockerfile}"

log() { echo "update-pins: $*" >&2; }

for cmd in curl jq sed; do
    command -v "$cmd" >/dev/null 2>&1 || { log "required: $cmd"; exit 1; }
done

if [ ! -f "$DOCKERFILE" ]; then
    log "no Dockerfile at $DOCKERFILE"
    exit 1
fi

# ── Snapshot and restore ────────────────────────────────────────────
# Same pattern as PartylinePager's hooks/update-cargo-deps.sh:
# snapshot before touching anything, restore on every failure path
# including Ctrl-C.

WORK=$(mktemp -d)
SNAPSHOT="$WORK/Dockerfile.snapshot"
cp "$DOCKERFILE" "$SNAPSHOT"
SNAPSHOT_KEEP=0

restore() {
    if cmp -s "$SNAPSHOT" "$DOCKERFILE"; then
        return 0
    fi
    if cp "$SNAPSHOT" "$DOCKERFILE"; then
        log "Dockerfile restored to its pre-update contents"
    else
        log "COULD NOT RESTORE Dockerfile"
        log "your pre-update copy is at: $SNAPSHOT"
        SNAPSHOT_KEEP=1
    fi
}

cleanup() {
    if [ "$SNAPSHOT_KEEP" -eq 1 ]; then
        rm -f "$WORK/from" "$WORK/pippins" 2>/dev/null || true
    else
        rm -rf "$WORK"
    fi
}

trap 'cleanup' EXIT
trap 'echo >&2; log "interrupted"; restore; cleanup; exit 130' INT
trap 'log "terminated"; restore; cleanup; exit 143' TERM

# ── Helpers ─────────────────────────────────────────────────────────

hub_token() {
    curl -fsSL \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" \
        | jq -r '.token'
}

# Current manifest-list digest for a tag (what the tag points at now).
registry_digest() {
    local repo="$1" tag="$2"
    local token
    token=$(hub_token "$repo") || { echo ""; return; }
    curl -sS -I \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://registry-1.docker.io/v2/$repo/manifests/$tag" 2>/dev/null \
        | grep -i 'docker-content-digest' | tr -d '\r' | awk '{print $2}' || true
}

# Publish date for a tag from Docker Hub (not the registry API, which
# has no dates). Returns an ISO 8601 timestamp or empty.
hub_tag_date() {
    local repo="$1" tag="$2"
    curl -fsSL "https://hub.docker.com/v2/repositories/$repo/tags/$tag" 2>/dev/null \
        | jq -r '.last_updated // .tag_last_pushed // empty' 2>/dev/null || true
}

# Days since an ISO 8601 timestamp. Returns -1 on parse failure.
age_days() {
    local ts="$1"
    jq -n --arg ts "$ts" '
        ($ts | sub("\\.[0-9]+[Zz]?$"; "") | sub("[Zz]$"; "")
             | sub("[+-][0-9]{2}:[0-9]{2}$"; "")
             | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $pub |
        ((now - $pub) / 86400) | floor
    ' 2>/dev/null || echo "-1"
}

# ── Update Docker image pins ────────────────────────────────────────

log "checking base image digests (min age: ${MIN_AGE_DAYS}d)"

grep -i '^[[:space:]]*FROM ' "$DOCKERFILE" > "$WORK/from" || true

already_checked=""
updated_images=""
held_images=""

while IFS= read -r line; do
    [ -z "$line" ] && continue

    ref=$(echo "$line" \
        | sed 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]*//' \
        | sed 's/[[:space:]]*[Aa][Ss][[:space:]].*$//')

    echo "$ref" | grep -q '@sha256:' || continue

    image_tag="${ref%%@*}"
    old_digest="${ref#*@}"

    # Deduplicate (tor has the same FROM twice)
    case " $already_checked " in
        *" $image_tag "*) continue ;;
    esac
    already_checked="$already_checked $image_tag"

    image="${image_tag%%:*}"
    tag="${image_tag#*:}"

    case "$image" in
        */*) repo="$image" ;;
        *)   repo="library/$image" ;;
    esac

    current_digest=$(registry_digest "$repo" "$tag")
    if [ -z "$current_digest" ]; then
        log "SKIP: could not fetch digest for $image_tag"
        continue
    fi

    if [ "$current_digest" = "$old_digest" ]; then
        log "CURRENT: $image_tag"
        continue
    fi

    # Newer digest exists. Check its age before adopting.
    pub_date=$(hub_tag_date "$repo" "$tag")
    if [ -z "$pub_date" ]; then
        log "SKIP: could not get publish date for $image_tag (refusing without age check)"
        held_images="$held_images $image_tag"
        continue
    fi

    age=$(age_days "$pub_date")
    if [ "$age" -lt 0 ]; then
        log "SKIP: could not parse date for $image_tag (refusing without age check)"
        held_images="$held_images $image_tag"
        continue
    fi

    if [ "$age" -lt "$MIN_AGE_DAYS" ]; then
        log "HOLD: $image_tag newer digest is only ${age}d old (need ${MIN_AGE_DAYS}d)"
        held_images="$held_images $image_tag"
        continue
    fi

    log "UPDATE: $image_tag (${age}d old)"
    log "  old: $old_digest"
    log "  new: $current_digest"
    sed -i "s|@${old_digest}|@${current_digest}|g" "$DOCKERFILE"
    updated_images="$updated_images $image_tag"
done < "$WORK/from"

# ── Update pip version pins ─────────────────────────────────────────

grep -oE '[a-zA-Z][a-zA-Z0-9_-]*==[0-9][0-9a-zA-Z._]*' "$DOCKERFILE" \
    > "$WORK/pippins" 2>/dev/null || true

updated_pip=""

while IFS= read -r pin; do
    [ -z "$pin" ] && continue
    pkg="${pin%%==*}"
    ver="${pin#*==}"

    latest=$(curl -fsSL "https://pypi.org/pypi/$pkg/json" 2>/dev/null \
        | jq -r '.info.version // empty' 2>/dev/null || true)
    if [ -z "$latest" ]; then
        log "SKIP: could not query PyPI for $pkg"
        continue
    fi

    if [ "$latest" = "$ver" ]; then
        log "CURRENT: $pkg==$ver"
        continue
    fi

    upload_time=$(curl -fsSL "https://pypi.org/pypi/$pkg/$latest/json" 2>/dev/null \
        | jq -r '.urls[0].upload_time_iso_8601 // empty' 2>/dev/null || true)
    if [ -z "$upload_time" ]; then
        log "SKIP: could not get upload time for $pkg==$latest (refusing without age check)"
        continue
    fi

    age=$(age_days "$upload_time")
    if [ "$age" -lt 0 ]; then
        log "SKIP: could not parse date for $pkg==$latest"
        continue
    fi

    if [ "$age" -lt "$MIN_AGE_DAYS" ]; then
        log "HOLD: $pkg==$latest available but only ${age}d old (need ${MIN_AGE_DAYS}d)"
        continue
    fi

    log "UPDATE: $pkg $ver -> $latest (${age}d old)"
    sed -i "s|${pkg}==${ver}|${pkg}==${latest}|g" "$DOCKERFILE"
    updated_pip="$updated_pip $pkg"
done < "$WORK/pippins"

# ── Post-update audit ───────────────────────────────────────────────

if ! cmp -s "$SNAPSHOT" "$DOCKERFILE"; then
    log "Dockerfile modified, auditing the result"
    if ! "$ROOT/docker/hooks/audit-pins.sh"; then
        restore
        log "post-update audit failed; changes discarded"
        exit 1
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────

if cmp -s "$SNAPSHOT" "$DOCKERFILE"; then
    if [ -n "$held_images" ]; then
        log "no updates applied (held:$held_images)"
    else
        log "Dockerfile was already current"
    fi
else
    log "Dockerfile updated and passed audit"
    [ -n "$updated_images" ] && log "  images:$updated_images"
    [ -n "$updated_pip" ] && log "  packages:$updated_pip"
fi
