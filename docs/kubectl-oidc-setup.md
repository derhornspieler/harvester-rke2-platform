# kubectl OIDC Setup Guide

Authenticate to the RKE2 cluster using your Keycloak identity via kubelogin.

## Prerequisites

- `kubectl` installed
- Access to the Keycloak realm (credentials from your admin)
- The cluster Root CA certificate (found at `cluster/root-ca.pem`, or from your admin)

## 1. Install kubelogin

**macOS (Homebrew):**
```bash
brew install int128/kubelogin/kubelogin
```

**kubectl krew:**
```bash
kubectl krew install oidc-login
```

**Linux (binary):**
```bash
# Download from https://github.com/int128/kubelogin/releases
curl -LO https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
unzip kubelogin_linux_amd64.zip
mv kubelogin /usr/local/bin/kubectl-oidc_login
chmod +x /usr/local/bin/kubectl-oidc_login
```

## 2. Import Root CA into OS trust store

The cluster uses a private CA. Import `root-ca.pem` (found at `cluster/root-ca.pem`) into your trust store:

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root-ca.pem
```

**RHEL/Rocky/Fedora:**
```bash
sudo cp root-ca.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

**Ubuntu/Debian:**
```bash
sudo cp root-ca.pem /usr/local/share/ca-certificates/rke2-root-ca.crt
sudo update-ca-certificates
```

## 3. Configure kubeconfig

Use the helper script to generate the OIDC kubeconfig snippet:

```bash
./scripts/setup-kubectl-oidc.sh
```

Or manually add to `~/.kube/config`:

```yaml
users:
  - name: oidc-user
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://keycloak.DOMAIN/realms/REALM
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=groups
        interactiveMode: IfAvailable

contexts:
  - name: ${CLUSTER_NAME}-oidc
    context:
      cluster: ${CLUSTER_NAME}
      user: oidc-user
      namespace: default
```

Replace `DOMAIN`, `REALM`, and `${CLUSTER_NAME}` with your actual values (e.g., `rke2-prod-oidc` for a cluster named `rke2-prod`). The helper script `setup-kubectl-oidc.sh` derives the context name as `${CLUSTER_NAME}-oidc` automatically.

> **Note**: For the manual kubeconfig, include `certificate-authority-data` under the cluster
> definition with the base64-encoded Root CA from `cluster/root-ca.pem`. The helper script
> embeds this automatically.

## 4. Test

```bash
kubectl --context ${CLUSTER_NAME}-oidc get pods -n default
```

Your browser will open for Keycloak authentication. After login, the token is cached locally and refreshed automatically.

## 5. Access Control

Your access level is determined by your Keycloak group membership:

| Group | Kubernetes Access |
|-------|------------------|
| `platform-admins` | `cluster-admin` (full access) |
| `infra-engineers` | Custom role: namespaces, apps, networking, cert-manager, traefik |
| `senior-developers` | `edit` in assigned namespaces |
| `developers` | `edit` in assigned namespaces |
| `viewers` | `view` (read-only, cluster-wide) |

Three additional Keycloak groups (`harvester-admins`, `rancher-admins`, `network-engineers`) exist for non-Kubernetes access management and do not have ClusterRoleBindings.

## Troubleshooting

**"error: You must be logged in to the server"**
- Ensure kubelogin is installed: `kubectl oidc-login --version`
- Check the OIDC issuer URL is reachable: `curl -s https://keycloak.DOMAIN/realms/REALM/.well-known/openid-configuration | jq .issuer`

**"x509: certificate signed by unknown authority"**
- Import the Root CA into your OS trust store (step 2)
- Or pass `--certificate-authority=/path/to/root-ca.pem` to kubelogin

**"Forbidden" errors after successful login**
- Your Keycloak group may not have a matching RBAC binding
- Ask an admin to add your group to the appropriate ClusterRoleBinding/RoleBinding

**Token refresh issues**
- kubelogin caches tokens in `~/.kube/cache/oidc-login/`
- Clear the cache: `rm -rf ~/.kube/cache/oidc-login/`
