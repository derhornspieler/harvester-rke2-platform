# TLS Integration Guide

How to get automatic TLS certificates for services running on the rke2-prod cluster. Certificates are signed by the Example Org internal PKI (Vault) and issued automatically by cert-manager.

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

---

## PKI Chain Overview

```
Example Org Root CA (External, key offline on Harvester)
  |
  +-- Intermediate CA (Vault pki_int/)
        |
        +-- Leaf certificates (*.<DOMAIN>)
              Issued by cert-manager via ClusterIssuer "vault-issuer"
```

- **Root CA**: 15-year lifetime, generated locally via openssl, key stored offline (Harvester). Key never enters Vault
- **Intermediate CA**: 10-year lifetime, key generated inside Vault `pki_int/`, CSR signed locally by Root CA
- **Leaf certificates**: Up to 720 hours (30 days) TTL, auto-renewed by cert-manager

All certificates are for `*.<DOMAIN>` domains only.

---

## Option 1: Auto-Certificate via Gateway API (Recommended)

This is the simplest approach. cert-manager watches Gateway resources and automatically creates Certificate resources when it detects the `cert-manager.io/cluster-issuer` annotation.

### Steps

1. Add the cert-manager annotation to your Gateway
2. Add an HTTPS listener with `certificateRefs` pointing to a Secret name of your choice
3. Point your HTTPRoute at the HTTPS listener's `sectionName`

cert-manager handles everything else: creates the Certificate, signs it via Vault, stores it in the referenced Secret, and renews it before expiry.

### Example Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: vault-issuer
spec:
  gatewayClassName: traefik
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: myservice.<DOMAIN>
      tls:
        mode: Terminate
        certificateRefs:
          - name: myservice-<DOMAIN_DASHED>-tls
      allowedRoutes:
        namespaces:
          from: Same
```

### Example HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myservice
  namespace: my-namespace
spec:
  parentRefs:
    - name: my-gateway
      namespace: my-namespace
      sectionName: https
  hostnames:
    - "myservice.<DOMAIN>"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myservice
          port: 8080
```

### What Happens Automatically

1. cert-manager detects the Gateway annotation and HTTPS listener
2. Creates a `Certificate` resource for `myservice.<DOMAIN>`
3. Sends a CSR to Vault via `pki_int/sign/<DOMAIN_DOT>`
4. Vault signs the certificate with the Intermediate CA
5. cert-manager stores the signed cert + key in Secret `myservice-<DOMAIN_DASHED>-tls`
6. Traefik loads the Secret and terminates TLS on port 443

---

## Option 2: Explicit Certificate Resource

For cases where you need more control (custom duration, DNS SANs, etc.), create a Certificate resource directly.

### Example Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myservice-cert
  namespace: my-namespace
spec:
  secretName: myservice-<DOMAIN_DASHED>-tls
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: myservice.<DOMAIN>
  dnsNames:
    - myservice.<DOMAIN>
  duration: 720h    # 30 days
  renewBefore: 168h # renew 7 days before expiry
```

Then reference `myservice-<DOMAIN_DASHED>-tls` in your Gateway listener's `certificateRefs`, or mount it directly in your Pod for mTLS / internal TLS.

---

## Verification

After deploying, verify your certificate is issued:

```bash
# Check Certificate status (should show Ready=True)
kubectl get certificates -n my-namespace

# Describe for detailed status and events
kubectl describe certificate myservice-cert -n my-namespace

# Verify the Secret was created with tls.crt and tls.key
kubectl get secret myservice-<DOMAIN_DASHED>-tls -n my-namespace

# Inspect the certificate chain
kubectl get secret myservice-<DOMAIN_DASHED>-tls -n my-namespace \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Expected output includes:
#   Issuer: CN = Example Org Intermediate CA
#   Subject: CN = myservice.<DOMAIN>
```

Test TLS from outside the cluster:

```bash
# curl with verbose TLS output
curl -v https://myservice.<DOMAIN>

# Check the full certificate chain
openssl s_client -connect myservice.<DOMAIN>:443 -showcerts </dev/null
```

---

## Troubleshooting

### Certificate stuck in "Pending"

```bash
# Check CertificateRequest status
kubectl get certificaterequests -n my-namespace

# Check cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager

# Common causes:
# - ClusterIssuer not ready: kubectl get clusterissuers vault-issuer
# - Vault sealed: kubectl exec -n vault vault-0 -- vault status
# - Domain not allowed: only *.<DOMAIN> subdomains are permitted
```

### ClusterIssuer not Ready

```bash
kubectl describe clusterissuer vault-issuer

# Common causes:
# - Vault pod not running: kubectl get pods -n vault
# - Kubernetes auth misconfigured in Vault
# - vault-issuer ServiceAccount missing in cert-manager namespace
```

### Certificate issued but TLS not working

```bash
# Verify Traefik picked up the Gateway changes
kubectl get gateways -n monitoring

# Check that the Secret has both tls.crt and tls.key
kubectl get secret myservice-<DOMAIN_DASHED>-tls -n my-namespace -o yaml

# Verify the hostname matches between Gateway listener, HTTPRoute, and cert
```

### Renewing certificates manually

cert-manager renews automatically, but you can force a renewal:

```bash
# Delete the Certificate's Secret to trigger re-issuance
kubectl delete secret myservice-<DOMAIN_DASHED>-tls -n my-namespace

# Or use cmctl (cert-manager CLI)
cmctl renew myservice-cert -n my-namespace
```
