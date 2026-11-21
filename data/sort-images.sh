#!/bin/bash

# This script splits Rancher images into bootstrap and required sets.
# BOOTSTRAP contains one image version per repository (latest tag).
# REQUIRED contains every remaining image/version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to the image list in the same directory as this script.
# This supports both: ./data/sort-images.sh and (cd data && ./sort-images.sh)
INPUT_LIST="${1:-$SCRIPT_DIR/rancher-images.txt}"
OUTPUT_DIR="${2:-$SCRIPT_DIR}"

# If a relative path was provided, try resolving it from the script directory too.
if [[ "$INPUT_LIST" != /* ]] && [[ ! -f "$INPUT_LIST" ]] && [[ -f "$SCRIPT_DIR/$INPUT_LIST" ]]; then
    INPUT_LIST="$SCRIPT_DIR/$INPUT_LIST"
fi

if [[ "$OUTPUT_DIR" != /* ]] && [[ ! -d "$OUTPUT_DIR" ]] && [[ -d "$SCRIPT_DIR/$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/$OUTPUT_DIR"
fi

if [ ! -f "$INPUT_LIST" ]; then
    echo "Error: Image list file not found: $INPUT_LIST"
    exit 1
fi

BOOTSTRAP_FILE="${OUTPUT_DIR}/bootstrap-images.txt"
REQUIRED_FILE="${OUTPUT_DIR}/required-images.txt"

# Always reset output files so each run starts clean.
: > "$BOOTSTRAP_FILE"
: > "$REQUIRED_FILE"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

CLEAN_LIST="$TMP_DIR/clean-images.txt"
PAIRS_FILE="$TMP_DIR/repo-tag.tsv"
SORTED_FILE="$TMP_DIR/repo-tag-sorted.tsv"

echo "Selecting bootstrap and required images..."

# Keep non-empty, non-comment lines only.
grep -vE '^[[:space:]]*(#|$)' "$INPUT_LIST" > "$CLEAN_LIST"

# Skip Helm chart packages. They are listed in rancher-images.txt, but they are
# not Docker images and cannot be pulled or pushed with the registry workflow.
grep -vE '^rancher/charts/' "$CLEAN_LIST" > "$TMP_DIR/image-only.txt"
mv "$TMP_DIR/image-only.txt" "$CLEAN_LIST"

# Split image into repository and tag at the last colon.
# Expected input format: repository:tag
awk '
{
    line=$0
    tag=line
    sub(/^.*:/, "", tag)
    repo=line
    sub(/:[^:]*$/, "", repo)
    if (repo != "" && tag != "") {
        print repo "\t" tag
    }
}
' "$CLEAN_LIST" > "$PAIRS_FILE"

# Sort by repository and then by tag version (ascending), remove duplicates.
sort -u -t $'\t' -k1,1 -k2,2V "$PAIRS_FILE" > "$SORTED_FILE"

# For each repository, keep the latest tag for bootstrap and the rest for required.
awk -v bootstrap_file="$BOOTSTRAP_FILE" -v required_file="$REQUIRED_FILE" -F'\t' '
function flush_repo() {
    if (current_repo == "") {
        return
    }
    if (latest != "") {
        print current_repo ":" latest > bootstrap_file
    }
    if (tags_count > 1) {
        for (i = 1; i <= tags_count - 1; i++) {
            print current_repo ":" tags[i] > required_file
        }
    }
}
{
    repo=$1
    tag=$2

    if (repo != current_repo) {
        flush_repo()
        current_repo=repo
        latest=""
        tags_count=0
        delete tags
    }

    latest=tag
    tags[++tags_count]=tag
}
END {
    flush_repo()
}
' "$SORTED_FILE"

# Sort outputs and remove duplicates.
sort -u "$BOOTSTRAP_FILE" -o "$BOOTSTRAP_FILE"
sort -u "$REQUIRED_FILE" -o "$REQUIRED_FILE"

repo_count=$(cut -f1 "$SORTED_FILE" | uniq | wc -l | tr -d ' ')
bootstrap_count=$(wc -l < "$BOOTSTRAP_FILE")
required_count=$(wc -l < "$REQUIRED_FILE")
total=$((bootstrap_count + required_count))

echo ""
echo "========== IMAGE SORTING COMPLETE =========="
echo "Repositories processed:                  $repo_count"
echo "BOOTSTRAP (one per repo):                $bootstrap_count images"
echo "REQUIRED (remaining images):             $required_count images"
echo "----------------------------------------"
echo "TOTAL WRITTEN:                           $total images"
echo ""
echo "Output files:"
echo "  $BOOTSTRAP_FILE"
echo "  $REQUIRED_FILE"
echo ""
