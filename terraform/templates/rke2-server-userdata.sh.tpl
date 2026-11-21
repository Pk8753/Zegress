#!/bin/bash
# =============================================================================
# RKE2 SERVER NODE BOOTSTRAP
# First server  → initialises the cluster (--cluster-init)
# Other servers → join via internal NLB on port 9345
# All servers wait for the registry artifact server before starting.
# =============================================================================
set -euo pipefail
exec > >(tee /var/log/airgap-rke2-setup.log | logger -t rke2-setup -s 2>/dev/console) 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

REGISTRY_IP="${registry_ip}"
REGISTRY_ENDPOINT="$${REGISTRY_IP}:5000"
RKE2_VERSION="${rke2_version}"
RKE2_TOKEN="${rke2_token}"
INTERNAL_NLB="${internal_nlb_dns}"
IS_FIRST_SERVER="${is_first_server}"
RANCHER_HOSTNAME="${rancher_hostname}"
SSH_USER="${ssh_user}"

log "=== RKE2 server bootstrap started (first_server=$${IS_FIRST_SERVER}) ==="

# --------------------------------------------------------------------------
# 1. Install SSH key so deploy.sh (via registry bastion) can reach this node
# --------------------------------------------------------------------------
mkdir -p /root/.ssh
echo "${ssh_public_key}" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys

HOME_DIR="/home/$${SSH_USER}"
if [ -d "$${HOME_DIR}" ]; then
  mkdir -p "$${HOME_DIR}/.ssh"
  echo "${ssh_public_key}" >> "$${HOME_DIR}/.ssh/authorized_keys"
  chmod 700 "$${HOME_DIR}/.ssh" && chmod 600 "$${HOME_DIR}/.ssh/authorized_keys"
  chown -R "$${SSH_USER}:$${SSH_USER}" "$${HOME_DIR}/.ssh"
fi

# --------------------------------------------------------------------------
# 2. Wait for registry artifact server (port 8080)
# Registry bootstraps in ~5 min; cluster nodes wait here in the background
# --------------------------------------------------------------------------
log "Waiting for registry artifact server at http://$${REGISTRY_IP}:8080/ready ..."
for i in $(seq 1 60); do
  if curl -sf "http://$${REGISTRY_IP}:8080/ready" > /dev/null 2>&1; then
    log "Artifact server is ready."
    break
  fi
  log "  attempt $${i}/60, waiting 10s..."
  sleep 10
done

# --------------------------------------------------------------------------
# 3. Download RKE2 artifacts (without verification against GitHub)
# --------------------------------------------------------------------------
log "Downloading RKE2 $${RKE2_VERSION} artifacts from registry artifact server..."
mkdir -p /opt/rke2-artifacts
cd /opt/rke2-artifacts

# Download all necessary files
curl -sfLo rke2 "http://$${REGISTRY_IP}:8080/rke2-artifacts/rke2" && chmod +x rke2
curl -sfLo rke2-images.linux-amd64.tar.zst "http://$${REGISTRY_IP}:8080/rke2-artifacts/rke2-images.linux-amd64.tar.zst"
curl -sfLo install.sh "http://$${REGISTRY_IP}:8080/rke2-artifacts/install.sh" && chmod +x install.sh

# Create /usr/local/bin/rke2 symlink
mkdir -p /usr/local/bin
ln -sf /opt/rke2-artifacts/rke2 /usr/local/bin/rke2 2>/dev/null || true

log "Installing RKE2 via installer script (air-gap mode)..."
cd /tmp
export INSTALL_RKE2_SKIP_DOWNLOAD=true
export INSTALL_RKE2_VERSION="$${RKE2_VERSION}"
export INSTALL_RKE2_TYPE=server
export INSTALL_RKE2_BIN_DIR=/usr/local/bin
export INSTALL_RKE2_SKIP_SELINUX_RPM=true
# Run installer but don't fail if GitHub verification fails (air-gap environment)
/opt/rke2-artifacts/install.sh 2>&1 | grep -v "Failed to connect\|Connection timed out\|github" || true
log "RKE2 installation phase complete (ignoring GitHub verification errors in air-gap mode)"

# --------------------------------------------------------------------------
# 4. Pre-load RKE2 air-gap images into containerd's image store
# --------------------------------------------------------------------------
log "Copying RKE2 air-gap images..."
mkdir -p /var/lib/rancher/rke2/agent/images/
curl -sfLo /var/lib/rancher/rke2/agent/images/rke2-images.linux-amd64.tar.zst \
  "http://$${REGISTRY_IP}:8080/rke2-artifacts/rke2-images.linux-amd64.tar.zst"

# --------------------------------------------------------------------------
# 5. Configure registries.yaml — all container pulls go via private registry
# --------------------------------------------------------------------------
mkdir -p /etc/rancher/rke2

cat > /etc/rancher/rke2/registries.yaml << REGISTRIES
mirrors:
  "$${REGISTRY_ENDPOINT}":
    endpoint:
      - "http://$${REGISTRY_ENDPOINT}"
  "docker.io":
    endpoint:
      - "http://$${REGISTRY_ENDPOINT}"
  "registry.k8s.io":
    endpoint:
      - "http://$${REGISTRY_ENDPOINT}"
  "quay.io":
    endpoint:
      - "http://$${REGISTRY_ENDPOINT}"
  "ghcr.io":
    endpoint:
      - "http://$${REGISTRY_ENDPOINT}"

configs:
  "$${REGISTRY_ENDPOINT}":
    auth:
      username: "${registry_username}"
      password: "${registry_password}"
REGISTRIES

# --------------------------------------------------------------------------
# 6. Write RKE2 config
# --------------------------------------------------------------------------
%{ if is_first_server }
# First server: cluster-init mode
cat > /etc/rancher/rke2/config.yaml << CONFIG
token: $${RKE2_TOKEN}
cluster-init: true
system-default-registry: "$${REGISTRY_ENDPOINT}"
tls-san:
  - "$${RANCHER_HOSTNAME}"
  - "$${INTERNAL_NLB}"
  - "127.0.0.1"
  - "localhost"
CONFIG
%{ else }
# Additional server: join via internal NLB
cat > /etc/rancher/rke2/config.yaml << CONFIG
token: $${RKE2_TOKEN}
server: "https://$${INTERNAL_NLB}:9345"
system-default-registry: "$${REGISTRY_ENDPOINT}"
tls-san:
  - "$${RANCHER_HOSTNAME}"
  - "$${INTERNAL_NLB}"
  - "127.0.0.1"
  - "localhost"
CONFIG
%{ endif }

# --------------------------------------------------------------------------
# 7. Ensure systemd service file exists (fallback if installer didn't create it)
# --------------------------------------------------------------------------
if [ ! -f /etc/systemd/system/rke2-server.service ]; then
  log "Creating rke2-server.service manually..."
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/rke2-server.service << 'SERVICE'
[Unit]
Description=Rancher Kubernetes Engine v2 (Server)
Documentation=https://docs.rke2.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/rke2-server
EnvironmentFile=-/etc/sysconfig/rke2-server
KillMode=process
Delegate=yes
# Having non-zero Restart policy allows for graceful server upgrades
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0
LimitNOFILE=1048576
LimitNPROC=infinity
LimitMEMLOCK=infinity
Delegate=yes
KillMode=process
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/local/bin/rke2 server
ExecReload=/bin/kill -HUP $MAINPID
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rke2

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
fi

# --------------------------------------------------------------------------
# 8. Start RKE2
# --------------------------------------------------------------------------
log "Starting RKE2 server..."
systemctl enable rke2-server.service
systemctl start rke2-server.service
sleep 5
systemctl status rke2-server.service || log "WARNING: Service status check failed, but continuing"

# --------------------------------------------------------------------------
# 8. Symlink tools for convenience
# --------------------------------------------------------------------------
ln -sf /var/lib/rancher/rke2/bin/kubectl  /usr/local/bin/kubectl  2>/dev/null || true
ln -sf /var/lib/rancher/rke2/bin/crictl   /usr/local/bin/crictl   2>/dev/null || true

# Kubeconfig for root
mkdir -p /root/.kube
ln -sf /etc/rancher/rke2/rke2.yaml /root/.kube/config

log "=== RKE2 server bootstrap COMPLETE ==="
log "  Check status: systemctl status rke2-server"
log "  Logs:         journalctl -u rke2-server -f"
log "  kubectl:      kubectl get nodes"
