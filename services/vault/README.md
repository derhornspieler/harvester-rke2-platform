# Vault HA — High-Availability Encryption & PKI

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

## Overview

This directory contains the Vault HA deployment on the RKE2 cluster, providing:
- **Secret Management**: Secure storage for credentials, API keys, and certificates
- **PKI Infrastructure**: Automated TLS certificate generation for all cluster services
- **Encryption as a Service**: Support for application-level encryption workflows
- **Audit Logging**: Comprehensive record of all Vault operations

Vault runs as a 3-replica HA cluster with integrated Raft storage on the database worker pool. Unsealing is manual via Shamir secret sharing (5 shares, threshold 3). TLS certificates are automatically issued by cert-manager via the Vault PKI backend.

**Vault Version**: 1.19.0 (from hashicorp/vault Helm chart 0.32.0)
**Sealed by default**: Yes — operator must unseal after pod restarts
**TLS**: TLS terminated at Traefik; Raft internal communication uses tls_disable=1

---

## Architecture

### Vault HA Cluster Layout

```
┌─────────────────────────────────────────────────────────────┐
│                    Traefik Ingress (203.0.113.202:443)       │
│            vault.<DOMAIN> (Gateway + HTTPRoute)        │
└────────────────────┬────────────────────────────────────────┘
                     │ HTTPS (Gateway API)
    ┌────────────────┼────────────────┐
    │                │                │
    v                v                v
┌──────────┐     ┌──────────┐     ┌──────────┐
│  Vault   │     │  Vault   │     │  Vault   │
│ Replica 1│     │ Replica 2│     │ Replica 3│
│ (Leader) │     │          │     │          │
│ :8200    │     │ :8200    │     │ :8200    │
└────┬─────┘     └────┬─────┘     └────┬─────┘
     │                │                │
     │   vault-internal (headless service)
     │   Raft cluster communication (:8201)
     │                │                │
     └────────────────┼────────────────┘
                      │
              vault (ClusterIP :8200)
              Active/Leader traffic only
                      │
     ┌────────────────┼────────────────┐
     │                │                │
     v                v                v
   Vault Client     Argo CD       cert-manager
   (Applications) (GitOps)       (TLS PKI)
```

**Service Layout:**
- `vault` — ClusterIP :8200, routes to active (leader) node only
- `vault-internal` — Headless service for Raft cluster communication (:8201, :8202)
- All replicas on `workload-type: database` nodes (guaranteed placement)
- Each replica: 10Gi PVC (Raft state + Unseal key backup), Raft automatically replicates

**High Availability Behavior:**
- Leader election in ~10 seconds on pod failure
- Read traffic can go to any unsealed replica (via port :8201 in Raft mode)
- Raft quorum: 3 nodes (automatic failover with 2 nodes healthy)

---

### PKI Certificate Chain

```
┌──────────────────────────────────────────────────────────┐
│    Example Org Root CA (External, Offline Key)          │
│    Validity: 15 years (5475 days)                       │
│    Key: 4096-bit RSA (generated locally via openssl)    │
│    Serial: AUTO-GENERATED                               │
│    Stored: cluster/root-ca.pem (cert), Harvester (key)  │
│    Key NEVER enters Vault or the RKE2 cluster           │
└────────────────────┬─────────────────────────────────────┘
                     │
                     │ Signed by: Root CA private key (locally)
                     v
┌──────────────────────────────────────────────────────────┐
│  Example Org Intermediate CA                            │
│  Validity: 10 years (3650 days)                         │
│  Key: 4096-bit RSA (generated inside Vault)             │
│  Use: Sign leaf certificates                            │
│  Stored in Vault: pki_int/ (key + cert)                 │
└────────────────────┬─────────────────────────────────────┘
                     │
                     │ Signed by: Intermediate CA private key
                     │
    ┌────────────────┼────────────────┐
    │                │                │
    v                v                v
Leaf: vault.*    Leaf: argo.*      Leaf: keycloak.*
(30-day cert)    (30-day cert)     (30-day cert)
 + others...

All leaf certificates auto-renew 30 days before expiration
via cert-manager ClusterIssuer vault-issuer
```

---

## Components

| Component | Purpose | Node Pool | Replicas | Storage |
|-----------|---------|-----------|----------|---------|
| **Vault Server** | Secret management & PKI | database | 3 | 10Gi PVC/replica (Raft) |
| **vault Service** | ClusterIP for clients | — | 1 | — |
| **vault-internal Service** | Headless for Raft peers | — | — | — |
| **TLS Certificate** | vault.<DOMAIN> via cert-manager gateway-shim | — | — | K8s Secret (auto-created) |
| **Gateway + HTTPRoute** | Traefik routing to :8200 | — | — | — |

---

## Prerequisites

1. **Cluster Setup**
   - RKE2 cluster v1.34+ running
   - Database worker pool with at least 3 nodes
   - `workload-type: database` label on each database node (auto-applied by Terraform)

2. **Dependencies**
   - cert-manager deployed with `vault-issuer` ClusterIssuer in `cert-manager` namespace
   - Traefik ingress controller (bundled in RKE2)
   - Cilium CNI for networking

3. **Secrets & Keys**
   - `vault-init.json` from previous Vault initialization (if recovering)
   - Unseal keys (5 total, need 3 to unseal)
   - Root token (stored safely, rarely needed)

4. **DNS**
   - `vault.<DOMAIN>` pointing to Traefik LB IP (203.0.113.202)

---

## Deployment

### Step 1: Create Namespace & RBAC

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: vault
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault
  namespace: vault
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault
  namespace: vault
EOF
```

### Step 2: Deploy via Helm

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# From the services/vault directory
cd services/vault

helm install vault hashicorp/vault \
  --namespace vault \
  --values vault-values.yaml \
  --wait \
  --timeout 5m
```

**Expected Output:**
```
NAME: vault
NAMESPACE: vault
STATUS: deployed
REVISION: 1

NOTES:
1. Vault Pods are running but are still sealed. Unseal them with unsealing keys.
2. TLS cert not yet provisioned (cert-manager needed).
```

### Step 3: Install Gateway & HTTPRoute

```bash
# Apply kustomization (includes gateway.yaml + httproute.yaml)
kubectl apply -k .
```

**Monitor cert issuance (auto-created by gateway-shim):**
```bash
kubectl get gateways -n vault -w
# Wait for Gateway to have an assigned IP

kubectl get secrets -n vault | grep tls
# Gateway-shim auto-creates the TLS secret from Gateway annotation

kubectl get secret -n vault -o name | grep tls | xargs -I{} kubectl get {} -n vault -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout | grep -A2 "Subject:"
```

### Step 4: Initialize Vault (First Time Only)

```bash
# Port-forward to active replica
kubectl port-forward -n vault svc/vault 8200:8200 &

# Initialize with 5 shares, threshold 3
curl -X POST http://localhost:8200/v1/sys/init \
  -H "Content-Type: application/json" \
  -d '{
    "secret_shares": 5,
    "secret_threshold": 3
  }' | tee vault-init.json

# Immediately save this file! Contains unseal keys + root token
# Store vault-init.json as K8s secret in terraform-state namespace (done by terraform.sh)
```

**vault-init.json structure:**
```json
{
  "keys": ["key1_64chars", "key2_64chars", ..., "key5_64chars"],
  "keys_base64": ["key1_base64", ...],
  "root_token": "hvs.XXXXXXXXXXXXXXXX",
  "recovery_keys": ["recovery_key1", ...],
  "recovery_keys_base64": ["recovery_key1_base64", ...],
  "recovery_keys_shares": 5,
  "recovery_keys_threshold": 3
}
```

### Step 5: Unseal All Replicas

```bash
# Get current sealed status
curl http://localhost:8200/v1/sys/seal-status | jq .

# Unseal replica 1 (provide 3 different keys)
curl -X PUT http://localhost:8200/v1/sys/unseal \
  -H "Content-Type: application/json" \
  -d '{"key": "key1_64chars"}' | jq .

# (Repeat with key2 and key3)

# Check all 3 replicas are unsealed:
for i in 0 1 2; do
  echo "=== Replica $i ==="
  kubectl get pod -n vault vault-$i -o jsonpath='{.status.phase}'
  kubectl exec -n vault vault-$i -- vault status
done
```

**Expected status:**
```
Key                    Value
---                    -----
Seal Type              shamir
Initialized            true
Sealed                 false    # ← Must be false
Total Shares           5
Threshold              3
Unseal Progress        0/3
Version                1.19.0
Build Date             2025-01-28T00:00:00Z
Storage Type           raft
HA Enabled             true
Raft Committed Index   123
Raft Applied Index     123
```

### Step 6: Set Up PKI Backend

The Root CA is generated **externally** via openssl. The Root CA private key never enters Vault — it stays on the local machine and is backed up to Harvester via `terraform.sh push-secrets`.

```bash
# --- Root CA (local openssl, run from cluster/ directory) ---

# Generate Root CA key + cert (15 years, 4096-bit RSA)
openssl genrsa -out root-ca-key.pem 4096
openssl req -x509 -new -nodes \
  -key root-ca-key.pem \
  -sha256 -days 5475 \
  -subj "/CN=Example Org Root CA" \
  -out root-ca.pem
chmod 600 root-ca-key.pem
chmod 644 root-ca.pem

# Back up Root CA to Harvester
./terraform.sh push-secrets

# --- Intermediate CA (key generated inside Vault, CSR signed locally) ---

# Enable intermediate PKI in Vault
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=87600h pki_int

# Generate intermediate CSR (key stays in Vault)
vault write -field=csr pki_int/intermediate/generate/internal \
  common_name="Example Org Intermediate CA" \
  ttl=87600h \
  key_bits=4096 \
  > intermediate.csr

# Sign the CSR LOCALLY with Root CA key (NOT in Vault)
openssl x509 -req -in intermediate.csr \
  -CA root-ca.pem \
  -CAkey root-ca-key.pem \
  -CAcreateserial -days 3650 -sha256 \
  -extfile <(printf "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always") \
  -out intermediate.crt

# Build full chain (intermediate + root) and import into Vault
cat intermediate.crt root-ca.pem > intermediate-chain.crt
vault write pki_int/intermediate/set-signed certificate=@intermediate-chain.crt

# Configure role for issuing leaf certs (30 days)
vault write pki_int/roles/<DOMAIN_DOT> \
  allowed_domains=<DOMAIN> \
  allow_subdomains=true \
  max_ttl=720h \
  require_cn=false
```

> **Note**: There is NO `pki/` mount in Vault. The Root CA key never enters Vault. Only the `pki_int/` mount exists, containing the Intermediate CA key and the full certificate chain (intermediate + root).

### Step 7: Create auth-method for Kubernetes

```bash
export KUBERNETES_HOST=https://$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
export KUBERNETES_PORT=443
export SA_NAME=vault
export SA_NAMESPACE=vault

# Get SA token & CA cert
SA_JWT=$(kubectl get secret -n $SA_NAMESPACE \
  $(kubectl get secret -n $SA_NAMESPACE | grep $SA_NAME-token | awk '{print $1}') \
  -o jsonpath='{.data.token}' | base64 -d)

SA_CA_CRT=$(kubectl get secret -n $SA_NAMESPACE \
  $(kubectl get secret -n $SA_NAMESPACE | grep $SA_NAME-token | awk '{print $1}') \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

# Configure K8s auth method
vault auth enable kubernetes

vault write auth/kubernetes/config \
  token_reviewer_jwt="$SA_JWT" \
  kubernetes_host="$KUBERNETES_HOST:$KUBERNETES_PORT" \
  kubernetes_ca_cert="$SA_CA_CRT" \
  issuer="https://kubernetes.default.svc.cluster.local"

# Create policy for cert-manager
vault policy write cert-manager - <<'POLICY'
path "pki_int/sign/<DOMAIN_DOT>" {
  capabilities = ["create", "update"]
}

path "pki_int/issue/<DOMAIN_DOT>" {
  capabilities = ["create", "update"]
}

path "pki_int/cert/ca" {
  capabilities = ["read"]
}
POLICY

# Create K8s auth role
vault write auth/kubernetes/role/cert-manager-issuer \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager \
  ttl=1h
```

### Step 8: Verify cert-manager ClusterIssuer

```bash
# Check vault-issuer status
kubectl get clusterissuer vault-issuer -o yaml | grep -A5 status

# Should show:
# status:
#   conditions:
#   - lastTransitionTime: "2025-02-11T12:00:00Z"
#     message: "Vault verified and ready to issue certificates"
#     reason: EnsureReady
#     status: "True"
#     type: Ready

# Test: Request a certificate
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-vault-cert
  namespace: vault
spec:
  secretName: test-vault-tls
  commonName: test.<DOMAIN>
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
EOF

# Watch for readiness
kubectl get certificate test-vault-cert -n vault -w
```

---

## Day-2 Operations

### Unsealing After Pod Restart

When Vault pods restart, they come back **sealed**. Operator must unseal all 3 replicas with 3-of-5 keys.

#### Unseal Procedure (Sequence Diagram)

```
Operator                Vault Cluster              cert-manager
   │                           │                         │
   ├──────────────────────────>│ vault status (sealed)   │
   │     Check seal status     │                         │
   │                           │                         │
   ├──────────────────────────>│ POST /sys/unseal (key1)│
   │      Unseal replica-0     │ ✓ Unseal Progress: 1/3│
   │                           │                         │
   ├──────────────────────────>│ POST /sys/unseal (key2)│
   │      Unseal replica-0     │ ✓ Unseal Progress: 2/3│
   │                           │                         │
   ├──────────────────────────>│ POST /sys/unseal (key3)│
   │      Unseal replica-0     │ ✓ UNSEALED             │
   │                           │                         │
   ├──────────────────────────>│ vault status (unsealed)│
   │     Repeat for replica-1  │                         │
   │     Repeat for replica-2  │                         │
   │                           │                         │
   │                  All 3 unsealed                     │
   │                           │                         │
   │                           ├──────────────────────>  │
   │                           │   Mount checks & route  │
   │                           │   TLS renewal requests  │
   │                           │                         │
   │                           │<──────────────────────  │
   │                           │   Sign leaf certificates│
   │                           │   (30-day auto-renew)   │
   │                           │                         │
   └───────────────────────────┘─────────────────────────┘
```

#### Operational Steps

```bash
# 1. Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &
sleep 2

# 2. Check seal status (should show Sealed: true)
curl -s http://localhost:8200/v1/sys/seal-status | jq '.sealed'

# 3. Unseal all replicas (provide 3 keys, repeat for each pod)
UNSEAL_KEY_1="key1_64chars_from_vault_init_json"
UNSEAL_KEY_2="key2_64chars_from_vault_init_json"
UNSEAL_KEY_3="key3_64chars_from_vault_init_json"

for i in 0 1 2; do
  echo "Unsealing vault-$i..."

  # Use kubectl exec (follows leader)
  kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_1
  kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_2
  kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_3
done

# 4. Verify all replicas unsealed
for i in 0 1 2; do
  echo "=== vault-$i status ==="
  kubectl exec -n vault vault-$i -- vault status | grep -E "Sealed|HA Enabled"
done

# Expected: Sealed=false for all 3

# 5. Monitor cert-manager discovering PKI
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager -f | grep -i vault
```

---

## Configuration

### vault-values.yaml (Helm Chart)

Key settings for HA Raft deployment:

```yaml
# Server configuration
server:
  image:
    repository: hashicorp/vault
    tag: "1.19.0"

  nodeSelector:
    workload-type: database

  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: vault
                component: server
            topologyKey: kubernetes.io/hostname

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: harvester

  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      config: |
        ui = true

        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_disable = 1
          telemetry {
            unauthenticated_metrics_access = true
          }
        }

        storage "raft" {
          path = "/vault/data"
        }

        service_registration "kubernetes" {}

        telemetry {
          prometheus_retention_time = "30s"
          disable_hostname = true
        }
```

> **Note**: `tls_disable = 1` means TLS is terminated at Traefik (Gateway API), not at Vault itself. Raft peer communication within the cluster uses HTTP on port 8201. The `telemetry` block enables Prometheus metrics scraping without authentication.

### Services

**vault** (ClusterIP) — Routes to active/leader only
```yaml
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: vault
spec:
  type: ClusterIP
  ports:
  - port: 8200
    targetPort: 8200
    name: http
  selector:
    app.kubernetes.io/name: vault
```

**vault-internal** (Headless) — Raft peer discovery
```yaml
apiVersion: v1
kind: Service
metadata:
  name: vault-internal
  namespace: vault
spec:
  clusterIP: None
  ports:
  - port: 8200
    name: http
  - port: 8201
    name: raft
  selector:
    app.kubernetes.io/name: vault
```

---

## Verification

### Check Raft Cluster Status

```bash
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# Expected output:
# Node                          Address                            State       Voter
# ----                          -------                            -----       -----
# vault-0                       vault-0.vault-internal:8201        leader      true
# vault-1                       vault-1.vault-internal:8201        follower    true
# vault-2                       vault-2.vault-internal:8201        follower    true
```

### Check PKI Secret Engine

```bash
# Port-forward
kubectl port-forward -n vault svc/vault 8200:8200 &

# Verify Root CA exists locally
openssl x509 -in cluster/root-ca.pem -text -noout | grep -E "Subject:|Issuer:|Not After"
# Expected: Subject and Issuer both "Example Org Root CA", Not After ~15 years

# Verify Intermediate CA in Vault
curl -s http://localhost:8200/v1/pki_int/cert/ca | jq '.data.certificate' | \
  openssl x509 -text -noout | grep -E "Subject:|Issuer:|Not After"
# Expected: Subject: "Example Org Intermediate CA", Issuer: "Example Org Root CA"

# Verify full chain in Vault (intermediate + root)
curl -s http://localhost:8200/v1/pki_int/cert/ca_chain
# Expected: Two PEM certificates (intermediate first, root second)
```

### Test Certificate Issuance

```bash
# Check cert-manager vault-issuer
kubectl get clusterissuer vault-issuer -o yaml | grep -A10 "status:"

# Should show: Ready=True, reason=EnsureReady

# Monitor active certificate renewals
kubectl get certificate -A | grep -E "ISSUER|vault"
```

### Verify TLS Certificate

```bash
# Check Gateway and HTTPRoute
kubectl get gateways -n vault
kubectl get httproutes -n vault

# Check auto-created TLS secret (gateway-shim)
kubectl get secrets -n vault | grep tls
kubectl get secret -n vault -o name | grep tls | head -1 | xargs -I{} kubectl get {} -n vault -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout | head -20

# Expected:
# Subject: CN = vault.<DOMAIN>
# Issuer: CN = Example Org Intermediate CA
# Not Before: 2025-02-11 ...
# Not After:  2025-03-13 ...  (30 days)
```

---

## Troubleshooting

### Issue: "Sealed Vault After Pod Restart"

**Symptom:**
```
kubectl exec -n vault vault-0 -- vault status
Error: Error making API request.

URL: GET http://127.0.0.1:8200/v1/sys/health
Code: 503. Errors:

* error performing request: Put "http://127.0.0.1:8200/v1/sys/unseal": unseal key should be 32 bytes
```

**Cause:** Vault pods are sealed after restart or forced termination.

**Solution:**
1. Get vault-init.json (stored as secret in terraform-state namespace or locally)
2. Unseal all 3 replicas using 3 of 5 keys (see Day-2 Unseal Procedure above)
3. Monitor PKI recovery: `kubectl logs -n cert-manager -f | grep vault`

---

### Issue: "Raft Peer Join Failures"

**Symptom:**
```
kubectl logs -n vault vault-2
...
[ERROR] core: failed to unseal core: error="error during raft configuration: couldn't join raft cluster"
```

**Cause:** Replica failed to discover Raft peers or hostname mismatch.

**Solution:**
```bash
# Check DNS resolution for vault-internal headless service
kubectl run -it --rm debug --image=alpine --restart=Never -- \
  nslookup vault-internal.vault.svc.cluster.local

# Expected: 3 IPs (one per pod)

# Check raft retry_join config in Helm values
kubectl get pods -n vault -o jsonpath='{.items[0].spec.containers[0].args}' | grep -i raft

# If pods fail to join:
# 1. Scale down to 1 replica
# 2. Unseal the single replica
# 3. Scale back up to 3 (replicas auto-discover via retry_join)
kubectl scale statefulset vault -n vault --replicas=1
# ... unseal ...
kubectl scale statefulset vault -n vault --replicas=3
```

---

### Issue: "cert-manager ClusterIssuer Not Ready"

**Symptom:**
```
kubectl get clusterissuer vault-issuer
NAME              READY   AGE
vault-issuer      False   5m
```

**Cause:** Vault sealed, Kubernetes auth not configured, or cert-manager can't reach Vault.

**Solution:**
```bash
# Check ClusterIssuer status
kubectl describe clusterissuer vault-issuer | tail -20

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager -f

# Verify Vault unsealed
kubectl exec -n vault vault-0 -- vault status | grep "Sealed:"

# If Vault sealed: unseal it (see Day-2 procedure)

# Verify K8s auth method exists
kubectl exec -n vault vault-0 -- vault auth list | grep kubernetes

# If missing: re-run Step 7 (Create auth-method for Kubernetes)

# Test Vault reachability from cert-manager
kubectl exec -n cert-manager $(kubectl get pod -n cert-manager -l app=cert-manager -o jsonpath='{.items[0].metadata.name}') -- \
  curl -k https://vault.vault.svc.cluster.local:8200/v1/sys/health
```

---

### Issue: "After Vault Rebuild, Old TLS Certs Persist"

**Symptom:** Old Vault Root CA still in use, cert-manager issues certs with old issuer.

**Cause:** Kubernetes Secrets from previous Vault installation not deleted.

**Solution:**
```bash
# Delete all TLS secrets across cluster (they'll be re-issued from new CA)
kubectl delete secret -A -l cert-manager.io/certificate-name

# Trigger re-issuance
kubectl delete certificate -A -l issuer=vault-issuer
sleep 5

# cert-manager will automatically recreate them with new CA
kubectl get certificate -A -w

# Verify new CA in certificates
kubectl get secret vault-tls -n vault -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout | grep "Issuer:"
```

---

### Issue: "vault-init.json Lost — Cannot Unseal"

**Symptom:** Pod restarts but unseal keys not available; Vault stuck sealed.

**Cause:** vault-init.json not backed up as K8s secret or locally.

**Solution:**
```bash
# Check if stored as secret in terraform-state namespace
kubectl get secret vault-init -n terraform-state -o jsonpath='{.data.init}' | base64 -d > vault-init.json

# If secret exists:
# Use keys from vault-init.json to unseal (see Day-2 procedure)

# If secret does NOT exist:
# Vault is permanently locked (cannot unseal without keys)
# Option 1: Rebuild Vault from scratch (new Root CA, re-issue all certs)
# Option 2: Restore Raft data from backup (if available)

# Prevent future loss: ensure terraform.sh push-secrets stores vault-init.json
# Location: /path/to/terraform-state/vault-init.json → Secret vault-init in terraform-state ns
```

**Prevention:**
```bash
# Manually backup vault-init.json
kubectl get secret vault-init -n terraform-state -o jsonpath='{.data.init}' | \
  base64 -d > ~/.vault-init-backup-$(date +%Y%m%d).json
chmod 600 ~/.vault-init-backup-*.json
```

---

### Issue: "Traefik Shows 502 Bad Gateway on vault.<DOMAIN>"

**Symptom:**
```
curl https://vault.<DOMAIN>/v1/sys/health
<html><body>502 Bad Gateway</body></html>
```

**Cause:** Vault service not accessible, cert not ready, or port mismatch.

**Solution:**
```bash
# Check Gateway and HTTPRoute exist
kubectl get gateways -n vault
kubectl get httproutes -n vault

# Verify service is accessible
kubectl port-forward -n vault svc/vault 8200:8200 &
curl -k http://localhost:8200/v1/sys/health

# Check if vault pods are running
kubectl get pods -n vault
# All 3 should be Running, 1/1 Ready

# If pods Running but not ready:
kubectl describe pod -n vault vault-0 | grep -A10 "Events:"

# Check TLS secret (auto-created by gateway-shim)
kubectl get secrets -n vault | grep tls
# Should show TLS secret
```

---

### Issue: "Raft Snapshot Too Large, Disk Full"

**Symptom:**
```
kubectl logs -n vault vault-0 | grep -i "snapshot\|disk full"
```

**Cause:** Raft log accumulation over time.

**Solution:**
```bash
# Check Vault storage usage
kubectl exec -n vault vault-0 -- du -sh /vault/data

# Trigger manual snapshot (requires leader access)
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /vault/data/snapshot.raft

# Restore from snapshot (if needed)
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /vault/data/snapshot.raft

# Or, scale down Vault and expand PVC:
# 1. Edit vault PVC size in vault-values.yaml (increase from 10Gi to 20Gi)
# 2. Helm upgrade vault
# 3. K8s auto-expands PVC on scale-up
```

---

## File Structure

```
services/vault/
├── README.md                    # This file
├── kustomization.yaml           # Kustomize: lists only gateway.yaml + httproute.yaml
├── vault-values.yaml            # Helm values for 3-replica HA Raft deployment
├── gateway.yaml                 # Gateway with cert-manager annotation (auto-creates TLS secret)
├── httproute.yaml               # HTTPRoute (port 8200, no basic-auth)
└── (generated by Helm)
    ├── vault-0                  # Replica 1, leader
    ├── vault-1                  # Replica 2, follower
    └── vault-2                  # Replica 3, follower
```

**kustomization.yaml Strategy:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - gateway.yaml
  - httproute.yaml

# Note: vault-values.yaml is NOT included (not a K8s manifest)
# Helm install handles it separately
# Certificate is auto-created by cert-manager gateway-shim from Gateway annotation
```

This allows ArgoCD Kustomize detection to work correctly (only K8s manifests).

---

## Dependencies

### Upstream
- **hashicorp/vault Helm chart v0.32.0** → Vault server 1.19.0
  - Chart reference: `https://helm.releases.hashicorp.com`
  - `helm install vault hashicorp/vault --values vault-values.yaml`

### Kubernetes Platform
- **cert-manager ClusterIssuer** `vault-issuer` (see services/cert-manager/)
  - Must be deployed before Vault certificate can be issued
  - Requires Vault PKI backend to be configured (Step 6)
- **Traefik Ingress Controller** (bundled in RKE2 v1.34+)
  - Routes `vault.<DOMAIN>` to vault Service :8200
- **Harvester cloud-provider** for PVC provisioning
  - Storage class: `harvester`

### Downstream Consumers
- **cert-manager** — Uses Vault PKI to issue all cluster TLS certificates
- **ArgoCD** — Reads Vault secrets for Git credentials (via Kubernetes auth)
- **Applications** — K8s auth + identity API for application-level encryption

---

## Next Steps

1. **Deploy Vault** — Follow Deployment section (Steps 1-7)
2. **Test PKI** — Run verification commands to confirm Root → Intermediate → Leaf chain
3. **Backup vault-init.json** — Store securely (both K8s secret + offline copy)
4. **Monitor Raft** — Check cluster status weekly, watch Raft committed index
5. **Plan CA Rotation** — Intermediate CA expires in 10 years; Root CA in 15 years. Set calendar reminders
6. **Document Unseal Keys** — Distribute Shamir shares to 5 different operators (threshold 3)

---

## References

- **Vault HA Architecture**: https://developer.hashicorp.com/vault/docs/concepts/ha
- **Raft Storage**: https://developer.hashicorp.com/vault/docs/configuration/storage/raft
- **Shamir Secret Sharing**: https://developer.hashicorp.com/vault/docs/concepts/seal#shamir-sealing
- **Kubernetes Auth Method**: https://developer.hashicorp.com/vault/docs/auth/kubernetes
- **PKI Secrets Engine**: https://developer.hashicorp.com/vault/docs/secrets/pki
- **cert-manager Integration**: https://cert-manager.io/docs/configuration/vault/

---

**Last Updated:** 2025-02-11
**Vault Version:** 1.19.0 (hashicorp/vault Helm chart 0.32.0)
**Cluster Version:** RKE2 v1.34+
**Maintainer:** RKE2 Infrastructure Team
