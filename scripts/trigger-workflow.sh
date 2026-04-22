#!/usr/bin/env bash
# Manually triggers one run of the NCD Referral Pipeline in local OpenFn.
# Useful for testing without waiting for the 15-minute cron.
set -euo pipefail

GENERATED_DIR="config/generated"
OPENFN_URL="http://localhost:4000"

TOKEN=$(cat "${GENERATED_DIR}/openfn-token.txt" 2>/dev/null || echo "")
PROJECT_ID=$(cat "${GENERATED_DIR}/openfn-project-id.txt" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
  echo "ERROR: No OpenFn token. Run 'make setup-openfn' first."
  exit 1
fi

echo "Fetching workflow ID..."
WORKFLOW_ID=$(curl -sf \
  -H "Authorization: Bearer ${TOKEN}" \
  "${OPENFN_URL}/api/v1/projects/${PROJECT_ID}/workflows" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
workflows = data.get('data', [])
for w in workflows:
    if 'NCD' in w.get('name', ''):
        print(w['id'])
        break
" 2>/dev/null || echo "")

if [ -z "$WORKFLOW_ID" ]; then
  echo "Could not find the NCD workflow. Is the project deployed?"
  echo "Run 'make deploy' first, then try again."
  echo ""
  echo "Alternatively, trigger it manually in the OpenFn UI at ${OPENFN_URL}"
  exit 0
fi

echo "Triggering workflow ${WORKFLOW_ID}..."
curl -sf -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${OPENFN_URL}/api/v1/workflows/${WORKFLOW_ID}/runs" \
  -d '{}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Run started: {d.get(\"data\",{}).get(\"id\",\"(see UI)\")}')"

echo ""
echo "Watch it run at: ${OPENFN_URL}/projects/${PROJECT_ID}/runs"
