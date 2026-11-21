#!/bin/bash
# =============================================================================
# ZEGRESS : ZERO EGRESS SETUP FOR SECURE AI
# RANCHER AIR-GAP DESTROY
# Tears down ALL AWS resources created by deploy.sh.
# This is irreversible — all EC2 instances, NLBs, DNS records will be deleted.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/utils.sh"

TFVARS="$SCRIPT_DIR/config.tfvars"
TFDIR="$SCRIPT_DIR/terraform"

log_step "RANCHER AIR-GAP DESTROY"
log_warn "This will permanently delete ALL AWS resources created by deploy.sh."
log_warn "EC2 instances, NLBs, DNS records, EBS volumes — everything."
echo ""

read -p "Type 'yes' to confirm destruction: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  log_info "Destruction cancelled."
  exit 0
fi

cd "$TFDIR"

log_step "Running terraform destroy..."
terraform destroy \
  -var-file="$TFVARS" \
  -auto-approve \
  -no-color \
  2>&1 | tee "$SCRIPT_DIR/logs/terraform-destroy.log"

# Clean up generated local files
log_step "Cleaning up local files..."
rm -f "$SCRIPT_DIR/ssh-key.pem"
rm -f "$SCRIPT_DIR/.deploy-state"
rm -f "$SCRIPT_DIR/.deploy-state.lock"
rm -f "$SCRIPT_DIR/logs/terraform-apply.log"
rm -f "$SCRIPT_DIR/logs/terraform-init.log"
rm -f "$SCRIPT_DIR/logs/bootstrap-images-push.log"
rm -f "$SCRIPT_DIR/logs/install-rancher.log"
rm -f "$SCRIPT_DIR/logs/push-remaining-images.log"
rm -f "$SCRIPT_DIR/logs/registry-bootstrap.log"

log_info "All resources destroyed."
log_info "The data/ directory and image lists are preserved."
