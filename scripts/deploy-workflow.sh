#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && set -o allexport && source .env && set +o allexport

# The export in docs/ is the working, deployable spec (credential keys in
# "<owner>-<name>" form, pinned adaptors). Override with PROJECT_SPEC= in .env.
PROJECT_SPEC="${PROJECT_SPEC:-docs/ncd-community-referral-export.yaml}"
GENERATED_DIR="config/generated"

if [ ! -f "$PROJECT_SPEC" ]; then
  echo "ERROR: Project spec not found at ${PROJECT_SPEC}"
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
    "http://localhost:4000/collections/ncd-screening-config/conditions",
    "-H", "Content-Type: application/json",
    "-H", f"Authorization: Bearer {token}",
    "-d", json.dumps({"value": json.dumps(conditions)}),
], capture_output=True, text=True)

print(f"  ncd-screening-config patched: {'ok' if r.returncode == 0 else r.stderr[:80]}")
PYEOF
fi

# Deploy the workflow with openfn CLI
echo "  Deploying workflow from ${PROJECT_SPEC}..."

TOKEN=$(cat "${GENERATED_DIR}/openfn-token.txt" 2>/dev/null || echo "")
PROJECT_ID=$(cat "${GENERATED_DIR}/openfn-project-id.txt" 2>/dev/null || echo "")

if [ -z "$TOKEN" ] || [ -z "$PROJECT_ID" ]; then
  echo "ERROR: No OpenFn token or project ID found. Run 'make setup-openfn' first."
  exit 1
fi

export OPENFN_API_KEY="$TOKEN"
export OPENFN_ENDPOINT="http://localhost:4000"

# Deploying without a state file creates a new project, but the Collections
# belong to the one setup-openfn created. Pull it first to get its state.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$PROJECT_SPEC" "$WORK_DIR/spec.yaml"

# An empty project pulls with a "must provide at least one workflow" warning
# but still writes .state.json, so check for the file rather than the exit code
(cd "$WORK_DIR" && npx --yes @openfn/cli pull "$PROJECT_ID" > pull.log 2>&1) || true
if [ ! -f "$WORK_DIR/.state.json" ]; then
  echo "ERROR: Could not pull project ${PROJECT_ID}:"
  tail -20 "$WORK_DIR/pull.log"
  exit 1
fi

(cd "$WORK_DIR" && npx --yes @openfn/cli deploy \
  -p spec.yaml \
  -s .state.json \
  --no-confirm 2>&1 | tail -3)

echo "  ✓ Workflow deployed. Visit http://localhost:4000/projects/${PROJECT_ID}/w to view and run it."
