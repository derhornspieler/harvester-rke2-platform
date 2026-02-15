# Rancher Issue: Cluster Autoscaler Nodes Missing Machine Pool Labels

Draft issue for `rancher/rancher` documenting the CAPI label propagation gap.

## Title

Cluster Autoscaler nodes do not inherit custom labels from machine pool configuration

## Description

When using the Rancher cluster autoscaler, nodes created by scaling up a machine pool do not receive custom labels defined in the machine pool's `labels` configuration (e.g., `workload-type=general`). This forces operators to implement external label reconciliation.

### Environment

- Rancher v2.11.x
- RKE2 v1.34.x
- Harvester cloud provider
- Cluster Autoscaler via Rancher cloud provider

### Steps to Reproduce

1. Create an RKE2 cluster with machine pools that have custom labels:
   ```hcl
   machine_pools {
     name = "general"
     labels = {
       "workload-type" = "general"
     }
     # ...
   }
   ```
2. Deploy workloads with `nodeSelector: workload-type: general`
3. Wait for cluster autoscaler to scale up the `general` pool
4. Observe that new nodes created by the autoscaler do **not** have the `workload-type=general` label

### Expected Behavior

Nodes created by the cluster autoscaler should inherit all custom labels from their machine pool configuration, matching the behavior of nodes created during initial provisioning.

### Actual Behavior

New nodes join the cluster without custom labels. Only Kubernetes-standard labels (hostname, arch, os) and CAPI-managed labels (`node.cluster.x-k8s.io/*`) are present.

Pods with `nodeSelector` for custom labels remain Pending even after the autoscaler provisions new nodes, defeating the purpose of autoscaling.

### Root Cause Analysis

The Rancher cluster autoscaler creates new machines via CAPI's MachineDeployment. CAPI propagates labels defined in `MachineDeployment.spec.template.metadata.labels` to Machine objects, but the node bootstrap process (cloud-init / RKE2 agent registration) does not apply these labels to the resulting Kubernetes Node objects.

The `node.cluster.x-k8s.io/*` prefix labels are applied by CAPI's node controller, but arbitrary custom labels from the machine pool config are not included in this reconciliation.

### Workaround

We've implemented two complementary workarounds:

1. **Bash function** (`label_unlabeled_nodes` in deploy scripts): Matches node hostnames against pool name patterns (e.g., `*-general-*` -> `workload-type=general`) and patches labels. Called periodically during deployment.

2. **Kubernetes controller** (`node-labeler` operator): Watches Node create/update events and applies labels based on hostname pattern matching. Runs continuously in the cluster to catch autoscaler-created nodes in real-time.

### Suggested Fix

Rancher should reconcile machine pool labels onto nodes created by the cluster autoscaler. Options:

1. **Rancher cluster agent**: Add a controller that watches for new nodes and applies labels from their corresponding machine pool config
2. **CAPI integration**: Ensure `MachineDeployment.spec.template.metadata.labels` are propagated to Node objects by the CAPI node controller (related: [CAPI Issue #493](https://github.com/kubernetes-sigs/cluster-api/issues/493))
3. **RKE2 agent args**: Pass `--node-label` flags via machine pool cloud-init so labels are applied during node registration

### Related Issues

- [CAPI Issue #493](https://github.com/kubernetes-sigs/cluster-api/issues/493) — Node labels from MachineDeployment
- Rancher autoscaler documentation does not mention this limitation
