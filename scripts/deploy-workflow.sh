#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && export $(grep -v '^#' .env | xargs)

WORKFLOW_DIR="${WORKFLOW_DIR:-../ncd-community-referral}"
GENERATED_DIR="config/generated"

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "ERROR: Workflow directory not found at ${WORKFLOW_DIR}"
  echo "Clone ncd-community-referral alongside this repo, or set WORKFLOW_DIR= in .env"
  exit 1
fi

# Patch concept UUIDs in the Collection if resolved UUIDs differ from defaults
if [ -f "${GENERATED_DIR}/concept-uuids.json" ]; then
  echo "  Patching ncd-screening-config with resolved concept UUIDs..."
  python3 - <<PYEOF
import json, subprocess, pathlib

concepts = json.loads(pathlib.Path("${GENERATED_DIR}/concept-uuids.json").read_text())
token = pathlib.Path("${GENERATED_DIR}/openfn-token.txt").read_text().strip()

conditions = [
    {
        "name": "Hypertension",
        "obs": [
            {"concept_uuid": concepts["systolic_bp"],  "label": "Systolic blood pressure", "threshold": 140},
            {"concept_uuid": concepts["diastolic_bp"], "label": "Diastolic blood pressure", "threshold": 90},
        ],
    },
    {
        "name": "Diabetes",
        "obs": [
            {"concept_uuid": concepts["fasting_glucose"], "label": "Fasting blood glucose", "threshold": 126},
        ],
    },
]

r = subprocess.run([
    "curl", "-sf", "-X", "PUT",
    "http://localhost:4000/api/v1/collections/ncd-screening-config/conditions",
    "-H", "Content-Type: application/json",
    "-H", f"Authorization: Bearer {token}",
    "-d", json.dumps({"value": conditions}),
], capture_output=True, text=True)

print(f"  ncd-screening-config patched: {'ok' if r.returncode == 0 else r.stderr[:80]}")
PYEOF
fi

# Deploy the workflow with openfn CLI
echo "  Deploying workflow from ${WORKFLOW_DIR}..."

TOKEN=$(cat "${GENERATED_DIR}/openfn-token.txt" 2>/dev/null || echo "")
PROJECT_ID=$(cat "${GENERATED_DIR}/openfn-project-id.txt" 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
  echo "ERROR: No OpenFn token found. Run 'make setup-openfn' first."
  exit 1
fi

cd "$WORKFLOW_DIR"
OPENFN_API_KEY="$TOKEN" \
OPENFN_ENDPOINT="http://localhost:4000" \
npx --yes @openfn/cli deploy \
  -c project.yaml \
  --no-confirm \
  ${PROJECT_ID:+--project-id "$PROJECT_ID"} 2>&1

echo "  ✓ Workflow deployed. Visit http://localhost:4000 to view and run it."
