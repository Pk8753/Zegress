#!/bin/bash
# =============================================================================
# INSTALL RANCHER VIA HELM
# Runs ON the registry node (called from deploy.sh via SSH).
# Gets kubeconfig from first server node, then helm installs cert-manager
# and Rancher using pre-downloaded charts.
# =============================================================================
set -euo pipefail
# Prefer /var/log, fallback to /tmp when running as non-root via SSH.
LOG_FILE="/var/log/install-rancher.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="/tmp/install-rancher.log"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%H:%M:%S')] $*"; }

SERVER_IP="${1}"
RANCHER_HOSTNAME="${2}"
RANCHER_PASSWORD="${3}"
REGISTRY_ENDPOINT="${4}"   # e.g. "10.0.1.50:5000"
TLS_MODE="${5:-rancher-self-signed}"
CERT_MANAGER_VERSION="${6:-v1.14.3}"
RANCHER_VERSION="${7}"
SSH_USER="${8:-ubuntu}"

log "=== Installing Rancher ==="
log "  Server IP          : $SERVER_IP"
log "  Rancher hostname   : $RANCHER_HOSTNAME"
log "  Registry endpoint  : $REGISTRY_ENDPOINT"
log "  TLS mode           : $TLS_MODE"
log "  cert-manager ver   : $CERT_MANAGER_VERSION"
log "  Rancher version    : $RANCHER_VERSION"

# --------------------------------------------------------------------------
# 1. Get kubeconfig from first RKE2 server
# --------------------------------------------------------------------------
log "Fetching kubeconfig from $SERVER_IP..."
mkdir -p ~/.kube
ssh -i ~/.ssh/id_rsa \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "$SSH_USER@$SERVER_IP" \
    "sudo cat /etc/rancher/rke2/rke2.yaml" \
  | sed "s/127.0.0.1/$SERVER_IP/g" \
  > ~/.kube/config
chmod 600 ~/.kube/config
log "kubeconfig saved."

# --------------------------------------------------------------------------
# 2. Wait for cluster to be ready
# --------------------------------------------------------------------------
log "Waiting for Kubernetes API..."
for i in $(seq 1 30); do
  if kubectl get nodes --request-timeout=5s &>/dev/null; then
    log "API server is responding."
    break
  fi
  log "  waiting... attempt $i/30"
  sleep 10
done

log "Current cluster nodes:"
kubectl get nodes -o wide

# --------------------------------------------------------------------------
# 3. Install cert-manager (required for rancher-self-signed and lets-encrypt)
# --------------------------------------------------------------------------
if [[ "$TLS_MODE" != "secret" ]]; then
  log "Installing cert-manager $CERT_MANAGER_VERSION..."

  # Ensure cert-manager images exist in private registry before helm install.
  CERT_MANAGER_IMAGES=(
    "quay.io/jetstack/cert-manager-controller:$CERT_MANAGER_VERSION"
    "quay.io/jetstack/cert-manager-webhook:$CERT_MANAGER_VERSION"
    "quay.io/jetstack/cert-manager-cainjector:$CERT_MANAGER_VERSION"
    "quay.io/jetstack/cert-manager-startupapicheck:$CERT_MANAGER_VERSION"
    "quay.io/jetstack/cert-manager-acmesolver:$CERT_MANAGER_VERSION"
  )
  for src_image in "${CERT_MANAGER_IMAGES[@]}"; do
    # Push through localhost to avoid HTTPS enforcement on private IP endpoint.
    dst_image_push="localhost:5000/$src_image"
    if ! docker manifest inspect "$dst_image_push" >/dev/null 2>&1; then
      log "Mirroring image: $src_image -> $dst_image_push"
      docker pull "$src_image"
      docker tag "$src_image" "$dst_image_push"
      docker push "$dst_image_push"
      docker rmi "$src_image" "$dst_image_push" >/dev/null 2>&1 || true
    fi
  done

  # Apply CRDs
  kubectl apply -f /opt/helm-charts/cert-manager-crds.yaml
  log "cert-manager CRDs applied."

  # Create namespace
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

  # Find the downloaded chart
  CERT_CHART=$(ls /opt/helm-charts/cert-manager-*.tgz 2>/dev/null | head -1)
  if [ -z "$CERT_CHART" ]; then
    log "cert-manager chart not found in /opt/helm-charts/, fetching..."
    helm fetch jetstack/cert-manager --version "$CERT_MANAGER_VERSION" --destination /opt/helm-charts/
    CERT_CHART=$(ls /opt/helm-charts/cert-manager-*.tgz | head -1)
  fi

  # Clear stuck helm operation from previous failed/pending installs.
  if helm -n cert-manager status cert-manager >/dev/null 2>&1; then
    CERT_STATUS=$(helm -n cert-manager status cert-manager -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || true)
    if [[ "$CERT_STATUS" == pending* ]]; then
      log "Detected stuck cert-manager release state: $CERT_STATUS; uninstalling stale release."
      helm -n cert-manager uninstall cert-manager || true
      sleep 10
    fi
  fi

  CERT_OK=false
  for attempt in 1 2 3; do
    log "Installing cert-manager (attempt $attempt/3)..."
    if helm upgrade --install cert-manager "$CERT_CHART" \
      --namespace cert-manager \
      --set image.repository="$REGISTRY_ENDPOINT/quay.io/jetstack/cert-manager-controller" \
      --set webhook.image.repository="$REGISTRY_ENDPOINT/quay.io/jetstack/cert-manager-webhook" \
      --set cainjector.image.repository="$REGISTRY_ENDPOINT/quay.io/jetstack/cert-manager-cainjector" \
      --set startupapicheck.image.repository="$REGISTRY_ENDPOINT/quay.io/jetstack/cert-manager-startupapicheck" \
      --set "extraArgs[0]=--acme-http01-solver-image=$REGISTRY_ENDPOINT/quay.io/jetstack/cert-manager-acmesolver:$CERT_MANAGER_VERSION" \
      --wait --timeout 15m; then
      CERT_OK=true
      break
    fi

    log "cert-manager install attempt $attempt failed; current pod status:"
    kubectl get pods -n cert-manager -o wide || true
    sleep 30
  done

  if [ "$CERT_OK" != "true" ]; then
    log "ERROR: cert-manager installation failed after retries."
    exit 1
  fi

  log "cert-manager installed successfully."
  kubectl get pods -n cert-manager
fi

# --------------------------------------------------------------------------
# 4. Install Rancher
# --------------------------------------------------------------------------
log "Installing Rancher $RANCHER_VERSION..."

kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

# Minimal fix: do not reuse stale Rancher tarballs from older runs.
find /opt/helm-charts -maxdepth 1 -type f -name 'rancher-*.tgz' -delete 2>/dev/null || true

RANCHER_CHART=$(ls /opt/helm-charts/rancher-*.tgz 2>/dev/null | head -1)
if [ -z "$RANCHER_CHART" ]; then
  log "Rancher chart not found in /opt/helm-charts/, fetching from PRIME repos only..."
  CHART_FOUND=false
  for REPO in rancher-prime rancher-alpha-prime; do
    if helm fetch "$REPO/rancher" --version "$RANCHER_VERSION" --destination /opt/helm-charts/ 2>/dev/null; then
      log "✓ Found Rancher $RANCHER_VERSION in $REPO"
      CHART_FOUND=true
      break
    fi
    log "  (not in $REPO)"
  done

  if [ "$CHART_FOUND" = "false" ]; then
    log "WARNING: Rancher chart not found in any repo, attempting with default chart location"
  fi

  RANCHER_CHART=$(ls /opt/helm-charts/rancher-*.tgz 2>/dev/null | head -1)
fi

if [ -z "$RANCHER_CHART" ]; then
  log "ERROR: Rancher chart could not be fetched or located for version $RANCHER_VERSION."
  exit 1
fi

# Build helm command based on TLS mode
HELM_CMD="helm upgrade --install rancher $RANCHER_CHART \
  --namespace cattle-system \
  --set hostname=$RANCHER_HOSTNAME \
  --set bootstrapPassword=$RANCHER_PASSWORD \
  --set systemDefaultRegistry=$REGISTRY_ENDPOINT \
  --set image.pullPolicy=Always \
  --set useBundledSystemChart=true \
  --set rancherImage=$REGISTRY_ENDPOINT/rancher/rancher"

case "$TLS_MODE" in
  "rancher-self-signed")
    HELM_CMD="$HELM_CMD --set ingress.tls.source=rancher"
    ;;
  "lets-encrypt")
    HELM_CMD="$HELM_CMD --set ingress.tls.source=letsEncrypt --set letsEncrypt.email=${LETS_ENCRYPT_EMAIL:-}"
    ;;
  "secret")
    HELM_CMD="$HELM_CMD --set ingress.tls.source=secret"
    ;;
esac

HELM_CMD="$HELM_CMD --wait --timeout 15m"
log "Running: $HELM_CMD"
eval "$HELM_CMD"

log ""
log "=== Rancher Installed Successfully ==="
log "  URL: https://$RANCHER_HOSTNAME"
log "  Waiting for Rancher pods to become ready..."

kubectl rollout status deploy/rancher -n cattle-system --timeout=5m || true
kubectl get pods -n cattle-system

log "Done! Access Rancher at: https://$RANCHER_HOSTNAME"
