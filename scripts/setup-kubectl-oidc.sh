#!/usr/bin/env bash
# =============================================================================
# setup-kubectl-oidc.sh — Generate kubeconfig snippet for OIDC authentication
# =============================================================================
# Outputs a kubeconfig YAML snippet that developers can merge into their
# ~/.kube/config to authenticate to the RKE2 cluster via Keycloak + kubelogin.
#
# Prerequisites:
#   - kubelogin installed (brew install int128/kubelogin/kubelogin)
#   - Root CA imported into OS trust store
#
# Usage:
#   ./scripts/setup-kubectl-oidc.sh                    # Print snippet to stdout
#   ./scripts/setup-kubectl-oidc.sh > /tmp/oidc.yaml   # Save to file
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Load .env for DOMAIN, KC_REALM, etc.
generate_or_load_env 2>/dev/null

# Determine cluster API server URL
CLUSTER_NAME=$(get_cluster_name 2>/dev/null || echo "rke2-prod")
API_SERVER=""

# Try to get API server from existing kubeconfig
RKE2_KUBECONFIG="${CLUSTER_DIR}/kubeconfig-rke2.yaml"
if [[ -f "$RKE2_KUBECONFIG" ]]; then
  API_SERVER=$(kubectl config view --kubeconfig="$RKE2_KUBECONFIG" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
fi

if [[ -z "$API_SERVER" ]]; then
  API_SERVER="https://<CLUSTER_API_SERVER>:6443"
  echo "# WARNING: Could not auto-detect API server URL. Replace <CLUSTER_API_SERVER> below." >&2
fi

# Extract Root CA for embedding
ROOT_CA_FILE="${CLUSTER_DIR}/root-ca.pem"
ROOT_CA_B64=""
if [[ -f "$ROOT_CA_FILE" ]]; then
  ROOT_CA_B64=$(base64 < "$ROOT_CA_FILE" | tr -d '\n')
fi

OIDC_ISSUER="https://keycloak.${DOMAIN}/realms/${KC_REALM}"

cat <<EOF
# =============================================================================
# OIDC kubeconfig snippet — merge into ~/.kube/config
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================
# To merge:
#   KUBECONFIG=~/.kube/config:/tmp/oidc.yaml kubectl config view --flatten > /tmp/merged
#   mv /tmp/merged ~/.kube/config
# =============================================================================

apiVersion: v1
kind: Config

clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${API_SERVER}
$(if [[ -n "$ROOT_CA_B64" ]]; then
echo "      certificate-authority-data: ${ROOT_CA_B64}"
else
echo "      # certificate-authority-data: <base64-encoded-root-ca.pem>"
fi)

users:
  - name: oidc-user
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=${OIDC_ISSUER}
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=groups
        interactiveMode: IfAvailable

contexts:
  - name: ${CLUSTER_NAME}-oidc
    context:
      cluster: ${CLUSTER_NAME}
      user: oidc-user
      namespace: default

current-context: ${CLUSTER_NAME}-oidc
EOF
