# Stream 7: Documentation Review Findings

**Reviewer**: Claude Opus 4.6
**Date**: 2026-02-17
**Scope**: Standalone design docs, operator READMEs, placeholder files

---

## 1. docs/airgapped-mode.md

**Cross-reference**: `scripts/prepare-airgapped.sh`, `scripts/lib.sh` (`validate_airgapped_prereqs`, `resolve_helm_chart`)

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 1.1 | INFO | Doc says "Updates the repoURL fields in the 13 ArgoCD bootstrap app manifests" but prepare-airgapped.sh says the same on line 5. Numbers match. | No change needed |
| 1.2 | OK | All 9 required HELM_OCI_* vars in doc match `validate_airgapped_prereqs()` in lib.sh (lines 107-110): CERT_MANAGER, CNPG, CLUSTER_AUTOSCALER, REDIS_OPERATOR, VAULT, HARBOR, ARGOCD, ARGO_ROLLOUTS, KASM. MariaDB conditional also matches. | No change needed |
| 1.3 | OK | Validation checks (UPSTREAM_PROXY_REGISTRY, GIT_BASE_URL, ARGO_ROLLOUTS_PLUGIN_URL not github.com, gateway CRDs file) all match lib.sh lines 101-135 | No change needed |
| 1.4 | OK | Chart versions in table (cert-manager v1.19.3, CNPG 0.27.1, vault 0.32.0, harbor 1.18.2, kasm 1.1181.0) match the error messages in `validate_airgapped_prereqs()` lines 140-149 | No change needed |
| 1.5 | OK | Phase-by-phase table accurately reflects deploy-cluster.sh phases 0-11 | No change needed |
| 1.6 | OK | Implementation status checklist matches actual implementation in lib.sh and deploy-cluster.sh | No change needed |

**Verdict**: ACCURATE. The airgapped-mode.md is comprehensive and matches the actual implementation closely. No edits required.

---

## 2. docs/kubectl-oidc-setup.md

**Cross-reference**: `scripts/setup-kubectl-oidc.sh`, `services/rbac/`

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 2.1 | OK | kubelogin install instructions match standard methods | No change needed |
| 2.2 | OK | Manual kubeconfig YAML structure matches setup-kubectl-oidc.sh output (lines 59-93): same args, same oidc-login params | No change needed |
| 2.3 | OK | Groups table (platform-admins=cluster-admin, infra-engineers=custom, senior-developers=edit, developers=edit, viewers=view) matches RBAC manifests in services/rbac/ | No change needed |
| 2.4 | OK | Doc says "Three additional Keycloak groups (harvester-admins, rancher-admins, network-engineers) exist for non-Kubernetes access" -- correct, setup-keycloak.sh creates 8 groups total | No change needed |
| 2.5 | MINOR | Doc mentions `senior-developers` getting `edit` but services/rbac/ only has a `developer-rolebinding-template.yaml` which binds both `developers` and `senior-developers` to `edit`. This is technically correct (both get edit in assigned namespaces). | No change needed |

**Verdict**: ACCURATE. No edits required.

---

## 3. docs/keycloak-user-management-strategy.md

**Cross-reference**: `scripts/setup-keycloak.sh`

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 3.1 | MINOR | Script comment says "7 groups" (line 4) but actually creates 8 groups (line 713: platform-admins, harvester-admins, rancher-admins, infra-engineers, network-engineers, senior-developers, developers, viewers). The doc does not reference group count directly. Script comment is wrong, not the doc. | Fix script comment (out of scope) |
| 3.2 | OK | Doc correctly describes Option B as current implementation with CNPG PostgreSQL 16.6 | No change needed |
| 3.3 | OK | The 14 OIDC clients listed in setup-keycloak.sh Phase 5 summary (line 823-824) match the MEMORY.md reference | No change needed |

**Verdict**: ACCURATE. Strategy doc is a design document, not a how-to. Content is sound.

---

## 4. docs/golden-image-plan.md

**Cross-reference**: `golden-image/` directory

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 4.1 | OK | Doc has a prominent "Historical Document" banner noting the actual implementation uses Terraform + virt-customize instead of Packer, and is in `golden-image/` directory. This is correct -- the golden-image/ directory contains Terraform files (main.tf, variables.tf, etc.) and a build.sh script. | No change needed |
| 4.2 | OK | Doc references engineering/golden-image-cicd.md which exists | No change needed |
| 4.3 | MINOR | "Files to Create / Modify" section at bottom still references `packer/golden-image-bake.sh` and `packer/rocky9-golden.pkr.hcl`. While the historical banner covers this, these references could confuse readers. | No edit -- banner already clarifies |

**Verdict**: ACCURATE with appropriate historical disclaimer.

---

## 5. docs/vault-ha.md

**Cross-reference**: `services/vault/vault-values.yaml`

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 5.1 | OK | Doc says HA 3 replicas with Raft -- matches vault-values.yaml: `ha.enabled: true`, `replicas: 3`, `raft.enabled: true` | No change needed |
| 5.2 | OK | Doc says database pool -- matches vault-values.yaml: `nodeSelector.workload-type: database` | No change needed |
| 5.3 | OK | Doc says 10Gi PVC -- matches vault-values.yaml: `dataStorage.size: 10Gi` | No change needed |
| 5.4 | OK | Doc says Shamir 3-of-5 -- matches vault-values.yaml init commands | No change needed |
| 5.5 | OK | Doc says chart is hashicorp/vault 0.32.0 -- matches vault-values.yaml comment on line 2 | No change needed |
| 5.6 | OK | Doc mentions pod anti-affinity -- matches vault-values.yaml `affinity.podAntiAffinity` config | No change needed |

**Verdict**: ACCURATE. Vault HA doc matches actual manifests precisely.

---

## 6. docs/vault-credential-storage.md

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 6.1 | OK | Doc has a prominent note acknowledging that basic-auth has been replaced by oauth2-proxy ForwardAuth and that migration targets need updating | No change needed |
| 6.2 | OK | Doc correctly identifies this as "Status: Planning" | No change needed |

**Verdict**: ACCURATE. Planning doc with appropriate disclaimer about changed landscape.

---

## 7. docs/public-repo-plan.md

**Cross-reference**: `.public/` directory, `scripts/sync-to-public.sh`

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 7.1 | LOW | Doc proposes repo name options (rke2-harvester-cluster, etc.) but sync-to-public.sh uses `harvester-rke2-platform` (line 40). The doc is a planning document so this is expected divergence. | No edit needed |
| 7.2 | OK | The .public/ directory exists with GitHub Actions workflows (shellcheck, terraform, gitleaks, kubeconform, yamllint) matching Phase 3.1 of the plan | No change needed |
| 7.3 | OK | sync-to-public.sh implements the sanitization pipeline described in Phase 1.2 (domain scrub, IP scrub, password scrub) | No change needed |

**Verdict**: ACCURATE for a planning document. Implementation has progressed beyond the plan.

---

## 8. docs/rancher-autoscaler-labels-issue.md

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 8.1 | OK | Doc accurately describes the CAPI label propagation issue and the two workarounds (bash function + node-labeler operator) | No change needed |
| 8.2 | OK | This is a draft issue for rancher/rancher, not a how-to doc | No change needed |

**Verdict**: ACCURATE.

---

## 9. docs/kubernetes-rbac-setup.md

**Finding**: File does NOT exist. The RBAC setup is documented in:
- `docs/kubectl-oidc-setup.md` (section 5: Access Control)
- `services/rbac/` manifests (self-documenting)
- `docs/engineering/security-architecture.md`

**Verdict**: N/A -- file does not exist, no action needed.

---

## 10. operators/node-labeler/README.md

**Cross-reference**: `operators/node-labeler/cmd/main.go`, `operators/node-labeler/go.mod`, `operators/node-labeler/Makefile`, `services/node-labeler/deployment.yaml`

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 10.1 | OK | Go version 1.25.7 matches go.mod | No change needed |
| 10.2 | OK | GHCR reference for docker-buildx matches Makefile `docker-buildx` target | No change needed |
| 10.3 | OK | Harbor reference for docker-save matches Makefile `docker-save` target | No change needed |
| 10.4 | OK | Deployment says Phase 1 -- matches deploy-cluster.sh line 378-379 | No change needed |
| 10.5 | OK | 3 replicas matches deployment.yaml (`replicas: 3`) | Verify... deployment.yaml says `replicas: 3` but README does not mention replica count explicitly. Fine. |
| 10.6 | OK | Metrics (node_labeler_labels_applied_total, node_labeler_errors_total) documented | No change needed |

**Verdict**: ACCURATE.

---

## 11. operators/storage-autoscaler/README.md

**Cross-reference**: `operators/storage-autoscaler/cmd/main.go`, `operators/storage-autoscaler/go.mod`, `operators/storage-autoscaler/Makefile`, `services/storage-autoscaler/deployment.yaml`

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 11.1 | OK | Go version 1.25.7 matches go.mod | No change needed |
| 11.2 | OK | 3-replica Deployment mentioned in doc matches deployment.yaml (`replicas: 3`) | No change needed |
| 11.3 | OK | Deploy phase 3 matches deploy-cluster.sh line 748-749 | No change needed |
| 11.4 | OK | Harbor image reference for build matches Makefile | No change needed |
| 11.5 | OK | Metrics table (4 metrics) documented | No change needed |
| 11.6 | MEDIUM | README Build section only shows `docker-build docker-push` (Harbor) but does NOT document the GHCR/multi-arch build option. Node-labeler README shows both GHCR (`docker-buildx`) and Harbor (`docker-save`). Should add GHCR build instruction for consistency and because commit abbac9b moved operator images to GHCR. | **FIX: Add GHCR docker-buildx command** |

**Verdict**: One fix needed -- add GHCR build option to match node-labeler README and the GHCR migration (commit abbac9b).

---

## 12. operators/images/README.md

### Findings

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 12.1 | OK | Correctly describes the chicken-and-egg problem (operators deploy before Harbor) | No change needed |
| 12.2 | OK | Phase numbers correct (Node Labeler=Phase 1, Storage Autoscaler=Phase 3, Harbor=Phase 4) | No change needed |
| 12.3 | OK | Rebuilding instructions match Makefile `docker-save` targets | No change needed |

**Verdict**: ACCURATE.

---

## 13. Placeholder Files Verification

All 10 placeholder files verified against engineering docs directory:

| Placeholder | Redirect Target | Engineering Doc Exists? | Status |
|------------|-----------------|------------------------|--------|
| docs/architecture.md | engineering/system-architecture.md | YES | OK |
| docs/deployment-flow.md | engineering/flow-charts.md | YES | OK |
| docs/troubleshooting.md | engineering/troubleshooting-sop.md | YES | OK |
| docs/data-flow.md | engineering/flow-charts.md | YES | OK |
| docs/decision-tree.md | engineering/flow-charts.md | YES | OK |
| docs/service-architecture.md | engineering/services-reference.md | YES | OK |
| docs/security.md | engineering/security-architecture.md | YES | OK |
| docs/network-flow.md | engineering/system-architecture.md + engineering/flow-charts.md | YES (both) | OK |
| docs/cicd-architecture.md | engineering/deployment-automation.md + engineering/golden-image-cicd.md | YES (both) | OK |
| docs/operations-runbook.md | engineering/troubleshooting-sop.md#11-day-2-operations-procedures | YES | OK |

**Verdict**: All placeholder files properly redirect to existing engineering docs. All 10 pass.

---

## Summary of Required Edits

| # | File | Edit Description | Severity |
|---|------|-----------------|----------|
| 1 | operators/storage-autoscaler/README.md | Add GHCR docker-buildx build command to Build section for consistency with node-labeler README and GHCR migration | MEDIUM |

All other files are accurate and require no changes.

---

STATUS: COMPLETE
