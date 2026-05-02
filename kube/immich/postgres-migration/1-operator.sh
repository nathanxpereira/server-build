#!/usr/bin/env bash
# Install the cloudnative-pg operator (v1.29.0).
# Run once per cluster — this is cluster-wide, not namespace-scoped.
set -euo pipefail

kubectl apply --server-side \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/v1.29.0/releases/cnpg-1.29.0.yaml

echo "Waiting for CNPG operator to be ready..."
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=120s

echo "CNPG operator ready."
