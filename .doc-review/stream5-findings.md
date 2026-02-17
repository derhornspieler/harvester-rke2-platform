# Stream 5 Findings: Operator, Golden Image, Flow Chart, and SOP Documentation

**Review Date**: 2026-02-17
**Reviewer**: Claude Opus 4.6 (automated doc review)
**Files Reviewed**:
1. `docs/engineering/custom-operators.md`
2. `docs/engineering/golden-image-cicd.md`
3. `docs/engineering/flow-charts.md`
4. `docs/engineering/troubleshooting-sop.md`

**Ground Truth Sources**:
- `operators/node-labeler/cmd/main.go`, `Makefile`, `Dockerfile`
- `operators/storage-autoscaler/cmd/main.go`, `Makefile`, `Dockerfile`
- `operators/storage-autoscaler/.golangci.yml`
- `.github/workflows/node-labeler.yml`, `.github/workflows/storage-autoscaler.yml`
- `golden-image/build.sh`, `golden-image/main.tf`
- `services/node-labeler/deployment.yaml`, `services/storage-autoscaler/deployment.yaml`

---

## Finding Summary

| # | File | Severity | Description | Status |
|---|------|----------|-------------|--------|
| 1 | custom-operators.md | HIGH | Dockerfile Go version says `golang:1.25` but actual Dockerfile says `golang:1.25.7` | FIXED |
| 2 | golden-image-cicd.md | HIGH | Dockerfile Go version says `golang:1.25` but actual Dockerfile says `golang:1.25.7` | FIXED |
| 3 | custom-operators.md | HIGH | Go version in comparison table says `1.25` but go.mod says `1.25.7` | FIXED |
| 4 | golden-image-cicd.md | HIGH | Go version in version matrix says `1.25.x` - should be `1.25.7` for precision | FIXED |
| 5 | custom-operators.md | MEDIUM | CI workflows use `actions/checkout@v4` and `actions/setup-go@v5` per docs, but actual workflows use `@v6` for both | FIXED |
| 6 | golden-image-cicd.md | MEDIUM | CI workflows use `actions/checkout@v4` and `actions/setup-go@v5` per docs, but actual workflows use `@v6` for both | FIXED |
| 7 | custom-operators.md | MEDIUM | CI lint action version says `golangci-lint-action@v6` but actual workflows use `@v9` | FIXED |
| 8 | golden-image-cicd.md | MEDIUM | CI lint action version says `golangci/golangci-lint-action@v6` but actual is `@v9` | FIXED |
| 9 | custom-operators.md | MEDIUM | CI workflows doc omits `govulncheck` job and `security-scan` job that exist in actual workflows | FIXED |
| 10 | golden-image-cicd.md | MEDIUM | CI workflow docs omit `govulncheck` job and `security-scan` job that exist in actual workflows | FIXED |
| 11 | custom-operators.md | LOW | Airgapped bootstrap sequence diagram shows `harbor.<DOMAIN>` image references but actual deployment manifests use `harbor.example.com` (which is correct since `_subst_changeme()` handles substitution) | NO-FIX (correct - domain substitution handles this) |
| 12 | golden-image-cicd.md | MEDIUM | CI Actions version table says `actions/checkout: v4`, `actions/setup-go: v5`, `golangci/golangci-lint-action: v6` - all should be v6, v6, v9 respectively | FIXED |
| 13 | custom-operators.md | LOW | Comparison table shows `Replicas: 3 (leader election)` which matches deployment.yaml (3 replicas with `--leader-elect` flag) | NO-FIX (correct) |
| 14 | custom-operators.md | LOW | GHCR image paths show `ghcr.io/derhornspieler/node-labeler` and `ghcr.io/derhornspieler/storage-autoscaler` which match workflow `IMAGE_NAME` env vars | NO-FIX (correct) |
| 15 | troubleshooting-sop.md | LOW | Section 8.3 Storage Autoscaler Not Expanding references `GHCR or Harbor` for image source, which is accurate for bootstrap | NO-FIX (correct) |
| 16 | flow-charts.md | LOW | All flow charts accurately reflect the deploy-cluster.sh phases, Terraform flows, and controller logic based on source code inspection | NO-FIX (correct) |
| 17 | golden-image-cicd.md | LOW | `docker/build-push-action` listed as v6 in the version matrix, which matches actual workflows | NO-FIX (correct) |

---

## Detailed Findings

### Finding 1-2: Dockerfile Go version imprecision

**Location**: custom-operators.md line 246/689, golden-image-cicd.md line 959
**Expected** (from Dockerfiles): `golang:1.25.7`
**Documented**: `golang:1.25`
**Impact**: Could cause confusion if building from docs instead of actual Dockerfile. The pinned patch version `1.25.7` was set in commit `ef1e68d` ("Bump Go to 1.25.7").

### Finding 3-4: Go version imprecision in comparison table and version matrix

**Location**: custom-operators.md line 744, golden-image-cicd.md line 1495
**Expected** (from go.mod): `1.25.7`
**Documented**: `1.25` (custom-operators.md), `1.25.x` (golden-image-cicd.md)

### Finding 5-8: GitHub Actions version drift

**Location**: custom-operators.md CI/CD section, golden-image-cicd.md CI/CD section
**Expected** (from actual workflows):
- `actions/checkout@v6`
- `actions/setup-go@v6`
- `golangci/golangci-lint-action@v9`
**Documented**:
- `actions/checkout@v4`
- `actions/setup-go@v5`
- `golangci/golangci-lint-action@v6`

### Finding 9-10: Missing CI jobs in documentation

**Location**: custom-operators.md CI/CD pipeline section, golden-image-cicd.md CI/CD section
**Missing**: Both actual workflows include:
1. `govulncheck` job - runs `govulncheck ./...` with `continue-on-error: true`
2. `security-scan` job - runs `aquasecurity/trivy-action@master` after `build-and-push`

These are not mentioned in the documentation at all.

### Finding 12: CI Actions version table outdated

**Location**: golden-image-cicd.md lines 1483-1489
**Expected** (from actual workflows):
- `actions/checkout`: v6
- `actions/setup-go`: v6
- `golangci/golangci-lint-action`: v9
**Documented**: v4, v5, v6 respectively

---

## Verification Notes

### Items verified as correct (no changes needed):

1. **Replica counts**: Both deployment.yaml files show `replicas: 3`, matching docs
2. **Image registry**: Deployment manifests reference `harbor.example.com/library/...` which is correct (Harbor is the in-cluster registry, not GHCR). GHCR is the CI/CD registry correctly documented
3. **Makefile targets**: All documented Makefile targets match actual Makefiles
4. **golangci-lint version**: v2.7.2 in both Makefiles, matches docs
5. **Leader election IDs**: `node-labeler.io` and `volume-autoscaler.io` match source code
6. **Metrics/health ports**: :8080/:8081 match source code
7. **EventRecorder names**: `node-labeler` and `volume-autoscaler` match `mgr.GetEventRecorder()` calls in source
8. **Storage autoscaler Makefile**: docker-buildx platforms `linux/arm64,linux/amd64,linux/s390x,linux/ppc64le` match docs
9. **Node labeler Makefile**: docker-buildx platforms `linux/arm64,linux/amd64` match docs
10. **Golden image build.sh**: 5-step process matches flow chart and documentation
11. **golden-image/main.tf**: Resources (harvester_image, kubernetes_secret, harvester_virtualmachine) match docs
12. **Controller-gen version**: v0.20.0 in Makefile matches docs
13. **Kustomize version**: v5.7.1 in Makefile matches docs
14. **Flow charts**: All deployment, service, and controller flow charts accurately reflect source code
15. **Troubleshooting SOP**: Procedures are comprehensive and accurate for current architecture
16. **VolumeAutoscaler examples**: All documented examples match actual files in `services/storage-autoscaler/examples/`

STATUS: COMPLETE
