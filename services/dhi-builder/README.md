# DHI Builder - Docker Hardened Image Pipeline

## Overview

DHI Builder is an automated pipeline for building security-hardened container images. It takes Docker Hardened Image (DHI) YAML definitions from a vendored catalog, translates them into Dockerfiles, builds them using BuildKit, and pushes the resulting images to Harbor.

**Key purposes**:
- **Automated hardened image builds**: Convert DHI catalog YAML specs into production-ready, security-hardened container images
- **Event-driven builds**: Automatically trigger builds when the image manifest ConfigMap is updated (via Argo Events)
- **Scheduled rebuilds**: Daily CronWorkflow at 02:00 UTC ensures images stay current with base image updates
- **Harbor integration**: Built images are pushed to the `dhi/` project in Harbor with full tag tracking
- **Skip-if-exists**: The pipeline checks Harbor before building, avoiding redundant rebuilds

**Architecture highlights**:
- BuildKit daemon runs as a rootless StatefulSet with persistent cache
- Argo Workflows orchestrates the multi-step build pipeline
- Argo Events watches the image manifest ConfigMap for changes
- Translator script converts DHI YAML into Dockerfiles using `yq`

**Domain**: Images pushed to `harbor.<DOMAIN>/dhi/<image-name>:<tag>`

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). CHANGEME tokens in
> manifests are replaced at deploy time by `_subst_changeme()`.

---

## Architecture

### High-Level Architecture

```
                      ┌──────────────────────┐
                      │   Image Manifest      │
                      │   (ConfigMap)          │
                      │   dhi-image-manifest   │
                      └──────────┬─────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
              (ConfigMap change)        (Daily 02:00 UTC)
                    │                         │
             ┌──────┴──────┐          ┌───────┴───────┐
             │ Argo Events │          │ CronWorkflow  │
             │ EventSource │          │ dhi-daily-scan│
             │  + Sensor   │          └───────┬───────┘
             └──────┬──────┘                  │
                    │                         │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │   Argo Workflow          │
                    │   dhi-build-pipeline     │
                    │                          │
                    │  ┌────────────────────┐  │
                    │  │ 1. parse-manifest  │  │
                    │  │    (read YAML)     │  │
                    │  └────────┬───────────┘  │
                    │           │               │
                    │  ┌────────┴───────────┐  │
                    │  │ Per image (fan-out) │  │
                    │  │                    │  │
                    │  │ 2. check-harbor    │  │
                    │  │    (crane)         │  │
                    │  │       │            │  │
                    │  │  [not found?]      │  │
                    │  │       │            │  │
                    │  │ 3. translate       │  │
                    │  │    (DHI→Dockerfile)│  │
                    │  │       │            │  │
                    │  │ 4. build-and-push  │  │
                    │  │    (buildctl)      │  │
                    │  └────────────────────┘  │
                    └──────────────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
             ┌──────┴──────┐          ┌───────┴───────┐
             │  BuildKit   │          │    Harbor      │
             │  Daemon     │          │    Registry    │
             │  (rootless) │          │  dhi/ project  │
             │  port 1234  │          │                │
             └─────────────┘          └────────────────┘
```

### Build Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Parse Manifest                                               │
│    Read dhi-image-manifest ConfigMap, extract image list         │
└──────────────────────────┬──────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. For Each Image (parallel fan-out)                            │
│                                                                  │
│    a. check-harbor: crane manifest harbor.<DOMAIN>/dhi/name:tag │
│       → exists: skip (no build needed)                           │
│       → not-found: continue to build                             │
│                                                                  │
│    b. translate: Run translate.sh on catalog YAML                │
│       → Reads DHI spec (base, packages, user, hardening)         │
│       → Generates Dockerfile to /workspace/Dockerfile            │
│                                                                  │
│    c. build-and-push: buildctl via BuildKit daemon               │
│       → buildctl --addr tcp://buildkitd:1234 build              │
│       → --output type=image,name=harbor.<DOMAIN>/dhi/name:tag   │
│       → Image is built and pushed in one step                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Components

| Component | Type | Namespace | Purpose |
|-----------|------|-----------|---------|
| **buildkitd** | StatefulSet | dhi-builder | Rootless BuildKit daemon for image builds |
| **dhi-build-pipeline** | WorkflowTemplate | dhi-builder | Argo Workflow orchestrating the build steps |
| **dhi-daily-scan** | CronWorkflow | dhi-builder | Daily rebuild trigger at 02:00 UTC |
| **dhi-manifest-watcher** | EventSource | argocd | Watches image manifest ConfigMap for changes |
| **dhi-build-trigger** | Sensor | argocd | Triggers workflow on manifest changes |
| **dhi-translator-scripts** | ConfigMap | dhi-builder | Shell script to convert DHI YAML to Dockerfile |
| **dhi-image-manifest** | ConfigMap | dhi-builder | Registry of images to build with catalog references |
| **harbor-push-credentials** | Secret | dhi-builder | Docker config for pushing to Harbor |

---

## Prerequisites

1. **Harbor** deployed and accessible at `harbor.<DOMAIN>` with a `dhi` project created
2. **Argo Workflows** controller deployed (provides WorkflowTemplate and CronWorkflow CRDs)
3. **Argo Events** controller deployed (provides EventSource and Sensor CRDs)
4. **Persistent storage** available for BuildKit cache (50Gi PVC)
5. **Node pool** with `workload-type: general` label for BuildKit scheduling

---

## Directory Structure

```
services/dhi-builder/
├── README.md                              # This file
├── namespace.yaml                         # dhi-builder namespace
├── rbac.yaml                              # ServiceAccount, Role, RoleBinding, ClusterRole
├── secret.yaml                            # Harbor push credentials (CHANGEME tokens)
├── image-manifest.yaml                    # ConfigMap with image build registry
├── kustomization.yaml                     # Kustomize resource aggregation
├── buildkit/
│   ├── pvc.yaml                           # 50Gi PVC for BuildKit cache
│   ├── statefulset.yaml                   # BuildKit daemon (rootless, port 1234)
│   └── service.yaml                       # ClusterIP service for BuildKit gRPC
├── argo-events/
│   ├── eventsource.yaml                   # Watches dhi-builder ConfigMaps
│   └── sensor.yaml                        # Triggers workflow on manifest change
├── argo-workflows/
│   ├── workflow-template.yaml             # Multi-step build pipeline template
│   └── cron-workflow.yaml                 # Daily rebuild at 02:00 UTC
├── translator/
│   └── configmap-scripts.yaml             # translate.sh script (DHI YAML → Dockerfile)
└── catalog/
    ├── README.md                          # Guide on vendoring DHI definitions
    └── nginx/
        └── alpine-mainline.yaml           # Example: nginx Alpine hardened image spec
```

---

## User Workflow: Adding a New Hardened Image

Follow these 5 steps to add a new hardened image to the pipeline:

### Step 1: Vendor the DHI YAML Definition

Copy the DHI catalog YAML into the `catalog/` directory:

```bash
mkdir -p services/dhi-builder/catalog/redis/
cp /path/to/dhi-catalog/image/redis/alpine/7.yaml \
   services/dhi-builder/catalog/redis/alpine-7.yaml
```

### Step 2: Register in the Image Manifest

Edit `services/dhi-builder/image-manifest.yaml` to add the new image:

```yaml
data:
  manifest.yaml: |
    images:
      - name: nginx
        tag: "1.27.0-alpine3.20"
        catalog: nginx/alpine-mainline.yaml
        platforms: ["linux/amd64"]
      - name: redis
        tag: "7.2.6-alpine3.20"
        catalog: redis/alpine-7.yaml
        platforms: ["linux/amd64"]
```

### Step 3: Commit and Push

```bash
git add services/dhi-builder/catalog/redis/
git add services/dhi-builder/image-manifest.yaml
git commit -m "Add redis hardened image to DHI pipeline"
git push
```

### Step 4: ArgoCD Syncs the Changes

ArgoCD detects the updated manifests and applies them to the cluster. The
updated ConfigMap triggers the Argo Events sensor.

### Step 5: Verify the Build

Monitor the Argo Workflow:

```bash
# List running workflows
kubectl -n dhi-builder get workflows

# Watch workflow progress
kubectl -n dhi-builder get workflow -w

# Check workflow logs
argo -n dhi-builder logs @latest

# Verify image in Harbor
crane catalog harbor.<DOMAIN>/dhi/redis --insecure
```

---

## Configuration Reference

### Image Manifest Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Image name (used as Harbor repository path: `dhi/<name>`) |
| `tag` | string | Image tag (e.g., `1.27.0-alpine3.20`) |
| `catalog` | string | Path to DHI YAML in `catalog/` directory |
| `platforms` | list | Target platforms (e.g., `["linux/amd64"]`) |

### DHI YAML Spec Fields

| Field | Type | Description |
|-------|------|-------------|
| `spec.base` | string | Base image (e.g., `alpine:3.20`) |
| `spec.packages` | list | Packages to install with version pinning |
| `spec.user.name` | string | Non-root username |
| `spec.user.uid` | int | User ID |
| `spec.user.gid` | int | Group ID |
| `spec.expose` | list | Ports to expose |
| `spec.entrypoint` | list | Container entrypoint command |
| `spec.hardening.removeShells` | bool | Remove shell binaries from image |
| `spec.hardening.readOnlyRootfs` | bool | Make root filesystem read-only |
| `spec.hardening.noNewPrivileges` | bool | Strip setuid/setgid bits |

### CHANGEME Tokens

These tokens are replaced at deploy time by `_subst_changeme()`:

| Token | Replaced With | Used In |
|-------|---------------|---------|
| `CHANGEME_DOMAIN` | Root domain (e.g., `example.com`) | secret.yaml, workflow-template.yaml |
| `CHANGEME_HARBOR_ADMIN_PASSWORD` | Harbor admin password | secret.yaml |
| `CHANGEME_GIT_BASE_URL` | Git base URL for ArgoCD | ArgoCD Application |

---

## Troubleshooting

### Build Workflow Fails at check-harbor Step

**Symptom**: The `check-harbor` step fails with connection errors.

**Cause**: Harbor is not accessible from within the dhi-builder namespace, or credentials are invalid.

**Solution**:
1. Verify Harbor is running:
   ```bash
   kubectl -n harbor get pods
   ```
2. Test connectivity:
   ```bash
   kubectl -n dhi-builder run debug --rm -it --image=curlimages/curl -- \
     curl -k https://harbor.<DOMAIN>/api/v2.0/systeminfo
   ```
3. Check credentials:
   ```bash
   kubectl -n dhi-builder get secret harbor-push-credentials -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
   ```

### BuildKit Connection Refused

**Symptom**: The `build-and-push` step fails with `could not connect to buildkitd`.

**Cause**: The BuildKit StatefulSet is not running or the service is misconfigured.

**Solution**:
1. Check BuildKit pod status:
   ```bash
   kubectl -n dhi-builder get pods -l app=buildkitd
   kubectl -n dhi-builder logs statefulset/buildkitd
   ```
2. Verify service:
   ```bash
   kubectl -n dhi-builder get svc buildkitd
   kubectl -n dhi-builder get endpoints buildkitd
   ```
3. Test gRPC connectivity:
   ```bash
   kubectl -n dhi-builder run debug --rm -it --image=moby/buildkit:v0.18.2 -- \
     buildctl --addr tcp://buildkitd:1234 debug workers
   ```

### Translator Fails to Parse YAML

**Symptom**: The `translate` step fails with yq errors.

**Cause**: The DHI YAML file is malformed or missing required fields.

**Solution**:
1. Validate the catalog YAML:
   ```bash
   yq '.' services/dhi-builder/catalog/<image>/<file>.yaml
   ```
2. Ensure all required fields are present (`spec.base`, `spec.packages`, `spec.user`)
3. Check the ConfigMap contains the script:
   ```bash
   kubectl -n dhi-builder get configmap dhi-translator-scripts -o yaml
   ```

### CronWorkflow Not Triggering

**Symptom**: No daily builds appear at 02:00 UTC.

**Cause**: The CronWorkflow may be suspended or the Argo Workflows controller is not watching the dhi-builder namespace.

**Solution**:
1. Check CronWorkflow status:
   ```bash
   kubectl -n dhi-builder get cronworkflow dhi-daily-scan
   kubectl -n dhi-builder describe cronworkflow dhi-daily-scan
   ```
2. Verify Argo Workflows controller is running:
   ```bash
   kubectl -n argo get pods -l app=workflow-controller
   ```
3. Manually trigger a test run:
   ```bash
   argo -n dhi-builder submit --from cronwf/dhi-daily-scan
   ```

### EventSource Not Detecting ConfigMap Changes

**Symptom**: Updating `image-manifest.yaml` does not trigger a build.

**Cause**: The EventSource may lack permissions to watch ConfigMaps in the dhi-builder namespace.

**Solution**:
1. Check EventSource status:
   ```bash
   kubectl -n argocd get eventsource dhi-manifest-watcher
   kubectl -n argocd describe eventsource dhi-manifest-watcher
   ```
2. Check Sensor status:
   ```bash
   kubectl -n argocd get sensor dhi-build-trigger
   kubectl -n argocd describe sensor dhi-build-trigger
   ```
3. Verify RBAC allows the EventSource to watch ConfigMaps:
   ```bash
   kubectl auth can-i watch configmaps --as=system:serviceaccount:argocd:default -n dhi-builder
   ```

---

## Dependencies

| Service | Purpose | Deployment Order |
|---------|---------|------------------|
| **Harbor** | Target registry for built images | Deploy before DHI Builder |
| **Argo Workflows** | Workflow orchestration engine | Deploy before DHI Builder |
| **Argo Events** | Event-driven trigger system | Deploy before DHI Builder |
| **BuildKit** | Container image builder (deployed as part of DHI Builder) | Included |
| **ArgoCD** | GitOps sync for manifest changes | Pre-existing |

---

## Related Documentation

- **Harbor setup**: `../harbor/README.md`
- **Argo configuration**: `../argo/README.md`
- **Cluster architecture**: `../../docs/`
- **DHI catalog format**: `catalog/README.md`
- **BuildKit documentation**: https://github.com/moby/buildkit
- **Argo Workflows documentation**: https://argo-workflows.readthedocs.io/

---

**Last updated**: 2026-02-18
