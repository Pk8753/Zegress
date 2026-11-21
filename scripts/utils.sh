#!/bin/bash
# =============================================================================
# SHARED UTILITIES — sourced by all deploy scripts
# =============================================================================

# SSH options — strict host checking off for ephemeral EC2 nodes
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=30"

# ---- Logging ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ---- Wait for SSH to become available on a host ----
wait_for_ssh() {
  local host="$1"
  local user="$2"
  local key="$3"
  local max_attempts="${4:-30}"

  log_info "Waiting for SSH on $user@$host ..."
  for i in $(seq 1 "$max_attempts"); do
    if ssh $SSH_OPTS -i "$key" "$user@$host" "echo ok" &>/dev/null; then
      log_info "SSH is ready on $host"
      return 0
    fi
    log_info "  attempt $i/$max_attempts — waiting 10s..."
    sleep 10
  done
  log_error "SSH did not become available on $host after $max_attempts attempts"
  return 1
}

# ---- Run a command on the registry node ----
registry_exec() {
  local registry_ip="$1"
  local ssh_user="$2"
  local key="$3"
  shift 3
  ssh $SSH_OPTS -i "$key" "$ssh_user@$registry_ip" "$@"
}

# ---- Copy a file to the registry node ----
registry_copy() {
  local registry_ip="$1"
  local ssh_user="$2"
  local key="$3"
  local src="$4"
  local dst="$5"
  scp $SSH_OPTS -i "$key" "$src" "$ssh_user@$registry_ip:$dst"
}

# ---- Wait for /tmp/registry-ready marker on registry node ----
wait_registry_ready() {
  local registry_ip="$1"
  local ssh_user="$2"
  local key="$3"
  local max_attempts="${4:-36}"   # 36 × 10s = 6 min

  log_info "Waiting for registry bootstrap to complete..."
  for i in $(seq 1 "$max_attempts"); do
    if ssh $SSH_OPTS -i "$key" "$ssh_user@$registry_ip" \
        "test -f /tmp/registry-ready" &>/dev/null; then
      log_info "Registry bootstrap complete."
      return 0
    fi
    log_info "  attempt $i/$max_attempts — waiting 10s..."
    sleep 10
  done
  log_error "Registry bootstrap did not complete in time. Check /var/log/airgap-setup.log"
  return 1
}

# ---- Wait for RKE2 cluster: all nodes Ready ----
wait_rke2_ready() {
  local registry_ip="$1"
  local ssh_user="$2"
  local key="$3"
  local expected_nodes="${4:-1}"
  local max_attempts="${5:-60}"   # 60 × 20s = 20 min

  log_info "Waiting for $expected_nodes RKE2 node(s) to become Ready..."
  for i in $(seq 1 "$max_attempts"); do
    READY=$(ssh $SSH_OPTS -i "$key" "$ssh_user@$registry_ip" "sudo kubectl --kubeconfig /root/.kube/config get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true" 2>/dev/null || echo 0)
    # Keep only first token in case remote output has extra whitespace/newlines
    READY=$(echo "$READY" | awk '{print $1}')
    [ -z "$READY" ] && READY=0
    log_info "  Ready nodes: $READY / $expected_nodes (attempt $i/$max_attempts)"
    if [ "$READY" -ge "$expected_nodes" ] 2>/dev/null; then
      log_info "Cluster is ready."
      return 0
    fi
    sleep 20
  done
  log_error "RKE2 cluster did not become ready in time."
  return 1
}

# ---- Wait for Rancher UI to respond ----
wait_rancher_ui() {
  local rancher_url="$1"
  local max_attempts="${2:-30}"   # 30 × 20s = 10 min
  local total_timeout_s="${3:-300}"  # hard cap: 5 minutes by default
  local started_at now elapsed
  started_at=$(date +%s)

  log_info "Waiting for Rancher UI at $rancher_url ..."
  for i in $(seq 1 "$max_attempts"); do
    now=$(date +%s)
    elapsed=$((now - started_at))
    if [ "$elapsed" -ge "$total_timeout_s" ]; then
      log_error "Rancher UI check timed out after ${total_timeout_s}s."
      return 1
    fi

    local http_code
    if http_code=$(curl -sk --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "$rancher_url/" 2>/dev/null); then
      :
    else
      http_code="000"
    fi

    log_info "  attempt $i/$max_attempts — HTTP $http_code"
    if [[ "$http_code" =~ ^(200|301|302|401|403)$ ]]; then
      log_info "Rancher UI is responding."
      return 0
    fi

    now=$(date +%s)
    elapsed=$((now - started_at))
    if [ "$elapsed" -ge "$total_timeout_s" ]; then
      log_error "Rancher UI check timed out after ${total_timeout_s}s."
      return 1
    fi

    sleep 20
  done
  log_error "Rancher UI did not become available."
  return 1
}
