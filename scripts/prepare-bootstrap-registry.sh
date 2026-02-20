#!/usr/bin/env bash
# =============================================================================
# prepare-bootstrap-registry.sh — Populate a bootstrap registry for airgapped deploy
# =============================================================================
# Run this on a machine WITH internet access to pre-load all container images
# and Helm charts into the bootstrap registry. The bootstrap registry is then
# used by deploy-cluster.sh in airgapped mode (Phases 0-4) before the in-cluster
# Harbor is available.
#
# Prerequisites:
#   1. crane CLI installed (https://github.com/google/go-containerregistry)
#   2. helm CLI installed
#   3. BOOTSTRAP_REGISTRY set (hostname[:port])
#   4. Network access to the bootstrap registry AND public registries
#
# Usage:
#   export BOOTSTRAP_REGISTRY=registry.local:5000
#   ./scripts/prepare-bootstrap-registry.sh              # Full populate
#   ./scripts/prepare-bootstrap-registry.sh --list-only   # Just list images
#   ./scripts/prepare-bootstrap-registry.sh --charts-only  # Only push Helm charts
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die() { log_error "$@"; exit 1; }

# CLI flags
LIST_ONLY=false
CHARTS_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-only)   LIST_ONLY=true; shift ;;
    --charts-only) CHARTS_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--list-only] [--charts-only]"
      echo ""
      echo "  (default)      Populate bootstrap registry with all images + charts"
      echo "  --list-only    Just print the image/chart list (no push)"
      echo "  --charts-only  Only push Helm charts as OCI artifacts"
      exit 0
      ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# Validate
: "${BOOTSTRAP_REGISTRY:?Set BOOTSTRAP_REGISTRY to your bootstrap registry hostname[:port]}"
command -v crane &>/dev/null || die "crane CLI not found. Install: https://github.com/google/go-containerregistry"
command -v helm &>/dev/null  || die "helm CLI not found"

# Source .env for Kubernetes version and chart versions
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
fi
: "${KPS_CHART_VERSION:=72.6.2}"

# ---- RKE2 Kubernetes version (from terraform.tfvars) ----
K8S_VERSION=$(grep 'kubernetes_version' "${REPO_ROOT}/cluster/terraform.tfvars" 2>/dev/null \
  | awk -F'"' '{print $2}' || echo "v1.34.2+rke2r1")
log_info "Kubernetes version: ${K8S_VERSION}"

# =============================================================================
# IMAGE LIST
# =============================================================================
# RKE2 system images — download the official list
RKE2_IMAGES_URL="https://github.com/rancher/rke2/releases/download/${K8S_VERSION}/rke2-images-all.linux-amd64.txt"

# Application images needed for Phases 0-4 (before Harbor exists)
APP_IMAGES=(
  # cert-manager
  "quay.io/jetstack/cert-manager-controller:v1.19.3"
  "quay.io/jetstack/cert-manager-webhook:v1.19.3"
  "quay.io/jetstack/cert-manager-cainjector:v1.19.3"
  # CNPG
  "ghcr.io/cloudnative-pg/cloudnative-pg:1.25.1"
  "ghcr.io/cloudnative-pg/postgresql:17.2"
  # Redis Operator
  "quay.io/opstree/redis-operator:latest"
  "quay.io/opstree/redis:v7.0.15"
  "quay.io/opstree/redis-sentinel:v7.0.15"
  "quay.io/opstree/redis-exporter:v1.44.0"
  # Vault
  "hashicorp/vault:1.18.3"
  "hashicorp/vault-csi-provider:1.4.1"
  # Monitoring
  "docker.io/grafana/grafana:11.4.0"
  "docker.io/grafana/loki:3.1.0"
  "docker.io/grafana/alloy:v1.3.0"
  "quay.io/prometheus/prometheus:v3.2.1"
  "quay.io/prometheus/alertmanager:v0.28.1"
  "quay.io/prometheus-operator/prometheus-operator:v0.80.1"
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.80.1"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.14.0"
  "quay.io/prometheus/node-exporter:v1.9.0"
  "quay.io/oauth2-proxy/oauth2-proxy:v7.8.1"
  # Harbor
  "goharbor/harbor-core:v2.12.2"
  "goharbor/harbor-portal:v2.12.2"
  "goharbor/harbor-registryctl:v2.12.2"
  "goharbor/harbor-jobservice:v2.12.2"
  "goharbor/harbor-trivy-adapter:v2.12.2"
  "goharbor/harbor-exporter:v2.12.2"
  "goharbor/nginx-photon:v2.12.2"
  # MinIO
  "docker.io/minio/minio:RELEASE.2024-10-02T17-50-41Z"
  "docker.io/minio/mc:RELEASE.2024-10-02T08-27-28Z"
  # Utilities
  "curlimages/curl:8.12.1"
  "alpine:3.21"
  # Cluster autoscaler
  "registry.k8s.io/autoscaling/cluster-autoscaler:v1.32.0"
)

# Helm charts (name version repo_url)
HELM_CHARTS=(
  "jetstack/cert-manager:v1.19.3:https://charts.jetstack.io"
  "cnpg/cloudnative-pg:0.27.1:https://cloudnative-pg.github.io/charts"
  "ot-helm/redis-operator:0.18.4:https://ot-container-kit.github.io/helm-charts/"
  "hashicorp/vault:0.32.0:https://helm.releases.hashicorp.com"
  "prometheus-community/kube-prometheus-stack:${KPS_CHART_VERSION}:https://prometheus-community.github.io/helm-charts"
  "goharbor/harbor:1.18.2:https://helm.goharbor.io"
)

# =============================================================================
# LIST MODE
# =============================================================================
if $LIST_ONLY; then
  echo ""
  echo -e "${BOLD}=== RKE2 System Images ===${NC}"
  echo "Download from: ${RKE2_IMAGES_URL}"
  echo ""
  echo -e "${BOLD}=== Application Images (Phases 0-4) ===${NC}"
  printf '%s\n' "${APP_IMAGES[@]}"
  echo ""
  echo -e "${BOLD}=== Helm Charts ===${NC}"
  for chart in "${HELM_CHARTS[@]}"; do
    IFS=':' read -r name version repo <<< "$chart"
    echo "  ${name} v${version} (${repo})"
  done
  echo ""
  echo "Total app images: ${#APP_IMAGES[@]}"
  echo "Total Helm charts: ${#HELM_CHARTS[@]}"
  exit 0
fi

# =============================================================================
# PUSH IMAGES
# =============================================================================
if ! $CHARTS_ONLY; then
  echo ""
  log_info "=== Copying RKE2 system images ==="
  log_info "Downloading image list from ${RKE2_IMAGES_URL}..."
  rke2_images=$(curl -sfL "$RKE2_IMAGES_URL" 2>/dev/null || true)
  if [[ -z "$rke2_images" ]]; then
    log_warn "Could not download RKE2 image list — skipping system images"
  else
    total=$(echo "$rke2_images" | wc -l)
    count=0
    while IFS= read -r img; do
      [[ -z "$img" || "$img" == "#"* ]] && continue
      count=$((count + 1))
      target="${BOOTSTRAP_REGISTRY}/${img}"
      echo -ne "\r  [${count}/${total}] ${img}..."
      crane copy "$img" "$target" 2>/dev/null || log_warn "Failed: ${img}"
    done <<< "$rke2_images"
    echo ""
    log_ok "Copied ${count} RKE2 system images"
  fi

  echo ""
  log_info "=== Copying application images ==="
  total=${#APP_IMAGES[@]}
  count=0
  for img in "${APP_IMAGES[@]}"; do
    count=$((count + 1))
    # Determine target path: prepend registry domain as project name
    # docker.io/grafana/grafana:11.4.0 → BOOTSTRAP_REGISTRY/docker.io/grafana/grafana:11.4.0
    registry=$(echo "$img" | cut -d'/' -f1)
    if [[ "$registry" == *"."* ]]; then
      target="${BOOTSTRAP_REGISTRY}/${img}"
    else
      target="${BOOTSTRAP_REGISTRY}/docker.io/${img}"
    fi
    echo -ne "\r  [${count}/${total}] ${img}..."
    crane copy "$img" "$target" 2>/dev/null || log_warn "Failed: ${img}"
  done
  echo ""
  log_ok "Copied ${count} application images"
fi

# =============================================================================
# PUSH HELM CHARTS
# =============================================================================
echo ""
log_info "=== Pushing Helm charts as OCI artifacts ==="
for chart_entry in "${HELM_CHARTS[@]}"; do
  IFS=':' read -r chart_name chart_version repo_url <<< "$chart_entry"
  repo_alias=$(echo "$chart_name" | cut -d'/' -f1)
  chart_short=$(echo "$chart_name" | cut -d'/' -f2)

  log_info "  ${chart_name} v${chart_version}..."

  # Add repo
  helm repo add "$repo_alias" "$repo_url" 2>/dev/null || true
  helm repo update "$repo_alias" 2>/dev/null || true

  # Pull chart
  helm pull "$chart_name" --version "$chart_version" -d /tmp 2>/dev/null || {
    log_warn "Failed to pull ${chart_name}:${chart_version}"
    continue
  }

  # Push as OCI
  tarball=$(ls /tmp/${chart_short}-${chart_version}.tgz 2>/dev/null | head -1)
  if [[ -n "$tarball" ]]; then
    helm push "$tarball" "oci://${BOOTSTRAP_REGISTRY}/charts" 2>/dev/null || \
      log_warn "Failed to push ${chart_name} to OCI"
    rm -f "$tarball"
    log_ok "  Pushed: oci://${BOOTSTRAP_REGISTRY}/charts/${chart_short}:${chart_version}"
  fi
done

echo ""
log_ok "Bootstrap registry population complete!"
log_info "Registry: ${BOOTSTRAP_REGISTRY}"
log_info ""
log_info "Next steps:"
log_info "  1. Set BOOTSTRAP_REGISTRY=${BOOTSTRAP_REGISTRY} in scripts/.env"
log_info "  2. Set AIRGAPPED=true in scripts/.env"
log_info "  3. Set HELM_OCI_* variables to point to oci://${BOOTSTRAP_REGISTRY}/charts/<chart>"
log_info "  4. Run: ./scripts/deploy-cluster.sh"
