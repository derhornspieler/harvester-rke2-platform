# Vault HA Migration Plan

## Status: Implemented

Vault HA migration is complete. This document is retained as a reference for the migration process. For current Vault operations, see the [Vault Service README](../services/vault/README.md).

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

---

**Original plan**: Migrate Vault from standalone (1 replica) to HA (3 replicas) with integrated Raft consensus on the database worker pool.

---

## Current State

- **Mode:** Standalone, 1 replica (`vault-0`)
- **Storage:** Raft (single node)
- **Node:** general pool
- **Unseal:** Manual (Shamir, 3-of-5 keys)
- **Risk:** Single point of failure — pod restart requires manual unseal, node failure causes downtime

## Target State

- **Mode:** HA, 3 replicas (`vault-0`, `vault-1`, `vault-2`)
- **Storage:** Integrated Raft (3-node cluster)
- **Nodes:** database pool (spread via pod anti-affinity)
- **Unseal:** Manual (Shamir) initially, auto-unseal as future follow-up
- **Benefit:** Automatic leader election, no downtime for single node failure

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Database Pool (3 nodes)                │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   vault-0    │  │   vault-1    │  │   vault-2    │   │
│  │   (leader)   │  │  (standby)   │  │  (standby)   │   │
│  │   :8200      │  │   :8200      │  │   :8200      │   │
│  │   10Gi PVC   │  │   10Gi PVC   │  │   10Gi PVC   │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │
│         │    Raft consensus (:8201)          │           │
│         └──────────────┼─────────────────────┘           │
│                        │                                  │
│  ┌─────────────────────▼──────────────────────────────┐  │
│  │  vault-internal (headless service)                  │  │
│  │  vault-0.vault-internal:8200                        │  │
│  │  vault-1.vault-internal:8200                        │  │
│  │  vault-2.vault-internal:8200                        │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  vault (active service)                             │  │
│  │  Routes to current Raft leader only                 │  │
│  │  ClusterIP :8200                                    │  │
│  └──────────────────────┬─────────────────────────────┘  │
└─────────────────────────┼────────────────────────────────┘
                          │
               ┌──────────▼──────────┐
               │  IngressRoute       │
               │  vault.<DOMAIN>      │
               │  TLS (cert-manager) │
               └─────────────────────┘
```

## Migration Steps

### Prerequisites

- [ ] Backup current Vault data (Raft snapshot)
- [ ] Record all unseal keys and root token
- [ ] Ensure database pool has 3 healthy nodes
- [ ] Verify Harvester CSI can provision 2 additional PVCs

### Step 1: Backup Existing Vault

```bash
# Create Raft snapshot
kubectl exec -n vault vault-0 -- sh -c \
  'VAULT_TOKEN=<root-token> vault operator raft snapshot save /tmp/vault-snapshot.snap'

# Copy snapshot locally
kubectl cp vault/vault-0:/tmp/vault-snapshot.snap ./vault-snapshot.snap
```

### Step 2: Uninstall Standalone Vault

```bash
helm uninstall vault -n vault

# PVC is retained by default (ReclaimPolicy: Retain)
# Verify PVC still exists
kubectl get pvc -n vault
```

### Step 3: Deploy HA Vault

```bash
# Install with HA values
helm install vault hashicorp/vault -n vault --create-namespace \
  -f services/vault/vault-values.yaml

# Wait for pods (they'll be 0/1 Ready — uninitialized)
kubectl get pods -n vault -w
```

### Step 4: Initialize and Unseal Leader

```bash
# Initialize on vault-0
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json

# CRITICAL: Save vault-init.json securely

# Unseal vault-0
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>

# Verify vault-0 is active
kubectl exec -n vault vault-0 -- vault status
# HA Mode: active
```

### Step 5: Join and Unseal Replicas

```bash
# Join vault-1 to Raft cluster
kubectl exec -n vault vault-1 -- vault operator raft join \
  http://vault-0.vault-internal:8200

# Unseal vault-1
kubectl exec -n vault vault-1 -- vault operator unseal <key1>
kubectl exec -n vault vault-1 -- vault operator unseal <key2>
kubectl exec -n vault vault-1 -- vault operator unseal <key3>

# Join vault-2 to Raft cluster
kubectl exec -n vault vault-2 -- vault operator raft join \
  http://vault-0.vault-internal:8200

# Unseal vault-2
kubectl exec -n vault vault-2 -- vault operator unseal <key1>
kubectl exec -n vault vault-2 -- vault operator unseal <key2>
kubectl exec -n vault vault-2 -- vault operator unseal <key3>
```

### Step 6: Restore Data (if migrating from existing Vault)

```bash
export VAULT_TOKEN=$(jq -r '.root_token' vault-init.json)

# Restore from snapshot
kubectl cp vault-snapshot.snap vault/vault-0:/tmp/vault-snapshot.snap
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN=$VAULT_TOKEN vault operator raft snapshot restore /tmp/vault-snapshot.snap"
```

### Step 7: Reconfigure PKI (if fresh install)

Follow Step 6 in the [Vault Service README](../services/vault/README.md) to set up:
- Root CA (generated locally via openssl — key never enters Vault)
- Intermediate CA (`pki_int/` — key generated inside Vault, CSR signed locally)
- PKI role (`<DOMAIN_DOT>`)
- Kubernetes auth for cert-manager

### Step 8: Apply Ingress Manifests

```bash
kubectl apply -k services/vault/
```

### Step 9: Verify

```bash
# All 3 pods running and ready
kubectl get pods -n vault
# vault-0   1/1   Running
# vault-1   1/1   Running
# vault-2   1/1   Running

# Raft cluster healthy
kubectl exec -n vault vault-0 -- sh -c \
  'VAULT_TOKEN=<root-token> vault operator raft list-peers'
# Should show 3 peers: vault-0 (leader), vault-1 (follower), vault-2 (follower)

# TLS certificate correct
echo | openssl s_client -connect 203.0.113.202:443 \
  -servername vault.<DOMAIN> 2>/dev/null | \
  openssl x509 -noout -issuer
# issuer=CN=Example Org Intermediate CA

# UI accessible
curl -sk -o /dev/null -w "%{http_code}" \
  https://203.0.113.202/ui/ -H "Host: vault.<DOMAIN>"
# 200

# cert-manager still working
kubectl get certificates -A
# All should be Ready=True
```

---

## Operational Considerations

### Unseal After Restart

Every Vault pod requires manual unsealing after restart. This is the default Shamir seal behavior. Each pod needs 3-of-5 unseal keys:

```bash
for i in 0 1 2; do
  kubectl exec -n vault vault-$i -- vault operator unseal <key1>
  kubectl exec -n vault vault-$i -- vault operator unseal <key2>
  kubectl exec -n vault vault-$i -- vault operator unseal <key3>
done
```

### Future: Auto-Unseal

To eliminate manual unsealing, configure auto-unseal with a KMS provider. Options for on-prem:
- **Transit auto-unseal** (requires a separate Vault instance — chicken-and-egg)
- **GCP/AWS/Azure KMS** (requires cloud account)
- **PKCS#11 HSM** (hardware option)

This is a separate follow-up task.

### Leader Election

Raft handles leader election automatically. If the leader pod dies:
1. Remaining nodes detect leader failure (~10s)
2. Election happens among unsealed standby nodes
3. New leader starts serving requests
4. The `vault` service automatically routes to the new leader

Client impact: brief (~10s) interruption during failover. cert-manager retries automatically.

### Storage

Each replica gets its own 10Gi PVC. With 3 replicas, total storage is 30Gi. Data is replicated across all Raft peers (no need for shared storage).

---

## Rollback

If HA migration fails:

```bash
helm uninstall vault -n vault
# Delete HA PVCs
kubectl delete pvc -n vault -l app.kubernetes.io/name=vault

# Reinstall standalone (edit vault-values.yaml: set ha.enabled=false, standalone.enabled=true)
helm install vault hashicorp/vault -n vault --create-namespace \
  -f services/vault/vault-values.yaml

# Restore snapshot, reinitialize, reconfigure PKI
```
