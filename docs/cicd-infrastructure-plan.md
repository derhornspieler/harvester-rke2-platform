# CI/CD Infrastructure Build-Out Plan

## Executive Summary

This plan implements a production-grade, enterprise CI/CD infrastructure on the existing
RKE2 platform, applying the principles of Minimum Viable Continuous Delivery (MinimumCD.org)
and the CD Migration phased approach (cd-migration). The goal is a bullet-proof, AWS-resilient,
scalable solution that enables any team to go from code commit to production deployment with
full automation, progressive delivery, security scanning, compliance audit trails, and
observability - all backed by the existing platform tooling (GitLab, ArgoCD, Argo Rollouts,
Vault, Harbor, Keycloak, Prometheus, Grafana, Loki).

**Phases 12-18** in `scripts/deploy-cluster.sh` are the primary deliverable — seven new
deployment phases that build out the complete CI/CD infrastructure on top of the already-deployed
platform services (phases 0-11). Run with `./scripts/deploy-cluster.sh --from 12`.

### Phase Summary

| Phase | Name | Function | What It Does |
|-------|------|----------|-------------|
| 12 | GitLab Hardening | `phase_12_gitlab_hardening()` | Disable registry, SSH via Traefik, protected branches, approval rules, Keycloak group sync |
| 13 | Vault CI/CD | `phase_13_vault_cicd()` | JWT auth for GitLab CI, CI/CD policies, ESO + ClusterSecretStore |
| 14 | CI Templates | `phase_14_ci_templates()` | Push shared template library, Harbor robot accounts, group CI/CD variables |
| 15 | ArgoCD Delivery | `phase_15_argocd_delivery()` | Enhanced RBAC, AppProjects, AnalysisTemplates, ephemeral MR envs |
| 16 | Security | `phase_16_security()` | Dedicated security runners, Harbor auto-scan |
| 17 | Observability | `phase_17_observability()` | DORA Grafana dashboard, CI/CD alert rules, summary |
| 18 | Demo Apps | `phase_18_demo_apps()` | NetOps Arcade: packet-relay (canary), netops-dashboard (blue-green) |

---

## Foundation: MinimumCD Principles Applied

Every decision in this plan is anchored to these non-negotiable requirements:

| MinimumCD Requirement | Platform Implementation |
|----------------------|------------------------|
| Trunk-based development | GitLab project settings enforce: no long-lived branches, MR to main only |
| Daily integration to trunk | GitLab CI triggers on every push, MR merge trains enabled |
| Automated testing before merge | GitLab CI pipeline gates: lint, unit, contract, SAST, SCA |
| Pipeline is sole deploy method | ArgoCD is the ONLY path to any environment - no kubectl apply, no helm install |
| Pipeline verdict is definitive | Quality gates in GitLab CI are blocking; ArgoCD sync only on green |
| Immutable artifacts | Harbor stores versioned OCI images; no :latest, no mutation after push |
| All work stops when pipeline red | GitLab CI auto-blocks MRs when main is red; Mattermost alerts |
| Production-like test environment | Ephemeral namespaces via GitLab CI + ArgoCD ApplicationSets |
| On-demand rollback | Argo Rollouts automated rollback on AnalysisRun failure |
| Config deploys with artifact | Kustomize overlays + Vault External Secrets; config is code |

---

## Organizational Structure

### Hierarchy and Escalation

```
                    +-----------+
                    |    GM     |  General Manager
                    | (1 agent) |  Final decisions, memory/progress tracking
                    +-----+-----+
                          |
              +-----------+-----------+
              |                       |
        +-----+-----+          +-----+-----+
        |    PTM    |          |    SDM    |  Program Technical Managers
        | (2 agents)|          | (2 agents)|  Software Development Managers
        +-----+-----+          +-----+-----+
              |                       |
    +---------+---------+    +--------+--------+
    |         |         |    |        |        |
  +---+    +---+    +---+  +---+   +---+   +---+
  |SDE|    |SDE|    |PE |  |SDE|   |PE |   |TDW|
  |Tm1|    |Tm2|    |Tm3|  |Tm4|   |Tm5|   |Tm6|
  +---+    +---+    +---+  +---+   +---+   +---+
                                              |
                                           +--+--+
                                           |SecE |  Security Engineers
                                           +-----+
```

### Team Definitions

| Team ID | Name | Type | Responsibility | Reports To |
|---------|------|------|---------------|------------|
| **GM** | General Manager | Management | Progress tracking, memory files, conflict resolution, final decisions | - |
| **PTM-1** | Pipeline & GitOps PTM | Technical Management | Oversees CI pipeline, GitOps, ArgoCD integration workstreams | GM |
| **PTM-2** | Security & Compliance PTM | Technical Management | Oversees security scanning, compliance, audit trail workstreams | GM |
| **SDM-1** | Platform Services SDM | Development Management | Manages Platform Engineer teams building infrastructure | GM |
| **SDM-2** | Application Services SDM | Development Management | Manages SDE teams building application-facing CI/CD tooling | GM |
| **SDE-1** | CI Pipeline Team | Software Development | GitLab CI templates, pipeline stages, quality gates | SDM-2 |
| **SDE-2** | GitOps & Delivery Team | Software Development | ArgoCD ApplicationSets, Argo Rollouts strategies, promotion | SDM-2 |
| **PE-1** | Platform Infrastructure Team | Platform Engineering | GitLab Runners, Vault integration, Harbor policies, networking | SDM-1 |
| **PE-2** | Observability Team | Platform Engineering | Pipeline metrics, DORA dashboards, alerting, Loki pipeline logs | SDM-1 |
| **TDW-1** | Documentation Team | Technical Writing | All CI/CD documentation, runbooks, developer guides, ADRs | PTM-1 |
| **SEC-1** | Security Engineering Team | Security | SAST/DAST/SCA scanning, secret detection, compliance gates, pen testing | PTM-2 |

### Parallel Execution Rules

1. **Independence**: Each team works on their workstream independently. No team blocks another
   unless explicitly noted in the dependency graph.
2. **Conflict Resolution**: If two teams need to modify the same file or service:
   - SDMs from both teams coordinate first
   - If unresolved, PTMs meet
   - If still unresolved, GM makes the final call within 4 hours
3. **Integration Points**: Teams integrate their work through GitLab MRs to a shared
   `feature/cicd-infrastructure` branch. PTMs review cross-team MRs.
4. **Memory Files**: GM maintains `/docs/cicd-progress.md` with current state of every
   workstream. Each team updates their section before end of each work session.
5. **Communication**: All teams use Mattermost channel `#cicd-buildout` for async coordination.
   Blocking issues get escalated immediately, not at end of day.

---

## Architecture Overview

### The CI/CD Data Flow

```
Developer Workstation
    |
    | git push (trunk or short-lived branch)
    v
GitLab (git@gitlab.<DOMAIN>)
    |
    | Webhook triggers pipeline
    v
GitLab CI Pipeline (on GitLab Runners in K8s)
    |
    +---> Stage 1: Pre-Build (< 2 min)
    |     - Linting (shellcheck, yamllint, hadolint, golangci-lint, eslint)
    |     - Static type checking
    |     - Secret scanning (gitleaks)
    |     - SAST (semgrep)
    |     - Dependency check (trivy fs)
    |
    +---> Stage 2: Build + Unit Test (< 5 min)
    |     - Compile / build
    |     - Unit tests (with coverage)
    |     - SBOM generation (syft)
    |     - Container image build (kaniko)
    |     - Push to Harbor (immutable tag: git SHA)
    |
    +---> Stage 3: Integration + Contract (< 10 min)
    |     - Contract tests (pact or schema validation)
    |     - Schema migration validation (CNPG dry-run)
    |     - Image vulnerability scan (trivy image)
    |     - License compliance check
    |
    +---> Stage 4: Acceptance (< 15 min)
    |     - Deploy to ephemeral namespace (ArgoCD ApplicationSet)
    |     - Functional acceptance tests
    |     - Performance benchmarks (k6)
    |     - Cleanup ephemeral namespace
    |
    +---> Stage 5: Artifact Promotion
          - Tag image in Harbor as "promoted"
          - Update GitOps manifest repo (image tag)
          - ArgoCD detects change, syncs
          v
ArgoCD (GitOps Controller)
    |
    | Sync to target environment
    v
Argo Rollouts (Progressive Delivery)
    |
    +---> Canary: 5% -> 25% -> 50% -> 100%
    |     - AnalysisRun at each step (Prometheus metrics)
    |     - Auto-rollback if error rate > 2x or latency p99 > 1.5x
    |
    +---> Blue-Green: (for stateful services)
    |     - Deploy to green, smoke test, switch Gateway HTTPRoute
    |     - Auto-rollback on health check failure
    |
    v
Production (RKE2 Cluster)
    |
    | Prometheus scrapes, Loki collects logs
    v
Grafana DORA Dashboard
    - Lead time, deploy frequency, change fail rate, MTTR
    - Pipeline duration, queue time, success rate
    - Feature flag status, rollback count
```

### Environment Promotion Model

```
+------------------+     +------------------+     +------------------+
|    Ephemeral     |     |     Staging      |     |   Production     |
|   (per-MR)       | --> |   (pre-prod)     | --> |   (live)         |
+------------------+     +------------------+     +------------------+
| Namespace: mr-123|     | Namespace: stg   |     | Namespace: prod  |
| Lifetime: 4 hrs  |     | Lifetime: perm   |     | Lifetime: perm   |
| ArgoCD AppSet    |     | ArgoCD App       |     | ArgoCD App       |
| Auto-cleanup     |     | Manual promote   |     | Argo Rollout     |
+------------------+     +------------------+     +------------------+
```

---

## Workstreams (Parallel Execution)

### WORKSTREAM 1: GitLab CI Pipeline Framework
**Owner**: SDE-1 (CI Pipeline Team)
**Overseen by**: PTM-1, SDM-2
**Dependencies**: PE-1 (runners must be ready)

#### Deliverables

**1.1 CI/CD Template Library** (`gitlab-ci-templates/`)

Create a shared GitLab CI template library deployed as a GitLab project that all service
repos include via `include:`. This is the single source of truth for all pipeline behavior.

```
gitlab-ci-templates/
  templates/
    base.yml                  # Common variables, rules, caching
    stages.yml                # Stage definitions (pre-build, build, test, scan, deploy)
    jobs/
      lint.yml                # Linting jobs (per-language)
      unit-test.yml           # Unit test jobs (per-language)
      build-image.yml         # Kaniko image build
      push-harbor.yml         # Harbor push with immutable tags
      trivy-scan.yml          # Container vulnerability scanning
      sast.yml                # Static application security testing
      sca.yml                 # Software composition analysis
      sbom.yml                # SBOM generation (syft/cyclonedx)
      gitleaks.yml            # Secret detection
      contract-test.yml       # Contract/schema testing
      k6-performance.yml      # Performance testing
      deploy-ephemeral.yml    # Ephemeral namespace deploy via ArgoCD
      promote-artifact.yml    # Artifact promotion (tag + manifest update)
      cleanup-ephemeral.yml   # Ephemeral namespace teardown
    languages/
      go.yml                  # Go-specific: golangci-lint, go test, go build
      node.yml                # Node-specific: eslint, jest/vitest, npm build
      python.yml              # Python-specific: ruff, pytest, pip build
      shell.yml               # Shell-specific: shellcheck, bats
      terraform.yml           # Terraform: fmt, validate, plan, apply
      helm.yml                # Helm: lint, template, kubeconform
    patterns/
      microservice.yml        # Full microservice pipeline (build+test+scan+deploy)
      library.yml             # Library pipeline (build+test+publish, no deploy)
      infrastructure.yml      # IaC pipeline (validate+plan+apply)
      static-site.yml         # Static site (build+deploy)
      operator.yml            # K8s operator (build+test+push+deploy)
```

**Usage in a service repo:**

```yaml
# .gitlab-ci.yml
include:
  - project: 'platform-services/gitlab-ci-templates'
    ref: main
    file:
      - 'templates/stages.yml'
      - 'templates/languages/go.yml'
      - 'templates/patterns/microservice.yml'

variables:
  SERVICE_NAME: my-service
  HARBOR_PROJECT: platform
  DEPLOY_STRATEGY: canary  # or bluegreen
```

**1.2 Quality Gate Definitions**

Each stage has explicit pass/fail criteria:

| Stage | Gate | Threshold | Blocks Merge? |
|-------|------|-----------|--------------|
| Pre-Build | Lint errors | 0 | Yes |
| Pre-Build | Secrets detected | 0 | Yes |
| Pre-Build | SAST critical/high | 0 | Yes |
| Build | Compilation | Success | Yes |
| Build | Unit test pass rate | 100% | Yes |
| Build | Unit test coverage | >= 80% (configurable) | Yes |
| Build | Image build | Success | Yes |
| Scan | CVE critical | 0 | Yes |
| Scan | CVE high | <= 5 (configurable) | Warn |
| Scan | License blocklist | 0 GPL/AGPL in proprietary | Yes |
| Contract | Schema compatibility | Backward compatible | Yes |
| Acceptance | Functional tests | 100% pass | Yes |
| Acceptance | Performance regression | < 10% degradation | Yes |

**1.3 Pipeline Variables and Configuration**

Pipeline behavior controlled via CI/CD variables (set at group or project level):

```yaml
# Group-level variables (inherited by all projects)
HARBOR_REGISTRY: harbor.<DOMAIN>
HARBOR_PROJECT: platform-services
VAULT_ADDR: https://vault.<DOMAIN>
VAULT_ROLE: gitlab-ci
ARGOCD_SERVER: argocd.<DOMAIN>
DOMAIN: <DOMAIN>
TRIVY_SEVERITY: CRITICAL,HIGH
COVERAGE_THRESHOLD: "80"

# Project-level variables (per-service overrides)
SERVICE_NAME: my-service
DEPLOY_STRATEGY: canary
CANARY_STEPS: "5,25,50,100"
CANARY_PAUSE_DURATION: "5m"
ROLLBACK_ERROR_THRESHOLD: "0.05"
```

**1.4 Merge Request Pipeline vs Main Pipeline**

```
MR Pipeline (on every push to MR):
  pre-build -> build -> unit-test -> sast -> sca -> contract-test
  (no deployment, no artifact promotion)
  Target: < 10 minutes

Main Pipeline (on merge to main):
  pre-build -> build -> unit-test -> sast -> sca -> image-build ->
  image-scan -> sbom -> contract-test -> deploy-ephemeral ->
  acceptance-test -> cleanup-ephemeral -> promote-artifact
  Target: < 15 minutes to promoted artifact
```

---

### WORKSTREAM 2: GitOps & Progressive Delivery
**Owner**: SDE-2 (GitOps & Delivery Team)
**Overseen by**: PTM-1, SDM-2
**Dependencies**: SDE-1 (pipeline must produce artifacts), PE-1 (ArgoCD config)

#### Deliverables

**2.1 GitOps Manifest Repository Structure**

Each service gets a dedicated manifest repo in GitLab with Kustomize overlays:

```
<service-name>-manifests/
  base/
    deployment.yaml           # Or rollout.yaml for Argo Rollouts
    service.yaml
    gateway.yaml              # Gateway API HTTPRoute
    hpa.yaml                  # HorizontalPodAutoscaler
    pdb.yaml                  # PodDisruptionBudget
    networkpolicy.yaml        # Cilium NetworkPolicy
    kustomization.yaml
  overlays/
    ephemeral/
      kustomization.yaml      # Ephemeral overrides (1 replica, no HPA)
      patches/
        scale-down.yaml
    staging/
      kustomization.yaml      # Staging overrides
      patches/
        replicas.yaml
    production/
      kustomization.yaml      # Production config
      patches/
        replicas.yaml         # HA replicas
        resources.yaml        # Production resource limits
        rollout-strategy.yaml # Canary/blue-green config
  analysis-templates/
    success-rate.yaml         # Prometheus AnalysisTemplate
    latency.yaml              # p99 latency check
    error-rate.yaml           # Error rate check
    custom-metric.yaml        # Business metric check
```

**2.2 ArgoCD ApplicationSet for Ephemeral Environments**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ephemeral-environments
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - pullRequest:
        gitlab:
          project: "platform-services/{{ .service }}"
          api: https://gitlab.<DOMAIN>
          tokenRef:
            secretName: argocd-gitlab-token
            key: token
        requeueAfterSeconds: 30
  template:
    metadata:
      name: "{{ .project }}-mr-{{ .number }}"
      labels:
        app.kubernetes.io/part-of: ephemeral
        ephemeral-ttl: "4h"
    spec:
      project: ephemeral
      source:
        repoURL: "git@gitlab.<DOMAIN>:platform-services/{{ .project }}-manifests.git"
        targetRevision: "mr-{{ .number }}"
        path: overlays/ephemeral
      destination:
        server: https://kubernetes.default.svc
        namespace: "ephemeral-{{ .project }}-mr-{{ .number }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**2.3 Argo Rollout Strategies**

**Canary with Prometheus Analysis (default for stateless services):**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .SERVICE_NAME }}
spec:
  replicas: 4
  strategy:
    canary:
      canaryService: {{ .SERVICE_NAME }}-canary
      stableService: {{ .SERVICE_NAME }}-stable
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: {{ .SERVICE_NAME }}-route
            namespace: {{ .NAMESPACE }}
      steps:
        - setWeight: 5
        - pause: {duration: 5m}
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
            args:
              - name: service-name
                value: {{ .SERVICE_NAME }}
        - setWeight: 25
        - pause: {duration: 10m}
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
              - templateName: error-rate
        - setWeight: 50
        - pause: {duration: 15m}
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
              - templateName: error-rate
        - setWeight: 100
      analysis:
        successfulRunHistoryLimit: 3
        unsuccessfulRunHistoryLimit: 3
      rollbackWindow:
        revisions: 3
```

**Blue-Green with Smoke Tests (for stateful or critical services):**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .SERVICE_NAME }}
spec:
  replicas: 4
  strategy:
    blueGreen:
      activeService: {{ .SERVICE_NAME }}-active
      previewService: {{ .SERVICE_NAME }}-preview
      autoPromotionEnabled: false
      prePromotionAnalysis:
        templates:
          - templateName: smoke-test
          - templateName: success-rate
        args:
          - name: service-name
            value: {{ .SERVICE_NAME }}
      postPromotionAnalysis:
        templates:
          - templateName: success-rate
          - templateName: latency-check
      scaleDownDelaySeconds: 300
```

**2.4 Prometheus AnalysisTemplates**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 60s
      count: 5
      successCondition: result[0] >= 0.98
      failureCondition: result[0] < 0.95
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus-server.monitoring.svc:9090
          query: |
            sum(rate(http_requests_total{
              service="{{ args.service-name }}",
              status=~"2.."
            }[5m])) /
            sum(rate(http_requests_total{
              service="{{ args.service-name }}"
            }[5m]))

---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency-check
spec:
  args:
    - name: service-name
  metrics:
    - name: p99-latency
      interval: 60s
      count: 5
      successCondition: result[0] < 0.5
      failureCondition: result[0] > 1.0
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus-server.monitoring.svc:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{
                service="{{ args.service-name }}"
              }[5m])) by (le))

---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: error-rate
spec:
  args:
    - name: service-name
  metrics:
    - name: error-rate
      interval: 60s
      count: 5
      successCondition: result[0] < 0.02
      failureCondition: result[0] > 0.05
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus-server.monitoring.svc:9090
          query: |
            sum(rate(http_requests_total{
              service="{{ args.service-name }}",
              status=~"5.."
            }[5m])) /
            sum(rate(http_requests_total{
              service="{{ args.service-name }}"
            }[5m]))
```

**2.5 Environment Promotion Flow**

```
Ephemeral (auto, per-MR)
    |
    | MR merged to main -> pipeline passes -> artifact promoted
    v
Staging (auto-sync from main branch manifests)
    |
    | Staging validation passes (24h soak)
    | PTM approves promotion (GitLab MR to production overlay)
    v
Production (Argo Rollout - canary or blue-green)
    |
    | AnalysisRun passes at each step
    | Auto-rollback on failure
    v
Live Traffic
```

**2.6 Merge Request Approval Gates (Keycloak Group-Based)**

Since ArgoCD watches `main` exclusively, controlling who can merge to `main` is the
primary security gate for production deployments. This is enforced through GitLab
protected branches + approval rules mapped to Keycloak OIDC groups.

**Branch Protection Model:**

```
Feature Branch (any developer can create)
    |
    | Push triggers MR Pipeline (lint, test, scan)
    |
    v
Merge Request to main
    |
    | GATE 1: Pipeline must pass (automated)
    | GATE 2: Minimum 2 approvers required
    | GATE 3: Approvers must be from authorized Keycloak groups
    | GATE 4: Code owner approval required (CODEOWNERS file)
    | GATE 5: No unresolved threads
    | GATE 6: Branch must be up-to-date with main
    |
    v
Merge to main (triggers ArgoCD sync)
```

**Keycloak Group to GitLab Approval Mapping:**

| Environment Target | Required Approver Group(s) | Min Approvals | Rationale |
|-------------------|---------------------------|---------------|-----------|
| Ephemeral (per-MR) | None (auto-deploy on MR create) | 0 | Safe: isolated namespace, auto-cleanup |
| Staging (main branch) | `senior-developers` OR `infra-engineers` | 2 | Standard code review gate |
| Production promotion | `platform-admins` AND `senior-developers` | 2 (one from each) | Dual-party approval for prod changes |
| Infrastructure/Terraform | `platform-admins` | 2 | Infrastructure changes require admin review |
| Security policies/RBAC | `platform-admins` | 2 + SEC-1 review | Security-sensitive changes |

**GitLab Protected Branch Configuration (via API):**

```bash
# Phase in setup-cicd-infrastructure.sh

# 1. Protect main branch - only maintainers can push, no one can force push
gitlab_api PUT "projects/${PROJECT_ID}/protected_branches" \
  --arg name "main" \
  --arg push_access_level "40" \
  --arg merge_access_level "40" \
  --arg unprotect_access_level "60" \
  --arg allow_force_push "false"

# 2. Set merge request approval rules
# Rule: Require 2 approvals from senior-developers or platform-admins
gitlab_api POST "projects/${PROJECT_ID}/approval_rules" \
  --arg name "Senior Review Required" \
  --arg approvals_required "2" \
  --arg rule_type "regular" \
  --arg group_ids "[${SENIOR_DEV_GROUP_ID},${PLATFORM_ADMIN_GROUP_ID}]"

# 3. For production overlay repos: require platform-admin approval
gitlab_api POST "projects/${PROD_MANIFEST_PROJECT_ID}/approval_rules" \
  --arg name "Production Approval" \
  --arg approvals_required "2" \
  --arg rule_type "regular" \
  --arg group_ids "[${PLATFORM_ADMIN_GROUP_ID}]"

# 4. Prevent approval by MR author (no self-approving)
gitlab_api PUT "projects/${PROJECT_ID}" \
  --arg merge_requests_author_approval "false" \
  --arg merge_requests_disable_committers_approval "true"

# 5. Require pipeline success before merge
gitlab_api PUT "projects/${PROJECT_ID}" \
  --arg only_allow_merge_if_pipeline_succeeds "true" \
  --arg only_allow_merge_if_all_discussions_are_resolved "true"
```

**Keycloak Group Sync to GitLab Groups:**

GitLab OIDC already receives the `groups` claim from Keycloak tokens. The mapping:

```
Keycloak Group            GitLab Role          GitLab Capabilities
----------------------------------------------------------------------
platform-admins      -->  Owner                Full admin, merge to main, approve all
harvester-admins     -->  Maintainer           Merge to main, approve infra changes
rancher-admins       -->  Maintainer           Merge to main, approve cluster changes
infra-engineers      -->  Maintainer           Merge to main, approve service changes
senior-developers    -->  Maintainer           Merge to main, approve code changes
developers           -->  Developer            Create MRs, cannot merge to main directly
viewers              -->  Reporter             Read-only access
ci-service-accounts  -->  (API token only)     Pipeline execution, image push, no merge
```

**SAML/OIDC Group Auto-Sync (GitLab Configuration):**

```yaml
# Addition to GitLab values-rke2-prod.yaml
appConfig:
  omniauth:
    enabled: true
    allowSingleSignOn: ['openid_connect']
    blockAutoCreatedUsers: false
    autoLinkUser: ['openid_connect']
    syncProfileFromProvider: ['openid_connect']
    syncProfileAttributes: ['email', 'name']
    # Group sync: map Keycloak groups to GitLab groups
    autoSignInWithProvider: openid_connect
    externalProviders: ['openid_connect']
```

```bash
# GitLab SAML group sync via API (run after OIDC login creates users)
# Map Keycloak group -> GitLab group with appropriate access level

sync_keycloak_group_to_gitlab() {
  local kc_group=$1
  local gitlab_group_id=$2
  local access_level=$3  # 10=Guest, 20=Reporter, 30=Developer, 40=Maintainer, 50=Owner

  # Get all GitLab users who have the Keycloak group in their OIDC claims
  local users=$(gitlab_api GET "groups/${gitlab_group_id}/members" | jq -r '.[].id')

  # For each user with matching Keycloak group, set appropriate access level
  for user_id in $users; do
    gitlab_api PUT "groups/${gitlab_group_id}/members/${user_id}" \
      --arg access_level "$access_level"
  done
}

# Execute group sync
sync_keycloak_group_to_gitlab "platform-admins" "$PLATFORM_SERVICES_GROUP_ID" 50
sync_keycloak_group_to_gitlab "infra-engineers" "$PLATFORM_SERVICES_GROUP_ID" 40
sync_keycloak_group_to_gitlab "senior-developers" "$PLATFORM_SERVICES_GROUP_ID" 40
sync_keycloak_group_to_gitlab "developers" "$PLATFORM_SERVICES_GROUP_ID" 30
sync_keycloak_group_to_gitlab "viewers" "$PLATFORM_SERVICES_GROUP_ID" 20
```

**Multi-Environment Approval Chain (Production Promotion):**

For the staging-to-production promotion flow, a separate manifest repo controls
production overlays. This repo has stricter approval rules:

```
Code Repo (service source code)
    |
    | Developer creates MR
    | Requires: 2 approvals from senior-developers/infra-engineers
    | Pipeline: full CI (lint, test, scan, build, push to Harbor)
    |
    v
Merge to main -> ArgoCD syncs to STAGING automatically
    |
    | 24h soak in staging
    | Monitoring validates health
    |
    v
Production Manifest Repo (Kustomize production overlay)
    |
    | Platform engineer creates MR to update image tag
    | Requires: 1 platform-admin + 1 senior-developer approval
    | Pipeline: kustomize build validation + kubeconform
    |
    v
Merge to main -> ArgoCD syncs to PRODUCTION via Argo Rollout
    |
    | Canary analysis at 5%, 25%, 50%, 100%
    | Auto-rollback on failure
    v
Live Traffic
```

**ArgoCD RBAC (Complementary to GitLab Gates):**

ArgoCD itself enforces role-based access via Keycloak groups:

```yaml
# services/argo/argocd/argocd-rbac-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    # platform-admins: full access
    g, platform-admins, role:admin

    # infra-engineers: sync and manage apps, no settings
    p, role:infra-ops, applications, sync, */*, allow
    p, role:infra-ops, applications, get, */*, allow
    p, role:infra-ops, applications, override, */*, allow
    p, role:infra-ops, applications, action/*, */*, allow
    g, infra-engineers, role:infra-ops

    # senior-developers: view apps, sync their own projects
    p, role:senior-dev, applications, get, */*, allow
    p, role:senior-dev, applications, sync, default/*, allow
    g, senior-developers, role:senior-dev

    # developers: read-only view of all apps
    g, developers, role:readonly

    # viewers: read-only
    g, viewers, role:readonly

    # ci-service-accounts: sync only (used by pipeline promotion)
    p, role:ci-sync, applications, sync, */*, allow
    p, role:ci-sync, applications, get, */*, allow
    g, ci-service-accounts, role:ci-sync
  scopes: '[groups]'
```

**Audit Trail for Approvals:**

Every merge approval is tracked in:
1. **GitLab Audit Events** - who approved, when, which MR
2. **ArgoCD Audit Log** - who triggered sync, what changed
3. **Vault Audit Log** - what secrets were accessed during pipeline
4. **Prometheus Metrics** - `cicd_merge_approval_total{group, project, approver}`

---

### WORKSTREAM 3: Platform Infrastructure
**Owner**: PE-1 (Platform Infrastructure Team)
**Overseen by**: SDM-1
**Dependencies**: None (builds on existing deployed services)

#### Deliverables

**3.1 GitLab Runner Fleet Enhancement**

Expand the existing runner infrastructure for CI/CD workload:

```yaml
# Runner pool architecture
runners:
  shared-runners:
    replicas: 3-10 (autoscale)
    nodeSelector: harvester-pool=general
    resources:
      requests: {cpu: "2", memory: "4Gi"}
      limits: {cpu: "4", memory: "8Gi"}
    tags: [shared, general]

  build-runners:
    replicas: 2-8 (autoscale)
    nodeSelector: harvester-pool=compute
    resources:
      requests: {cpu: "4", memory: "8Gi"}
      limits: {cpu: "8", memory: "16Gi"}
    tags: [build, docker, kaniko]
    privileged: false  # kaniko does not need privileged

  security-runners:
    replicas: 1-4 (autoscale)
    nodeSelector: harvester-pool=general
    resources:
      requests: {cpu: "2", memory: "4Gi"}
      limits: {cpu: "4", memory: "8Gi"}
    tags: [security, trivy, semgrep, gitleaks]

  test-runners:
    replicas: 2-6 (autoscale)
    nodeSelector: harvester-pool=general
    resources:
      requests: {cpu: "2", memory: "4Gi"}
      limits: {cpu: "4", memory: "8Gi"}
    tags: [test, acceptance, k6]
```

**3.2 Vault CI/CD Integration**

```
Vault Configuration for CI/CD:

vault/
  auth/
    jwt/
      role: gitlab-ci           # GitLab CI JWT auth
        bound_claims:
          project_path: platform-services/*
          ref: main
          ref_protected: true
        token_policies: [ci-read-secrets]
        token_ttl: 1h

      role: argocd              # ArgoCD service account auth
        bound_service_account_names: [argocd-server, argocd-repo-server]
        bound_service_account_namespaces: [argocd]
        token_policies: [argocd-secrets]

  secrets/
    kv-v2/
      ci/
        harbor-credentials      # Harbor push credentials for CI
        gitlab-api-token        # GitLab API token for ArgoCD
        sonarqube-token         # If SonarQube added later
        signing-key             # Image signing key (cosign)
      services/
        <service-name>/
          database-url          # Per-service secrets
          api-keys
          encryption-keys

  pki/
    ci-intermediate/            # Short-lived certs for CI/CD
      role: ci-server-cert
        max_ttl: 24h
        allow_subdomains: true
```

**External Secrets Operator (ESO) Integration:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: {{ .NAMESPACE }}
spec:
  provider:
    vault:
      server: https://vault.<DOMAIN>
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: {{ .SERVICE_NAME }}
          serviceAccountRef:
            name: {{ .SERVICE_NAME }}

---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ .SERVICE_NAME }}-secrets
  namespace: {{ .NAMESPACE }}
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: {{ .SERVICE_NAME }}-secrets
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: services/{{ .SERVICE_NAME }}
        property: database-url
```

**3.3 Harbor CI/CD Policies**

```
Harbor Configuration:

Projects:
  platform-services/          # Platform infrastructure images
    retention: 90 days, keep last 10 tags per repo
    vulnerability: auto-scan on push
    immutable: tags matching semver (v*)

  application-services/       # Application team images
    retention: 30 days, keep last 5 tags per repo
    vulnerability: auto-scan on push
    immutable: tags matching semver (v*)

  ci-cache/                   # Build cache layers
    retention: 7 days
    vulnerability: disabled (cache only)

Robot Accounts:
  ci-push:                    # GitLab CI pushes images
    projects: [platform-services, application-services, ci-cache]
    permissions: push, pull

  argocd-pull:                # ArgoCD pulls images
    projects: [platform-services, application-services]
    permissions: pull

  trivy-scan:                 # Trivy scans images
    projects: [platform-services, application-services]
    permissions: pull

Webhook Notifications:
  - On critical vulnerability found -> Mattermost #security-alerts
  - On image push -> ArgoCD image updater (optional)
```

**3.4 Ephemeral Namespace Management**

```yaml
# Namespace controller (CronJob or operator)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ephemeral-namespace-cleaner
  namespace: kube-system
spec:
  schedule: "*/30 * * * *"  # Every 30 minutes
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: namespace-cleaner
          containers:
            - name: cleaner
              image: bitnami/kubectl
              command:
                - /bin/sh
                - -c
                - |
                  # Delete namespaces older than TTL
                  kubectl get ns -l ephemeral-ttl \
                    -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}' | \
                  while read ns created; do
                    age=$(( $(date +%s) - $(date -d "$created" +%s) ))
                    if [ $age -gt 14400 ]; then  # 4 hours
                      kubectl delete ns "$ns" --grace-period=30
                    fi
                  done
```

**3.5 Network Policies for CI/CD**

```yaml
# GitLab runners can only reach:
# - Harbor (push images)
# - Vault (fetch secrets)
# - GitLab (clone repos, report status)
# - Internet (pull dependencies) - via egress proxy
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: gitlab-runner-egress
  namespace: gitlab-runners
spec:
  endpointSelector:
    matchLabels:
      app: gitlab-runner
  egress:
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: harbor
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: vault
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: gitlab
    - toFQDNs:
        - matchPattern: "*.golang.org"
        - matchPattern: "*.npmjs.org"
        - matchPattern: "*.pypi.org"
        - matchPattern: "registry.npmjs.org"
```

---

### WORKSTREAM 4: Observability & DORA Metrics
**Owner**: PE-2 (Observability Team)
**Overseen by**: SDM-1
**Dependencies**: SDE-1 (pipeline must emit metrics), PE-1 (Prometheus config)

#### Deliverables

**4.1 DORA Metrics Collection**

```yaml
# GitLab webhook receiver for pipeline events
# Deployed as a lightweight Go service in the monitoring namespace
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dora-metrics-collector
  namespace: monitoring
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: collector
          image: harbor.<DOMAIN>/platform-services/dora-collector:v1.0.0
          ports:
            - containerPort: 8080
          env:
            - name: GITLAB_WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: dora-collector-secrets
                  key: webhook-secret
            - name: PROMETHEUS_PUSHGATEWAY
              value: prometheus-pushgateway.monitoring.svc:9091
```

**Metrics exposed to Prometheus:**

```
# DORA Four Key Metrics
cicd_deployment_frequency_total{service, environment}          # Counter
cicd_lead_time_seconds{service, environment}                   # Histogram
cicd_change_failure_rate{service, environment}                 # Gauge (0-1)
cicd_mean_time_to_restore_seconds{service, environment}        # Histogram

# Pipeline Performance Metrics
cicd_pipeline_duration_seconds{service, stage, status}         # Histogram
cicd_pipeline_queue_time_seconds{service, runner_type}         # Histogram
cicd_pipeline_success_rate{service}                            # Gauge
cicd_pipeline_runs_total{service, status}                      # Counter

# Quality Gate Metrics
cicd_test_pass_rate{service, test_type}                        # Gauge
cicd_test_coverage_percent{service}                            # Gauge
cicd_vulnerability_count{service, severity}                    # Gauge
cicd_sbom_component_count{service}                             # Gauge

# Rollout Metrics
cicd_rollout_duration_seconds{service, strategy}               # Histogram
cicd_rollback_total{service, reason}                           # Counter
cicd_canary_analysis_result{service, template}                 # Gauge (0=fail, 1=pass)

# Feature Flag Metrics (if Unleash/Vault flags deployed)
cicd_feature_flag_count{state}                                 # Gauge
cicd_feature_flag_age_days{flag_name}                          # Gauge
```

**4.2 Grafana DORA Dashboard**

```json
{
  "dashboard": {
    "title": "DORA Metrics - CI/CD Performance",
    "panels": [
      {
        "title": "Deployment Frequency",
        "type": "stat",
        "description": "Deployments to production per day (Elite: multiple/day)",
        "targets": [{"expr": "sum(increase(cicd_deployment_frequency_total{environment='production'}[24h]))"}]
      },
      {
        "title": "Lead Time for Changes",
        "type": "stat",
        "description": "Commit to production (Elite: < 1 hour)",
        "targets": [{"expr": "histogram_quantile(0.50, sum(rate(cicd_lead_time_seconds_bucket{environment='production'}[7d])) by (le))"}]
      },
      {
        "title": "Change Failure Rate",
        "type": "gauge",
        "description": "% of deployments causing failure (Elite: < 5%)",
        "targets": [{"expr": "avg(cicd_change_failure_rate{environment='production'})"}]
      },
      {
        "title": "Mean Time to Restore",
        "type": "stat",
        "description": "Time to recover from failure (Elite: < 1 hour)",
        "targets": [{"expr": "histogram_quantile(0.50, sum(rate(cicd_mean_time_to_restore_seconds_bucket{environment='production'}[30d])) by (le))"}]
      },
      {
        "title": "Pipeline Duration Trend",
        "type": "timeseries",
        "targets": [{"expr": "histogram_quantile(0.95, sum(rate(cicd_pipeline_duration_seconds_bucket[1h])) by (le, stage))"}]
      },
      {
        "title": "Pipeline Success Rate",
        "type": "timeseries",
        "targets": [{"expr": "cicd_pipeline_success_rate"}]
      },
      {
        "title": "Vulnerability Trend",
        "type": "timeseries",
        "targets": [{"expr": "sum(cicd_vulnerability_count) by (severity)"}]
      },
      {
        "title": "Rollback Frequency",
        "type": "timeseries",
        "targets": [{"expr": "sum(increase(cicd_rollback_total[24h])) by (service)"}]
      }
    ]
  }
}
```

**4.3 Pipeline Log Aggregation**

Configure Alloy/Loki to capture GitLab Runner pod logs with structured labels:

```yaml
# Alloy config addition for CI/CD logs
discovery.kubernetes "gitlab_runners" {
  role = "pod"
  namespaces {
    names = ["gitlab-runners"]
  }
  selectors {
    role = "pod"
    label = "app=gitlab-runner"
  }
}

loki.source.kubernetes "runner_logs" {
  targets    = discovery.kubernetes.gitlab_runners.targets
  forward_to = [loki.write.default.receiver]

  clustering {
    enabled = true
  }
}
```

**4.4 Alerting Rules for CI/CD**

```yaml
groups:
  - name: cicd-alerts
    rules:
      - alert: PipelineSuccessRateLow
        expr: cicd_pipeline_success_rate < 0.90
        for: 30m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Pipeline success rate below 90% for {{ $labels.service }}"

      - alert: PipelineDurationHigh
        expr: histogram_quantile(0.95, rate(cicd_pipeline_duration_seconds_bucket[1h])) > 900
        for: 1h
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Pipeline p95 duration exceeds 15 minutes"

      - alert: DeploymentRollbackFrequent
        expr: increase(cicd_rollback_total[24h]) > 3
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "More than 3 rollbacks in 24h for {{ $labels.service }}"

      - alert: CriticalVulnerabilityDetected
        expr: cicd_vulnerability_count{severity="CRITICAL"} > 0
        labels:
          severity: critical
          team: security
        annotations:
          summary: "Critical vulnerability in {{ $labels.service }}"

      - alert: LeadTimeRegression
        expr: histogram_quantile(0.50, rate(cicd_lead_time_seconds_bucket[7d])) > 86400
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Median lead time exceeds 24 hours"
```

---

### WORKSTREAM 5: Security & Compliance
**Owner**: SEC-1 (Security Engineering Team)
**Overseen by**: PTM-2
**Dependencies**: SDE-1 (pipeline integration points), PE-1 (Vault config)

#### Deliverables

**5.1 Security Scanning Pipeline Integration**

```yaml
# templates/jobs/security-scan.yml

# SAST - Static Application Security Testing
sast:
  stage: scan
  image: returntocorp/semgrep
  script:
    - semgrep scan --config auto --json --output semgrep-results.json .
    - |
      CRITICAL=$(jq '[.results[] | select(.extra.severity == "ERROR")] | length' semgrep-results.json)
      if [ "$CRITICAL" -gt 0 ]; then
        echo "SAST found $CRITICAL critical issues"
        exit 1
      fi
  artifacts:
    reports:
      sast: semgrep-results.json
  tags: [security]

# SCA - Software Composition Analysis
dependency-scan:
  stage: scan
  image: aquasec/trivy
  script:
    - trivy fs --severity ${TRIVY_SEVERITY:-CRITICAL,HIGH} --exit-code 1 --format json --output trivy-fs.json .
  artifacts:
    reports:
      dependency_scanning: trivy-fs.json
  tags: [security]

# Container Image Scan
image-scan:
  stage: scan
  image: aquasec/trivy
  needs: [build-image]
  script:
    - trivy image --severity ${TRIVY_SEVERITY:-CRITICAL,HIGH} --exit-code 1 --format json --output trivy-image.json ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${SERVICE_NAME}:${CI_COMMIT_SHA}
  artifacts:
    reports:
      container_scanning: trivy-image.json
  tags: [security]

# Secret Detection
secret-detection:
  stage: pre-build
  image: zricethezav/gitleaks
  script:
    - gitleaks detect --source . --verbose --report-format json --report-path gitleaks.json
  artifacts:
    reports:
      secret_detection: gitleaks.json
  tags: [security]

# SBOM Generation
sbom:
  stage: build
  image: anchore/syft
  needs: [build-image]
  script:
    - syft ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${SERVICE_NAME}:${CI_COMMIT_SHA} -o cyclonedx-json=sbom.json
  artifacts:
    paths:
      - sbom.json
  tags: [security]

# License Compliance
license-check:
  stage: scan
  image: aquasec/trivy
  script:
    - trivy fs --scanners license --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --format json --output license-report.json .
    - |
      # Block on GPL/AGPL in non-GPL projects
      BLOCKED=$(jq '[.Results[].Licenses[]? | select(.Name | test("GPL|AGPL"))] | length' license-report.json)
      if [ "$BLOCKED" -gt 0 ]; then
        echo "Blocked licenses found: GPL/AGPL"
        exit 1
      fi
  artifacts:
    paths:
      - license-report.json
  tags: [security]
```

**5.2 Image Signing with Cosign**

```yaml
# Sign images after build, verify before deploy
sign-image:
  stage: build
  needs: [build-image, image-scan]
  image: gcr.io/projectsigstore/cosign
  script:
    - |
      # Sign with Vault-stored key
      export VAULT_ADDR=https://vault.<DOMAIN>
      export VAULT_TOKEN=$(vault write -field=token auth/jwt/login role=gitlab-ci jwt=$CI_JOB_JWT)
      cosign sign --key hashivault://ci/signing-key \
        ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${SERVICE_NAME}:${CI_COMMIT_SHA}
  tags: [security]

# ArgoCD admission controller verifies signatures before deploy
# (Kyverno or OPA Gatekeeper policy)
```

**5.3 Compliance Audit Trail**

```yaml
# Audit events stored in Vault Audit Log + GitLab Audit Events

# Vault audit backend (already enabled, add CI/CD-specific log)
vault audit enable file file_path=/vault/audit/cicd-audit.log

# GitLab project audit events tracked automatically:
# - Who merged what MR
# - Who triggered what pipeline
# - Who approved what deployment
# - What artifacts were produced
# - What vulnerabilities were found and accepted

# Compliance dashboard query (Loki):
# {namespace="gitlab"} |= "pipeline" | json | line_format "{{.user}} {{.action}} {{.project}}"
```

**5.4 RBAC for CI/CD Operations**

```yaml
# Keycloak groups mapped to GitLab + ArgoCD + Vault roles

Keycloak Groups:
  cicd-admins:          # Full CI/CD admin access
    GitLab: Owner role on platform-services group
    ArgoCD: admin role
    Vault: ci-admin policy

  cicd-operators:       # Can trigger deploys, view pipelines
    GitLab: Maintainer role
    ArgoCD: sync-only role (custom)
    Vault: ci-read-secrets policy

  cicd-developers:      # Can push code, view pipeline results
    GitLab: Developer role
    ArgoCD: read-only
    Vault: no direct access (CI fetches secrets)

  cicd-security:        # Can view security reports, manage policies
    GitLab: Reporter + security dashboard
    ArgoCD: read-only
    Vault: security-audit policy
```

---

### WORKSTREAM 6: Documentation & Developer Experience
**Owner**: TDW-1 (Documentation Team)
**Overseen by**: PTM-1
**Dependencies**: All other workstreams (documents what they build)

#### Deliverables

**6.1 Developer Onboarding Guide**

```
docs/cicd/
  developer-guide.md              # Getting started with the CI/CD platform
  creating-a-service.md           # Step-by-step: new service from template
  pipeline-reference.md           # All stages, gates, variables, overrides
  troubleshooting-pipelines.md    # Common failures and fixes
  rollback-runbook.md             # How to roll back any service
  feature-flag-guide.md           # How to use feature flags
  security-scanning-guide.md      # Understanding scan results, fixing vulns
  dora-metrics-guide.md           # Reading the DORA dashboard
```

**6.2 Architecture Decision Records (ADRs)**

```
docs/cicd/adrs/
  001-gitlab-ci-over-github-actions.md
  002-kaniko-over-docker-in-docker.md
  003-kustomize-over-helm-for-app-manifests.md
  004-argocd-applicationsets-for-ephemeral.md
  005-trivy-over-grype-for-scanning.md
  006-cosign-for-image-signing.md
  007-vault-jwt-auth-for-ci.md
  008-argo-rollouts-over-flagger.md
  009-expand-contract-for-schema-changes.md
  010-dora-collector-architecture.md
```

**6.3 Runbooks (Operational)**

```
docs/cicd/runbooks/
  pipeline-failure-triage.md      # Decision tree for pipeline failures
  rollback-procedure.md           # Step-by-step rollback for any service
  runner-scaling-issues.md        # Runner pool troubleshooting
  harbor-storage-full.md          # Registry cleanup procedures
  vault-token-expired.md          # CI Vault auth issues
  argocd-sync-failure.md          # ArgoCD sync troubleshooting
  canary-analysis-failure.md      # Argo Rollouts analysis debugging
  security-incident-response.md   # CVE found in production image
```

**6.4 Service Template Repository**

```
service-template/
  .gitlab-ci.yml                  # Pre-configured pipeline
  Dockerfile                      # Multi-stage build template
  Makefile                        # Common targets (build, test, lint, run)
  go.mod / package.json           # Language-specific dependency file
  cmd/main.go / src/index.ts      # Entry point
  internal/ / src/                # Source code structure
  test/                           # Test directory
  manifests/                      # Kustomize base + overlays
    base/
      deployment.yaml
      service.yaml
      kustomization.yaml
    overlays/
      ephemeral/
      staging/
      production/
  README.md                       # Service documentation template
  CODEOWNERS                      # Required reviewers
```

---

### WORKSTREAM 7: Feature Flag Infrastructure (Optional/Phase 2)
**Owner**: SDE-2 (GitOps & Delivery Team)
**Overseen by**: PTM-1
**Dependencies**: PE-1 (Vault for flag storage), Workstream 2

#### Deliverables

**7.1 Feature Flag System**

Two implementation options (GM decides):

**Option A: Vault KV-based (Simple, no new services)**
- Feature flags stored in Vault KV v2 at `kv/feature-flags/<service>/`
- Applications read flags via Vault API or sidecar
- Dashboard via Grafana (query Vault API)
- Suitable for < 50 flags

**Option B: Unleash (Full-featured, self-hosted)**
- Deploy Unleash server in K8s (CNPG PostgreSQL backend)
- Keycloak OIDC integration for dashboard auth
- Client SDKs for Go, Node, Python
- Feature: percentage rollout, user targeting, A/B testing
- Suitable for 50+ flags, multiple teams

**7.2 Flag Lifecycle Automation**

```yaml
# CronJob to alert on stale flags (> 90 days)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: feature-flag-auditor
spec:
  schedule: "0 9 * * 1"  # Weekly Monday 9am
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: auditor
              image: harbor.<DOMAIN>/platform-services/flag-auditor:v1.0.0
              env:
                - name: MAX_FLAG_AGE_DAYS
                  value: "90"
                - name: MATTERMOST_WEBHOOK
                  valueFrom:
                    secretKeyRef:
                      name: flag-auditor-secrets
                      key: mattermost-webhook
```

---

## Dependency Graph

```
                    +-------------------+
                    | PE-1: Runners +   |
                    | Vault + Harbor    |
                    | Network Policies  |
                    +--------+----------+
                             |
              +--------------+--------------+
              |                             |
    +---------v---------+        +----------v----------+
    | SDE-1: CI Pipeline|        | SDE-2: GitOps +     |
    | Templates + Gates |        | Argo Rollouts +     |
    | Quality Framework |        | Env Promotion       |
    +---------+---------+        +----------+----------+
              |                             |
              +-------------+---------------+
                            |
              +-------------v--------------+
              | SEC-1: Security Scanning   |
              | SBOM, Signing, Compliance  |
              +-------------+--------------+
                            |
              +-------------v--------------+
              | PE-2: DORA Metrics +       |
              | Dashboards + Alerting      |
              +-------------+--------------+
                            |
              +-------------v--------------+
              | TDW-1: Documentation       |
              | (runs in parallel with all)|
              +----------------------------+
```

**Critical Path**: PE-1 -> SDE-1 -> SDE-2 -> SEC-1 -> PE-2

**Parallel tracks**:
- TDW-1 runs continuously alongside all workstreams
- SEC-1 can start policy work before SDE-1 completes (just cannot integrate until pipelines exist)
- PE-2 can build dashboards before metrics are flowing (use mock data)

---

## Execution Timeline

### Phase A: Foundation (Weeks 1-2)
**All teams start simultaneously**

| Team | Week 1 | Week 2 |
|------|--------|--------|
| PE-1 | Runner fleet deployed + autoscaling, Vault JWT auth configured | Harbor robot accounts, ESO deployed, network policies |
| SDE-1 | Template repo scaffolded, base.yml + stages.yml, lint jobs | Build jobs (kaniko), unit test jobs, push-harbor job |
| SDE-2 | Manifest repo structure defined, Kustomize base templates | ArgoCD ApplicationSet for ephemeral envs |
| SEC-1 | Security policy document, scanning tool evaluation | gitleaks + semgrep CI job templates |
| PE-2 | DORA collector design, Prometheus metric names defined | Collector service scaffolded, Grafana dashboard mockup |
| TDW-1 | ADR templates, developer guide outline | ADRs 001-005 written, onboarding guide draft |

### Phase B: Pipeline Assembly (Weeks 3-4)

| Team | Week 3 | Week 4 |
|------|--------|--------|
| PE-1 | Ephemeral namespace controller, runner monitoring | Load testing runners, capacity planning |
| SDE-1 | Contract test jobs, acceptance test framework | Full microservice.yml pattern, MR vs main pipeline split |
| SDE-2 | Canary Rollout templates, AnalysisTemplates | Blue-green templates, promotion workflow |
| SEC-1 | Trivy image scan, SBOM generation, license check | Cosign signing, compliance audit trail |
| PE-2 | DORA collector deployed, pipeline webhook integration | Grafana dashboards live with real data |
| TDW-1 | Pipeline reference doc, security scanning guide | Rollback runbook, troubleshooting guide |

### Phase C: Integration & Hardening (Weeks 5-6)

| Team | Week 5 | Week 6 |
|------|--------|--------|
| PE-1 | End-to-end integration testing, failover drills | Performance optimization, documentation |
| SDE-1 | Example service deployed through full pipeline | Edge cases, error handling, retry logic |
| SDE-2 | Full promotion flow tested (ephemeral->staging->prod) | Rollback drills, multi-service coordination |
| SEC-1 | Pen test of CI/CD infrastructure | Remediation, final security report |
| PE-2 | Alert tuning, SLO definition, capacity alerting | DORA baseline established |
| TDW-1 | All docs reviewed and published | Service template repo with walkthrough |

### Phase D: Golden Path & Handoff (Week 7)

| Team | Activity |
|------|----------|
| ALL | First real application deployed through complete pipeline |
| ALL | Chaos testing: kill runners, fail Vault, corrupt images |
| ALL | Documentation review, knowledge transfer sessions |
| GM | Final progress report, memory files updated, handoff to operations |

---

## Script 4 Structure

The primary deliverable is `scripts/setup-cicd-infrastructure.sh`:

```bash
#!/usr/bin/env bash
# setup-cicd-infrastructure.sh - CI/CD Infrastructure Build-Out
# Phases 1-10, supports --from N for resumption

# Phase 1: Prerequisites & Validation
#   - Verify GitLab, ArgoCD, Vault, Harbor, Prometheus are healthy
#   - Verify runner fleet is operational
#   - Verify Keycloak OIDC clients exist

# Phase 2: Vault CI/CD Configuration
#   - Enable JWT auth method for GitLab CI
#   - Create CI/CD policies and roles
#   - Store signing keys, Harbor credentials

# Phase 3: Harbor CI/CD Configuration
#   - Create CI/CD projects (platform-services, application-services, ci-cache)
#   - Create robot accounts (ci-push, argocd-pull, trivy-scan)
#   - Configure retention policies and vulnerability scanning

# Phase 4: External Secrets Operator
#   - Deploy ESO via Helm
#   - Configure Vault SecretStore (cluster-wide)
#   - Test with sample ExternalSecret

# Phase 5: GitLab CI Template Library
#   - Create platform-services/gitlab-ci-templates project
#   - Push all template files
#   - Configure group-level CI/CD variables

# Phase 6: GitOps Manifest Templates
#   - Create manifest repo templates
#   - Deploy ArgoCD ApplicationSet for ephemeral environments
#   - Deploy ArgoCD ApplicationSet for staging
#   - Configure ArgoCD RBAC for CI/CD roles

# Phase 7: Argo Rollouts Configuration
#   - Deploy AnalysisTemplates (success-rate, latency, error-rate)
#   - Configure traffic routing plugin for Gateway API
#   - Test canary rollout with sample service

# Phase 8: Security Scanning Infrastructure
#   - Deploy security runner pool
#   - Configure image signing (cosign + Vault)
#   - Test full security pipeline with sample service

# Phase 9: DORA Metrics & Observability
#   - Deploy dora-metrics-collector
#   - Import Grafana DORA dashboard
#   - Configure CI/CD alerting rules
#   - Configure pipeline log aggregation

# Phase 10: Validation & Smoke Tests
#   - Deploy sample service through complete pipeline
#   - Verify all quality gates fire correctly
#   - Test rollback
#   - Validate DORA metrics are flowing
#   - Print summary with all endpoints
```

---

## Success Criteria

### MinimumCD Compliance Checklist

| Requirement | Verification Method | Target |
|------------|-------------------|--------|
| Trunk-based development | GitLab project settings audit | All projects enforce |
| Daily integration | Integration frequency metric | >= 1 per dev per day |
| Automated testing before merge | MR pipeline gates | 100% enforced |
| Pipeline is sole deploy path | ArgoCD audit log + RBAC | No manual deploys possible |
| Pipeline verdict is definitive | Quality gate configuration | All gates blocking |
| Immutable artifacts | Harbor tag immutability policy | Enabled on all projects |
| Work stops when pipeline red | GitLab auto-block MRs | Configured + tested |
| Production-like test env | Ephemeral namespace comparison | < 5% config drift |
| On-demand rollback | Rollback drill timing | < 5 minutes |
| Config with artifact | Kustomize overlay audit | No manual config changes |

### DORA Metrics Targets (30-day baseline)

| Metric | Initial Target | Elite Target |
|--------|---------------|-------------|
| Deployment Frequency | Weekly | Multiple per day |
| Lead Time | < 1 week | < 1 hour |
| Change Failure Rate | < 15% | < 5% |
| Mean Time to Restore | < 1 day | < 1 hour |
| Pipeline Duration | < 20 min | < 10 min |

### Operational Readiness

| Capability | Requirement |
|-----------|------------|
| Pipeline success rate | > 95% over 7 days |
| Runner availability | > 99.5% uptime |
| Rollback tested | 3 successful drills |
| Security scanning | 0 critical CVEs in production images |
| Documentation | All runbooks reviewed by ops team |
| DORA dashboard | Live data flowing for 7+ days |
| Alerting | All alerts tested with synthetic failures |

---

## Memory File Structure for GM

The GM maintains these files for context continuity:

```
docs/cicd-progress.md           # Overall progress tracker (updated daily)
  - Per-workstream status (RED/YELLOW/GREEN)
  - Current blockers
  - Decisions made (with rationale)
  - Next actions per team

docs/cicd-decisions-log.md      # All architectural/technical decisions
  - Decision ID, date, who made it, rationale
  - Links to relevant ADRs

docs/cicd-integration-points.md # Cross-team integration tracker
  - Which teams need what from whom
  - Interface contracts between workstreams
  - Test results for integration points
```

---

## Risk Register

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|-----------|
| Runner capacity insufficient for parallel pipelines | Medium | High | Autoscaling configured, compute node pool scales 0-10 |
| Vault token expiry breaks CI pipelines | Medium | High | JWT auth with auto-renewal, Prometheus alert on auth failures |
| Harbor storage exhaustion | Low | High | Retention policies, storage-autoscaler, capacity alerting |
| Ephemeral namespace leak (not cleaned up) | Medium | Medium | CronJob cleaner, namespace TTL labels, monitoring |
| Security scanning false positives block pipelines | High | Medium | Configurable severity thresholds, allowlist mechanism |
| ArgoCD sync storms during mass deployments | Low | High | Rate limiting, sync waves, resource hooks |
| CNPG database failover during schema migration | Low | Critical | Expand-contract pattern, migration dry-run stage |
| Cross-team merge conflicts in template repo | Medium | Medium | CODEOWNERS file, PTM review for cross-cutting changes |

---

## Phase 18: Demo — NetOps Arcade (3-Router Topology)

### Network Topology

```
              router-north (standby)
                  ↑
                  │ (activated by re-route)
router-west ──→ router-core ──→ router-east (default path)
```

- **router-west**: Entry point, receives packets from traffic generator, forwards to router-core
- **router-core**: Central relay — NEXT_HOPS is configurable (this is what the demo user changes)
- **router-east**: Default terminal node (receives packets in normal flow)
- **router-north**: Standby terminal (receives packets after successful re-route)

### Demo Scenarios

| # | Scenario | How to Trigger | What to Watch |
|---|----------|---------------|---------------|
| 1 | **Bad IP (auto-rollback)** | Edit `routing-config.yaml`: set `NEXT_HOPS=http://10.0.0.99:8080`, push | Canary deploys → packets drop → AnalysisRun fires → auto-rollback. Dashboard shows link go red, then recover. |
| 2 | **Good IP (full transition)** | Edit `routing-config.yaml`: set `NEXT_HOPS=http://router-north:8080`, push | Canary 5%→25%→50%→100%. Dashboard shows east link fade, north link activate. Zero dropped packets. |
| 3 | **Security block** | Push netops-dashboard with vulnerable lodash dep | Pipeline blocks at trivy scan stage. MR shows CVE details. |
| 4 | **Approval gate** | Create MR from developer account | MR requires senior-developer approval (Keycloak group enforcement). |
| 5 | **Blue-green switch** | Push netops-dashboard v2 (UI change) | Blue-green deploy with preview URL. Manual promote. Instant switchover. |

### Key File

The one file the demo user edits: `deploy/overlays/rke2-prod/routing-config.yaml` in the
`platform_services/packet-relay` GitLab project. It's a strategic merge patch for the
router-core Rollout's `NEXT_HOPS` environment variable.

---

## Appendix A: Tool Selection Rationale

| Tool | Purpose | Why This Over Alternatives |
|------|---------|--------------------------|
| GitLab CI | Pipeline execution | Already deployed, native GitLab integration, no additional infrastructure |
| ArgoCD | GitOps deployment | Already deployed, app-of-apps pattern established, HA configured |
| Argo Rollouts | Progressive delivery | Already deployed, Gateway API traffic router plugin configured |
| Vault | Secret management | Already deployed, PKI + K8s auth + audit logging |
| Harbor | Container registry | Already deployed, vulnerability scanning, retention policies |
| Trivy | Vulnerability scanning | Single tool for fs + image + license scanning, OSS, fast |
| Semgrep | SAST | Language-agnostic, fast, good rule library, OSS |
| Gitleaks | Secret detection | Fast, accurate, well-maintained, OSS |
| Syft | SBOM generation | CycloneDX + SPDX output, OCI-native, OSS |
| Cosign | Image signing | Sigstore standard, Vault integration, keyless option |
| Kaniko | Image building | No privileged mode needed, cache layers in Harbor |
| Kustomize | Manifest management | Native kubectl support, overlay model fits env promotion |
| k6 | Performance testing | Scriptable, Prometheus metrics output, OSS |

---

## Appendix B: Reference Links

- MinimumCD.org - Minimum Viable Continuous Delivery requirements
- CD Migration (bdfinst/cd-migration) - Phased migration guide
- DORA (dora.dev) - DevOps Research and Assessment metrics
- Argo Rollouts - Progressive delivery controller
- ArgoCD - Declarative GitOps CD
- Gateway API - Kubernetes ingress standard
