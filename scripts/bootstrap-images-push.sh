#!/bin/bash
# =============================================================================
# PUSH BOOTSTRAP IMAGES TO PRIVATE REGISTRY
# Runs ON the registry node (called from deploy.sh via SSH).
# Pulls bootstrap images from Docker Hub and pushes them to localhost:5000.
# Expected time: ~10-15 minutes (depends on network speed).
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/bootstrap-images-push.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="/tmp/bootstrap-images-push.log"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*"; }

IMAGE_LIST="${1:-/opt/image-lists/bootstrap-images.txt}"
REGISTRY="${2:-localhost:5000}"
REGISTRY_USER="${3:-admin}"
REGISTRY_PASS="${4}"
SOURCE_REGISTRY="${5:-}"

SOURCE_REGISTRY="${SOURCE_REGISTRY%/}"

if [ -z "${REGISTRY_PASS:-}" ]; then
  log "ERROR: Registry password required as 4th argument"
  exit 1
fi

log "=== Pushing Bootstrap Images ==="
log "Log file  : $LOG_FILE"
log "Registry  : $REGISTRY"
log "Image list: $IMAGE_LIST"
log "Images    : $(wc -l < "$IMAGE_LIST")"
if [ -n "$SOURCE_REGISTRY" ]; then
  log "Source    : prefer $SOURCE_REGISTRY (fallback to original image)"
fi

# Log in to registry
echo "$REGISTRY_PASS" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin
log "Logged in to $REGISTRY"

TOTAL=$(grep -c . "$IMAGE_LIST" || true)
PUSHED=0
FAILED=0
FAILED_IMAGES=""

while IFS= read -r IMAGE; do
  [ -z "$IMAGE" ] && continue
  [[ "$IMAGE" == \#* ]] && continue

  DEST="$REGISTRY/$IMAGE"
  PULL_REF="$IMAGE"

  log "[$((PUSHED+FAILED+1))/$TOTAL] Pulling: $IMAGE"
  if [ -n "$SOURCE_REGISTRY" ]; then
    PRIME_REF="$SOURCE_REGISTRY/$IMAGE"
    if docker pull "$PRIME_REF" 2>/dev/null; then
      PULL_REF="$PRIME_REF"
    elif ! docker pull "$IMAGE" 2>/dev/null; then
      warn "  ✗ Pull failed: $PRIME_REF and fallback $IMAGE"
      FAILED_IMAGES="$FAILED_IMAGES\n  $IMAGE"
      ((FAILED++)) || true
      continue
    fi
  elif ! docker pull "$IMAGE" 2>/dev/null; then
    warn "  ✗ Pull failed: $IMAGE"
    FAILED_IMAGES="$FAILED_IMAGES\n  $IMAGE"
    ((FAILED++)) || true
    continue
  fi

  docker tag "$PULL_REF" "$DEST"
  if docker push "$DEST" 2>/dev/null; then
    log "  ✓ Pushed: $DEST"
    ((PUSHED++)) || true
  else
    warn "  ✗ Push failed: $DEST"
    FAILED_IMAGES="$FAILED_IMAGES\n  $IMAGE"
    ((FAILED++)) || true
  fi
  # Clean up local image to save disk space
  docker rmi "$PULL_REF" "$DEST" 2>/dev/null || true
  if [ "$PULL_REF" != "$IMAGE" ]; then
    docker rmi "$IMAGE" 2>/dev/null || true
  fi
done < "$IMAGE_LIST"

log ""
log "=== Tier-1 Push Summary ==="
log "  Pushed : $PUSHED"
log "  Failed : $FAILED"
log "  Total  : $TOTAL"

if [ "$FAILED" -gt 0 ]; then
  warn "Failed images:$FAILED_IMAGES"
  log "These images can be retried later. Rancher may still start with most tier-1 images."
fi

log "Bootstrap image push complete. Rancher can now be installed."
