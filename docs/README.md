# Documentation Index

Master index for all RKE2 cluster platform documentation. The `engineering/` directory contains deep, source-verified technical references. Standalone docs capture design records, planning documents, and user guides.

> **Note**: Throughout these documents, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env`. Derived formats: `<DOMAIN_DASHED>` (dots → hyphens),
> `<DOMAIN_DOT>` (dots → `-dot-`). All service FQDNs follow `<service>.<DOMAIN>`.

---

## Engineering References

Comprehensive, source-verified documentation derived from the actual codebase. Updated 2026-02-15.

| Document | Lines | Description |
|----------|------:|-------------|
| [System Architecture](engineering/system-architecture.md) | ~1,400 | Infrastructure topology, networking (Cilium CNI, L2, dual-NIC), cluster topology (4 node pools), storage architecture, and service overview |
| [Terraform Infrastructure](engineering/terraform-infrastructure.md) | ~1,700 | Deep dive into all Terraform resources, 54 variables, cloud-init templates, `terraform.sh` wrapper, and state management |
| [Deployment Automation](engineering/deployment-automation.md) | ~1,600 | All deployment scripts (`deploy-cluster.sh`, `destroy-cluster.sh`, `setup-keycloak.sh`, `setup-cicd.sh`, `upgrade-cluster.sh`), 12-phase deployment sequence (0-11), `lib.sh` function reference |
| [Services Reference](engineering/services-reference.md) | ~2,000 | All 14+ Kubernetes services: architecture, resources, networking, storage, security contexts, HA design, monitoring integration |
| [Monitoring & Observability](engineering/monitoring-observability.md) | ~900 | Monitoring stack deep dive: Prometheus scrape jobs, Grafana dashboards, Loki log pipeline, Alloy collection, Alertmanager routing, TLS integration |
| [Security Architecture](engineering/security-architecture.md) | ~950 | PKI architecture (Root CA → Intermediate → leaf), Vault HA, cert-manager, Keycloak OIDC (14 clients), RBAC, secrets management, network security, container hardening |
| [Custom Operators](engineering/custom-operators.md) | ~1,100 | Two Kubebuilder operators: node-labeler (harvester-pool labels from machine annotations) and storage-autoscaler (PVC expansion via VolumeAutoscaler CRD) |
| [Golden Image & CI/CD](engineering/golden-image-cicd.md) | ~1,550 | Golden image build pipeline (Packer + Terraform), CI/CD architecture (GitLab CI + ArgoCD app-of-apps), Harbor integration |
| [Flow Charts](engineering/flow-charts.md) | ~1,350 | 23+ Mermaid diagrams covering deployment phases, operational flows, controller reconciliation loops, decision trees, and network/TLS flows |
| [Troubleshooting SOP](engineering/troubleshooting-sop.md) | ~3,400+ | Standard Operating Procedures: diagnostic flowcharts, cluster issues, networking, TLS, Vault, databases, all services, storage, deployment scripts, Day-2 operations, disaster recovery |

**Total**: ~15,900+ lines of engineering documentation across 10 documents.

---

## Cross-Reference Matrix

Find what you need by topic:

| Topic | Primary Document | Also See |
|-------|-----------------|----------|
| **Cluster provisioning** | [Terraform Infrastructure](engineering/terraform-infrastructure.md) | [System Architecture](engineering/system-architecture.md), [Flow Charts](engineering/flow-charts.md) |
| **Service deployment** | [Deployment Automation](engineering/deployment-automation.md) | [Flow Charts](engineering/flow-charts.md), [Services Reference](engineering/services-reference.md) |
| **Adding/modifying a service** | [Services Reference](engineering/services-reference.md) | [Deployment Automation](engineering/deployment-automation.md) |
| **TLS / certificates** | [Security Architecture](engineering/security-architecture.md) | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 4) |
| **Vault (unseal, PKI, auth)** | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 5) | [Security Architecture](engineering/security-architecture.md) |
| **Keycloak / OIDC / SSO** | [Security Architecture](engineering/security-architecture.md) | [Deployment Automation](engineering/deployment-automation.md), [kubectl OIDC Setup](kubectl-oidc-setup.md) |
| **Monitoring / alerting** | [Monitoring & Observability](engineering/monitoring-observability.md) | [Services Reference](engineering/services-reference.md) |
| **Networking (Cilium, Traefik)** | [System Architecture](engineering/system-architecture.md) | [Flow Charts](engineering/flow-charts.md), [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 3) |
| **Database issues (CNPG)** | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 6) | [Services Reference](engineering/services-reference.md) |
| **Custom operators** | [Custom Operators](engineering/custom-operators.md) | [Golden Image & CI/CD](engineering/golden-image-cicd.md) |
| **CI/CD pipeline** | [Deployment Automation](engineering/deployment-automation.md) | [Golden Image & CI/CD](engineering/golden-image-cicd.md) |
| **Cluster upgrade** | [Deployment Automation](engineering/deployment-automation.md) | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 9.5) |
| **Backup / restore** | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 11) | [Terraform Infrastructure](engineering/terraform-infrastructure.md) |
| **Day-2 operations** | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 11) | [Deployment Automation](engineering/deployment-automation.md) |
| **Disaster recovery** | [Troubleshooting SOP](engineering/troubleshooting-sop.md) (Section 10) | [Flow Charts](engineering/flow-charts.md) |
| **Golden image pipeline** | [Golden Image & CI/CD](engineering/golden-image-cicd.md) | [Terraform Infrastructure](engineering/terraform-infrastructure.md) |

---

## User Guides

| Document | Description |
|----------|-------------|
| [kubectl OIDC Setup](kubectl-oidc-setup.md) | End-user guide: install kubelogin, import Root CA, configure kubeconfig for Keycloak OIDC authentication |

---

## Design Records & Planning

Standalone documents capturing architectural decisions, migration plans, and issue tracking. These are **not** superseded by the engineering references — they serve as historical design records.

| Document | Description | Status |
|----------|-------------|--------|
| [Airgapped Deployment Mode](airgapped-mode.md) | Air-gapped / offline cluster deployment with local registries, OCI helm charts, and private repo mirrors | Implemented |
| [Golden Image Plan](golden-image-plan.md) | Pre-baked Rocky 9 VM image for faster node provisioning — design and implementation plan | Implemented |
| [Vault HA Migration](vault-ha.md) | Migration from single Vault to 3-node HA Raft cluster | Implemented |
| [Vault Credential Storage](vault-credential-storage.md) | Migration plan: move K8s Secrets to Vault KV v2 + External Secrets Operator | Planning |
| [Public Repo Plan](public-repo-plan.md) | Plan to create a public reference repo with sanitized examples | Planning |
| [Keycloak User Management Strategy](keycloak-user-management-strategy.md) | Strategy for Keycloak user and group management across the platform | Design doc |
| [Rancher Autoscaler Labels Issue](rancher-autoscaler-labels-issue.md) | Issue tracker: autoscaler-provisioned nodes missing machine pool labels | Issue |

---

## Document Lifecycle

The following legacy docs have been consolidated into the engineering references and replaced with redirect notices:

| Old Document | Replaced By |
|-------------|-------------|
| `architecture.md` | [engineering/system-architecture.md](engineering/system-architecture.md) |
| `deployment-flow.md` | [engineering/flow-charts.md](engineering/flow-charts.md) |
| `data-flow.md` | [engineering/flow-charts.md](engineering/flow-charts.md) |
| `decision-tree.md` | [engineering/flow-charts.md](engineering/flow-charts.md) |
| `network-flow.md` | [engineering/system-architecture.md](engineering/system-architecture.md) |
| `service-architecture.md` | [engineering/services-reference.md](engineering/services-reference.md) |
| `troubleshooting.md` | [engineering/troubleshooting-sop.md](engineering/troubleshooting-sop.md) |
| `security.md` | [engineering/security-architecture.md](engineering/security-architecture.md) |
| `operations-runbook.md` | [engineering/troubleshooting-sop.md](engineering/troubleshooting-sop.md) |
| `cicd-architecture.md` | [engineering/deployment-automation.md](engineering/deployment-automation.md) |
