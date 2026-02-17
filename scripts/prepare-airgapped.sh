#!/usr/bin/env bash
# =============================================================================
# prepare-airgapped.sh — Rewrite ArgoCD bootstrap app manifests for airgapped git
# =============================================================================
# Updates the repoURL fields in the 13 ArgoCD bootstrap app manifests
# (services/argo/bootstrap/apps/*.yaml) and argocd-self-manage.yaml to use
# GIT_BASE_URL from .env instead of the hardcoded GitHub URLs.
#
# Run this ONCE before committing and pushing to your internal git server.
#
# Usage:
#   ./scripts/prepare-airgapped.sh              # Uses GIT_BASE_URL from .env
#   GIT_BASE_URL=git@gitea.internal:org ./scripts/prepare-airgapped.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Load .env if it exists (for GIT_BASE_URL)
if [[ -f "${SCRIPTS_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPTS_DIR}/.env"
fi

if [[ -z "${GIT_BASE_URL:-}" ]]; then
  die "GIT_BASE_URL is not set. Set it in .env or pass via environment."
fi

APPS_DIR="${SERVICES_DIR}/argo/bootstrap/apps"
SELF_MANAGE="${SERVICES_DIR}/argo/bootstrap/argocd-self-manage.yaml"

# Detect current git base URL from existing files
CURRENT_BASE=$(grep -m1 'repoURL:' "${APPS_DIR}/argocd.yaml" 2>/dev/null | sed 's|.*repoURL: *||; s|/svc-.*||')

if [[ -z "$CURRENT_BASE" ]]; then
  die "Could not detect current git base URL from ${APPS_DIR}/argocd.yaml"
fi

if [[ "$CURRENT_BASE" == "$GIT_BASE_URL" ]]; then
  log_ok "ArgoCD app manifests already use GIT_BASE_URL=${GIT_BASE_URL}"
  exit 0
fi

log_info "Rewriting ArgoCD bootstrap app manifests..."
log_info "  From: ${CURRENT_BASE}"
log_info "  To:   ${GIT_BASE_URL}"

# Rewrite all app manifests
count=0
for f in "${APPS_DIR}"/*.yaml; do
  if grep -q "repoURL:" "$f"; then
    sed -i "s|${CURRENT_BASE}|${GIT_BASE_URL}|g" "$f"
    count=$((count + 1))
    log_ok "  Updated: $(basename "$f")"
  fi
done

# Rewrite argocd-self-manage.yaml (uses CHANGEME_GIT_REPO_URL token — skip if still tokenized)
if [[ -f "$SELF_MANAGE" ]] && grep -q "$CURRENT_BASE" "$SELF_MANAGE"; then
  sed -i "s|${CURRENT_BASE}|${GIT_BASE_URL}|g" "$SELF_MANAGE"
  count=$((count + 1))
  log_ok "  Updated: argocd-self-manage.yaml"
fi

log_ok "Updated ${count} file(s)"
echo ""
log_info "Next steps:"
echo "  1. Review changes: git diff services/argo/bootstrap/"
echo "  2. Commit: git add -A && git commit -m 'chore: rewrite ArgoCD repos for airgapped deploy'"
echo "  3. Push to internal git: git push"
