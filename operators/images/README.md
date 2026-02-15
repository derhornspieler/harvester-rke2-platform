# Operator Image Tarballs

Pre-built linux/amd64 container images for custom operators, stored as
compressed Docker tarballs. These solve the chicken-and-egg problem where
operators deploy before Harbor exists:

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

- **Node Labeler** deploys in Phase 1 (Foundation)
- **Storage Autoscaler** deploys in Phase 3 (Monitoring)
- **Harbor** deploys in Phase 4

Without these tarballs, operator pods stay in `ErrImagePull` until Harbor is
available. After Phase 4, `deploy-cluster.sh` calls `push_operator_images()`
which loads the tarballs, pushes them to Harbor, and restarts the operator
deployments so pods recover.

## Files

| File | Image |
|------|-------|
| `node-labeler-v0.1.0-amd64.tar.gz` | `harbor.<DOMAIN>/library/node-labeler:v0.1.0` |
| `storage-autoscaler-v0.1.0-amd64.tar.gz` | `harbor.<DOMAIN>/library/storage-autoscaler:v0.1.0` |

## Rebuilding

From each operator directory:

```bash
cd operators/node-labeler
make docker-save IMG=harbor.<DOMAIN>/library/node-labeler:v0.1.0

cd operators/storage-autoscaler
make docker-save IMG=harbor.<DOMAIN>/library/storage-autoscaler:v0.1.0
```

This builds a linux/amd64 image, then runs `docker save | gzip` into this
directory. Commit the updated tarballs.

## Manual Verification

```bash
docker load -i <(gunzip -c node-labeler-v0.1.0-amd64.tar.gz)
docker load -i <(gunzip -c storage-autoscaler-v0.1.0-amd64.tar.gz)
docker images | grep harbor.<DOMAIN>/library
```
