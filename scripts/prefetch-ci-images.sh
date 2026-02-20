#!/usr/bin/env bash
# prefetch-ci-images.sh — Populate Harbor proxy cache with CI tool images
#
# In airgapped environments, GitLab CI runners pull images through Harbor's
# proxy cache (e.g., harbor.DOMAIN/docker.io/library/golang:1.23-alpine).
# This script triggers the cache population by running crane manifest checks
# from inside the cluster, so the first real CI pipeline doesn't stall.
#
# Usage:
#   ./scripts/prefetch-ci-images.sh             # prefetch all images
#   ./scripts/prefetch-ci-images.sh --dry-run   # list Harbor proxy URLs only
#
# Follows the same crane-pod pattern as push_operator_images() in lib.sh.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPTS_DIR}/lib.sh"

# Load .env if not already loaded
if [[ -z "${DOMAIN:-}" ]]; then
  if [[ -f "${SCRIPTS_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPTS_DIR}/.env"
  else
    die ".env not found and DOMAIN not set"
  fi
fi

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

HARBOR_FQDN="harbor.${DOMAIN}"

# ---------------------------------------------------------------------------
# CI tool images — must stay in sync with services/gitlab-ci-templates/jobs/
# Format: <upstream-registry>/<path>:<tag>
# ---------------------------------------------------------------------------
CI_IMAGES=(
  # test.yml
  "docker.io/library/golang:1.23-alpine"
  "docker.io/library/node:22-alpine"
  "docker.io/library/python:3.12-slim"
  # build.yml
  "gcr.io/kaniko-project/executor:v1.23.2-debug"
  # deploy.yml
  "docker.io/argoproj/argocd:v2.14.0"
  "docker.io/bitnami/git:latest"
  # promote.yml
  "gcr.io/go-containerregistry/crane:debug"
  # scan.yml
  "docker.io/zricethezav/gitleaks:latest"
  "docker.io/semgrep/semgrep:latest"
  "docker.io/aquasec/trivy:latest"
  "docker.io/anchore/syft:latest"
  # lint.yml
  "docker.io/hadolint/hadolint:latest-alpine"
  "docker.io/cytopia/yamllint:latest"
  "docker.io/koalaman/shellcheck-alpine:stable"
  # infrastructure.yml
  "docker.io/bitnami/kubectl:latest"
  # default runner image
  "docker.io/library/alpine:3.21"
)

# ---------------------------------------------------------------------------
# Convert upstream image ref to Harbor proxy-cache URL
# docker.io/library/golang:1.23-alpine → harbor.DOMAIN/docker.io/library/golang:1.23-alpine
# gcr.io/kaniko-project/executor:v1.23.2-debug → harbor.DOMAIN/gcr.io/kaniko-project/executor:v1.23.2-debug
# ---------------------------------------------------------------------------
to_harbor_proxy_ref() {
  local upstream="$1"
  local registry="${upstream%%/*}"
  local remainder="${upstream#*/}"
  echo "${HARBOR_FQDN}/${registry}/${remainder}"
}

# ---------------------------------------------------------------------------
# Dry-run mode: just list all Harbor proxy URLs
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry run — Harbor proxy URLs for CI tool images:"
  for img in "${CI_IMAGES[@]}"; do
    echo "  $(to_harbor_proxy_ref "$img")"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ "${AIRGAPPED:-false}" != "true" ]]; then
  log_info "AIRGAPPED is not true — skipping CI image prefetch"
  exit 0
fi

# Get Harbor admin password
admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
if [[ -z "$admin_pass" ]]; then
  admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" 2>/dev/null | awk -F'"' '{print $2}' || true)
fi
if [[ -z "$admin_pass" || "$admin_pass" == *CHANGEME* ]]; then
  log_warn "Could not resolve Harbor admin password — skipping CI image prefetch"
  exit 0
fi

# ---------------------------------------------------------------------------
# Create crane pod inside the cluster
# ---------------------------------------------------------------------------
POD_NAME="ci-image-prefetch"
kubectl delete pod "$POD_NAME" -n default --ignore-not-found 2>/dev/null || true

log_info "Creating crane pod for CI image prefetch..."
kubectl run "$POD_NAME" -n default \
  --image=gcr.io/go-containerregistry/crane:debug \
  --restart=Never \
  --command -- sleep 600

if ! kubectl wait --for=condition=ready pod/"$POD_NAME" -n default --timeout=120s 2>/dev/null; then
  log_warn "crane pod failed to start — skipping CI image prefetch"
  kubectl delete pod "$POD_NAME" -n default --ignore-not-found 2>/dev/null || true
  exit 0
fi

# Authenticate crane to Harbor
kubectl exec "$POD_NAME" -n default -- \
  crane auth login "${HARBOR_FQDN}" -u admin -p "${admin_pass}" --insecure 2>/dev/null || {
  log_warn "crane auth login failed — skipping CI image prefetch"
  kubectl delete pod "$POD_NAME" -n default --ignore-not-found 2>/dev/null || true
  exit 0
}

# ---------------------------------------------------------------------------
# Prefetch each image via Harbor proxy cache
# ---------------------------------------------------------------------------
success_count=0
fail_count=0
total=${#CI_IMAGES[@]}

for img in "${CI_IMAGES[@]}"; do
  proxy_ref=$(to_harbor_proxy_ref "$img")
  log_info "Prefetching ${proxy_ref} ..."

  if kubectl exec "$POD_NAME" -n default -- \
    crane manifest "${proxy_ref}" --insecure >/dev/null 2>&1; then
    log_ok "Cached: ${proxy_ref}"
    success_count=$((success_count + 1))
  else
    log_warn "Failed to cache: ${proxy_ref}"
    fail_count=$((fail_count + 1))
  fi
done

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
kubectl delete pod "$POD_NAME" -n default --ignore-not-found 2>/dev/null || true

log_info "CI image prefetch complete: ${success_count}/${total} cached, ${fail_count} failed"
if [[ "$fail_count" -gt 0 ]]; then
  log_warn "Some images failed to prefetch — CI pipelines may need to pull on first run"
fi
