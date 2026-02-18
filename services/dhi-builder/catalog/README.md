# DHI Catalog - Vendored Image Definitions

This directory contains vendored DHI (Docker Hardened Image) YAML definitions
that describe how to build security-hardened container images.

## Vendoring Process

1. **Clone the DHI catalog repository**:
   ```bash
   git clone https://github.com/docker-hardened-images/catalog.git /tmp/dhi-catalog
   ```

2. **Copy the desired YAML definitions** into this directory, preserving the
   directory structure:
   ```bash
   mkdir -p services/dhi-builder/catalog/nginx/
   cp /tmp/dhi-catalog/image/nginx/alpine/mainline.yaml \
      services/dhi-builder/catalog/nginx/alpine-mainline.yaml
   ```

3. **Register the image in the manifest** by editing
   `services/dhi-builder/image-manifest.yaml`:
   ```yaml
   images:
     - name: nginx
       tag: "1.27.0-alpine3.20"
       catalog: nginx/alpine-mainline.yaml
       platforms: ["linux/amd64"]
   ```

## Naming Conventions

- **Directory**: `<image-name>/` (e.g., `nginx/`, `redis/`, `postgres/`)
- **File**: `<variant>-<stream>.yaml` (e.g., `alpine-mainline.yaml`, `debian-bookworm.yaml`)
- **Flat naming**: If there is only one variant, use `<image-name>.yaml` directly

## Updating Vendored Definitions

When upstream DHI catalog definitions change:

1. Re-clone or pull the latest catalog
2. Copy updated YAML files into this directory
3. Update the image tag in `image-manifest.yaml` if the version changed
4. Commit and push -- the Argo Events sensor will trigger a rebuild automatically

## Schema Reference

Each vendored YAML file follows the `dhi.io/v1 HardenedImage` schema:

```yaml
apiVersion: dhi.io/v1
kind: HardenedImage
metadata:
  name: <unique-identifier>
spec:
  base: <base-image>:<tag>        # Base image to build from
  packages:                        # Packages to install
    - <package>=<version>
  user:                            # Non-root user configuration
    name: <username>
    uid: <uid>
    gid: <gid>
  expose:                          # Ports to expose
    - <port>
  entrypoint: [<cmd>, <args>...]   # Container entrypoint
  hardening:                       # Security hardening options
    removeShells: true|false       # Remove shell binaries
    readOnlyRootfs: true|false     # Make root filesystem read-only
    noNewPrivileges: true|false    # Strip setuid/setgid bits
```
