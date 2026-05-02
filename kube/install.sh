#!/usr/bin/env bash
# Install k3s single-node cluster with data stored on the ZFS pool.
# Run as root or with sudo.
set -euo pipefail

K3S_DATA_DIR="/tank/appdata/k3s"

mkdir -p "$K3S_DATA_DIR"

# Disable Traefik — we keep the existing Nginx reverse proxy.
# Disable servicelb — we expose services via NodePort + Nginx.
curl -sfL https://get.k3s.io | sh -s - \
  --data-dir "$K3S_DATA_DIR" \
  --disable traefik \
  --disable servicelb

# Make kubeconfig accessible to the current user.
KUBECONFIG_DIR="$HOME/.kube"
mkdir -p "$KUBECONFIG_DIR"
cp "$K3S_DATA_DIR/server/creds/admin.kubeconfig" "$KUBECONFIG_DIR/config" 2>/dev/null \
  || cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_DIR/config"
chmod 600 "$KUBECONFIG_DIR/config"

echo ""
echo "k3s installed. Verify with:"
echo "  kubectl get nodes"
