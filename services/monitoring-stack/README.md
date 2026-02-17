# RKE2 Monitoring Stack

![Built with Claude Code](https://img.shields.io/badge/Built%20with-Claude%20Code-blueviolet?logo=anthropic&logoColor=white)
![Security Review](https://img.shields.io/badge/Security%20Review-Passed-brightgreen?logo=shieldsdotio&logoColor=white)
![Docker Hardened Images](https://img.shields.io/badge/Images-Docker%20Hardened%20(dhi.io)-blue?logo=docker&logoColor=white)

Production-grade monitoring and logging stack for RKE2 Kubernetes clusters running on Rancher/Harvester. Deploys Prometheus, Grafana, Loki, Alloy, Node Exporter, and kube-state-metrics into a single `monitoring` namespace via Kustomize. Includes Vault PKI and cert-manager for automatic TLS certificate management.

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

All container images use the `dhi.io/` Docker Hardened Images registry prefix.

---

## Components

| Component | Image | Kind | Replicas | CPU (req/lim) | Memory (req/lim) | Storage | Service Port(s) |
|---|---|---|---|---|---|---|---|
| Prometheus | `dhi.io/prometheus:v2.53.0` | StatefulSet | 1 | 500m / 2 | 2Gi / 4Gi | 50Gi PVC | 9090 |
| Grafana | `dhi.io/grafana:11.1.0` | Deployment | 1 | 500m / 1 | 512Mi / 1Gi | 10Gi PVC | 3000 |
| Loki | `dhi.io/loki:3.1.0` | StatefulSet | 1 | 250m / 1 | 512Mi / 2Gi | 50Gi PVC | 3100, 9096 (gRPC) |
| Alloy | `dhi.io/alloy:v1.3.0` | DaemonSet | all nodes | 100m / 500m | 128Mi / 512Mi | emptyDir | 12345 (headless) |
| Node Exporter | `dhi.io/node-exporter:v1.8.2` | DaemonSet | all nodes | 50m / 250m | 64Mi / 256Mi | none | 9100 (headless) |
| kube-state-metrics | `dhi.io/kube-state-metrics:v2.13.0` | Deployment | 1 | 100m / 500m | 256Mi / 512Mi | none | 8080, 8081 |

### PKI / TLS (Helm-managed, separate from Kustomize)

| Component | Chart | Namespace | Description |
|---|---|---|---|
| Vault | `hashicorp/vault` 0.32.0 | `vault` | Intermediate CA via PKI secrets engine (Root CA external), 3-replica HA Raft storage |
| cert-manager | `jetstack/cert-manager` v1.19.3 | `cert-manager` | Automatic certificate issuance via ClusterIssuer `vault-issuer` |

---

## Architecture

### Data Flow Diagram

```
                         +--------------+
                         |   Grafana    |
                         |   :3000      |
                         +---+----+-----+
                             |    |
                   query     |    |   query
                 (PromQL)    |    |  (LogQL)
                             v    v
                    +---------+  +-------+
                    |Prometheus|  | Loki  |
                    |  :9090   |  | :3100 |
                    +----+-----+  +---+---+
                         |            ^
              scrape     |            |  push (HTTP)
        +--------+-------+-------+   |
        |        |       |       |   |
        v        v       v       v   |
   +--------+ +-----+ +-----+ +-----+----+
   | Node   | | KSM | |kube | | Alloy    |
   |Exporter| |:8080| |api/ | | :12345   |
   | :9100  | |     | |etcd | | (per     |
   |(per    | +-----+ |/etc | |  node)   |
   | node)  |         +-----+ +----------+
   +--------+
```

### Network Flow

```
EXTERNAL TRAFFIC (all HTTPS, TLS terminated by Traefik)
=======================================================
User Browser
  --> Grafana:    Gateway (traefik, port 8443) -> HTTPRoute -> grafana.monitoring.svc:3000
  --> Prometheus: Gateway (traefik, port 8443) -> HTTPRoute -> prometheus.monitoring.svc:9090
  --> Hubble UI:  Gateway (traefik, port 8443) -> HTTPRoute -> hubble-ui.kube-system.svc:80
  --> Traefik:    IngressRoute (websecure)     -> api@internal (exception: api@internal backend)

TLS CERTIFICATE FLOW
====================
Vault PKI (Root CA -> Intermediate CA)
  <-- cert-manager requests signing via pki_int/sign/<DOMAIN_DOT>
    --> Grafana:    auto-cert via Gateway annotation (gateway-shim)
    --> Prometheus: auto-cert via Gateway annotation (gateway-shim)
    --> Hubble UI:  auto-cert via Gateway annotation (gateway-shim)
    --> Traefik:    explicit Certificate resource

METRICS FLOW (pull-based)
=========================
prometheus.monitoring.svc:9090
  --> node-exporter.monitoring.svc:9100       (every node, hostNetwork)
  --> kube-state-metrics.monitoring.svc:8080  (cluster state)
  --> kubernetes.default.svc:443              (API server metrics)
  --> 203.0.113.{47,14,24}:2379                (etcd, mTLS)
  --> 203.0.113.{47,14,24}:10259              (kube-scheduler)
  --> 203.0.113.{47,14,24}:10257              (kube-controller-manager)
  --> kubelet :10250                          (per-node, /metrics + /metrics/cadvisor)
  --> cilium-agent :9962                      (per-node, pod SD in kube-system)
  --> rke2-coredns-rke2-coredns :9153         (kube-system)
  --> annotation-discovered pods/services     (prometheus.io/scrape: "true")

LOG FLOW (push-based)
=====================
alloy (per node, DaemonSet)
  --> reads: /var/log (pod logs via K8s API)
  --> reads: /var/log/journal (rke2-server.service, rke2-agent.service)
  --> reads: Kubernetes events (cluster-wide)
  --> pushes to: loki.monitoring.svc:3100/loki/api/v1/push

QUERY FLOW
==========
grafana.monitoring.svc:3000
  --> prometheus.monitoring.svc:9090  (PromQL, datasource uid: "prometheus")
  --> loki.monitoring.svc:3100        (LogQL, datasource uid: "loki")
```

### Logic Flow (Deployment Sequence)

```
1. Namespace        monitoring namespace created
        |
        v
2. RBAC             ServiceAccounts + ClusterRoles + ClusterRoleBindings
   (all components)     for prometheus, alloy, kube-state-metrics,
        |               node-exporter, loki
        v
3. ConfigMaps       prometheus-config (scrape jobs)
   & Secrets        loki-config (TSDB + retention)
                    alloy-config (River pipeline)
                    grafana-datasources
                    grafana-dashboard-provider
                    grafana-dashboard-* (7 dashboards)
                    grafana-admin-secret (admin password)
        |
        v
4. PVCs             prometheus data-prometheus-0 (50Gi)
                    loki data-loki-0 (50Gi)
                    grafana-data (10Gi)
        |
        v
5. Workloads        StatefulSet: prometheus, loki
                    Deployment:  grafana, kube-state-metrics
                    DaemonSet:   node-exporter, alloy
        |
        v
6. Services         ClusterIP: prometheus, loki, grafana,
                               kube-state-metrics
                    Headless:   node-exporter, alloy
        |
        v
7. Ingress          Gateway (traefik, HTTPS port 8443, TLS via cert-manager)
                    HTTPRoute -> Gateway -> Grafana
                    HTTPRoute -> Gateway -> Prometheus (oauth2-proxy ForwardAuth, monitoring)
                    HTTPRoute -> Gateway -> AlertManager (oauth2-proxy ForwardAuth, monitoring)
                    HTTPRoute -> Gateway -> Hubble UI (oauth2-proxy ForwardAuth, kube-system)
                    HTTPRoute -> Gateway -> Traefik Dashboard (oauth2-proxy ForwardAuth, kube-system)
```

See [Project Structure](#project-structure) for the full file tree.

---

## TLS Endpoints

All external services are served over HTTPS via Traefik (LB IP: `203.0.113.202`). Certificates are signed by the Example Org Intermediate CA (Vault PKI) and auto-renewed by cert-manager.

| Service | URL | Namespace | Ingress Type | Certificate Secret | Auth |
|---|---|---|---|---|---|
| Grafana | `https://grafana.<DOMAIN>` | monitoring | Gateway + HTTPRoute | `grafana-<DOMAIN_DASHED>-tls` (auto via gateway-shim) | Grafana login |
| Prometheus | `https://prometheus.<DOMAIN>` | monitoring | Gateway + HTTPRoute | `prometheus-<DOMAIN_DASHED>-tls` (auto via gateway-shim) | oauth2-proxy ForwardAuth (platform-admins, infra-engineers) |
| AlertManager | `https://alertmanager.<DOMAIN>` | monitoring | Gateway + HTTPRoute | `alertmanager-<DOMAIN_DASHED>-tls` (auto via gateway-shim) | oauth2-proxy ForwardAuth (platform-admins, infra-engineers) |
| Hubble UI | `https://hubble.<DOMAIN>` | kube-system | Gateway + HTTPRoute | `hubble-<DOMAIN_DASHED>-tls` (auto via gateway-shim) | oauth2-proxy ForwardAuth (platform-admins, infra-engineers, network-engineers) |
| Traefik Dashboard | `https://traefik.<DOMAIN>` | kube-system | Gateway + HTTPRoute | `traefik-<DOMAIN_DASHED>-tls` (explicit Certificate) | oauth2-proxy ForwardAuth (platform-admins, network-engineers) |
| Vault | `https://vault.<DOMAIN>` | vault | Gateway + HTTPRoute | `vault-<DOMAIN_DASHED>-tls` (auto via gateway-shim) | Vault login |

### PKI Chain

```
Example Org Root CA (External, 15yr TTL, key offline on Harvester)
  +-- Example Org Intermediate CA (Vault pki_int/, 10yr TTL)
        +-- *.<DOMAIN> leaf certificates (720h max TTL, auto-renewed)
```

To trust these certificates in a browser, import the Root CA into your system trust store:

```bash
# Root CA is stored locally (not in Vault) — copy from cluster/ directory
cp cluster/root-ca.pem aegis-group-root-ca.crt

# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain aegis-group-root-ca.crt
```

See [docs/tls-integration-guide.md](docs/tls-integration-guide.md) for developer instructions on adding TLS to new services. For the full platform TLS chain and certificate inventory, see [docs/security.md](../../docs/security.md).

---

## Environment Variables

### Grafana

| Variable | Value | Source | Description |
|---|---|---|---|
| `GF_SECURITY_ADMIN_USER` | `admin` | Literal | Grafana admin username |
| `GF_SECURITY_ADMIN_PASSWORD` | (secret) | `grafana-admin-secret` key `admin-password` | Grafana admin password |
| `GF_PATHS_PROVISIONING` | `/etc/grafana/provisioning` | Literal | Provisioning config path |

### Alloy

| Variable | Value | Source | Description |
|---|---|---|---|
| `HOSTNAME` | (node name) | `fieldRef: spec.nodeName` | Used to filter pod logs to local node only |

### Prometheus

No environment variables. Configured entirely via CLI args and `prometheus.yml` ConfigMap.

### Loki

No environment variables. Configured via CLI args and `loki.yaml` ConfigMap.

### Node Exporter

No environment variables. Configured via CLI args.

### kube-state-metrics

No environment variables. Uses default configuration.

---

## Prometheus Scrape Jobs

| # | Job Name | Target | Discovery | Protocol | Auth |
|---|---|---|---|---|---|
| 1 | `prometheus` | localhost:9090 | static | HTTP | none |
| 2 | `kubernetes-apiservers` | API server endpoints | endpoints SD | HTTPS | ServiceAccount token |
| 3 | `kubelet` | node :10250 | node SD | HTTPS | ServiceAccount token |
| 4 | `cadvisor` | node :10250/metrics/cadvisor | node SD | HTTPS | ServiceAccount token |
| 5 | `etcd` | 203.0.113.{47,14,24}:2379 | static | HTTPS | mTLS (etcd-certs) |
| 6 | `cilium-agent` | cilium pods :9962 | pod SD (kube-system) | HTTP | none |
| 7 | `coredns` | rke2-coredns endpoints | endpoints SD (kube-system) | HTTP | none |
| 8 | `kube-scheduler` | 203.0.113.{47,14,24}:10259 | static | HTTPS | ServiceAccount token |
| 9 | `kube-controller-manager` | 203.0.113.{47,14,24}:10257 | static | HTTPS | ServiceAccount token |
| 10 | `node-exporter` | node-exporter endpoints | endpoints SD | HTTP | none |
| 11 | `kube-state-metrics` | kube-state-metrics :8080 | endpoints SD | HTTP | none |
| 12 | `kubernetes-service-endpoints` | annotated services | endpoints SD | varies | none |
| 13 | `kubernetes-pods` | annotated pods | pod SD | varies | none |

---

## Alloy Log Pipelines

| Pipeline | Source | Labels Added | Filter |
|---|---|---|---|
| Pod logs | `loki.source.kubernetes` via K8s SD | `namespace`, `pod`, `container`, `node`, `app` | Same-node only (`HOSTNAME` match) |
| Kubernetes events | `loki.source.kubernetes_events` | (logfmt event fields) | All cluster events |
| Journal logs | `loki.source.journal` at `/var/log/journal` | `unit`, `node` | `rke2-server.service` OR `rke2-agent.service` |

All pipelines push to `loki.monitoring.svc:3100/loki/api/v1/push` with external label `cluster=rke2-production`.

---

## Prerequisites

### RKE2 Server Configuration

The following RKE2 control-plane components must bind their metrics endpoints to `0.0.0.0` (they default to `127.0.0.1`). Add to `/etc/rancher/rke2/config.yaml` on each **server** node:

```yaml
kube-scheduler-arg:
  - "bind-address=0.0.0.0"
kube-controller-manager-arg:
  - "bind-address=0.0.0.0"
```

Restart RKE2 after changing:

```bash
sudo systemctl restart rke2-server
```

### Secrets

**Grafana admin password** is managed in `grafana/secret-admin.yaml`. Edit the `admin-password` value before deploying:

```yaml
stringData:
  admin-password: "your-strong-password-here"
```

**etcd TLS certificates** (for etcd scrape job) must be created manually before deploying. Copy certs from an RKE2 server node:

```bash
scp rocky@203.0.113.47:/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt /tmp/
scp rocky@203.0.113.47:/var/lib/rancher/rke2/server/tls/etcd/client.crt /tmp/
scp rocky@203.0.113.47:/var/lib/rancher/rke2/server/tls/etcd/client.key /tmp/

kubectl -n monitoring create secret generic etcd-certs \
  --from-file=server-ca.crt=/tmp/server-ca.crt \
  --from-file=client.crt=/tmp/client.crt \
  --from-file=client.key=/tmp/client.key
```

> The `etcd-certs` secret is marked `optional: true` in the Prometheus StatefulSet. If not created, Prometheus will start but the etcd scrape job will fail.
>
> Note: The cert files are root-owned on the server node. Use `sudo cat` over SSH if `scp` fails with permission errors.

---

## Configuration

The following values are configured for the current cluster and may need updating for different environments:

| Value | File | Current Setting |
|---|---|---|
| Control plane IPs | `prometheus/configmap.yaml` | `203.0.113.47`, `203.0.113.14`, `203.0.113.24` (etcd, kube-scheduler, kube-controller-manager targets) |
| Gateway ref | `grafana/httproute.yaml` | `name: monitoring`, `namespace: monitoring` |
| Gateway class | `grafana/gateway.yaml` | `gatewayClassName: traefik`, HTTPS port 8443 (Traefik internal; exposed as 443) |
| TLS issuer | `grafana/gateway.yaml` | `cert-manager.io/cluster-issuer: vault-issuer` |
| Vault address | `cert-manager/cluster-issuer.yaml` | `http://vault.vault.svc.cluster.local:8200` |
| Grafana admin password | `grafana/secret-admin.yaml` | `CHANGEME_GRAFANA_ADMIN_PASSWORD` (must change before deploying) |
| Node selector | All StatefulSets/Deployments | `workload-type: general` |

---

## Deployment

### Phase 1: Install cert-manager (Helm)

```bash
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --version v1.19.3 \
  --set crds.enabled=true \
  --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
  --set config.kind=ControllerConfiguration \
  --set config.enableGatewayAPI=true \
  --set nodeSelector.workload-type=general \
  --set webhook.nodeSelector.workload-type=general \
  --set cainjector.nodeSelector.workload-type=general

# Verify pods running and gateway-shim enabled
kubectl get pods -n cert-manager
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager | grep gateway
# Should see: "enabling the sig-network Gateway API certificate-shim"
```

> **Note:** cert-manager v1.15+ replaced the `ExperimentalGatewayAPISupport` feature gate with the `enableGatewayAPI` controller config. Using the old feature gate will silently skip the gateway-shim controller.

### Phase 2: Install Vault (Helm)

```bash
helm install vault hashicorp/vault \
  -n vault --create-namespace \
  -f vault/vault-values.yaml

# Wait for vault-0 to be running (0/1 Ready is expected — it's uninitialized)
kubectl -n vault get pods

# Initialize Vault
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 \
  -format=json > vault-init.json

# IMPORTANT: Save vault-init.json securely — it contains unseal keys and root token

# Unseal with 3 of the 5 keys
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>

# Verify: Sealed = false
kubectl exec -n vault vault-0 -- vault status
```

### Phase 3: Configure Vault PKI

The Root CA is generated **externally** via openssl (key never enters Vault). Only the Intermediate CA key lives in Vault.

```bash
# Set root token for the session
export VAULT_TOKEN=$(jq -r '.root_token' vault-init.json)

# --- Root CA (local openssl, from cluster/ directory) ---
# Generate Root CA key + cert (15 years, 4096-bit RSA)
openssl genrsa -out root-ca-key.pem 4096
openssl req -x509 -new -nodes \
  -key root-ca-key.pem -sha256 -days 5475 \
  -subj "/CN=Example Org Root CA" -out root-ca.pem
chmod 600 root-ca-key.pem && chmod 644 root-ca.pem

# --- Intermediate CA (key in Vault, CSR signed locally) ---
kubectl exec -n vault vault-0 -- vault secrets enable -path=pki_int pki
kubectl exec -n vault vault-0 -- vault secrets tune -max-lease-ttl=87600h pki_int

# Generate CSR inside Vault (key never leaves Vault)
kubectl exec -n vault vault-0 -- vault write -field=csr pki_int/intermediate/generate/internal \
  common_name="Example Org Intermediate CA" ttl=87600h key_bits=4096 > intermediate.csr

# Sign the CSR LOCALLY with Root CA key
openssl x509 -req -in intermediate.csr \
  -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -days 3650 -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always") \
  -out intermediate.crt

# Import full chain (intermediate + root) into Vault
cat intermediate.crt root-ca.pem > intermediate-chain.crt
kubectl cp intermediate-chain.crt vault/vault-0:/tmp/intermediate-chain.crt
kubectl exec -n vault vault-0 -- vault write pki_int/intermediate/set-signed certificate=@/tmp/intermediate-chain.crt

# Create PKI role (require_cn=false is needed for cert-manager's SAN-only CSRs)
kubectl exec -n vault vault-0 -- vault write pki_int/roles/<DOMAIN_DOT> \
  allowed_domains=<DOMAIN> allow_subdomains=true max_ttl=720h require_cn=false

# Create policy for cert-manager
kubectl exec -n vault vault-0 -- sh -c 'vault policy write pki-policy - <<EOF
path "pki_int/sign/<DOMAIN_DOT>" {
  capabilities = ["create", "update"]
}
path "pki_int/cert/ca" {
  capabilities = ["read"]
}
EOF'

# Enable Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes
kubectl exec -n vault vault-0 -- sh -c 'vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/cert-manager-issuer \
  bound_service_account_names=vault-issuer \
  bound_service_account_namespaces=cert-manager \
  policies=pki-policy \
  ttl=1h

# Back up Root CA to Harvester
./terraform.sh push-secrets
```

> **Note**: There is NO `pki/` mount in Vault. The Root CA private key stays on the local machine and Harvester only. It never enters the RKE2 cluster or Vault.

### Phase 4: Deploy Monitoring Stack + cert-manager Integration

```bash
kubectl apply -k .
```

This deploys the full monitoring stack including cert-manager RBAC, ClusterIssuer, Certificates, IngressRoutes, and kube-system resources.

To preview generated manifests before applying:

```bash
kubectl kustomize .
```

### Phase 5: Verify TLS

```bash
# ClusterIssuer should be Ready
kubectl get clusterissuers vault-issuer

# Check Gateway resources
kubectl get gateways -A
kubectl get httproutes -A

# Test HTTPS on all services
echo | openssl s_client -connect 203.0.113.202:443 -servername grafana.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
echo | openssl s_client -connect 203.0.113.202:443 -servername prometheus.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
echo | openssl s_client -connect 203.0.113.202:443 -servername hubble.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
echo | openssl s_client -connect 203.0.113.202:443 -servername traefik.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
# All should show: issuer=CN=Example Org Intermediate CA
```

### Resource Count

The stack creates **55 Kubernetes resources** across **46 YAML files**:

- 1 Namespace
- 6 ServiceAccounts (including `vault-issuer` in cert-manager)
- 3 ClusterRoles
- 3 ClusterRoleBindings
- 1 Role, 1 RoleBinding (cert-manager token creator)
- 10 ConfigMaps
- 1 Secret (Grafana admin) + oauth2-proxy secrets (created at deploy time)
- 1 PVC (Grafana) + 2 VolumeClaimTemplates (Prometheus, Loki)
- 2 StatefulSets, 2 Deployments, 2 DaemonSets
- 6 Services
- 2 Gateways (monitoring + kube-system namespaces, HTTPS with cert-manager annotations)
- 4 HTTPRoutes (Grafana, Prometheus, AlertManager, Hubble UI, Traefik Dashboard)
- 4 oauth2-proxy Deployments + Services (Prometheus, AlertManager, Hubble, Traefik Dashboard)
- 4 Middlewares (oauth2-proxy ForwardAuth in monitoring + kube-system)
- 1 ClusterIssuer (`vault-issuer`)
- 4 Certificates (3 auto via gateway-shim: Grafana, Prometheus, Hubble; 1 explicit: Traefik dashboard)

---

## Dashboards

24 dashboards are provisioned as ConfigMaps across 6 Grafana folders:

| Folder | Dashboard | UID | ConfigMap | Datasource |
|---|---|---|---|---|
| **Home** | Cluster Home | `home-overview` | `grafana-dashboard-home` | Prometheus |
| **Home** | Firing Alerts | `firing-alerts` | `grafana-dashboard-firing-alerts` | Prometheus |
| **Platform** | etcd | `etcd-dashboard` | `grafana-dashboard-etcd` | Prometheus |
| **Platform** | Control Plane | `apiserver-performance` | `grafana-dashboard-apiserver` | Prometheus |
| **Platform** | Node Deep Dive | `node-deep-dive` | `grafana-dashboard-node-detail` | Prometheus |
| **Platform** | Storage & PV Usage | `k8s-pv-usage` | `grafana-dashboard-storage` | Prometheus |
| **Platform** | Node Labeler | `node-labeler` | `grafana-dashboard-node-labeler` | Prometheus |
| **Networking** | Traefik GatewayAPI | `traefik-ingress-controller` | `grafana-dashboard-traefik` | Prometheus |
| **Networking** | CoreDNS | `coredns-dashboard` | `grafana-dashboard-coredns` | Prometheus |
| **Networking** | Cilium CNI Overview | `cilium-cni-overview` | `grafana-dashboard-cilium` | Prometheus |
| **Services** | Vault Cluster Overview | `vault-cluster-overview` | `grafana-dashboard-vault` | Prometheus |
| **Services** | GitLab Overview | `gitlab-overview` | `grafana-dashboard-gitlab` | Prometheus + Loki |
| **Services** | CloudNativePG Cluster | `cnpg-cluster` | `grafana-dashboard-cnpg` | Prometheus |
| **Services** | Harbor Registry Overview | `harbor-overview` | `grafana-dashboard-harbor` | Prometheus |
| **Services** | Mattermost Overview | `mattermost-overview` | `grafana-dashboard-mattermost` | Prometheus + Loki |
| **Services** | ArgoCD Overview | `argocd-overview` | `grafana-dashboard-argocd` | Prometheus |
| **Services** | Argo Rollouts Overview | `argo-rollouts-overview` | `grafana-dashboard-argo-rollouts` | Prometheus |
| **Services** | Redis Overview | `redis-overview` | `grafana-dashboard-redis` | Prometheus |
| **Security** | Keycloak IAM Overview | `keycloak-overview` | `grafana-dashboard-keycloak` | Prometheus |
| **Security** | cert-manager Certificates | `cert-manager-certificates` | `grafana-dashboard-cert-manager` | Prometheus |
| **Security** | Security Operations | `security-advanced` | `grafana-dashboard-security-advanced` | Prometheus + Loki |
| **Security** | oauth2-proxy ForwardAuth | `oauth2-proxy-overview` | `grafana-dashboard-oauth2-proxy` | Prometheus + Loki |
| **Observability** | Loki Stack Monitoring | `loki-stack-monitoring` | `grafana-dashboard-loki-stack` | Prometheus + Loki |
| **Observability** | Log Explorer | `loki-logs` | `grafana-dashboard-loki` | Loki |

Every detail dashboard links back to Cluster Home. Service tiles on the Home dashboard link to their respective detail dashboards.

For a comprehensive reference of every panel and metric in each dashboard, see [grafana/DASHBOARDS.md](grafana/DASHBOARDS.md).

---

## Loki Configuration

| Parameter | Value |
|---|---|
| Mode | Monolithic (`-target=all`) |
| Schema | v13 (TSDB) |
| Storage backend | Filesystem (`/loki/chunks`) |
| Retention | Enabled via compactor (`reject_old_samples_max_age: 168h`) |
| Ingestion rate limit | 20 MB/s (burst: 40 MB/s) |
| Max streams per user | 50,000 |
| Max entries per query | 10,000 |
| Embedded cache | 100 MB (chunk + results) |
| Auth | Disabled (`auth_enabled: false`) |
| Analytics | Disabled |

---

## Prometheus Configuration

| Parameter | Value |
|---|---|
| Scrape interval | 30s |
| Evaluation interval | 30s |
| Scrape timeout | 10s |
| Retention (time) | 30d |
| Retention (size) | 80GB |
| Storage path | `/prometheus` |
| Web lifecycle | Enabled (`--web.enable-lifecycle`) |

---

## Verification

After deploying, verify the stack is healthy:

```bash
# All pods running
kubectl -n monitoring get pods

# Prometheus targets (from a node or via port-forward)
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# Visit http://localhost:9090/targets - all 13 jobs should show UP

# Grafana accessible
kubectl -n monitoring port-forward svc/grafana 3000:3000
# Visit http://localhost:3000 - log in with admin / <your password>
# Check all 7 dashboards in the RKE2, Kubernetes, and Loki folders

# Loki receiving logs
kubectl -n monitoring port-forward svc/loki 3100:3100
# curl http://localhost:3100/ready  --> "ready"
# curl http://localhost:3100/loki/api/v1/labels  --> should return label names

# Node Exporter running on every node
kubectl -n monitoring get ds node-exporter
# DESIRED = CURRENT = READY

# Alloy running on every node
kubectl -n monitoring get ds alloy
# DESIRED = CURRENT = READY

# kube-state-metrics healthy
kubectl -n monitoring get deploy kube-state-metrics
# READY 1/1

# Vault unsealed
kubectl exec -n vault vault-0 -- vault status
# Sealed = false

# ClusterIssuer ready
kubectl get clusterissuers vault-issuer
# READY = True

# All 4 TLS certificates issued
kubectl get certificates -A
# grafana-<DOMAIN_DASHED>-tls      (monitoring)   = True
# prometheus-<DOMAIN_DASHED>-tls   (monitoring)   = True
# hubble-<DOMAIN_DASHED>-tls       (kube-system)  = True
# traefik-<DOMAIN_DASHED>-tls      (kube-system)  = True

# HTTPS working on all services (via Traefik LB 203.0.113.202)
echo | openssl s_client -connect 203.0.113.202:443 -servername grafana.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
echo | openssl s_client -connect 203.0.113.202:443 -servername prometheus.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
echo | openssl s_client -connect 203.0.113.202:443 -servername hubble.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
echo | openssl s_client -connect 203.0.113.202:443 -servername traefik.<DOMAIN> 2>/dev/null | openssl x509 -noout -issuer
# All should show: issuer=CN=Example Org Intermediate CA
```

---

## Security Context Summary

| Component | runAsUser | runAsGroup | fsGroup | hostNetwork | hostPID | readOnlyRootFilesystem |
|---|---|---|---|---|---|---|
| Prometheus | 65534 | 65534 | 65534 | no | no | no |
| Grafana | 472 | 472 | 472 | no | no | no |
| Loki | 10001 | 10001 | 10001 | no | no | no |
| Alloy | - | - | - | no | no | no |
| Node Exporter | - | - | - | **yes** | **yes** | **yes** |
| kube-state-metrics | 65534 | - | - | no | no | **yes** |

---

## Project Structure

```
monitoring-stack/
+-- kustomization.yaml
+-- namespace.yaml
+-- README.md                          (this file)
|
+-- prometheus/
|   +-- rbac.yaml
|   +-- configmap.yaml                 (scrape configs + alert rules)
|   +-- statefulset.yaml
|   +-- service.yaml
|   +-- oauth2-proxy.yaml              (oauth2-proxy Deployment + Service)
|   +-- middleware-oauth2-proxy.yaml    (Traefik ForwardAuth middleware)
|   +-- gateway.yaml                   (Gateway, HTTPS + cert-manager annotation)
|   +-- httproute.yaml                 (HTTPRoute with /oauth2 callback + ForwardAuth)
|
+-- grafana/
|   +-- pvc.yaml
|   +-- configmap-datasources.yaml     (Prometheus + Loki datasource configs)
|   +-- configmap-dashboard-provider.yaml  (6 folder providers: Home, Platform, Networking, Services, Security, Observability)
|   +-- configmap-dashboard-*.yaml     (24 dashboard ConfigMaps — see Dashboards section above)
|   +-- DASHBOARDS.md                  (comprehensive per-panel metric reference)
|   +-- secret-admin.yaml             (Grafana admin password)
|   +-- deployment.yaml               (Grafana Deployment with all dashboard volume mounts)
|   +-- service.yaml
|   +-- gateway.yaml                   (Gateway, HTTPS + cert-manager annotation)
|   +-- httproute.yaml                 (HTTPRoute -> HTTPS listener)
|
+-- alertmanager/
|   +-- configmap.yaml                 (routing + receivers)
|   +-- statefulset.yaml
|   +-- service.yaml
|   +-- oauth2-proxy.yaml
|   +-- middleware-oauth2-proxy.yaml
|   +-- gateway.yaml
|   +-- httproute.yaml
|
+-- loki/
|   +-- rbac.yaml
|   +-- configmap.yaml                 (TSDB schema, retention, ingestion limits)
|   +-- statefulset.yaml
|   +-- service.yaml
|
+-- alloy/
|   +-- rbac.yaml
|   +-- configmap.yaml                 (River pipeline: pod logs, journal, events)
|   +-- daemonset.yaml
|   +-- service.yaml
|
+-- node-exporter/
|   +-- rbac.yaml
|   +-- daemonset.yaml
|   +-- service.yaml
|
+-- kube-state-metrics/
|   +-- rbac.yaml
|   +-- deployment.yaml
|   +-- service.yaml
|
+-- oauth2-proxy-redis/
|   +-- secret.yaml                    (Redis auth)
|   +-- replication.yaml               (Redis replication config)
|   +-- sentinel.yaml                  (Redis Sentinel HA)
|
+-- kube-system/
|   +-- oauth2-proxy-hubble.yaml
|   +-- middleware-oauth2-proxy-hubble.yaml
|   +-- oauth2-proxy-traefik-dashboard.yaml
|   +-- middleware-oauth2-proxy-traefik-dashboard.yaml
|   +-- traefik-default-tlsstore.yaml
|   +-- hubble-gateway.yaml
|   +-- hubble-httproute.yaml
|   +-- traefik-dashboard-certificate.yaml
|   +-- traefik-dashboard-ingressroute.yaml
```
