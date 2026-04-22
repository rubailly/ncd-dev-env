#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && export $(grep -v '^#' .env | xargs)

OPENMRS_URL="http://localhost:8080/openmrs"
OPENMRS_USER="admin"
OPENMRS_PASS="${OPENMRS_ADMIN_PASSWORD:-Admin123}"
GENERATED_DIR="config/generated"

post() { curl -sf -u "${OPENMRS_USER}:${OPENMRS_PASS}" -H "Content-Type: application/json" -d "$2" "${OPENMRS_URL}/ws/rest/v1/$1"; }
get()  { curl -sf -u "${OPENMRS_USER}:${OPENMRS_PASS}" "${OPENMRS_URL}/ws/rest/v1/$1"; }

# ── Resolve encounter type UUID ───────────────────────────────────────────────
NCD_ENCOUNTER_TYPE=$(get "encountertype?q=NCD+Community+Screening" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")

if [ -z "$NCD_ENCOUNTER_TYPE" ]; then
  echo "ERROR: NCD encounter type not found. Run 'make setup-openmrs' first."
  exit 1
fi

# ── Get first available location ──────────────────────────────────────────────
LOCATION_UUID=$(get "location?q=Community+Site&limit=1" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")

if [ -z "$LOCATION_UUID" ]; then
  echo "ERROR: No community screening locations found. Run 'make setup-openmrs' first."
  exit 1
fi

echo "Using encounter type: ${NCD_ENCOUNTER_TYPE}"
echo "Using location:       ${LOCATION_UUID}"
echo ""

# ── Concept UUIDs (CIEL standard — present in OpenMRS RefApp) ─────────────────
SYSTOLIC_UUID="5085AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
DIASTOLIC_UUID="5086AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
GLUCOSE_UUID="887AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

# Resolve actual UUIDs from local instance (CIEL codes may differ)
SYSTOLIC_UUID=$(get "concept?q=Systolic+blood+pressure&limit=1&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '5085AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 2>/dev/null || echo "5085AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
DIASTOLIC_UUID=$(get "concept?q=Diastolic+blood+pressure&limit=1&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '5086AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 2>/dev/null || echo "5086AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
GLUCOSE_UUID=$(get "concept?q=Blood+glucose&limit=1&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '887AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 2>/dev/null || echo "887AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

echo "Concepts resolved:"
echo "  Systolic BP:      ${SYSTOLIC_UUID}"
echo "  Diastolic BP:     ${DIASTOLIC_UUID}"
echo "  Blood glucose:    ${GLUCOSE_UUID}"
echo ""

# Save resolved concept UUIDs so deploy-workflow.sh can patch the Collection
cat > "${GENERATED_DIR}/concept-uuids.json" <<JSON
{
  "systolic_bp": "${SYSTOLIC_UUID}",
  "diastolic_bp": "${DIASTOLIC_UUID}",
  "fasting_glucose": "${GLUCOSE_UUID}"
}
JSON

create_patient_and_encounter() {
  local given="$1" family="$2" phone="$3" systolic="$4" diastolic="$5" glucose="$6" description="$7"

  # Create patient
  PATIENT_UUID=$(post "patient" "{
    \"person\": {
      \"names\": [{\"givenName\": \"${given}\", \"familyName\": \"${family}\"}],
      \"gender\": \"M\",
      \"birthdate\": \"1980-01-01\",
      \"attributes\": [{
        \"attributeType\": \"14d4f066-15f5-102d-96e4-000c29c2a5d7\",
        \"value\": \"${phone}\"
      }]
    },
    \"identifiers\": [{
      \"identifier\": \"NCD-$(date +%s%N | tail -c 6)\",
      \"identifierType\": \"05a29f94-c0ed-11e2-94be-8c13b969e334\",
      \"preferred\": true
    }]
  }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

  if [ -z "$PATIENT_UUID" ]; then
    echo "  ✗ Failed to create patient ${given} ${family}"
    return
  fi

  # Create NCD encounter with obs
  local obs_array="[]"
  if [ "$systolic" -gt 0 ]; then
    obs_array=$(python3 -c "
import json
obs = []
if ${systolic} > 0:
    obs.append({'concept': '${SYSTOLIC_UUID}', 'value': ${systolic}})
if ${diastolic} > 0:
    obs.append({'concept': '${DIASTOLIC_UUID}', 'value': ${diastolic}})
if ${glucose} > 0:
    obs.append({'concept': '${GLUCOSE_UUID}', 'value': ${glucose}})
print(json.dumps(obs))
")
  fi

  post "encounter" "{
    \"patient\": \"${PATIENT_UUID}\",
    \"encounterType\": \"${NCD_ENCOUNTER_TYPE}\",
    \"encounterDatetime\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000+0000)\",
    \"location\": \"${LOCATION_UUID}\",
    \"obs\": ${obs_array}
  }" > /dev/null

  echo "  ✓ ${given} ${family} — ${description} (${phone})"
}

echo "Creating test patients and encounters..."
echo ""

# HIGH readings — should trigger referrals
create_patient_and_encounter "Jean" "Habimana"   "+250781000001" 162 98  0   "BP 162/98 → Hypertension referral"
create_patient_and_encounter "Marie" "Uwimana"   "+250781000002" 175 102 0   "BP 175/102 → Hypertension referral"
create_patient_and_encounter "Pierre" "Nkurunziza" "+250781000003" 130 85 148 "Glucose 148 → Diabetes referral"
create_patient_and_encounter "Alice" "Mukamana"  "+250781000004" 155 95  210 "BP + Glucose → Both conditions"
create_patient_and_encounter "Robert" "Bizimana" "+250781000005" 0   0   135 "Glucose 135 → Diabetes referral"

echo ""
# NORMAL readings — should NOT trigger referrals
create_patient_and_encounter "Diane" "Ingabire"  "+250781000006" 118 76  90  "BP 118/76, Glucose 90 → No referral"
create_patient_and_encounter "Claude" "Nzeyimana" "+250781000007" 122 80  0   "BP 122/80 → No referral"

echo ""
echo "✓ Seed complete: 5 patients with high readings + 2 controls."
echo ""
echo "Run 'make deploy' then 'make trigger' to test the full pipeline."
