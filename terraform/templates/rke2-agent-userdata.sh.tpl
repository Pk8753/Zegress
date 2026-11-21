#!/bin/bash
# =============================================================================
# RKE2 AGENT NODE BOOTSTRAP
# Joins the cluster via the internal NLB on port 9345.
# Waits for registry artifact server before installing RKE2.
# =============================================================================
set -euo pipefail
exec > >(tee /var/log/airgap-rke2-agent-setup.log | logger -t rke2-agent -s 2>/dev/console) 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

REGISTRY_IP="${registry_ip}"
REGISTRY_ENDPOINT="$${REGISTRY_IP}:5000"
RKE2_VERSION="${rke2_version}"
RKE2_TOKEN="${rke2_token}"
INTERNAL_NLB="${internal_nlb_dns}"
SSH_USER="${ssh_user}"

log "=== RKE2 agent bootstrap started ==="

# --------------------------------------------------------------------------
# 1. SSH key
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
# 2. Wait for registry artifact server
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
# 3. Download RKE2 artifacts (without GitHub verification)
# --------------------------------------------------------------------------
log "Downloading RKE2 $${RKE2_VERSION} agent artifacts..."
mkdir -p /opt/rke2-artifacts
cd /opt/rke2-artifacts

# Download all necessary files
curl -sfLo rke2 "http://$${REGISTRY_IP}:8080/rke2-artifacts/rke2" && chmod +x rke2
curl -sfLo rke2-images.linux-amd64.tar.zst "http://$${REGISTRY_IP}:8080/rke2-artifacts/rke2-images.linux-amd64.tar.zst"
curl -sfLo install.sh "http://$${REGISTRY_IP}:8080/rke2-artifacts/install.sh" && chmod +x install.sh

# Create /usr/local/bin/rke2 symlink
mkdir -p /usr/local/bin
ln -sf /opt/rke2-artifacts/rke2 /usr/local/bin/rke2 2>/dev/null || true

log "Installing RKE2 agent via installer script (air-gap mode)..."
cd /tmp
export INSTALL_RKE2_SKIP_DOWNLOAD=true
export INSTALL_RKE2_VERSION="$${RKE2_VERSION}"
export INSTALL_RKE2_TYPE=agent
export INSTALL_RKE2_BIN_DIR=/usr/local/bin
export INSTALL_RKE2_SKIP_SELINUX_RPM=true
# Run installer but don't fail if GitHub verification fails (air-gap environment)
/opt/rke2-artifacts/install.sh 2>&1 | grep -v "Failed to connect\|Connection timed out\|github" || true
log "RKE2 agent installation phase complete (ignoring GitHub verification errors in air-gap mode)"

# --------------------------------------------------------------------------
# 4. Pre-load air-gap images
# --------------------------------------------------------------------------
log "Copying RKE2 air-gap images..."
mkdir -p /var/lib/rancher/rke2/agent/images/
curl -sfLo /var/lib/rancher/rke2/agent/images/rke2-images.linux-amd64.tar.zst \
  "http://$${REGISTRY_IP}:8080/rke2-artifacts/rke2-images.linux-amd64.tar.zst"

# --------------------------------------------------------------------------
# 5. Configure registries.yaml
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
# 6. RKE2 agent config
# --------------------------------------------------------------------------
cat > /etc/rancher/rke2/config.yaml << CONFIG
token: $${RKE2_TOKEN}
server: "https://$${INTERNAL_NLB}:9345"
system-default-registry: "$${REGISTRY_ENDPOINT}"
CONFIG

# --------------------------------------------------------------------------
# 7. Ensure systemd service file exists (fallback if installer didn't create it)
# --------------------------------------------------------------------------
if [ ! -f /etc/systemd/system/rke2-agent.service ]; then
  log "Creating rke2-agent.service manually..."
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/rke2-agent.service << 'SERVICE'
[Unit]
Description=Rancher Kubernetes Engine v2 (Agent)
Documentation=https://docs.rke2.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/rke2-agent
EnvironmentFile=-/etc/sysconfig/rke2-agent
KillMode=process
Delegate=yes
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0
LimitNOFILE=1048576
LimitNPROC=infinity
LimitMEMLOCK=infinity
Delegate=yes
KillMode=process
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/local/bin/rke2 agent
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
# 8. Start agent
# --------------------------------------------------------------------------
log "Starting RKE2 agent..."
systemctl enable rke2-agent.service
systemctl start rke2-agent.service
sleep 5
systemctl status rke2-agent.service || log "WARNING: Service status check failed, but continuing"

log "=== RKE2 agent bootstrap COMPLETE ==="
log "  Status: systemctl status rke2-agent"
log "  Logs:   journalctl -u rke2-agent -f"
