#!/bin/bash
# =============================================================================
# ZEGRESS : ZERO EGRESS SETUP FOR SECURE AI
# CREATE DOWNSTREAM RKE2 NODES (DIRECT AWS EC2)
#
# Provisions downstream EC2 nodes in AWS and prints commands to register them
# to existing Rancher airgap server using system-agent-install.sh.
#
# Usage:
#   ./create-downstream.sh               — create nodes and fully prep them
#   ./create-downstream.sh --destroy     — destroy nodes
#   ./create-downstream.sh --allow-replace — allow terraform replace actions
#   ./create-downstream.sh --prep-only   — re-run node prep on existing nodes (no terraform)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/utils.sh"

TFVARS="$SCRIPT_DIR/config.tfvars"
MGMT_TFDIR="$SCRIPT_DIR/terraform"
DOWNSTREAM_TFDIR="$SCRIPT_DIR/terraform-rancher-downstream"
LOGDIR="$SCRIPT_DIR/logs"
TMP_TFVARS="$DOWNSTREAM_TFDIR/.tmp.downstream.auto.tfvars"

DESTROY_MODE=false
ALLOW_REPLACE=false
PREP_ONLY=false

mkdir -p "$LOGDIR"

for arg in "$@"; do
  case "$arg" in
    --destroy) DESTROY_MODE=true ;;
    --allow-replace) ALLOW_REPLACE=true ;;
    --prep-only) PREP_ONLY=true ;;
    *) log_error "Unknown argument: $arg"; exit 1 ;;
  esac
done

get_tfvar() {
  sed -n -E "s/^[[:space:]]*${1}[[:space:]]*=[[:space:]]*\"?([^\"#]+)\"?.*$/\1/p" "$TFVARS" | head -1 | xargs
}

ensure_tools() {
  for cmd in terraform aws curl jq ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || {
      log_error "Required tool not found: $cmd"
      exit 1
    }
  done
}

downstream_terraform_process_running() {
  pgrep -f "terraform.*terraform-rancher-downstream" >/dev/null 2>&1
}

recover_downstream_lock_if_stale() {
  local lock_file lock_id
  lock_file="$DOWNSTREAM_TFDIR/.terraform.tfstate.lock.info"

  if [ ! -f "$lock_file" ]; then
    return 0
  fi

  if downstream_terraform_process_running; then
    log_error "Terraform state lock is currently held by an active downstream Terraform process."
    log_error "Stop that process first, then re-run this command."
    return 1
  fi

  lock_id=$(jq -r '.ID // empty' "$lock_file" 2>/dev/null || true)
  if [ -n "$lock_id" ]; then
    log_warn "Detected stale Terraform lock. Releasing lock ID: $lock_id"
    terraform -chdir="$DOWNSTREAM_TFDIR" force-unlock -force "$lock_id" >/dev/null 2>&1 || true
  fi
  rm -f "$lock_file"
  return 0
}

run_tf_with_lock_recovery() {
  local log_file="$1"
  shift

  local tf_output
  set +e
  tf_output=$(terraform -chdir="$DOWNSTREAM_TFDIR" "$@" -no-color 2>&1)
  local rc=$?
  set -e
  echo "$tf_output" | tee "$log_file"

  if [ $rc -eq 0 ]; then
    return 0
  fi

  if echo "$tf_output" | grep -qi "Error acquiring the state lock"; then
    log_warn "Terraform lock acquisition failed. Attempting stale lock recovery..."
    recover_downstream_lock_if_stale || return 1

    set +e
    tf_output=$(terraform -chdir="$DOWNSTREAM_TFDIR" "$@" -no-color 2>&1)
    rc=$?
    set -e
    echo "$tf_output" | tee -a "$log_file"
    return $rc
  fi

  return $rc
}

ensure_prereqs() {
  [ -f "$TFVARS" ] || { log_error "config.tfvars not found."; exit 1; }
  [ -f "$MGMT_TFDIR/terraform.tfstate" ] || { log_error "No management terraform state found. Run ./deploy.sh first."; exit 1; }
  [ -f "$DOWNSTREAM_TFDIR/main.tf" ] || { log_error "Missing terraform-rancher-downstream/main.tf"; exit 1; }

  local enabled
  enabled=$(get_tfvar "enable_downstream_cluster")
  if [[ "$(echo "${enabled:-false}" | tr '[:upper:]' '[:lower:]')" != "true" ]]; then
    log_error "enable_downstream_cluster must be true in config.tfvars"
    exit 1
  fi
}

load_aws_env_from_tfvars() {
  local region ak sk
  region=$(get_tfvar "aws_region")
  ak=$(get_tfvar "aws_access_key")
  sk=$(get_tfvar "aws_secret_key")

  [ -n "$ak" ] && export AWS_ACCESS_KEY_ID="$ak"
  [ -n "$sk" ] && export AWS_SECRET_ACCESS_KEY="$sk"
  [ -n "$region" ] && export AWS_DEFAULT_REGION="$region"

  if ! aws --no-cli-pager sts get-caller-identity --output text >/dev/null 2>&1; then
    log_error "AWS authentication failed."
    exit 1
  fi
}

build_context() {
  local ssh_key_path mgmt_server_url ssh_key_candidate

  # Management stack outputs
  REGISTRY_PRIVATE_IP=$(terraform -chdir="$MGMT_TFDIR" output -raw registry_private_ip)
  REGISTRY_PUBLIC_IP=$(terraform -chdir="$MGMT_TFDIR" output -raw registry_public_ip)
  PREFIX=$(terraform -chdir="$MGMT_TFDIR" output -raw prefix)
  VPC_ID=$(terraform -chdir="$MGMT_TFDIR" output -raw vpc_id)
  SUBNET_ID=$(terraform -chdir="$MGMT_TFDIR" output -raw private_subnet_id)
  RANCHER_INTERNAL_NLB=$(terraform -chdir="$MGMT_TFDIR" output -raw internal_nlb_dns)
  mgmt_server_url="https://$RANCHER_INTERNAL_NLB"

  ssh_key_path=$(terraform -chdir="$MGMT_TFDIR" output -raw ssh_private_key_path)

  # Output may be relative to the management terraform directory.
  if [[ "$ssh_key_path" = /* ]]; then
    ssh_key_candidate="$ssh_key_path"
  else
    ssh_key_candidate="$MGMT_TFDIR/$ssh_key_path"
  fi

  # Fallback to project root ssh-key.pem for older states/layouts.
  if [ ! -f "$ssh_key_candidate" ] && [ -f "$SCRIPT_DIR/ssh-key.pem" ]; then
    ssh_key_candidate="$SCRIPT_DIR/ssh-key.pem"
  fi

  if [ ! -f "$ssh_key_candidate" ]; then
    log_error "SSH private key from management outputs not found: $ssh_key_path"
    log_error "Also checked fallback: $SCRIPT_DIR/ssh-key.pem"
    exit 1
  fi

  SSH_KEY_ABS="$(cd "$(dirname "$ssh_key_candidate")" && pwd)/$(basename "$ssh_key_candidate")"
  SSH_PUBLIC_KEY=$(ssh-keygen -y -f "$SSH_KEY_ABS")

  # Locate registry security group by standard name
  REGISTRY_SG_ID=$(aws --no-cli-pager ec2 describe-security-groups \
    --region "$AWS_DEFAULT_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PREFIX}-registry-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)

  if [ -z "$REGISTRY_SG_ID" ] || [ "$REGISTRY_SG_ID" = "None" ]; then
    log_error "Unable to locate registry security group: ${PREFIX}-registry-sg"
    exit 1
  fi

  SSH_USER=$(get_tfvar "aws_ssh_user")
  AWS_AMI=$(get_tfvar "aws_ami")

  DOWNSTREAM_CLUSTER_NAME=$(get_tfvar "downstream_cluster_name")
  [ -z "$DOWNSTREAM_CLUSTER_NAME" ] && DOWNSTREAM_CLUSTER_NAME="downstream-rke2"

  DOWNSTREAM_INSTANCE_TYPE=$(get_tfvar "downstream_instance_type")
  [ -z "$DOWNSTREAM_INSTANCE_TYPE" ] && DOWNSTREAM_INSTANCE_TYPE=$(get_tfvar "server_instance_type")

  DOWNSTREAM_ROOT_SIZE=$(get_tfvar "downstream_root_size_gb")
  [ -z "$DOWNSTREAM_ROOT_SIZE" ] && DOWNSTREAM_ROOT_SIZE=50

  DOWNSTREAM_SERVER_COUNT=$(get_tfvar "downstream_server_count")
  [ -z "$DOWNSTREAM_SERVER_COUNT" ] && DOWNSTREAM_SERVER_COUNT=1

  DOWNSTREAM_AGENT_COUNT=$(get_tfvar "downstream_agent_count")
  [ -z "$DOWNSTREAM_AGENT_COUNT" ] && DOWNSTREAM_AGENT_COUNT=1

  RANCHER_SERVER_URL=$(get_tfvar "downstream_rancher_server_url")
  [ -z "$RANCHER_SERVER_URL" ] && RANCHER_SERVER_URL="$mgmt_server_url"

  DOWNSTREAM_REG_TOKEN=$(get_tfvar "downstream_registration_token")
  DOWNSTREAM_CA_CHECKSUM=$(get_tfvar "downstream_ca_checksum")
}

write_downstream_tfvars() {
  cat > "$TMP_TFVARS" <<EOF
aws_access_key         = "$AWS_ACCESS_KEY_ID"
aws_secret_key         = "$AWS_SECRET_ACCESS_KEY"
aws_region             = "$AWS_DEFAULT_REGION"
aws_ami                = "$AWS_AMI"
aws_vpc_id             = "$VPC_ID"
aws_subnet_id          = "$SUBNET_ID"
registry_security_group_id = "$REGISTRY_SG_ID"
aws_ssh_user           = "$SSH_USER"
ssh_public_key         = "$SSH_PUBLIC_KEY"

downstream_cluster_name = "$DOWNSTREAM_CLUSTER_NAME"
downstream_server_count = $DOWNSTREAM_SERVER_COUNT
downstream_agent_count  = $DOWNSTREAM_AGENT_COUNT
downstream_instance_type = "$DOWNSTREAM_INSTANCE_TYPE"
downstream_root_size_gb  = $DOWNSTREAM_ROOT_SIZE

registry_private_ip    = "$REGISTRY_PRIVATE_IP"
rancher_server_url     = "$RANCHER_SERVER_URL"
EOF
}

run_destroy() {
  log_step "Destroy downstream AWS nodes (terraform-rancher-downstream)"

  recover_downstream_lock_if_stale
  run_tf_with_lock_recovery "$LOGDIR/downstream-destroy-init.log" init -upgrade

  local plan_file
  plan_file="$LOGDIR/downstream-destroy.plan"
  run_tf_with_lock_recovery "$LOGDIR/downstream-destroy-plan.log" plan -destroy -var-file="$TMP_TFVARS" -out="$plan_file"

  local unsafe_deletes
  unsafe_deletes=$(terraform -chdir="$DOWNSTREAM_TFDIR" show -json "$plan_file" \
    | jq '[.resource_changes[]? | select(.change.actions | index("delete")) | select((.type | IN("aws_instance","aws_security_group","aws_key_pair","random_id")) | not)] | length')

  if [ "${unsafe_deletes:-0}" -gt 0 ]; then
    log_error "Refusing destroy: plan contains unexpected resource types."
    log_error "Inspect: $LOGDIR/downstream-destroy-plan.log"
    rm -f "$plan_file"
    exit 1
  fi

  run_tf_with_lock_recovery "$LOGDIR/downstream-destroy.log" apply -auto-approve "$plan_file" || {
    log_warn "Apply failed — retrying with -lock=false..."
    terraform -chdir="$DOWNSTREAM_TFDIR" apply -auto-approve -lock=false "$plan_file" \
      2>&1 | tee -a "$LOGDIR/downstream-destroy.log"
  }
  rm -f "$plan_file"

  log_info "Downstream AWS nodes destroyed successfully."
}

# -----------------------------------------------------------------------------
# Prepare a single downstream node for air-gap RKE2 provisioning:
#   - Downloads RKE2 binary + images + installer from the registry artifact server
#   - Writes /etc/rancher/rke2/registries.yaml pointing all pulls to private registry
#   - Resolves internal NLB DNS on the node itself (in-VPC DNS works) and adds
#     an /etc/hosts entry mapping the external NLB hostname → internal NLB IP,
#     so the node can reach Rancher without a NAT gateway. NLB IPs are resolved
#     fresh each run — no hardcoded addresses.
#   - Configures kernel settings required for etcd and RKE2
# Args: <node_ip>
# -----------------------------------------------------------------------------
# Wait up to 3 min for SSH to become available on a node via bastion proxy
wait_for_ssh() {
  local node_ip="$1"
  log_info "  Waiting for SSH on $node_ip (up to 3 min)..."
  for i in $(seq 1 18); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes \
           -i "$SSH_KEY_ABS" \
           -o "ProxyCommand=ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i $SSH_KEY_ABS $SSH_USER@$REGISTRY_PUBLIC_IP -W %h:%p" \
           "$SSH_USER@$node_ip" true 2>/dev/null; then
      log_info "  SSH ready on $node_ip."
      return 0
    fi
    log_info "  SSH not yet available on $node_ip (attempt $i/18), retrying in 10s..."
    sleep 10
  done
  log_error "SSH on $node_ip did not become available after 3 min."
  return 1
}

prep_downstream_node() {
  local node_ip="$1"
  local rke2_version internal_nlb_dns external_nlb_hostname
  rke2_version=$(get_tfvar "rke2_version")
  [ -z "$rke2_version" ] && { log_error "rke2_version not set in config.tfvars"; return 1; }

  # Internal NLB DNS — resolved by the node itself from within the VPC (no hardcoded IP)
  internal_nlb_dns=$(terraform -chdir="$MGMT_TFDIR" output -raw internal_nlb_dns)
  # External NLB hostname stripped of scheme and trailing slash
  external_nlb_hostname=$(echo "$RANCHER_SERVER_URL" | sed 's|https\?://||; s|/$||')

  log_info "  Prepping node $node_ip"
  log_info "    RKE2 version    : $rke2_version"
  log_info "    Registry        : $REGISTRY_PRIVATE_IP:5000"
  log_info "    Internal NLB    : $internal_nlb_dns"
  log_info "    External NLB    : $external_nlb_hostname"

  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
      -i "$SSH_KEY_ABS" \
      -o "ProxyCommand=ssh -o StrictHostKeyChecking=no -i $SSH_KEY_ABS $SSH_USER@$REGISTRY_PUBLIC_IP -W %h:%p" \
      "$SSH_USER@$node_ip" bash -s -- \
        "$REGISTRY_PRIVATE_IP" "$rke2_version" "$external_nlb_hostname" "$internal_nlb_dns" \
  << 'NODEPREP'
set -euo pipefail
REGISTRY_IP="$1"
RKE2_VERSION="$2"
EXTERNAL_NLB_HOSTNAME="$3"
INTERNAL_NLB_DNS="$4"

log() { echo "[node-prep $(hostname -s)] $*"; }
log "=== Starting air-gap node preparation ==="

# --------------------------------------------------------------------------
# 0. Clean any stale Rancher/RKE2 state from previous attempts
#    This ensures a fresh registration every time — no stale Cattle IDs,
#    no leftover rke2 services or data that would cause 401s or etcd conflicts.
# --------------------------------------------------------------------------
log "Cleaning stale Rancher/RKE2 state..."
systemctl stop rancher-system-agent rke2-server rke2-agent 2>/dev/null || true
if [ -x /usr/local/bin/rancher-system-agent-uninstall.sh ]; then
  /usr/local/bin/rancher-system-agent-uninstall.sh 2>/dev/null || true
fi
if [ -x /usr/local/bin/rke2-uninstall.sh ]; then
  /usr/local/bin/rke2-uninstall.sh 2>/dev/null || true
fi
rm -rf /etc/rancher /var/lib/rancher /var/lib/cattle /run/k3s \
       /usr/local/bin/rke2 /usr/local/bin/kubectl /usr/local/bin/crictl \
       /opt/rke2-artifacts 2>/dev/null || true
log "Stale state cleaned."

# --------------------------------------------------------------------------
# 1. Kernel settings required for etcd and RKE2
# --------------------------------------------------------------------------
log "Configuring kernel settings..."
cat > /etc/sysctl.d/99-rke2.conf << 'EOF'
vm.swappiness=0
vm.panic_on_oom=0
kernel.panic=10
kernel.panic_on_oops=1
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
# 2. Wait for registry artifact server (up to 5 min)
# --------------------------------------------------------------------------
log "Waiting for artifact server at http://$REGISTRY_IP:8080/ready ..."
for i in $(seq 1 30); do
  curl -sf "http://$REGISTRY_IP:8080/ready" >/dev/null 2>&1 && { log "Artifact server ready."; break; }
  [ "$i" -eq 30 ] && { log "ERROR: Artifact server not ready after 5 min"; exit 1; }
  sleep 10
done

# --------------------------------------------------------------------------
# 3. Download and install RKE2 (air-gap)
# --------------------------------------------------------------------------
mkdir -p /opt/rke2-artifacts && cd /opt/rke2-artifacts
log "Downloading RKE2 $RKE2_VERSION artifacts from http://$REGISTRY_IP:8080 ..."
curl -sfLo rke2                          "http://$REGISTRY_IP:8080/rke2-artifacts/rke2" && chmod +x rke2
curl -sfLo rke2-images.linux-amd64.tar.zst "http://$REGISTRY_IP:8080/rke2-artifacts/rke2-images.linux-amd64.tar.zst"
curl -sfLo install.sh                    "http://$REGISTRY_IP:8080/rke2-artifacts/install.sh" && chmod +x install.sh
mkdir -p /usr/local/bin
ln -sf /opt/rke2-artifacts/rke2 /usr/local/bin/rke2

log "Installing RKE2 (air-gap mode)..."
export INSTALL_RKE2_SKIP_DOWNLOAD=true
export INSTALL_RKE2_VERSION="$RKE2_VERSION"
export INSTALL_RKE2_TYPE=server
export INSTALL_RKE2_BIN_DIR=/usr/local/bin
export INSTALL_RKE2_SKIP_SELINUX_RPM=true
/opt/rke2-artifacts/install.sh 2>&1 | grep -v "Failed to connect\|Connection timed out\|github" || true
log "RKE2 install complete."

# --------------------------------------------------------------------------
# 4. Pre-load air-gap images into containerd image store path
# --------------------------------------------------------------------------
log "Pre-loading RKE2 air-gap images..."
mkdir -p /var/lib/rancher/rke2/agent/images/
cp /opt/rke2-artifacts/rke2-images.linux-amd64.tar.zst \
   /var/lib/rancher/rke2/agent/images/

# --------------------------------------------------------------------------
# 5. Write /etc/rancher/rke2/registries.yaml
#    All image pulls (docker.io, registry.k8s.io, quay.io, ghcr.io) are
#    redirected to the private registry. No internet needed.
# --------------------------------------------------------------------------
log "Writing registries.yaml (registry: $REGISTRY_IP:5000)..."
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/registries.yaml << EOF
mirrors:
  "$REGISTRY_IP:5000":
    endpoint:
      - "http://$REGISTRY_IP:5000"
  "docker.io":
    endpoint:
      - "http://$REGISTRY_IP:5000"
  "registry.k8s.io":
    endpoint:
      - "http://$REGISTRY_IP:5000"
  "quay.io":
    endpoint:
      - "http://$REGISTRY_IP:5000"
  "ghcr.io":
    endpoint:
      - "http://$REGISTRY_IP:5000"
configs:
  "$REGISTRY_IP:5000":
    tls:
      insecure_skip_verify: true
EOF

# --------------------------------------------------------------------------
# 6. /etc/hosts — map external NLB hostname → internal NLB private IP
#    The node is in a private subnet with no NAT gateway. DNS for the external
#    NLB resolves to a public IP which is unreachable. We resolve the internal
#    NLB here (in-VPC DNS works) and pin the external hostname to that IP.
#    This is done fresh each run so stale/changed IPs are always corrected.
# --------------------------------------------------------------------------
if [ -n "$INTERNAL_NLB_DNS" ] && [ -n "$EXTERNAL_NLB_HOSTNAME" ]; then
  log "Resolving internal NLB: $INTERNAL_NLB_DNS ..."
  # Use getent (always available) then fall back to dig
  INTERNAL_NLB_IP=$(getent hosts "$INTERNAL_NLB_DNS" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -z "$INTERNAL_NLB_IP" ] && command -v dig >/dev/null 2>&1; then
    INTERNAL_NLB_IP=$(dig +short "$INTERNAL_NLB_DNS" | grep -E '^[0-9]+\.' | head -1)
  fi

  if [ -n "$INTERNAL_NLB_IP" ]; then
    # Remove any stale entry for the external hostname then add fresh one
    sed -i "/$EXTERNAL_NLB_HOSTNAME/d" /etc/hosts
    echo "$INTERNAL_NLB_IP $EXTERNAL_NLB_HOSTNAME" >> /etc/hosts
    log "/etc/hosts: $INTERNAL_NLB_IP $EXTERNAL_NLB_HOSTNAME"
  else
    log "WARNING: Could not resolve $INTERNAL_NLB_DNS — /etc/hosts not updated."
    log "         The node may fail to reach Rancher. Check DNS and internal NLB."
  fi
fi

# --------------------------------------------------------------------------
# 7. Verify connectivity to registry and Rancher before handing off
# --------------------------------------------------------------------------
log "Verifying registry connectivity (http://$REGISTRY_IP:5000/v2/) ..."
if curl -sf --connect-timeout 8 "http://$REGISTRY_IP:5000/v2/" >/dev/null 2>&1; then
  log "Registry reachable."
else
  log "WARNING: Registry at $REGISTRY_IP:5000 not reachable. Image pulls will fail."
fi

log "Verifying Rancher connectivity (https://$EXTERNAL_NLB_HOSTNAME/ping) ..."
if curl -sk --connect-timeout 8 "https://$EXTERNAL_NLB_HOSTNAME/ping" >/dev/null 2>&1; then
  log "Rancher reachable."
else
  log "WARNING: Rancher at $EXTERNAL_NLB_HOSTNAME not reachable. Registration will fail."
fi

log "=== Node preparation complete ==="
NODEPREP
}

run_create() {
  log_step "Create downstream AWS RKE2 nodes"
  log_info "Configuration:"
  log_info "  Cluster Name        : $DOWNSTREAM_CLUSTER_NAME"
  log_info "  Server Count        : $DOWNSTREAM_SERVER_COUNT"
  log_info "  Agent Count         : $DOWNSTREAM_AGENT_COUNT"
  log_info "  Instance Type       : $DOWNSTREAM_INSTANCE_TYPE"
  log_info "  Root Size (GB)      : $DOWNSTREAM_ROOT_SIZE"
  log_info "  Rancher Server URL  : $RANCHER_SERVER_URL"
  log_info "  Registry Private IP : $REGISTRY_PRIVATE_IP"

  recover_downstream_lock_if_stale
  run_tf_with_lock_recovery "$LOGDIR/downstream-init.log" init -upgrade

  local plan_file
  plan_file="$LOGDIR/downstream.plan"
  run_tf_with_lock_recovery "$LOGDIR/downstream-plan.log" plan -var-file="$TMP_TFVARS" -out="$plan_file"

  local destroy_actions
  destroy_actions=$(terraform -chdir="$DOWNSTREAM_TFDIR" show -json "$plan_file" \
    | jq '[.resource_changes[]?.change.actions | select(index("delete"))] | length')

  if [ "${destroy_actions:-0}" -gt 0 ] && [ "$ALLOW_REPLACE" != "true" ]; then
    log_error "Create plan includes delete/replace actions (${destroy_actions})."
    log_error "Refusing to continue to avoid unintentional replacement."
    log_error "If intended, run: ./create-downstream.sh --allow-replace"
    rm -f "$plan_file"
    exit 1
  fi

  run_tf_with_lock_recovery "$LOGDIR/downstream-apply.log" apply -auto-approve "$plan_file"
  rm -f "$plan_file"

  local server_ips agent_ips first_server
  server_ips=$(terraform -chdir="$DOWNSTREAM_TFDIR" output -json downstream_server_private_ips | jq -r '.[]')
  agent_ips=$(terraform -chdir="$DOWNSTREAM_TFDIR" output -json downstream_agent_private_ips | jq -r '.[]')
  first_server=$(terraform -chdir="$DOWNSTREAM_TFDIR" output -raw downstream_first_server_private_ip)

  # Wait for SSH + prepare all nodes for air-gap RKE2 provisioning
  log_step "Preparing downstream nodes for air-gap RKE2 provisioning"
  local all_ips=()
  for ip in $server_ips $agent_ips; do all_ips+=("$ip"); done
  local prep_failed=false
  for ip in "${all_ips[@]}"; do
    log_info "Waiting for node $ip to be SSH-ready..."
    if ! wait_for_ssh "$ip"; then
      log_warn "Node $ip SSH timeout — skipping prep."
      prep_failed=true
      continue
    fi
    log_info "Prepping node: $ip"
    if prep_downstream_node "$ip"; then
      log_info "Node $ip prepared successfully."
    else
      log_warn "Node $ip preparation failed — you may need to run prep manually."
      prep_failed=true
    fi
  done
  $prep_failed && log_warn "One or more nodes failed prep. Check logs before registering with Rancher."

  # Validate that downstream private node can reach Rancher URL.
  if [ -n "$first_server" ]; then
    local reach_code
    reach_code=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_ABS" "$SSH_USER@$REGISTRY_PUBLIC_IP" \
      "ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa $SSH_USER@$first_server 'curl -sk --connect-timeout 8 -o /dev/null -w %{http_code} $RANCHER_SERVER_URL/ping || true'" 2>/dev/null || echo "000")
    reach_code=$(echo "$reach_code" | awk '{print $1}')
    if [[ ! "$reach_code" =~ ^(200|301|302|401|403|404)$ ]]; then
      log_warn "Downstream node could not reach Rancher URL: $RANCHER_SERVER_URL (HTTP ${reach_code:-000})"
      log_warn "For private subnet nodes, use INTERNAL NLB URL (internal_nlb_dns) in downstream_rancher_server_url."
    else
      log_info "Connectivity check from downstream node to Rancher URL succeeded (HTTP $reach_code)."
    fi
  fi

  log_step "Downstream nodes ready for Rancher import"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────────────────┐"
  echo "  │          DOWNSTREAM AWS NODES CREATED (NODE-TO-NODE INTERNAL OK)      │"
  echo "  ├─────────────────────────────────────────────────────────────────────────┤"
  echo "  │ Cluster Name : $DOWNSTREAM_CLUSTER_NAME"
  echo "  │ Rancher URL  : $RANCHER_SERVER_URL"
  echo "  │ Registry IP  : $REGISTRY_PRIVATE_IP"
  echo "  ├─────────────────────────────────────────────────────────────────────────┤"
  echo "  │ Bastion SSH                                                              │"
  echo "  │   ssh -i $SSH_KEY_ABS ${SSH_USER}@${REGISTRY_PUBLIC_IP}                 │"
  echo "  ├─────────────────────────────────────────────────────────────────────────┤"
  echo "  │ Downstream Server Nodes                                                   │"
  idx=0
  for ip in $server_ips; do
    echo "  │   [server-$idx] ssh -i $SSH_KEY_ABS -o \"ProxyCommand=ssh -i $SSH_KEY_ABS ${SSH_USER}@${REGISTRY_PUBLIC_IP} -W %h:%p\" ${SSH_USER}@${ip}"
    idx=$((idx + 1))
  done
  [ "$idx" -eq 0 ] && echo "  │   (none)"

  echo "  ├─────────────────────────────────────────────────────────────────────────┤"
  echo "  │ Downstream Agent Nodes                                                    │"
  idx=0
  for ip in $agent_ips; do
    echo "  │   [agent-$idx]  ssh -i $SSH_KEY_ABS -o \"ProxyCommand=ssh -i $SSH_KEY_ABS ${SSH_USER}@${REGISTRY_PUBLIC_IP} -W %h:%p\" ${SSH_USER}@${ip}"
    idx=$((idx + 1))
  done
  [ "$idx" -eq 0 ] && echo "  │   (none)"

  echo "  ├─────────────────────────────────────────────────────────────────────────┤"
  echo "  │ Run this on EACH downstream node after SSH                               │"
  if [ -n "$DOWNSTREAM_REG_TOKEN" ] && [ -n "$DOWNSTREAM_CA_CHECKSUM" ]; then
    echo "  │   CATTLE_SYSTEM_CATALOG=bundled curl --insecure -fL $RANCHER_SERVER_URL/system-agent-install.sh | sudo CATTLE_SYSTEM_CATALOG=bundled sh -s - --server $RANCHER_SERVER_URL --label 'cattle.io/os=linux' --token $DOWNSTREAM_REG_TOKEN --ca-checksum $DOWNSTREAM_CA_CHECKSUM --etcd --controlplane --worker"
  else
    echo "  │   CATTLE_SYSTEM_CATALOG=bundled curl --insecure -fL $RANCHER_SERVER_URL/system-agent-install.sh | sudo CATTLE_SYSTEM_CATALOG=bundled sh -s - --server $RANCHER_SERVER_URL --label 'cattle.io/os=linux' --token <TOKEN> --ca-checksum <CA_CHECKSUM> --etcd --controlplane --worker"
  fi
  echo "  ├─────────────────────────────────────────────────────────────────────────┤"
  echo "  │ First server private IP : $first_server"
  echo "  │ Destroy command         : ./create-downstream.sh --destroy"
  echo "  └─────────────────────────────────────────────────────────────────────────┘"
  echo ""
}

ensure_tools
ensure_prereqs
load_aws_env_from_tfvars
build_context
write_downstream_tfvars

if $DESTROY_MODE; then
  run_destroy
elif $PREP_ONLY; then
  log_step "Re-preparing existing downstream nodes (--prep-only)"
  server_ips=$(terraform -chdir="$DOWNSTREAM_TFDIR" output -json downstream_server_private_ips 2>/dev/null | jq -r '.[]' || true)
  agent_ips=$(terraform -chdir="$DOWNSTREAM_TFDIR" output -json downstream_agent_private_ips 2>/dev/null | jq -r '.[]' || true)
  if [ -z "$server_ips" ] && [ -z "$agent_ips" ]; then
    log_error "No downstream nodes found in terraform state. Run ./create-downstream.sh first."
    exit 1
  fi
  for ip in $server_ips $agent_ips; do
    wait_for_ssh "$ip" && prep_downstream_node "$ip" \
      && log_info "Node $ip re-prepared." \
      || log_warn "Node $ip prep failed."
  done
else
  run_create
fi
