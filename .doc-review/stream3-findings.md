# Stream 3 Findings: deployment-automation.md + services-reference.md

Reviewer: Claude (automated)
Date: 2026-02-17
Ground truth: deploy-cluster.sh, lib.sh, setup-keycloak.sh, setup-cicd.sh, destroy-cluster.sh, upgrade-cluster.sh, prepare-airgapped.sh, setup-gitlab.sh

---

## deployment-automation.md

### FINDING DA-01: destroy-cluster.sh has 5 phases, not 4
- **Section**: 1 (Architecture Overview mermaid), 6.2 (Destroy Flow), Appendix A
- **Doc says**: "4 phases, Harvester cleanup orphan removal" / Phase 0=Pre-flight, Phase 1=Terraform Destroy, Phase 2=Harvester Cleanup, Phase 3=Local Cleanup
- **Actual**: 5 phases (0-4): Phase 0=Pre-flight, Phase 1=K8S Workload Cleanup (GitLab Helm uninstall, Redis CRs, CNPG cleanup, gitlab namespace), Phase 2=Terraform Destroy, Phase 3=Harvester Orphan Cleanup, Phase 4=Local Cleanup
- **Severity**: HIGH -- entire phase missing from documentation
- **Fix**: Add Phase 1 K8S workload cleanup, renumber all subsequent phases

### FINDING DA-02: setup-cicd.sh uses GitHub, not GitLab
- **Section**: 1 (mermaid), 9.1 (CLI Arguments), 9.2 (Flow), Appendix A
- **Doc says**: "GitLab <-> ArgoCD Connection", `--skip-gitlab` CLI arg, "GitLab-ArgoCD" references
- **Actual**: Script header says "GitHub + ArgoCD + Argo Rollouts CI/CD Integration". Uses `gh` CLI. CLI args are `--from N` and `--dry-run` (no `--skip-gitlab`). Creates GitHub repos, not GitLab.
- **Severity**: HIGH -- wrong tool/platform throughout
- **Fix**: Replace GitLab references with GitHub, fix CLI arg table, update flow descriptions

### FINDING DA-03: OIDC client count wrong (9 vs 14)
- **Section**: 8.3 (Phase 2 flowchart), Appendix A
- **Doc says**: "Phase 2: OIDC Client Creation (9 clients)"
- **Actual**: setup-keycloak.sh creates 14 clients: grafana, argocd, harbor, vault, mattermost, kasm, gitlab, kubernetes (public), prometheus-oidc, alertmanager-oidc, hubble-oidc, traefik-dashboard-oidc, rollouts-oidc, rancher
- **Severity**: HIGH
- **Fix**: Update count to 14

### FINDING DA-04: Group count wrong (7 vs 8) -- missing network-engineers
- **Section**: 8.3 (Phase 4 groups list), Appendix A
- **Doc says**: 7 groups: "platform-admins, harvester-admins, rancher-admins, infra-engineers, senior-developers, developers, viewers"
- **Actual**: 8 groups (setup-keycloak.sh line 713): platform-admins, harvester-admins, rancher-admins, infra-engineers, **network-engineers**, senior-developers, developers, viewers
- **Severity**: HIGH -- missing group
- **Fix**: Add network-engineers to both locations

### FINDING DA-05: distribute_root_ca targets 8 namespaces, not 4
- **Section**: 2.14 (function table), 4.7 (Phase 4 flowchart), 5.1 (Phase 2 flowchart)
- **Doc says**: "monitoring, argocd, harbor, and mattermost namespaces"
- **Actual** (lib.sh line 1184): kube-system, monitoring, argocd, argo-rollouts, harbor, mattermost, gitlab, keycloak
- **Severity**: HIGH -- 4 namespaces missing
- **Fix**: Update all three locations to list all 8 namespaces

### FINDING DA-06: Phase flowcharts incorrectly show label_unlabeled_nodes()
- **Section**: 4.7 (Phase 4), 4.8 (Phase 5), 4.9 (Phase 6), 4.10 (Phase 7), 4.12 (Phase 9)
- **Doc says**: Each flowchart starts with `label_unlabeled_nodes()`
- **Actual**: Phases 4-7 and Phase 9 in deploy-cluster.sh do NOT call label_unlabeled_nodes(). Only Phase 1 calls it (at start and end).
- **Severity**: MEDIUM -- misleading flowcharts
- **Fix**: Remove label_unlabeled_nodes() from Phase 4-7 and 9 flowcharts

### FINDING DA-07: Missing .env variables in Section 3.1
- **Section**: 3.1 (.env Variable Reference)
- **Missing variables**: HARBOR_ADMIN_PASSWORD, HARBOR_MINIO_SECRET_KEY, HARBOR_DB_PASSWORD, KASM_PG_SUPERUSER_PASSWORD, KASM_PG_APP_PASSWORD, KC_ADMIN_PASSWORD, GITLAB_ROOT_PASSWORD, GITLAB_PRAEFECT_DB_PASSWORD, GITLAB_REDIS_PASSWORD, GITLAB_GITALY_TOKEN, GITLAB_PRAEFECT_TOKEN, GITLAB_CHART_PATH, OAUTH2_PROXY_REDIS_PASSWORD, GIT_BASE_URL, ARGO_ROLLOUTS_PLUGIN_URL, HELM_OCI_* (10 vars)
- **Severity**: HIGH -- many credential variables undocumented
- **Fix**: Add all missing variables to the table

### FINDING DA-08: Missing CHANGEME tokens in Section 3.3
- **Section**: 3.3 (CHANGEME Token Substitution table)
- **Missing tokens**: CHANGEME_HARBOR_ADMIN_PASSWORD, CHANGEME_HARBOR_MINIO_SECRET_KEY, CHANGEME_HARBOR_DB_PASSWORD, CHANGEME_KASM_PG_SUPERUSER_PASSWORD, CHANGEME_KASM_PG_APP_PASSWORD, CHANGEME_KC_ADMIN_PASSWORD, CHANGEME_OAUTH2_PROXY_REDIS_PASSWORD, CHANGEME_ARGO_ROLLOUTS_PLUGIN_URL, CHANGEME_GIT_BASE_URL, CHANGEME_KC_REALM, CHANGEME_GITLAB_REDIS_PASSWORD
- **Severity**: HIGH
- **Fix**: Add all missing tokens to the table

### FINDING DA-09: Phase 10 description incomplete
- **Section**: 4.13
- **Doc says**: "Phase 10 calls setup-keycloak.sh as a child process. See Section 8 for details."
- **Actual**: Phase 10 does much more: after calling setup-keycloak.sh, it creates oauth2-proxy secrets for 5 services (prometheus-oidc, alertmanager-oidc, hubble-oidc, traefik-dashboard-oidc, rollouts-oidc), distributes Redis credentials to kube-system and argo-rollouts, and applies all oauth2-proxy deployment + ForwardAuth middleware manifests.
- **Severity**: MEDIUM
- **Fix**: Add Phase 10 details

### FINDING DA-10: Missing Phase 11 details
- **Section**: After 4.13 (no section exists for Phase 11)
- **Actual**: Phase 11 calls setup-gitlab.sh which has 7 phases: Prerequisites, CNPG PostgreSQL, Secrets, OpsTree Redis, Gateway, Helm Install, Validation
- **Severity**: LOW -- brief mention exists but no detail
- **Fix**: Add Phase 11 section

### FINDING DA-11: Missing airgapped functions in lib.sh section
- **Section**: 2 (lib.sh Shared Library)
- **Missing functions**: validate_airgapped_prereqs(), resolve_helm_chart()
- **Severity**: MEDIUM
- **Fix**: Add to function tables

### FINDING DA-12: GIT_REPO_URL default value wrong
- **Section**: 3.1 (.env Variable Reference)
- **Doc says**: Default is `git@gitlab.${DOMAIN}:infrastructure/rke2-cluster.git`
- **Actual** (lib.sh line 883): Derived from `git remote get-url origin`, fallback is `git@github.com:OWNER/rke2-cluster.git`
- **Severity**: MEDIUM
- **Fix**: Correct the default value

### FINDING DA-13: Keycloak called in Phase 10 per doc, but script says Phase 10
- **Section**: 1 (Script Dependency Chain mermaid)
- **Doc says**: "Phase 10 calls" setup-keycloak.sh
- **Actual**: Correct (Phase 10). No fix needed.
- **Severity**: N/A (correct)

### FINDING DA-14: Missing Rollouts oauth2-proxy in Phase 5 flowchart
- **Section**: 4.8 (Phase 5 flowchart)
- **Doc says**: Phase 5 applies Gateway + HTTPRoute for Rollouts
- **Actual**: Phase 5 also applies Rollouts oauth2-proxy.yaml and middleware-oauth2-proxy.yaml
- **Severity**: LOW
- **Fix**: Add oauth2-proxy middleware to Phase 5 flowchart

### FINDING DA-15: Phase 3 missing Traefik restart
- **Section**: Phase 2 flowchart (5.1)
- **Actual**: After distribute_root_ca(), Phase 2 also restarts Traefik daemonset to pick up Root CA
- **Severity**: LOW
- **Fix**: Add Traefik restart step to Phase 2 flowchart

---

## services-reference.md

### FINDING SR-01: Phase 1 deployment order table incomplete
- **Section**: Deployment Order table
- **Doc says**: Phase 1: "cert-manager, Node Labeler"
- **Actual**: Phase 1 includes: Traefik config, Gateway API CRDs, cert-manager, CNPG Operator, Cluster Autoscaler, OpsTree Redis Operator, Node Labeler, and conditionally MariaDB Operator
- **Severity**: HIGH
- **Fix**: Update Phase 1 row

### FINDING SR-02: Harbor proxy cache project names wrong
- **Section**: 6.11 (Proxy Cache Projects table)
- **Doc says**: dockerhub, quay, ghcr, gcr, k8s, elastic
- **Actual** (deploy-cluster.sh line 893): docker.io, quay.io, ghcr.io, gcr.io, registry.k8s.io, docker.elastic.co
- **Severity**: HIGH -- actual project names in Harbor use full domain names
- **Fix**: Update project names in table

### FINDING SR-03: Node Labeler replicas inconsistent (1 vs 3)
- **Section**: 13.1 (Architecture mermaid), 13.3 (Configuration table)
- **Doc says**: "1 replica" in mermaid diagram and configuration table
- **Resource budget table** (Section 2): Shows 3 replicas
- **Severity**: MEDIUM -- resource budget is correct (3), detail section is wrong
- **Fix**: Update Sections 13.1 and 13.3 to say 3 replicas

### FINDING SR-04: Storage Autoscaler replicas inconsistent (1 vs 3)
- **Section**: 14.1 (Architecture mermaid), 14.5 (Configuration table)
- **Doc says**: "1 replica" in mermaid diagram and configuration table
- **Resource budget table** (Section 2): Shows 3 replicas
- **Severity**: MEDIUM -- resource budget is correct (3), detail section is wrong
- **Fix**: Update Sections 14.1 and 14.5 to say 3 replicas

### FINDING SR-05: Uptime Kuma FQDN wrong in multiple locations
- **Section**: Appendix (All External Endpoints table), Section 4.11 (TLS table), Section 11.1 (Architecture mermaid)
- **Doc says**: `uptime.DOMAIN` in three places
- **Actual** (deploy-cluster.sh line 1211-1212, services/uptime-kuma/gateway.yaml): TLS secret is `status-${DOMAIN_DASHED}-tls`, FQDN is `status.DOMAIN`
- **Severity**: MEDIUM
- **Fix**: Change `uptime.DOMAIN` to `status.DOMAIN` in all three locations (Appendix endpoint table, TLS/Gateway table, architecture mermaid diagram)

### FINDING SR-06: OIDC Client table missing kasm and gitlab
- **Section**: 8.8 (OIDC Client Integrations table)
- **Doc table**: Lists 12 entries (Grafana, ArgoCD, Vault, Harbor, Mattermost, Prometheus, AlertManager, Hubble UI, Traefik Dashboard, Rollouts, Rancher, Kubernetes)
- **Actual**: 14 clients. Missing from table: kasm, gitlab
- **Severity**: MEDIUM
- **Fix**: Add kasm and gitlab rows

### FINDING SR-07: Missing GitLab service section
- **Section**: Table of Contents / entire document
- **Actual**: GitLab is deployed in Phase 11 (setup-gitlab.sh) but has no section in services-reference.md
- **Severity**: LOW -- GitLab is called out in deploy phases and dependency diagrams but lacks its own section
- **Fix**: Add a GitLab section (Section 15) -- out of scope for this review, noting only

### FINDING SR-08: Missing CNPG scheduled backups in service sections
- **Section**: Harbor (6), Keycloak (8), Mattermost (9), Kasm (10) storage/database sections
- **Actual**: deploy-cluster.sh applies scheduled backup manifests for all CNPG clusters (harbor-pg-scheduled-backup.yaml, keycloak-pg-scheduled-backup.yaml, mattermost-pg-scheduled-backup.yaml, kasm-pg-scheduled-backup.yaml)
- **Severity**: LOW -- backup CRs are applied but not documented in service sections
- **Fix**: Note scheduled backups in each service's database section

### FINDING SR-09: Missing oauth2-proxy Redis in monitoring section
- **Section**: Monitoring Stack (5)
- **Actual**: Phase 10 deploys oauth2-proxy with shared Redis session store for Prometheus, Alertmanager, Hubble, and Traefik Dashboard. Redis credentials are distributed to kube-system and argo-rollouts namespaces.
- **Severity**: LOW
- **Fix**: Note oauth2-proxy Redis in monitoring architecture

### FINDING SR-10: Node Labeler / Storage Autoscaler HA sections say "Single replica"
- **Section**: 13.9 (Node Labeler HA), 14.11 (Storage Autoscaler HA)
- **Doc says**: "Single replica with leader election"
- **Actual**: Resource budget shows 3 replicas each. With leader election, multiple replicas provide HA.
- **Severity**: MEDIUM
- **Fix**: Update to "3 replicas with leader election"

---

## Summary

| Severity | deployment-automation.md | services-reference.md | Total |
|----------|:-----------------------:|:---------------------:|:-----:|
| HIGH     | 8                       | 2                     | 10    |
| MEDIUM   | 3                       | 5                     | 8     |
| LOW      | 2                       | 3                     | 5     |
| **Total**| **13**                  | **10**                | **23**|

Critical issues: destroy-cluster.sh missing Phase 1 (K8S cleanup), setup-cicd.sh incorrectly described as GitLab (actually GitHub), OIDC client count (9 vs 14), group count (7 vs 8), distribute_root_ca namespace list (4 vs 8), many missing .env variables and CHANGEME tokens.

STATUS: COMPLETE
