#!/bin/bash

# Staged Rancher Image Loading Script
# Loads images in priority order: BOOTSTRAP → REQUIRED
# Allows pausing between stages to verify Rancher startup

set -e

# Configuration
BOOTSTRAP_LIST="bootstrap-images.txt"
REQUIRED_LIST="required-images.txt"
IMAGES_TAR="rancher-images.tar.gz"
TARGET_REGISTRY=""
SOURCE_REGISTRY=""
SKIP_BOOTSTRAP=false
LOAD_ALL=false

usage() {
    echo "USAGE: $0 --registry my.registry.com:5000 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -r|--registry REGISTRY          Target registry (required)"
    echo "  -s|--source-registry REGISTRY   Source registry (optional)"
    echo "  -i|--images PATH                Path to rancher-images.tar.gz"
    echo "  -b|--bootstrap-list PATH        Bootstrap image list"
    echo "  -R|--required-list PATH         Required image list"
    echo "  --skip-bootstrap                Skip bootstrap stage (for resume scenarios)"
    echo "  --load-all                      Load all images without pause"
    echo "  -h|--help                       Show this message"
    echo ""
    echo "EXAMPLES:"
    echo "  # Load bootstrap images only, then pause for verification:"
    echo "  $0 --registry private.registry:5000"
    echo ""
    echo "  # Load all images without pausing:"
    echo "  $0 --registry private.registry:5000 --load-all"
    echo ""
    echo "  # Resume from required images (bootstrap already loaded):"
    echo "  $0 --registry private.registry:5000 --skip-bootstrap"
}

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

log_header() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ $1"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

load_images_from_tar() {
    local list_file="$1"
    local stage_name="$2"
    local image_count
    image_count=$(wc -l < "$list_file")

    log_header "STAGE: $stage_name ($image_count images)"

    if [ ! -f "$IMAGES_TAR" ]; then
        log_error "Image tar file not found: $IMAGES_TAR"
        return 1
    fi

    log_info "Extracting and loading images from $IMAGES_TAR..."

    local loaded=0
    local failed=0

    while IFS= read -r image; do
        [ -z "$image" ] && continue
        [ "${image:0:1}" = "#" ] && continue

        ((loaded++))

        if tar -tzf "$IMAGES_TAR" "${image}.tar" > /dev/null 2>&1; then
            log_info "[$loaded/$image_count] Loading: $image"
            tar -xzf "$IMAGES_TAR" "${image}.tar" -O | docker load > /dev/null 2>&1

            if [ -n "$TARGET_REGISTRY" ]; then
                docker tag "$image" "$TARGET_REGISTRY/$image" 2>/dev/null || true
                docker push "$TARGET_REGISTRY/$image" 2>/dev/null || {
                    log_warn "Failed to push: $image"
                    ((failed++))
                }
            fi
        else
            log_warn "[$loaded/$image_count] Image tar not found: ${image}.tar"
            ((failed++))
        fi
    done < "$list_file"

    echo ""
    log_info "$stage_name complete: Loaded $((loaded - failed))/$image_count images"
    if [ $failed -gt 0 ]; then
        log_warn "Failed: $failed images"
    fi
    echo ""

    return $((failed > 0 ? 1 : 0))
}

prompt_continue() {
    local stage_name="$1"
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ $stage_name loaded successfully                             ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "⏸️  PAUSE: $stage_name has been loaded."
    echo ""
    echo "Recommended: Check Rancher UI status before proceeding:"
    echo "  - Verify Rancher pod is running"
    echo "  - Confirm UI is accessible"
    echo "  - Check pod logs for errors"
    echo ""
    echo "Continue loading next stage? (yes/no/skip-remaining)"
    read -p "> " response

    case "$response" in
        yes|y)
            return 0
            ;;
        no|n)
            log_info "Exiting. Remaining images not loaded."
            exit 0
            ;;
        skip*)
            return 2
            ;;
        *)
            log_warn "Invalid response. Exiting."
            exit 1
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--registry)
            TARGET_REGISTRY="$2"
            shift 2
            ;;
        -s|--source-registry)
            SOURCE_REGISTRY="$2"
            shift 2
            ;;
        -i|--images)
            IMAGES_TAR="$2"
            shift 2
            ;;
        -b|--bootstrap-list)
            BOOTSTRAP_LIST="$2"
            shift 2
            ;;
        -R|--required-list)
            REQUIRED_LIST="$2"
            shift 2
            ;;
        --skip-bootstrap)
            SKIP_BOOTSTRAP=true
            shift
            ;;
        --load-all)
            LOAD_ALL=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$TARGET_REGISTRY" ]; then
    log_error "Registry is required"
    usage
    exit 1
fi

for list in "$BOOTSTRAP_LIST" "$REQUIRED_LIST"; do
    if [ ! -f "$list" ]; then
        log_warn "Image list not found: $list"
        log_info "Run sort-images.sh first to generate bootstrap/required lists"
        exit 1
    fi
done

log_header "STAGED RANCHER IMAGE LOADING"
log_info "Target Registry: $TARGET_REGISTRY"
log_info "Load All Images: $LOAD_ALL"
echo ""

if [ "$SKIP_BOOTSTRAP" = false ]; then
    load_images_from_tar "$BOOTSTRAP_LIST" "BOOTSTRAP"

    if [ "$LOAD_ALL" = false ]; then
        prompt_continue "BOOTSTRAP"
        result=$?
        if [ $result -eq 2 ]; then
            log_info "Skipping bootstrap pause..."
        fi
    fi
else
    log_info "Skipping BOOTSTRAP (already loaded)"
fi

load_images_from_tar "$REQUIRED_LIST" "REQUIRED"

log_header "IMAGE LOADING COMPLETE"
log_info "All requested images have been loaded to $TARGET_REGISTRY"
echo ""
