# Stream 1 Findings: Root-Level and Index Documentation

Reviewer: Claude Opus 4.6
Date: 2026-02-17
Files reviewed: README.md, DEVELOPERS_GUIDE.md, docs/README.md

---

## README.md

### Finding 1: Terraform variable count says "44 variables"
- File: README.md
- Issue: Line 183 references "44 variables" in the Terraform Infrastructure doc link description. The actual count in cluster/variables.tf is 54 variables. The docs/README.md says "50 variables" at line 18 -- also wrong.
- Line: 183
- Fix: Update to "54 variables" in README.md and docs/README.md

### Finding 2: Mattermost status shows "Manifests ready" instead of "Deployed"
- File: README.md
- Issue: Line 216 lists Mattermost status as "Manifests ready" but Mattermost is fully deployed in Phase 7 of deploy-cluster.sh with automated CNPG PostgreSQL, MinIO, Gateway+HTTPRoute, TLS certs, and HTTPS validation.
- Line: 216
- Fix: Change status to "Deployed"

### Finding 3: Missing airgapped mode in "Platform at a Glance" or Quick Start
- File: README.md
- Issue: Airgapped deployment mode (commit 97c4173) is a significant feature but the Quick Start section does not mention it at all. The README does link to docs/airgapped-mode.md in the Guides & Planning section, but the Quick Start should at least hint at airgapped support.
- Line: 123-139
- Fix: Add a brief note about airgapped mode support to the Quick Start section

### Finding 4: CNPG description in dependency map missing scheduled backups
- File: README.md
- Issue: The CNPG box in the Service Dependency Map (line 66) lists "harbor-pg, kasm-pg, keycloak-pg, mattermost-pg" but does not mention that all 4 CNPG clusters now have scheduled backups (commit 6960bc7). This is a feature worth mentioning.
- Line: 66
- Fix: Update CNPG description in mermaid diagram to include "Scheduled Backups"

### Finding 5: Prerequisites on line 75 list `htpasswd` but check_prerequisites() does not
- File: DEVELOPERS_GUIDE.md (cross-ref README.md line 75 issue in DEVELOPERS_GUIDE)
- Issue: The DEVELOPERS_GUIDE prerequisites (line 75 of the file structure context from README quick-start) mention htpasswd. The check_prerequisites() function in lib.sh only checks: terraform, kubectl, helm, jq, openssl, curl. htpasswd is checked later only if BASIC_AUTH_HTPASSWD is unset. This is not wrong per se, but the README does not mention prerequisites; DEVELOPERS_GUIDE does, and htpasswd is listed there. This is correct as-is.
- Line: N/A
- Fix: No fix needed

### Finding 6: Missing doc link for keycloak-user-management-strategy.md
- File: docs/README.md
- Issue: The file docs/keycloak-user-management-strategy.md exists in the docs/ directory but is not referenced in docs/README.md Design Records & Planning table.
- Line: 69-76
- Fix: Add entry for keycloak-user-management-strategy.md

---

## DEVELOPERS_GUIDE.md

### Finding 7: Prerequisites tool list includes htpasswd but htpasswd is conditionally needed
- File: DEVELOPERS_GUIDE.md
- Issue: Line 75 lists `htpasswd` in prerequisites tools. This is correct because the deploy script uses it when BASIC_AUTH_HTPASSWD is not pre-set. No change needed.
- Line: 75
- Fix: No change needed (htpasswd IS still used)

### Finding 8: File structure missing scripts/ directory
- File: DEVELOPERS_GUIDE.md
- Issue: The file structure tree (lines 18-65) shows cluster/, services/, docs/ but omits the scripts/ directory entirely. This is a significant omission since scripts/ contains deploy-cluster.sh, lib.sh, setup-keycloak.sh, destroy-cluster.sh, upgrade-cluster.sh, prepare-airgapped.sh, and many other critical operational scripts.
- Line: 18-65
- Fix: Add scripts/ directory to the file structure tree

### Finding 9: File structure missing operators/ directory
- File: DEVELOPERS_GUIDE.md
- Issue: The file structure tree omits the operators/ directory which contains the Go source for node-labeler and storage-autoscaler Kubebuilder operators.
- Line: 18-65
- Fix: Add operators/ directory to the file structure tree

### Finding 10: Phase overview text matches source but is missing MariaDB Operator detail
- File: DEVELOPERS_GUIDE.md
- Issue: Line 140 phase overview says Phase 1 includes "cert-manager, CNPG, Redis Operator, Node Labeler, Cluster Autoscaler" but deploy-cluster.sh Phase 1 also includes MariaDB Operator (conditional, for LibreNMS). Minor omission since it's conditional.
- Line: 140
- Fix: Add "(+ MariaDB Operator if LibreNMS enabled)" to Phase 1 description

### Finding 11: docs/engineering/ says "10 comprehensive engineering references" but the count is correct
- File: DEVELOPERS_GUIDE.md
- Issue: Line 50 says "10 comprehensive engineering references" and there are exactly 10 files in docs/engineering/. Correct.
- Line: 50
- Fix: No fix needed

---

## docs/README.md

### Finding 12: Terraform variable count says "50 variables" -- should be 54
- File: docs/README.md
- Issue: Line 18 says "50 variables" for terraform-infrastructure.md description. The actual count in cluster/variables.tf is 54 variables.
- Line: 18
- Fix: Update to "54 variables"

### Finding 13: Security Architecture says "13 clients" for Keycloak OIDC
- File: docs/README.md
- Issue: Line 22 says "Keycloak OIDC (13 clients)". The MEMORY.md says 14 OIDC clients. Need to verify. This may or may not be correct depending on recent additions. Since setup-keycloak.sh is the source of truth, this may need verification but is not verifiable from the files I reviewed. Leaving as-is unless count is clearly wrong.
- Line: 22
- Fix: Defer -- cannot verify exact count from files reviewed

### Finding 14: Missing keycloak-user-management-strategy.md from Design Records table
- File: docs/README.md
- Issue: The file docs/keycloak-user-management-strategy.md exists but is not listed in the Design Records & Planning table (lines 69-76).
- Line: 69-76
- Fix: Add row for Keycloak User Management Strategy

### Finding 15: Terraform Infrastructure internal reference says "44 variables"
- File: docs/engineering/terraform-infrastructure.md
- Issue: Line 44 of that file says "All input variables (44 variables)" -- should be 54. This is in a referenced doc, not in the three target files, so noting for completeness but fixing in the target docs only.
- Line: N/A (separate file)
- Fix: Out of scope for this review stream, but noted

### Finding 16: Airgapped mode design doc status should be updated
- File: docs/README.md
- Issue: Line 71 lists Airgapped Deployment Mode as "Design doc" status. However, commit 97c4173 "Implement full airgapped deployment support" means this is now implemented, not just a design doc. The scripts (prepare-airgapped.sh, AIRGAPPED=true support in lib.sh and deploy-cluster.sh) confirm implementation.
- Line: 71
- Fix: Change status from "Design doc" to "Implemented"

---

## Summary of Fixes to Apply

1. README.md line 183: "44 variables" -> "54 variables"
2. README.md line 216: Mattermost "Manifests ready" -> "Deployed"
3. README.md lines 123-139: Add airgapped mode note to Quick Start
4. README.md line 66: Add scheduled backups mention to CNPG in mermaid diagram
5. DEVELOPERS_GUIDE.md lines 18-65: Add scripts/ and operators/ to file structure tree
6. DEVELOPERS_GUIDE.md line 140: Add MariaDB Operator to Phase 1 description
7. docs/README.md line 18: "50 variables" -> "54 variables"
8. docs/README.md line 71: Airgapped status "Design doc" -> "Implemented"
9. docs/README.md lines 69-76: Add keycloak-user-management-strategy.md entry

---

STATUS: COMPLETE

All 9 fixes have been applied and verified.
