#!/bin/bash
# =============================================================================
# PUSH REMAINING IMAGES (REQUIRED)
# Runs ON the registry node (called from deploy.sh, runs in the background).
# Rancher is already up at this point.
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/push-remaining-images.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="/tmp/push-remaining-images.log"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*"; }

REGISTRY="${1:-localhost:5000}"
REGISTRY_USER="${2:-admin}"
REGISTRY_PASS="${3}"
IMAGE_LIST_DIR="${4:-/opt/image-lists}"
SOURCE_REGISTRY="${5:-}"

SOURCE_REGISTRY="${SOURCE_REGISTRY%/}"

if [ -z "${REGISTRY_PASS:-}" ]; then
  log "ERROR: Registry password required"
  exit 1
fi

push_list() {
  local list_name="$1"
  local list_file="$2"

  if [ ! -f "$list_file" ]; then
    warn "Image list not found: $list_file — skipping $list_name"
    return 0
  fi

  local total pushed failed
  total=$(grep -c . "$list_file" || echo 0)
  pushed=0; failed=0

  log "=== $list_name: $total images ==="

  while IFS= read -r IMAGE; do
    [ -z "$IMAGE" ] && continue
    [[ "$IMAGE" == \#* ]] && continue

    DEST="$REGISTRY/$IMAGE"
    PULL_REF="$IMAGE"
    if [ -n "$SOURCE_REGISTRY" ]; then
      PRIME_REF="$SOURCE_REGISTRY/$IMAGE"
      if docker pull "$PRIME_REF" 2>/dev/null; then
        PULL_REF="$PRIME_REF"
      elif ! docker pull "$IMAGE" 2>/dev/null; then
        warn "Pull failed: $PRIME_REF and fallback $IMAGE"
        ((failed++)) || true
        continue
      fi
    elif ! docker pull "$IMAGE" 2>/dev/null; then
      warn "Pull failed: $IMAGE"
      ((failed++)) || true
      continue
    fi

    docker tag "$PULL_REF" "$DEST"
    if docker push "$DEST" 2>/dev/null; then
      ((pushed++)) || true
    else
      warn "Push failed: $DEST"
      ((failed++)) || true
    fi
    docker rmi "$PULL_REF" "$DEST" 2>/dev/null || true
    if [ "$PULL_REF" != "$IMAGE" ]; then
      docker rmi "$IMAGE" 2>/dev/null || true
    fi
  done < "$list_file"

  log "$list_name complete: pushed=$pushed failed=$failed total=$total"
}

# Log in
echo "$REGISTRY_PASS" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin

log "=== Background image push started (Rancher is already running) ==="
log "This process runs in the background. Tail $LOG_FILE to monitor."
if [ -n "$SOURCE_REGISTRY" ]; then
  log "Using source registry preference: $SOURCE_REGISTRY"
fi

push_list "REQUIRED" "$IMAGE_LIST_DIR/required-images.txt"

log "=== All required images pushed. Air-gap setup is fully complete! ==="
