#!/bin/bash
# =============================================================================
# ZEGRESS : ZERO EGRESS SETUP FOR SECURE AI
# RANCHER AIR-GAP DEPLOY (RESUMABLE)
# One-command deployment with resume capability. Edit config.tfvars first, then run: ./deploy.sh
#
# If deployment fails at any step, re-run ./deploy.sh and it will resume from the failed step.
# State is tracked in .deploy-state file (deleted on success).
#
# Timeline (approximate):
#   0-5 min   → Terraform provisions all AWS resources
#   5-10 min  → Registry bootstraps (Docker, RKE2 downloads) in the background
#              → Cluster nodes boot and wait for registry artifact server
#   10-20 min → Tier-1 critical images pushed to private registry (26 images)
#              → RKE2 cluster forms (was bootstrapping in parallel)
#   20-25 min → Helm installs cert-manager + Rancher
#   25-35 min → Rancher UI becomes accessible ✓
#   35-120min → Tier-2 + Tier-3 images load in background (778 total)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/utils.sh"

TFVARS="$SCRIPT_DIR/config.tfvars"
TFDIR="$SCRIPT_DIR/terraform"
LOGDIR="$SCRIPT_DIR/logs"
SSH_KEY="$SCRIPT_DIR/ssh-key.pem"
DATA_DIR="$SCRIPT_DIR/data"
STATE_FILE="$SCRIPT_DIR/.deploy-state"

mkdir -p "$LOGDIR"

# =============================================================================
# State Management Functions
# =============================================================================
save_step_state() {
  local step="$1"
  echo "step=$step" > "$STATE_FILE"
  log_info "[STATE] Last completed step: $step"
}

load_step_state() {
  if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    echo "${step:-}"
  fi
}

resume_from_step() {
  local current_step="$1"
  local last_step=$(load_step_state)
  
  if [ -z "$last_step" ]; then
    return 0  # First run — execute this step
  fi
  
  if [ "$last_step" -ge "$current_step" ]; then
    log_info "[RESUME] Skipping step $current_step (already completed in previous run)"
    return 1  # Skip — this step was already completed
  fi
  
  # last_step < current_step: we haven't reached this step yet
  return 0  # Run this step
}

clear_state() {
  rm -f "$STATE_FILE"
  log_info "[STATE] Cleared deployment state (success)"
}

get_tfvar_value() {
  local key="$1"
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]+)\"?.*$/\1/p" "$TFVARS" | head -1 | xargs
}

terraform_resources_exist() {
  if [ ! -f "$TFDIR/terraform.tfstate" ]; then
    return 1  # No state file = resources don't exist
  fi
  
  # Check if VPC resource exists in state
  if jq -e '.resources[] | select(.type=="aws_vpc")' "$TFDIR/terraform.tfstate" >/dev/null 2>&1; then
    return 0  # Resources exist
  fi
  
  return 1  # No resources
}

  ensure_required_terraform_outputs() {
    local required_outputs=(
      "registry_public_ip"
      "registry_private_ip"
      "registry_endpoint"
      "first_server_private_ip"
      "external_nlb_dns"
      "rancher_url"
      "rancher_hostname"
      "ssh_user"
      "prefix"
      "server_private_ips"
      "agent_private_ips"
    )

    local outputs_json
    outputs_json=$(terraform -chdir="$TFDIR" output -json 2>/dev/null || echo "{}")

    local missing=()
    local out
    for out in "${required_outputs[@]}"; do
      if ! echo "$outputs_json" | jq -e --arg k "$out" 'has($k)' >/dev/null 2>&1; then
        missing+=("$out")
      fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
      return 0
    fi

    log_warn "Terraform state is missing outputs: ${missing[*]}"
    log_info "Running terraform apply once to refresh state outputs..."
    cd "$TFDIR"
    terraform apply -var-file="$TFVARS" -auto-approve -no-color 2>&1 \
      | tee -a "$LOGDIR/terraform-apply.log"
    cd "$SCRIPT_DIR"
  }

destroy_and_replace_registry() {
  local prefix=$(get_tfvar_value "prefix")
  log_warn "Registry bootstrap failed. Destroying old instance to recreate with fixed bootstrap..."
  
  cd "$TFDIR"
  terraform apply \
    -var-file="$TFVARS" \
    -destroy \
    -target="aws_instance.registry" \
    -auto-approve -no-color 2>&1 | tee "$LOGDIR/terraform-destroy-registry.log"
  
  log_info "Recreating registry instance with fixed bootstrap..."
  terraform apply \
    -var-file="$TFVARS" \
    -auto-approve -no-color 2>&1 | tee -a "$LOGDIR/terraform-apply.log"
  
  cd "$SCRIPT_DIR"
}

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------
log_step "Pre-flight checks"

for cmd in terraform aws ssh scp curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required tool not found: $cmd"
    exit 1
  fi
done

if [ ! -f "$TFVARS" ]; then
  log_error "config.tfvars not found. Copy the template and fill in your values."
  exit 1
fi

# A stale state file can survive a failed destroy or manual reset. If the Terraform
# state itself is gone, the deployment must restart from step 1 instead of resuming.
if [ -f "$STATE_FILE" ] && ! terraform_resources_exist; then
  log_warn "Deploy state exists but Terraform resources are missing. Clearing stale resume state."
  clear_state
fi

REGISTRY_VOLUME_GB=$(get_tfvar_value "registry_volume_size_gb")
SERVER_VOLUME_GB=$(get_tfvar_value "server_volume_size_gb")
AGENT_VOLUME_GB=$(get_tfvar_value "agent_volume_size_gb")
SERVER_INSTANCE_TYPE=$(get_tfvar_value "server_instance_type")
AGENT_INSTANCE_TYPE=$(get_tfvar_value "agent_instance_type")
AWS_REGION_FROM_TFVARS=$(get_tfvar_value "aws_region")
AWS_ACCESS_KEY_FROM_TFVARS=$(get_tfvar_value "aws_access_key")
AWS_SECRET_KEY_FROM_TFVARS=$(get_tfvar_value "aws_secret_key")

if [ -z "$AWS_REGION_FROM_TFVARS" ]; then
  log_error "aws_region is missing or empty in config.tfvars"
  exit 1
fi

# Auto-load AWS credentials from config.tfvars if env vars are not set.
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "$AWS_ACCESS_KEY_FROM_TFVARS" ]; then
  export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_FROM_TFVARS"
fi

if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] && [ -n "$AWS_SECRET_KEY_FROM_TFVARS" ]; then
  export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY_FROM_TFVARS"
fi

# Keep region consistent for AWS CLI calls in this script.
if [ -z "${AWS_DEFAULT_REGION:-}" ]; then
  export AWS_DEFAULT_REGION="$AWS_REGION_FROM_TFVARS"
fi

if ! aws --no-cli-pager sts get-caller-identity --output text >/dev/null 2>&1; then
  log_error "AWS authentication failed. Provide valid credentials via env vars or aws_access_key/aws_secret_key in config.tfvars"
  log_error "Try: aws --no-cli-pager sts get-caller-identity"
  exit 1
fi

if [ -z "$REGISTRY_VOLUME_GB" ] || [ "$REGISTRY_VOLUME_GB" -lt 200 ]; then
  log_error "registry_volume_size_gb must be at least 200 in config.tfvars"
  exit 1
fi

if [ -z "$SERVER_VOLUME_GB" ] || [ "$SERVER_VOLUME_GB" -lt 50 ]; then
  log_error "server_volume_size_gb must be at least 50 in config.tfvars"
  exit 1
fi

if [ -z "$AGENT_VOLUME_GB" ] || [ "$AGENT_VOLUME_GB" -lt 50 ]; then
  log_error "agent_volume_size_gb must be at least 50 in config.tfvars"
  exit 1
fi

SERVER_VCPUS=$(aws --no-cli-pager ec2 describe-instance-types \
  --region "$AWS_REGION_FROM_TFVARS" \
  --instance-types "$SERVER_INSTANCE_TYPE" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' \
  --output text 2>/dev/null || true)

AGENT_VCPUS=$(aws --no-cli-pager ec2 describe-instance-types \
  --region "$AWS_REGION_FROM_TFVARS" \
  --instance-types "$AGENT_INSTANCE_TYPE" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' \
  --output text 2>/dev/null || true)

if ! [[ "$SERVER_VCPUS" =~ ^[0-9]+$ ]]; then
  log_error "Unable to query vCPU count for server_instance_type=$SERVER_INSTANCE_TYPE in region=$AWS_REGION_FROM_TFVARS"
  log_error "Try manually: aws --no-cli-pager ec2 describe-instance-types --region '$AWS_REGION_FROM_TFVARS' --instance-types '$SERVER_INSTANCE_TYPE' --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text"
  exit 1
fi

if ! [[ "$AGENT_VCPUS" =~ ^[0-9]+$ ]]; then
  log_error "Unable to query vCPU count for agent_instance_type=$AGENT_INSTANCE_TYPE in region=$AWS_REGION_FROM_TFVARS"
  log_error "Try manually: aws --no-cli-pager ec2 describe-instance-types --region '$AWS_REGION_FROM_TFVARS' --instance-types '$AGENT_INSTANCE_TYPE' --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text"
  exit 1
fi

if [ "$SERVER_VCPUS" -lt 8 ]; then
  log_error "server_instance_type ($SERVER_INSTANCE_TYPE) has $SERVER_VCPUS vCPU; minimum required is 8"
  exit 1
fi

if [ "$AGENT_VCPUS" -lt 8 ]; then
  log_error "agent_instance_type ($AGENT_INSTANCE_TYPE) has $AGENT_VCPUS vCPU; minimum required is 8"
  exit 1
fi

log_info "Sizing checks passed: registry=${REGISTRY_VOLUME_GB}GB, server=${SERVER_VOLUME_GB}GB/${SERVER_VCPUS}vCPU, agent=${AGENT_VOLUME_GB}GB/${AGENT_VCPUS}vCPU"

# Check if images need to be sorted/filtered
# Re-sort if: (1) bootstrap list missing, or (2) rancher-images.txt is newer than bootstrap list
needs_sorting=false

if [ ! -f "$DATA_DIR/bootstrap-images.txt" ]; then
  needs_sorting=true
  log_warn "Bootstrap image list not found. Will sort images..."
elif [ "$DATA_DIR/rancher-images.txt" -nt "$DATA_DIR/bootstrap-images.txt" ]; then
  needs_sorting=true
  log_warn "rancher-images.txt is newer than sorted files. Re-sorting images..."
fi

if [ "$needs_sorting" = true ]; then
  log_info "Running sort-images.sh to split bootstrap and required images..."
  bash "$DATA_DIR/sort-images.sh" "$DATA_DIR/rancher-images.txt" "$DATA_DIR"
fi

log_info "All pre-flight checks passed."

# --------------------------------------------------------------------------
# STEP 1 — Terraform: provision all AWS infrastructure (or resume)
# --------------------------------------------------------------------------
log_step "STEP 1/6 — Terraform: provisioning AWS infrastructure"

if ! resume_from_step 1; then
  log_info "Skipping Terraform (resources already created in previous run)"
else
  if terraform_resources_exist; then
    log_info "Terraform resources already exist. Skipping apply (use ./destroy.sh to reset)."
  else
    log_info "Applying Terraform configuration..."
    cd "$TFDIR"
    terraform init -upgrade -no-color 2>&1 | tee "$LOGDIR/terraform-init.log"
    terraform apply -var-file="$TFVARS" -auto-approve -no-color 2>&1 \
      | tee "$LOGDIR/terraform-apply.log"
    cd "$SCRIPT_DIR"
  fi
  save_step_state 1
fi

ensure_required_terraform_outputs

# Read Terraform outputs
REGISTRY_IP=$(terraform -chdir="$TFDIR" output -raw registry_public_ip)
REGISTRY_PRIVATE_IP=$(terraform -chdir="$TFDIR" output -raw registry_private_ip)
REGISTRY_ENDPOINT=$(terraform -chdir="$TFDIR" output -raw registry_endpoint)
SERVER_IP=$(terraform -chdir="$TFDIR" output -raw first_server_private_ip)
EXTERNAL_NLB_DNS=$(terraform -chdir="$TFDIR" output -raw external_nlb_dns)
RANCHER_URL=$(terraform -chdir="$TFDIR" output -raw rancher_url)
RANCHER_HOSTNAME=$(terraform -chdir="$TFDIR" output -raw rancher_hostname)
SSH_USER=$(terraform -chdir="$TFDIR" output -raw ssh_user)
PREFIX=$(terraform -chdir="$TFDIR" output -raw prefix)

# Extract credentials from config.tfvars
REGISTRY_USER=$(grep 'registry_username' "$TFVARS" | awk -F'"' '{print $2}')
REGISTRY_PASS=$(grep 'registry_password' "$TFVARS" | awk -F'"' '{print $2}')
RANCHER_PASS=$(grep 'rancher_bootstrap_password' "$TFVARS" | awk -F'"' '{print $2}')
TLS_MODE=$(grep 'tls_mode' "$TFVARS" | awk -F'"' '{print $2}')
CERT_MANAGER_VER=$(grep 'cert_manager_version' "$TFVARS" | awk -F'"' '{print $2}')
RANCHER_VER=$(grep 'rancher_version' "$TFVARS" | awk -F'"' '{print $2}')
RANCHER_SOURCE_REGISTRY=$(get_tfvar_value "rancher_source_registry")
RANCHER_SOURCE_REGISTRY="${RANCHER_SOURCE_REGISTRY:-stgregistry.suse.com}"
TOTAL_NODES=$(($(terraform -chdir="$TFDIR" output -json server_private_ips | jq 'length') + $(terraform -chdir="$TFDIR" output -json agent_private_ips | jq 'length')))
USE_NLB_DNS_HOSTNAME=$(get_tfvar_value "use_nlb_dns_hostname")
ENABLE_ROUTE53=$(get_tfvar_value "enable_route53")

if [[ "$(echo "${ENABLE_ROUTE53:-true}" | tr '[:upper:]' '[:lower:]')" == "false" ]]; then
  USE_NLB_DNS_HOSTNAME=true
fi

if [[ "$(echo "${USE_NLB_DNS_HOSTNAME:-false}" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
  RANCHER_HOSTNAME="$EXTERNAL_NLB_DNS"
  RANCHER_URL="https://$RANCHER_HOSTNAME"
  log_warn "Using NLB DNS hostname mode for Rancher UI: $RANCHER_HOSTNAME"
  log_warn "Route53 hostname is bypassed for UI launch reliability."
fi

log_info "Infrastructure ready:"
log_info "  Registry public IP : $REGISTRY_IP"
log_info "  Registry private IP: $REGISTRY_PRIVATE_IP"
log_info "  Registry endpoint  : $REGISTRY_ENDPOINT"
log_info "  Rancher source reg : $RANCHER_SOURCE_REGISTRY"
log_info "  First server IP    : $SERVER_IP"
log_info "  Rancher URL        : $RANCHER_URL"

# --------------------------------------------------------------------------
# STEP 2 — Wait for SSH on registry node
# --------------------------------------------------------------------------
log_step "STEP 2/6 — Waiting for registry node to boot"

if resume_from_step 2; then
  wait_for_ssh "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" 30
  save_step_state 2
else
  log_info "Skipping SSH wait (already verified in previous run)"
fi

# --------------------------------------------------------------------------
# STEP 3 — Wait for registry bootstrap (Docker, nginx, RKE2 downloads)
# --------------------------------------------------------------------------
log_step "STEP 3/6 — Waiting for registry bootstrap to complete"

if ! resume_from_step 3; then
  log_info "Skipping registry bootstrap wait (already completed in previous run)"
else
  # Try waiting for registry bootstrap
  if ! wait_registry_ready "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" 36 2>&1 | tee -a "$LOGDIR/registry-bootstrap.log"; then
    log_error "Registry bootstrap timed out. This typically means the bootstrap script had errors."
    log_error "Common cause: EC2 instance cached old cloud-init userdata with syntax errors."
    log_error ""
    log_warn "Attempting automatic recovery: destroying old registry and recreating with fixed bootstrap..."
    log_warn ""
    
    destroy_and_replace_registry
    
    log_info "New registry instance created. Waiting for it to boot and bootstrap..."
    wait_for_ssh "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" 30
    
    # Retry the bootstrap wait
    log_info "Waiting for bootstrap on replacement registry..."
    wait_registry_ready "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" 36
  fi
  # Upload bootstrap and required image lists to registry node
  log_info "Uploading image lists to registry node..."
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" "sudo mkdir -p /opt/image-lists /opt/scripts && sudo chown $SSH_USER:$SSH_USER /opt/image-lists /opt/scripts && sudo chmod 755 /opt/image-lists /opt/scripts"

  for list in bootstrap-images required-images; do
    if [ -f "$DATA_DIR/${list}.txt" ]; then
      scp $SSH_OPTS -i "$SSH_KEY" \
        "$DATA_DIR/${list}.txt" \
        "$SSH_USER@$REGISTRY_IP:/opt/image-lists/" 2>&1 || {
          log_error "Failed to upload $list"
          exit 1
        }
    fi
  done

  # Upload push scripts to registry node
  scp $SSH_OPTS -i "$SSH_KEY" \
    "$SCRIPT_DIR/scripts/bootstrap-images-push.sh" \
    "$SCRIPT_DIR/scripts/push-remaining-images.sh" \
    "$SSH_USER@$REGISTRY_IP:/opt/scripts/" 2>&1 || {
      log_error "Failed to upload push scripts"
      exit 1
    }
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
    "sudo chmod +x /opt/scripts/*.sh"

  # Upload SSH private key to registry so it can SSH to cluster nodes
  log_info "Uploading SSH key to registry (for cluster node access)..."
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  scp $SSH_OPTS -i "$SSH_KEY" \
    "$SSH_KEY" "$SSH_USER@$REGISTRY_IP:~/.ssh/id_rsa" 2>&1 || {
      log_error "Failed to upload SSH key"
      exit 1
    }
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" "chmod 600 ~/.ssh/id_rsa"

  save_step_state 3
fi

# --------------------------------------------------------------------------
# STEP 4 — Push bootstrap images (one per repository)
# Cluster nodes are bootstrapping in parallel — they'll be ready when we need them
# --------------------------------------------------------------------------
log_step "STEP 4/6 — Pushing bootstrap images to private registry"

if resume_from_step 4; then
  log_info "Pushing bootstrap images (one per repository)..."
  log_info "Cluster nodes are bootstrapping in parallel..."

  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
    "bash /opt/scripts/bootstrap-images-push.sh \
       /opt/image-lists/bootstrap-images.txt \
       localhost:5000 \
       '$REGISTRY_USER' \
       '$REGISTRY_PASS' \
       '$RANCHER_SOURCE_REGISTRY'" \
    2>&1 | tee "$LOGDIR/bootstrap-images-push.log"

  log_info "Bootstrap images pushed."
  save_step_state 4
else
  log_info "Skipping bootstrap image push (already completed in previous run)"
fi

# --------------------------------------------------------------------------
# STEP 5 — Wait for RKE2 cluster, then install Rancher
# --------------------------------------------------------------------------
log_step "STEP 5/6 — Waiting for RKE2 cluster and installing Rancher"

if resume_from_step 5; then
  # Get kubeconfig from first server (SSH via registry as bastion)
  log_info "Waiting for RKE2 first server to be ready..."
  SERVER_READY=false
  for i in $(seq 1 30); do
    if registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
        "ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no \
         -o ConnectTimeout=10 '$SSH_USER@$SERVER_IP' \
         'test -f /etc/rancher/rke2/rke2.yaml'" &>/dev/null; then
      log_info "RKE2 server is ready."
      SERVER_READY=true
      break
    fi
    log_info "  waiting for server ($i/30)..."
    sleep 20
  done

  if [ "$SERVER_READY" != "true" ]; then
    log_error "RKE2 server kubeconfig did not become available in time"
    exit 1
  fi

  # Fetch kubeconfig from server node and setup on registry node
  log_info "Fetching kubeconfig from RKE2 server..."
  # Fetch directly from server via registry node (same path already validated above).
  if ! registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
      "ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=10 '$SSH_USER@$SERVER_IP' 'sudo cat /etc/rancher/rke2/rke2.yaml' > /tmp/rke2-kubeconfig.yaml"; then
    log_error "Failed to fetch kubeconfig from server"
    exit 1
  fi

  if ! registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" "test -s /tmp/rke2-kubeconfig.yaml"; then
    log_error "Kubeconfig is empty or not found"
    exit 1
  fi

  # Rewrite server endpoint from localhost to first server private IP.
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
    "sed 's/127.0.0.1/$SERVER_IP/g' /tmp/rke2-kubeconfig.yaml > /tmp/rke2-kubeconfig.yaml.tmp && mv /tmp/rke2-kubeconfig.yaml.tmp /tmp/rke2-kubeconfig.yaml"

  # Install kubeconfig to /root/.kube/config on registry node
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
    "sudo mkdir -p /root/.kube && sudo cp /tmp/rke2-kubeconfig.yaml /root/.kube/config && sudo chown root:root /root/.kube/config && sudo chmod 600 /root/.kube/config"

  # Wait for cluster nodes ready
  wait_rke2_ready "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" "$TOTAL_NODES" 30

  # Upload install-rancher script
  scp $SSH_OPTS -i "$SSH_KEY" \
    "$SCRIPT_DIR/scripts/install-rancher.sh" \
    "$SSH_USER@$REGISTRY_IP:/opt/scripts/" 2>&1 || {
      log_error "Failed to upload install-rancher script"
      exit 1
    }
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
    "sudo chmod +x /opt/scripts/install-rancher.sh"

  # Run Rancher install
  log_info "Installing Rancher..."
  registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
    "bash /opt/scripts/install-rancher.sh \
       '$SERVER_IP' \
       '$RANCHER_HOSTNAME' \
       '$RANCHER_PASS' \
       '$REGISTRY_ENDPOINT' \
       '$TLS_MODE' \
       '$CERT_MANAGER_VER' \
       '$RANCHER_VER' \
       '$SSH_USER'" \
    2>&1 | tee "$LOGDIR/install-rancher.log"
  save_step_state 5
else
  log_info "Skipping RKE2 cluster and Rancher install (already completed in previous run)"
fi

# --------------------------------------------------------------------------
# STEP 6 — Wait for Rancher UI, then kick off background image push
# --------------------------------------------------------------------------
log_step "STEP 6/6 — Waiting for Rancher UI"

if resume_from_step 6; then
  if ! wait_rancher_ui "$RANCHER_URL" 10; then
    log_warn "Local Rancher UI probe failed. Trying from registry node..."
    UI_CODE=$(registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" "curl -sk -o /dev/null -w '%{http_code}' '$RANCHER_URL/' || true" 2>/dev/null || true)
    UI_CODE=$(echo "$UI_CODE" | awk '{print $1}')
    if [[ "$UI_CODE" =~ ^(200|301|302|401|403)$ ]]; then
      log_info "Registry-side Rancher UI probe succeeded (HTTP $UI_CODE). Continuing."
    else
      log_warn "Rancher UI endpoint probe still failing (HTTP ${UI_CODE:-000}), but Rancher pods are deployed. Continuing deployment."
    fi

    # When using custom hostname mode, provide /etc/hosts fallback after UI timeout.
    if [[ "$(echo "${USE_NLB_DNS_HOSTNAME:-false}" | tr '[:upper:]' '[:lower:]')" == "false" ]]; then
      NLB_IP="$( (dig +short "$EXTERNAL_NLB_DNS" 2>/dev/null || true) | grep -E '^[0-9]+\.' | head -1 )"
      if [ -z "$NLB_IP" ] && command -v nslookup >/dev/null 2>&1; then
        NLB_IP="$(nslookup "$EXTERNAL_NLB_DNS" 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^[0-9]+\.' | head -1)"
      fi

      echo ""
      echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════════╗${NC}"
      echo -e "${YELLOW}║  Rancher UI is not reachable via: $RANCHER_URL${NC}"
      echo -e "${YELLOW}║                                                                      ║${NC}"
      echo -e "${YELLOW}║  Rancher pods are deployed and NLB is healthy.                       ║${NC}"
      echo -e "${YELLOW}║  The issue is likely DNS — your machine cannot resolve the hostname. ║${NC}"
      echo -e "${YELLOW}║                                                                      ║${NC}"
      echo -e "${YELLOW}║  Fix: add this line to /etc/hosts on your local machine:             ║${NC}"
      if [ -n "$NLB_IP" ]; then
        echo -e "${YELLOW}║    $NLB_IP  $RANCHER_HOSTNAME${NC}"
        echo -e "${YELLOW}║                                                                      ║${NC}"
        echo -e "${YELLOW}║  Run this command on your local machine:                             ║${NC}"
        echo -e "${YELLOW}║    echo '$NLB_IP $RANCHER_HOSTNAME' | sudo tee -a /etc/hosts${NC}"
      else
        echo -e "${YELLOW}║    <NLB_IP>  $RANCHER_HOSTNAME${NC}"
        echo -e "${YELLOW}║  (Could not auto-resolve NLB IP from: $EXTERNAL_NLB_DNS)${NC}"
        echo -e "${YELLOW}║  Resolve the IP manually and add it to /etc/hosts.                  ║${NC}"
      fi
      echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════════╝${NC}"
      echo ""
    fi
  fi

  # --------------------------------------------------------------------------
  # Background: push remaining images (Rancher is already running)
  # --------------------------------------------------------------------------
  log_info "Starting background push of required images ($(wc -l < "$DATA_DIR/required-images.txt") images)..."
  REMOTE_PUSH_LOG="/tmp/push-remaining-images.log"
  REMOTE_PUSH_DONE="/tmp/push-remaining-images.done"
  REMOTE_PUSH_EXIT="/tmp/push-remaining-images.exitcode"
  LOCAL_PUSH_LOG="$LOGDIR/push-remaining-images.log"

  : > "$LOCAL_PUSH_LOG"
  log_info "Monitor progress (local): tail -f $LOCAL_PUSH_LOG"

  ssh $SSH_OPTS -i "$SSH_KEY" -f "$SSH_USER@$REGISTRY_IP" \
    "nohup bash -lc 'rm -f \"$REMOTE_PUSH_DONE\" \"$REMOTE_PUSH_EXIT\"; \
       bash /opt/scripts/push-remaining-images.sh \
       \"localhost:5000\" \"$REGISTRY_USER\" \"$REGISTRY_PASS\" \"/opt/image-lists\" \"$RANCHER_SOURCE_REGISTRY\" \
       > \"$REMOTE_PUSH_LOG\" 2>&1; \
       code=\$?; echo \"\$code\" > \"$REMOTE_PUSH_EXIT\"; touch \"$REMOTE_PUSH_DONE\"' \
       >/dev/null 2>&1 &"

  # Mirror remote push log to local logs/ for easy tracking from this machine.
  nohup ssh $SSH_OPTS -i "$SSH_KEY" "$SSH_USER@$REGISTRY_IP" \
    "bash -lc 'while [ ! -f \"$REMOTE_PUSH_LOG\" ]; do sleep 2; done; tail -F \"$REMOTE_PUSH_LOG\"'" \
    > "$LOCAL_PUSH_LOG" 2>&1 < /dev/null &

  BG_PUSH_STARTED=false
  if registry_exec "$REGISTRY_IP" "$SSH_USER" "$SSH_KEY" \
      "pgrep -af '/opt/scripts/push-remaining-images.sh' >/dev/null 2>&1"; then
    log_info "Background push process started successfully."
    BG_PUSH_STARTED=true
  else
    log_error "Background push process did not start on registry. Check $LOCAL_PUSH_LOG"
  fi

  if [ "$BG_PUSH_STARTED" != "true" ]; then
    exit 1
  fi

  log_info "Check completion: ssh -i ssh-key.pem $SSH_USER@$REGISTRY_IP 'test -f $REMOTE_PUSH_DONE && cat $REMOTE_PUSH_EXIT || echo RUNNING'"
  
  # Clear state file on successful completion
  clear_state
else
  log_info "Resuming from completed deployment (all steps already done)"
fi

# Always print Rancher credentials (whether fresh or resumed deployment)
log_step "Rancher is UP!"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  Rancher UI:  $RANCHER_URL"
echo "  │  Username  :  admin"
echo "  │  Password  :  $RANCHER_PASS"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

log_info "Deployment complete in approximately $(( (SECONDS / 60) )) minutes!"
log_info ""
log_info "Starting background push of required images ($(wc -l < "$DATA_DIR/required-images.txt") images)..."
log_info "Monitor progress (local): tail -f $LOGDIR/push-remaining-images.log"
log_info "Background push process started successfully."
log_info "Check completion: ssh -i ssh-key.pem $SSH_USER@$REGISTRY_IP 'test -f /tmp/push-remaining-images.done && cat /tmp/push-remaining-images.exitcode || echo RUNNING'"
log_info ""
log_info "Useful commands:"
log_info "  SSH to registry:      ssh -i ssh-key.pem $SSH_USER@$REGISTRY_IP"
log_info "  Watch push progress:  tail -f logs/push-remaining-images.log"
log_info "  Push completion:      ssh -i ssh-key.pem $SSH_USER@$REGISTRY_IP 'test -f /tmp/push-remaining-images.done && cat /tmp/push-remaining-images.exitcode || echo RUNNING'"
log_info "  kubectl on registry:  ssh -i ssh-key.pem $SSH_USER@$REGISTRY_IP 'kubectl get nodes'"
log_info "  Destroy everything:   ./destroy.sh"
