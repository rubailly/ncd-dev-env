#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && set -o allexport && source .env && set +o allexport

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
NCD_ENCOUNTER_TYPE_NAME_ENCODED="NCD+Community+Screening"

existing=$(omrs_get "encountertype?q=${NCD_ENCOUNTER_TYPE_NAME_ENCODED}" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")

if [ -z "$existing" ]; then
  echo "  Creating NCD encounter type..."
  omrs_post "encountertype" "{
    \"name\": \"${NCD_ENCOUNTER_TYPE_NAME}\",
    \"description\": \"Community-based NCD (hypertension and diabetes) screening encounter\"
  }" > /dev/null || true
  echo "  ✓ Encounter type created."
  # Resolve the auto-generated UUID
  existing=$(omrs_get "encountertype?q=${NCD_ENCOUNTER_TYPE_NAME_ENCODED}" \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")
fi

if [ -n "$existing" ]; then
  echo "  ✓ Encounter type UUID: ${existing}"
  NCD_ENCOUNTER_TYPE_UUID="$existing"
  echo "$existing" > "${GENERATED_DIR}/ncd-encounter-type-uuid.txt"
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

# ── Update rw-facility-routing collection with real location UUIDs ─────────────
# Map each OpenMRS location UUID to its corresponding health center.
# This allows Job 3 to look up the health center from the encounter's location.
if [ -f "${GENERATED_DIR}/openfn-token.txt" ]; then
  echo "  Updating rw-facility-routing collection with local location UUIDs..."
  python3 - <<PYEOF
import json, subprocess, pathlib

token = pathlib.Path("${GENERATED_DIR}/openfn-token.txt").read_text().strip()
loc_uuids = json.loads(pathlib.Path("${GENERATED_DIR}/location-uuids.json").read_text())

# Maps location name → health center config (for local dev testing)
location_to_hc = {
    "Kamonyi Community Site A":    {"fossa_code":"4/1/5/2","hc_name":"Kamonyi Health Center","district":"Kamonyi","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788100001"},
    "Kamonyi Community Site B":    {"fossa_code":"4/1/5/4","hc_name":"Gacurabwenge Health Center","district":"Kamonyi","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788100002"},
    "Rusizi Community Site A":     {"fossa_code":"2/7/3/1","hc_name":"Gihundwe Health Center","district":"Rusizi","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788200001"},
    "Rusizi Community Site B":     {"fossa_code":"2/7/3/3","hc_name":"Kamembe Health Center","district":"Rusizi","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788200002"},
    "Nyamasheke Community Site A": {"fossa_code":"2/6/4/1","hc_name":"Nyamasheke Health Center","district":"Nyamasheke","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788300001"},
    "Nyamasheke Community Site B": {"fossa_code":"2/6/4/3","hc_name":"Shangi Health Center","district":"Nyamasheke","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788300002"},
    "Karongi Community Site A":    {"fossa_code":"2/4/2/1","hc_name":"Karongi Health Center","district":"Karongi","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788400001"},
    "Karongi Community Site B":    {"fossa_code":"2/4/2/3","hc_name":"Bwishyura Health Center","district":"Karongi","erp_base_url":"http://erpnext-backend:8000","hc_whatsapp":"+250788400002"},
}

for loc_name, loc_uuid in loc_uuids.items():
    if loc_name not in location_to_hc:
        continue
    hc = location_to_hc[loc_name]
    r = subprocess.run([
        "curl", "-sf", "-X", "PUT",
        f"http://localhost:4000/collections/rw-facility-routing/{loc_uuid}",
        "-H", "Content-Type: application/json",
        "-H", f"Authorization: Bearer {token}",
        "-d", json.dumps({"value": json.dumps(hc)}),
    ], capture_output=True, text=True)
    status = "ok" if r.returncode == 0 else r.stderr[:40]
    print(f"  {loc_name} ({loc_uuid[:8]}...): {status}")

print("  ✓ rw-facility-routing updated with local OpenMRS location UUIDs.")
PYEOF
fi

# ── Update ncd-screening-config with encounter type UUID ──────────────────────
if [ -f "${GENERATED_DIR}/openfn-token.txt" ] && [ -f "${GENERATED_DIR}/ncd-encounter-type-uuid.txt" ]; then
  TOKEN=$(cat "${GENERATED_DIR}/openfn-token.txt")
  ET_UUID=$(cat "${GENERATED_DIR}/ncd-encounter-type-uuid.txt")
  curl -sf -X PUT "http://localhost:4000/collections/ncd-screening-config/encounter-type-uuid" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d "{\"value\": \"${ET_UUID}\"}" > /dev/null && echo "  ✓ Encounter type UUID saved to collection."
fi

# ── NCD Community Screening Form (O3 / React SPA) ────────────────────────────
echo "  Setting up NCD Community Screening form..."

SYSTOLIC_UUID=$(omrs_get "concept?q=Systolic+blood+pressure&limit=1&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '5085AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 2>/dev/null || echo "5085AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
DIASTOLIC_UUID=$(omrs_get "concept?q=Diastolic+blood+pressure&limit=1&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '5086AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 2>/dev/null || echo "5086AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
GLUCOSE_UUID=$(omrs_get "concept?q=Blood+glucose&limit=1&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '887AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')" 2>/dev/null || echo "887AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

FORM_UUID=$(omrs_get "form?q=NCD+Community+Screening&v=default" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['results'][0]['uuid'] if r['results'] else '')" 2>/dev/null || echo "")

if [ -z "$FORM_UUID" ]; then
  FORM_UUID=$(omrs_post "form" "{
    \"name\": \"NCD Community Screening\",
    \"version\": \"1.0\",
    \"published\": true,
    \"encounterType\": \"${NCD_ENCOUNTER_TYPE_UUID}\",
    \"description\": \"Community NCD screening — records blood pressure and blood glucose for referral\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
  [ -n "$FORM_UUID" ] && echo "  ✓ Form created: ${FORM_UUID}" || echo "  ✗ Failed to create form."
else
  echo "  ✓ Form already exists: ${FORM_UUID}"
fi

if [ -n "$FORM_UUID" ]; then
  existing_resource=$(omrs_get "form/${FORM_UUID}/resource" \
    | python3 -c "
import sys,json
r=json.load(sys.stdin)
# Only count if the JSON schema resource exists (not stale html resource)
hits = [x for x in r.get('results',[]) if x.get('name')=='JSON schema']
print(hits[0]['uuid'] if hits else '')
" 2>/dev/null || echo "")

  if [ -z "$existing_resource" ]; then
    python3 - <<PYEOF
import json, subprocess, uuid, pathlib

systolic  = "${SYSTOLIC_UUID}"
diastolic = "${DIASTOLIC_UUID}"
glucose   = "${GLUCOSE_UUID}"
form_uuid = "${FORM_UUID}"
omrs_user = "${OPENMRS_USER}"
omrs_pass = "${OPENMRS_PASS}"
omrs_url  = "${OPENMRS_URL}"

# Build schema from template, substituting concept UUIDs
schema_str = pathlib.Path("config/ncd-screening-form.json").read_text()
schema_str = schema_str.replace("__SYSTOLIC_UUID__",  systolic)
schema_str = schema_str.replace("__DIASTOLIC_UUID__", diastolic)
schema_str = schema_str.replace("__GLUCOSE_UUID__",   glucose)

# The O3 form engine requires the schema to be stored in clob_datatype_storage
# and referenced by UUID from the form_resource (same pattern as shipped forms).
clob_uuid = str(uuid.uuid4())
escaped   = schema_str.replace("\\\\", "\\\\\\\\").replace("'", "\\\\'")

sql = (
    f"INSERT INTO clob_datatype_storage (uuid, value) VALUES ('{clob_uuid}', '{escaped}');\n"
    f"SELECT uuid, LEFT(value,40) FROM clob_datatype_storage WHERE uuid='{clob_uuid}';"
)
r = subprocess.run(
    ["docker", "compose", "exec", "-T", "openmrs-db",
     "mysql", "-u", "openmrs", "-popenmrs", "openmrs"],
    input=sql, capture_output=True, text=True
)
if "clob_uuid" in r.stdout or clob_uuid[:8] in r.stdout:
    print(f"  ✗ Unexpected output inserting clob: {r.stdout[:80]}")
else:
    # Create form resource pointing at the clob
    payload = json.dumps({
        "name": "JSON schema",
        "valueReference": clob_uuid,
        "datatypeClassname": "AmpathJsonSchema",
    })
    r2 = subprocess.run([
        "curl", "-sf", "-u", f"{omrs_user}:{omrs_pass}",
        "-H", "Content-Type: application/json",
        "-d", payload,
        f"{omrs_url}/ws/rest/v1/form/{form_uuid}/resource",
    ], capture_output=True, text=True)
    if r2.returncode == 0:
        print("  ✓ Form JSON schema uploaded.")
    else:
        print(f"  ✗ Resource upload failed: {r2.stderr[:80]}")
PYEOF
  else
    echo "  ✓ Form JSON schema already exists."
  fi
fi

echo "  ✓ OpenMRS setup complete."
