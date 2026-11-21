#!/bin/bash
# =============================================================================
# REGISTRY NODE BOOTSTRAP
# Runs as cloud-init user-data on first boot.
# Sets up: Docker registry, RKE2 artifact server, kubectl, helm
# =============================================================================
set -euo pipefail
exec > >(tee /var/log/airgap-setup.log | logger -t airgap-setup -s 2>/dev/console) 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log "=== Registry node bootstrap started ==="

# --------------------------------------------------------------------------
# 1. OS packages
# --------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  docker.io docker-compose \
  nginx apache2-utils \
  curl wget jq unzip git \
  ca-certificates gnupg

systemctl enable docker
systemctl start docker

# Allow default user to use docker
usermod -aG docker ${ssh_user} || true

log "Docker installed — version: $(docker --version)"

# --------------------------------------------------------------------------
# 2. Install SSH public key (allows deploy.sh to SSH in)
# --------------------------------------------------------------------------
mkdir -p /root/.ssh
echo "${ssh_public_key}" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

HOME_DIR="/home/${ssh_user}"
mkdir -p "$${HOME_DIR}/.ssh"
echo "${ssh_public_key}" >> "$${HOME_DIR}/.ssh/authorized_keys"
chmod 700 "$${HOME_DIR}/.ssh"
chmod 600 "$${HOME_DIR}/.ssh/authorized_keys"
chown -R ${ssh_user}:${ssh_user} "$${HOME_DIR}/.ssh"

# --------------------------------------------------------------------------
# 3. Docker private registry with htpasswd auth
# --------------------------------------------------------------------------
log "Setting up Docker registry..."
mkdir -p /opt/registry/{auth,data}

# Create htpasswd credentials
htpasswd -Bbn "${registry_username}" "${registry_password}" > /opt/registry/auth/htpasswd

cat > /opt/registry/docker-compose.yaml << 'DOCKERCOMPOSE'
version: "3"
services:
  registry:
    image: registry:2
    restart: always
    ports:
      - "5000:5000"
    environment:
      REGISTRY_AUTH: htpasswd
      REGISTRY_AUTH_HTPASSWD_REALM: "Registry Realm"
      REGISTRY_AUTH_HTPASSWD_PATH: /auth/htpasswd
      REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY: /var/lib/registry
      REGISTRY_HTTP_ADDR: "0.0.0.0:5000"
    volumes:
      - /opt/registry/auth:/auth
      - /opt/registry/data:/var/lib/registry
DOCKERCOMPOSE

cd /opt/registry && docker-compose up -d

# Wait for registry to become healthy
log "Waiting for registry to accept connections..."
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%%{http_code}" http://localhost:5000/v2/ || true)
  if [ "$${STATUS}" = "401" ]; then
    log "Registry is up (HTTP 401 = auth required = healthy)"
    break
  fi
  log "  attempt $${i}/30 (got $${STATUS}), retrying..."
  sleep 5
done

# --------------------------------------------------------------------------
# 4. Download RKE2 binaries and serve them via nginx
# Cluster nodes (no internet) download RKE2 from this server on port 8080
# --------------------------------------------------------------------------
log "Downloading RKE2 ${rke2_version} artifacts..."
mkdir -p /opt/rke2-artifacts

RKE2_VER="${rke2_version}"

# RKE2 install script
curl -sfL https://get.rke2.io -o /opt/rke2-artifacts/install.sh
chmod +x /opt/rke2-artifacts/install.sh

# RKE2 binary
curl -sfLo /opt/rke2-artifacts/rke2 \
  "https://github.com/rancher/rke2/releases/download/$${RKE2_VER}/rke2.linux-amd64"
chmod +x /opt/rke2-artifacts/rke2

# RKE2 checksums
curl -sfLo /opt/rke2-artifacts/sha256sum-amd64.txt \
  "https://github.com/rancher/rke2/releases/download/$${RKE2_VER}/sha256sum-amd64.txt" || true

# RKE2 air-gap images tarball (core images for RKE2 itself — needed on cluster nodes)
log "Downloading RKE2 air-gap images (this may take a few minutes)..."
curl -sfLo /opt/rke2-artifacts/rke2-images.linux-amd64.tar.zst \
  "https://github.com/rancher/rke2/releases/download/$${RKE2_VER}/rke2-images.linux-amd64.tar.zst"

log "RKE2 artifacts downloaded."

# --------------------------------------------------------------------------
# 5. nginx — serve /opt/rke2-artifacts on port 8080
# --------------------------------------------------------------------------
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/rke2-artifacts << 'NGINXCONF'
server {
    listen 8080;
    server_name _;

    location /rke2-artifacts/ {
        root /opt;
        autoindex on;
        add_header Cache-Control "no-cache";
    }

    location /ready {
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/rke2-artifacts /etc/nginx/sites-enabled/rke2-artifacts
nginx -t && systemctl reload nginx

log "nginx artifact server running on port 8080."

# --------------------------------------------------------------------------
# 6. Install kubectl
# --------------------------------------------------------------------------
log "Installing kubectl..."
K8S_STABLE=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -sfLo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$${K8S_STABLE}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# --------------------------------------------------------------------------
# 7. Install Helm ${helm_version}
# --------------------------------------------------------------------------
log "Installing Helm ${helm_version}..."
curl -sfL "https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz" \
  | tar -xz -C /tmp linux-amd64/helm
mv /tmp/linux-amd64/helm /usr/local/bin/helm
chmod +x /usr/local/bin/helm

# Add Helm repos — includes multiple Rancher release channels
# Enables support for: stable, latest, prime, alpha versions
helm repo add jetstack                 https://charts.jetstack.io
helm repo add rancher-latest           https://releases.rancher.com/server-charts/latest
helm repo add rancher-stable           https://releases.rancher.com/server-charts/stable
helm repo add rancher-prime            https://charts.rancher.com/server-charts/prime
helm repo add rancher-primealpha       https://charts.rancher.com/server-charts/alpha
helm repo add rancher-alpha            https://releases.rancher.com/server-charts/alpha
helm repo add rancher-alpha-prime      https://charts.optimus.rancher.io/server-charts/alpha
helm repo update

# Pre-download charts to /opt/helm-charts (for offline helm install from this node)
log "Downloading Helm charts..."
mkdir -p /opt/helm-charts
helm fetch jetstack/cert-manager \
  --version "${cert_manager_version}" \
  --destination /opt/helm-charts/

# Try to fetch Rancher chart from PRIME repos ONLY
# This enforces Rancher Prime installation: rancher-prime (stable) > rancher-alpha-prime (alpha)
RANCHER_CHART_FOUND=false
for REPO in rancher-prime rancher-alpha-prime; do
  if helm fetch "$${REPO}/rancher" \
    --version "${rancher_version}" \
    --destination /opt/helm-charts/ 2>/dev/null; then
    log "✓ Rancher ${rancher_version} found in $${REPO} repo"
    RANCHER_CHART_FOUND=true
    break
  fi
done

if [ "$${RANCHER_CHART_FOUND}" = "false" ]; then
  log "WARNING: Rancher ${rancher_version} not found in any repo, but will attempt install anyway"
fi

# Download cert-manager CRDs yaml
curl -sfLo /opt/helm-charts/cert-manager-crds.yaml \
  "https://github.com/cert-manager/cert-manager/releases/download/${cert_manager_version}/cert-manager.crds.yaml"

log "Helm charts downloaded to /opt/helm-charts/"
ls -lh /opt/helm-charts/

# --------------------------------------------------------------------------
# 8. Helper scripts used by deploy.sh (run on this node via SSH)
# --------------------------------------------------------------------------
mkdir -p /opt/scripts
mkdir -p /opt/image-lists
chown ${ssh_user}:${ssh_user} /opt/scripts /opt/image-lists
chmod 755 /opt/scripts /opt/image-lists

# Script: get kubeconfig from first server node
# Note: This script is called from deploy.sh which provides SSH access.
# The script uses SSH via ProxyCommand to reach the server through the registry node itself.
cat > /opt/scripts/fetch-kubeconfig.sh << 'FETCHKUBE'
#!/bin/bash
# Usage: fetch-kubeconfig.sh <server_private_ip> <ssh_user>
# Called from deploy.sh via: registry_exec ... bash /opt/scripts/fetch-kubeconfig.sh
# This script runs on the registry node and fetches kubeconfig from the RKE2 server.
set -euo pipefail
SERVER_IP="$1"
SSH_USER="$2"
mkdir -p /root/.kube
# The kubeconfig will be written to /root/.kube/config
# The SSH connection comes from deploy.sh which has already established connectivity
KUBECONFIG_CONTENT=$(ssh -i /root/.ssh/deploy_key \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    -o UserKnownHostsFile=/dev/null \
    "$${SSH_USER}@$${SERVER_IP}" \
    "sudo cat /etc/rancher/rke2/rke2.yaml" 2>/dev/null || true)
if [ -z "$KUBECONFIG_CONTENT" ]; then
  # Fallback: Try reading from the artifact server's shared data
  # If nodes are configured to share kubeconfig via artifact server
  echo "WARNING: Could not fetch kubeconfig via SSH, checking artifact server..."
  KUBECONFIG_CONTENT=$(curl -s "http://$${SERVER_IP}:8080/kubeconfig" 2>/dev/null || true)
  if [ -z "$KUBECONFIG_CONTENT" ]; then
    echo "ERROR: Could not fetch kubeconfig from $${SERVER_IP}"
    exit 1
  fi
fi
echo "$KUBECONFIG_CONTENT" \
  | sed "s/127.0.0.1/$${SERVER_IP}/g" \
  > /root/.kube/config
chmod 600 /root/.kube/config
echo "kubeconfig written to /root/.kube/config"
FETCHKUBE
chmod +x /opt/scripts/fetch-kubeconfig.sh

# --------------------------------------------------------------------------
# 9. Ready marker — deploy.sh polls this
# --------------------------------------------------------------------------
touch /tmp/registry-ready
log "=== Registry node bootstrap COMPLETE ==="
log "  Docker registry  : port 5000"
log "  Artifact server  : port 8080"
log "  Ready marker     : /tmp/registry-ready"
