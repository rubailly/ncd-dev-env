#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && export $(grep -v '^#' .env | xargs)

OPENMRS_URL="http://localhost:8080/openmrs"
OPENMRS_USER="admin"
OPENMRS_PASS="${OPENMRS_ADMIN_PASSWORD:-Admin123}"
AUTH="-u ${OPENMRS_USER}:${OPENMRS_PASS}"
HEADERS='-H "Content-Type: application/json"'
GENERATED_DIR="config/generated"
mkdir -p "$GENERATED_DIR"

# ── Wait for OpenMRS to be ready ─────────────────────────────────────────────
echo "  Waiting for OpenMRS to be ready (this can take 3-5 minutes on first run)..."
until curl -sf $AUTH "${OPENMRS_URL}/ws/rest/v1/session" | grep -q '"authenticated":true'; do
  printf "."
  sleep 10
done
echo ""
echo "  OpenMRS is ready."

# ── Helper ───────────────────────────────────────────────────────────────────
omrs_get() { curl -sf $AUTH "${OPENMRS_URL}/ws/rest/v1/$1"; }
omrs_post() { curl -sf $AUTH -H "Content-Type: application/json" -d "$2" "${OPENMRS_URL}/ws/rest/v1/$1"; }

# ── Encounter type ───────────────────────────────────────────────────────────
NCD_ENCOUNTER_TYPE_UUID="dde00823-5ade-46b6-9e2b-1b52f5339ed1"
NCD_ENCOUNTER_TYPE_NAME="NCD Community Screening"

existing=$(omrs_get "encountertype?q=${NCD_ENCOUNTER_TYPE_NAME}" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")

if [ -z "$existing" ]; then
  echo "  Creating NCD encounter type..."
  omrs_post "encountertype" "{
    \"name\": \"${NCD_ENCOUNTER_TYPE_NAME}\",
    \"description\": \"Community-based NCD (hypertension and diabetes) screening encounter\"
  }" > /dev/null
  echo "  ✓ Encounter type created."
  echo "  NOTE: The encounter type UUID will be auto-generated. Update ncd-screening-config if it differs from ${NCD_ENCOUNTER_TYPE_UUID}."
else
  echo "  ✓ Encounter type already exists (${existing})."
fi

# ── Community screening locations ────────────────────────────────────────────
echo "  Creating community screening locations..."

declare -A LOCATIONS=(
  ["Kamonyi Community Site A"]="Kamonyi"
  ["Kamonyi Community Site B"]="Kamonyi"
  ["Rusizi Community Site A"]="Rusizi"
  ["Rusizi Community Site B"]="Rusizi"
  ["Nyamasheke Community Site A"]="Nyamasheke"
  ["Nyamasheke Community Site B"]="Nyamasheke"
  ["Karongi Community Site A"]="Karongi"
  ["Karongi Community Site B"]="Karongi"
)

echo "{" > "${GENERATED_DIR}/location-uuids.json"
first=true
for loc_name in "${!LOCATIONS[@]}"; do
  existing_loc=$(omrs_get "location?q=${loc_name}&v=default" \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")

  if [ -z "$existing_loc" ]; then
    uuid=$(omrs_post "location" "{
      \"name\": \"${loc_name}\",
      \"description\": \"Community NCD screening site — ${LOCATIONS[$loc_name]}\",
      \"tags\": []
    }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
    echo "  ✓ Created location: ${loc_name} (${uuid})"
  else
    uuid="$existing_loc"
    echo "  ✓ Location already exists: ${loc_name} (${uuid})"
  fi

  [ "$first" = true ] && first=false || echo "," >> "${GENERATED_DIR}/location-uuids.json"
  echo "  \"${loc_name}\": \"${uuid}\"" >> "${GENERATED_DIR}/location-uuids.json"
done
echo "}" >> "${GENERATED_DIR}/location-uuids.json"

echo "  Location UUIDs saved to ${GENERATED_DIR}/location-uuids.json"
echo "  ✓ OpenMRS setup complete."
