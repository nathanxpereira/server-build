#!/usr/bin/env bash
# Reads /tank/appdata/secrets.env and creates/updates all k8s Secrets.
# Safe to re-run — existing secrets are updated in place.
#
# First-time setup:
#   cp scripts/secrets.env.template /tank/appdata/secrets.env
#   nano /tank/appdata/secrets.env   # fill in all values
#   bash scripts/apply-secrets.sh
set -euo pipefail

SECRETS_FILE="${SECRETS_FILE:-/tank/appdata/secrets.env}"

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Error: $SECRETS_FILE not found."
    echo "Run: cp scripts/secrets.env.template $SECRETS_FILE"
    echo "Then fill in all values and re-run this script."
    exit 1
fi

echo "Checking kubectl connection..."
kubectl cluster-info --request-timeout=5s >/dev/null
echo ""

# Source the secrets file — makes all KEY=VALUE pairs available as shell variables.
set -o allexport
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +o allexport

# ── Helper ────────────────────────────────────────────────────────────────────

apply_secret() {
    local name="$1" namespace="$2"
    shift 2
    kubectl create secret generic "$name" \
        --namespace="$namespace" \
        "$@" \
        --dry-run=client -o yaml \
      | kubectl apply -f - >/dev/null
    echo "  ✓ $namespace/$name"
}

# ── Cloudflare Tunnel ─────────────────────────────────────────────────────────

echo "[ cloudflare ]"
apply_secret cloudflare-tunnel cloudflare \
    "--from-literal=token=${CLOUDFLARE_TUNNEL_TOKEN}"

# ── Actual Budget ─────────────────────────────────────────────────────────────

echo "[ actual-budget ]"
apply_secret actual-budget-nathan actual-budget \
    "--from-literal=ACTUAL_OPENID_DISCOVERY_URL=${ACTUAL_NATHAN_OPENID_DISCOVERY_URL}" \
    "--from-literal=ACTUAL_OPENID_CLIENT_ID=${ACTUAL_NATHAN_OPENID_CLIENT_ID}" \
    "--from-literal=ACTUAL_OPENID_CLIENT_SECRET=${ACTUAL_NATHAN_OPENID_CLIENT_SECRET}"

apply_secret actual-budget-cherise actual-budget \
    "--from-literal=ACTUAL_OPENID_DISCOVERY_URL=${ACTUAL_CHERISE_OPENID_DISCOVERY_URL}" \
    "--from-literal=ACTUAL_OPENID_CLIENT_ID=${ACTUAL_CHERISE_OPENID_CLIENT_ID}" \
    "--from-literal=ACTUAL_OPENID_CLIENT_SECRET=${ACTUAL_CHERISE_OPENID_CLIENT_SECRET}"

# ── Immich ────────────────────────────────────────────────────────────────────

echo "[ immich ]"
apply_secret immich immich \
    "--from-literal=DB_USERNAME=${IMMICH_DB_USERNAME}" \
    "--from-literal=DB_PASSWORD=${IMMICH_DB_PASSWORD}" \
    "--from-literal=DB_DATABASE_NAME=${IMMICH_DB_DATABASE_NAME}"

# CNPG uses kubernetes.io/basic-auth type — handled separately
kubectl create secret generic immich-cnpg-credentials \
    --namespace=immich \
    --from-literal=username="${IMMICH_DB_USERNAME}" \
    --from-literal=password="${IMMICH_DB_PASSWORD}" \
    --type=kubernetes.io/basic-auth \
    --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
echo "  ✓ immich/immich-cnpg-credentials"

# ── Nextcloud ─────────────────────────────────────────────────────────────────

echo "[ nextcloud ]"
apply_secret nextcloud-db nextcloud \
    "--from-literal=MYSQL_ROOT_PASSWORD=${NEXTCLOUD_MYSQL_ROOT_PASSWORD}" \
    "--from-literal=MYSQL_PASSWORD=${NEXTCLOUD_MYSQL_PASSWORD}" \
    "--from-literal=REDIS_PASSWORD=${NEXTCLOUD_REDIS_PASSWORD}" \
    "--from-literal=COLLABORA_PASSWORD=${NEXTCLOUD_COLLABORA_PASSWORD}"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "All secrets applied from $SECRETS_FILE"
