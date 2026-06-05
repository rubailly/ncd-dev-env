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

echo "Fetching webhook trigger ID..."
WEBHOOK_TRIGGER_ID=$(curl -sf \
  -H "Authorization: Bearer ${TOKEN}" \
  "${OPENFN_URL}/api/projects/${PROJECT_ID}/workflows" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for w in data.get('workflows', []):
    if 'NCD' in w.get('name', ''):
        for t in w.get('triggers', []):
            if t.get('type') == 'webhook':
                print(t['id'])
                break
" 2>/dev/null || echo "")

if [ -z "$WEBHOOK_TRIGGER_ID" ]; then
  echo "Could not find the NCD webhook trigger. Is the project deployed?"
  echo "Run 'make deploy' first, then try again."
  echo ""
  echo "Alternatively, trigger it manually in the OpenFn UI at ${OPENFN_URL}"
  exit 0
fi

echo "Triggering via webhook ${WEBHOOK_TRIGGER_ID}..."
RESULT=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  "${OPENFN_URL}/i/${WEBHOOK_TRIGGER_ID}" \
  -d '{}')
WO_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_order_id','(see UI)'))" 2>/dev/null || echo "(see UI)")
echo "Work order: ${WO_ID}"

echo ""
echo "Watch it run at: ${OPENFN_URL}/projects/${PROJECT_ID}/runs"
