#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && export $(grep -v '^#' .env | xargs)

OPENFN_URL="http://localhost:4000"
ADMIN_EMAIL="${OPENFN_ADMIN_EMAIL:-admin@local.dev}"
ADMIN_PASS="${OPENFN_ADMIN_PASSWORD:-openfn_local_password}"
GENERATED_DIR="config/generated"
mkdir -p "$GENERATED_DIR"

# ── Wait for OpenFn Lightning to be ready ────────────────────────────────────
echo "  Waiting for OpenFn Lightning..."
until curl -sf "${OPENFN_URL}/health" | grep -q "ok" 2>/dev/null || \
      curl -sf "${OPENFN_URL}" | grep -q "Lightning" 2>/dev/null; do
  printf "."
  sleep 5
done
echo ""
echo "  OpenFn Lightning is ready."

# ── Authenticate and get API token ───────────────────────────────────────────
echo "  Authenticating with OpenFn Lightning..."

TOKEN_RESPONSE=$(curl -sf -X POST "${OPENFN_URL}/api/v1/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"email\": \"${ADMIN_EMAIL}\", \"password\": \"${ADMIN_PASS}\"}" 2>/dev/null || echo "")

if [ -z "$TOKEN_RESPONSE" ]; then
  echo "  Could not authenticate. OpenFn Lightning may need manual user creation."
  echo "  Visit ${OPENFN_URL} → create account with:"
  echo "    Email: ${ADMIN_EMAIL}"
  echo "    Password: ${ADMIN_PASS}"
  echo "  Then re-run 'make setup-openfn'."
  exit 0
fi

API_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
echo "$API_TOKEN" > "${GENERATED_DIR}/openfn-token.txt"
echo "  ✓ Authenticated. Token saved to ${GENERATED_DIR}/openfn-token.txt"

AUTH_HEADER="Authorization: Bearer ${API_TOKEN}"

# ── Create or find the project ───────────────────────────────────────────────
echo "  Creating OpenFn project..."

PROJECT_RESPONSE=$(curl -sf -X POST "${OPENFN_URL}/api/v1/projects" \
  -H "Content-Type: application/json" \
  -H "${AUTH_HEADER}" \
  -d '{"project": {"name": "NCD Community Referral", "description": "Routes high NCD screening readings from OpenMRS to E-Buzima health centers"}}' 2>/dev/null || echo "")

PROJECT_ID=$(echo "$PROJECT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))" 2>/dev/null || echo "")
echo "$PROJECT_ID" > "${GENERATED_DIR}/openfn-project-id.txt"
echo "  ✓ Project ID: ${PROJECT_ID}"

# ── Upload Collections ────────────────────────────────────────────────────────
echo "  Uploading Collections..."

WORKFLOW_DIR="../ncd-community-referral"
if [ ! -d "$WORKFLOW_DIR" ]; then
  WORKFLOW_DIR="."
  echo "  Warning: ../ncd-community-referral not found. Looking for seed files in current directory."
fi

# ncd-screening-config
COLLECTION_PAYLOAD=$(cat "${WORKFLOW_DIR}/seed/ncd-screening-config.json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps({'collection': {'name': 'ncd-screening-config'}}))
")

curl -sf -X POST "${OPENFN_URL}/api/v1/collections" \
  -H "Content-Type: application/json" \
  -H "${AUTH_HEADER}" \
  -d "$COLLECTION_PAYLOAD" > /dev/null 2>&1 || echo "  (collection may already exist)"

# Upload the conditions key
CONDITIONS_VALUE=$(cat "${WORKFLOW_DIR}/seed/ncd-screening-config.json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps({'value': data['value']}))
")

curl -sf -X PUT "${OPENFN_URL}/api/v1/collections/ncd-screening-config/conditions" \
  -H "Content-Type: application/json" \
  -H "${AUTH_HEADER}" \
  -d "$CONDITIONS_VALUE" > /dev/null && echo "  ✓ ncd-screening-config uploaded"

# rw-facility-routing — substitute local ERPNext URL for all entries
ROUTING_JSON=$(cat "${WORKFLOW_DIR}/seed/rw-facility-routing.json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Replace production erp_base_url with local ERPNext
for key, val in data.items():
    if isinstance(val, dict) and 'erp_base_url' in val:
        val['erp_base_url'] = 'http://erpnext-backend:8000'
print(json.dumps(data, indent=2))
")

# Upload each location entry as its own collection key
echo "$ROUTING_JSON" | python3 - <<'PYEOF'
import sys, json, subprocess, os

routing = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}

# Re-read the file since stdin was consumed
import pathlib
routing_file = pathlib.Path("../ncd-community-referral/seed/rw-facility-routing.json")
if not routing_file.exists():
    routing_file = pathlib.Path("seed/rw-facility-routing.json")

routing = json.loads(routing_file.read_text())
api_token = pathlib.Path("config/generated/openfn-token.txt").read_text().strip()

for loc_uuid, hc_data in routing.items():
    if loc_uuid == "description":
        continue
    hc_data["erp_base_url"] = "http://erpnext-backend:8000"
    r = subprocess.run([
        "curl", "-sf", "-X", "PUT",
        f"http://localhost:4000/api/v1/collections/rw-facility-routing/{loc_uuid}",
        "-H", "Content-Type: application/json",
        "-H", f"Authorization: Bearer {api_token}",
        "-d", json.dumps({"value": hc_data}),
    ], capture_output=True, text=True)
    print(f"  Uploaded routing for {hc_data.get('hc_name','?')}: {r.returncode == 0 and 'ok' or r.stderr[:60]}")
PYEOF

echo "  ✓ OpenFn setup complete."
echo "  Visit ${OPENFN_URL} and log in with ${ADMIN_EMAIL} / ${ADMIN_PASS}"
