#!/bin/sh
set -e

RANCHER_URL="${RANCHER_URL:-}"
TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
API="https://kubernetes.default.svc"

if [ -z "$RANCHER_URL" ]; then
  echo "[ERROR] RANCHER_URL not set"
  exit 1
fi

# Fetch what /cacerts currently serves
cacerts=$(curl -sf -k "${RANCHER_URL}/cacerts" 2>/dev/null || true)
if [ -z "$cacerts" ] || [ "$cacerts" = "null" ]; then
  echo "[WARN] Could not fetch ${RANCHER_URL}/cacerts — skipping"
  exit 0
fi

# Strip trailing whitespace (matches install.sh behavior)
cacerts=$(printf '%s' "$cacerts" | sed -e 's/[[:space:]]*$//')

# Compute sha256 of what /cacerts returns
actual_hash=$(printf '%s' "$cacerts" | sha256sum | awk '{print $1}')

# Read current CATTLE_CA_CHECKSUM from stv-aggregation secret via K8s API
TOKEN=$(cat "$TOKEN_PATH")
AUTH="Authorization: Bearer ${TOKEN}"

secret_json=$(curl -sf --cacert "$CACERT" -H "$AUTH" \
  "${API}/api/v1/namespaces/cattle-system/secrets/stv-aggregation" 2>/dev/null || true)

if [ -z "$secret_json" ]; then
  echo "[WARN] Could not read stv-aggregation secret — skipping"
  exit 0
fi

# Extract and decode CATTLE_CA_CHECKSUM using jq
stored_hash=$(printf '%s' "$secret_json" | jq -r '.data.CATTLE_CA_CHECKSUM // empty' | base64 -d 2>/dev/null || echo "")

if [ "$stored_hash" = "$actual_hash" ]; then
  echo "[OK] CA checksum is current (${actual_hash})"
  exit 0
fi

echo "[WARN] CA checksum drift detected"
echo "  stored:  ${stored_hash}"
echo "  actual:  ${actual_hash}"

# Build updated secret using jq to replace fields
encoded_hash=$(printf '%s' "$actual_hash" | base64 | tr -d '\n')
encoded_cert=$(printf '%s' "$cacerts" | base64 | tr -d '\n')

updated_json=$(printf '%s' "$secret_json" | jq \
  --arg h "$encoded_hash" \
  --arg c "$encoded_cert" \
  '.data.CATTLE_CA_CHECKSUM = $h | .data["ca.crt"] = $c')

# Replace the secret via PUT
result=$(curl -sf --cacert "$CACERT" -H "$AUTH" \
  -H "Content-Type: application/json" \
  -X PUT -d "$updated_json" \
  "${API}/api/v1/namespaces/cattle-system/secrets/stv-aggregation" 2>&1 || true)

if printf '%s' "$result" | jq -e '.kind == "Secret"' >/dev/null 2>&1; then
  echo "[OK] Replaced stv-aggregation: CATTLE_CA_CHECKSUM + ca.crt updated"
else
  echo "[ERROR] Failed to patch stv-aggregation"
  printf '%s' "$result" | head -c 500
  exit 1
fi

# Clean up failed system-agent-upgrader pods
failed_json=$(curl -sf --cacert "$CACERT" -H "$AUTH" \
  "${API}/api/v1/namespaces/cattle-system/pods?labelSelector=upgrade.cattle.io/plan=system-agent-upgrader&fieldSelector=status.phase=Failed" 2>/dev/null || true)

failed_pods=$(printf '%s' "$failed_json" | jq -r '.items[]?.metadata.name // empty' 2>/dev/null || true)

if [ -n "$failed_pods" ]; then
  count=$(printf '%s\n' "$failed_pods" | wc -l)
  echo "[INFO] Deleting ${count} failed upgrader pods..."
  for pod in $failed_pods; do
    curl -sf --cacert "$CACERT" -H "$AUTH" \
      -X DELETE "${API}/api/v1/namespaces/cattle-system/pods/${pod}" >/dev/null 2>&1 || true
  done
  echo "[OK] Failed pods cleaned up"
fi
