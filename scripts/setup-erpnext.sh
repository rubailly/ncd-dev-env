#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && set -o allexport && source .env && set +o allexport

SITE="${ERPNEXT_SITE:-local.ebuzima}"
ADMIN_PASS="${ERPNEXT_ADMIN_PASSWORD:-admin}"
DB_ROOT_PASS="${ERPNEXT_DB_ROOT_PASSWORD:-erpnext_root}"
GENERATED_DIR="config/generated"
BACKEND_CONTAINER="${ERPNEXT_BACKEND_CONTAINER:-ncd-dev-env-erpnext-backend-1}"
mkdir -p "$GENERATED_DIR"

EXEC="docker compose exec -T erpnext-backend"
BASE_URL="http://localhost:8000"

# ── Wait for ERPNext backend to be ready ─────────────────────────────────────
echo "  Waiting for ERPNext backend..."
until $EXEC bench version &>/dev/null; do
  printf "."
  sleep 10
done
echo ""

# ── Create site ───────────────────────────────────────────────────────────────
site_exists=$($EXEC bench --site "$SITE" show-config 2>/dev/null | grep -c "db_host" || echo "0")

if [ "$site_exists" -eq 0 ]; then
  echo "  Creating ERPNext site: ${SITE}..."
  $EXEC bench new-site "$SITE" \
    --db-root-password "$DB_ROOT_PASS" \
    --admin-password "$ADMIN_PASS" \
    --install-app erpnext
  echo "  ✓ Site created."
else
  echo "  ✓ Site ${SITE} already exists."
fi

# ── Install Healthcare app ────────────────────────────────────────────────────
# The healthcare app must be downloaded in the erpnext-backend container.
# NOTE: It is installed into the container's writable layer (not a shared volume).
# After 'docker compose down && docker compose up', re-run 'make setup-erpnext'.
healthcare_in_apps=$($EXEC ls /home/frappe/frappe-bench/apps/ 2>/dev/null | grep -c "^healthcare$" || echo "0")

if [ "$healthcare_in_apps" -eq 0 ]; then
  echo "  Downloading Healthcare app (requires internet access)..."
  $EXEC bench get-app healthcare --branch version-15
  echo "  ✓ Healthcare app downloaded."
fi

healthcare_installed=$($EXEC bench --site "$SITE" list-apps 2>/dev/null | grep -c "healthcare" || echo "0")

if [ "$healthcare_installed" -eq 0 ]; then
  echo "  Installing Healthcare app on site ${SITE}..."
  # Note: install-app may report an error in the after_install hook (create_medical_departments)
  # due to a version mismatch, but the doctypes are installed correctly. Safe to continue.
  $EXEC bench --site "$SITE" install-app healthcare 2>/dev/null || true
  echo "  ✓ Healthcare app installed (Patient and Patient Appointment doctypes available)."
fi

# Restart services so they pick up the newly installed healthcare module
echo "  Restarting ERPNext services to load healthcare module..."
docker compose restart erpnext-backend erpnext-frontend erpnext-scheduler erpnext-worker erpnext-websocket 2>/dev/null || true
sleep 8  # Give services time to restart

# ── Generate API key ─────────────────────────────────────────────────────────
echo "  Generating ERPNext API key for Administrator..."

API_DETAILS=$($EXEC bench --site "$SITE" execute frappe.core.doctype.user.user.generate_keys \
  --args '["Administrator"]' 2>/dev/null | grep -v "^time\|level=" || echo "")

if [ -n "$API_DETAILS" ]; then
  echo "$API_DETAILS" > "${GENERATED_DIR}/erpnext-api-credentials.json"
  API_KEY=$(echo "$API_DETAILS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('api_key',''))" 2>/dev/null || echo "")
  API_SECRET=$(echo "$API_DETAILS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('api_secret',''))" 2>/dev/null || echo "")
  echo "  ✓ API credentials saved to ${GENERATED_DIR}/erpnext-api-credentials.json"
else
  # Fallback: re-read if key was already generated before
  if [ -f "${GENERATED_DIR}/erpnext-api-credentials.json" ]; then
    echo "  ✓ Using existing API credentials from ${GENERATED_DIR}/erpnext-api-credentials.json"
    API_KEY=$(python3 -c "import json; d=json.load(open('${GENERATED_DIR}/erpnext-api-credentials.json')); print(d.get('api_key',''))" 2>/dev/null || echo "")
    API_SECRET=$(python3 -c "import json; d=json.load(open('${GENERATED_DIR}/erpnext-api-credentials.json')); print(d.get('api_secret',''))" 2>/dev/null || echo "")
  fi
fi

AUTH_HEADER="Authorization: token ${API_KEY}:${API_SECRET}"

# ── Create prerequisite Warehouse Types ───────────────────────────────────────
echo "  Ensuring Warehouse Types exist..."
for wt in "Transit" "Finished Goods" "Work In Progress" "Raw Material" "Scrap"; do
  curl -sf -X POST "${BASE_URL}/api/resource/Warehouse%20Type" \
    -H "Content-Type: application/json" \
    -H "${AUTH_HEADER}" \
    -d "{\"doctype\":\"Warehouse Type\",\"name\":\"${wt}\"}" > /dev/null 2>&1 || true
done
echo "  ✓ Warehouse Types ready."

# ── Create health center companies ───────────────────────────────────────────
echo "  Creating health center companies..."

python3 - <<PYEOF
import subprocess, json, urllib.parse, sys

api_key = "${API_KEY}"
api_secret = "${API_SECRET}"
base_url = "${BASE_URL}"
auth_header = f"token {api_key}:{api_secret}"

companies = [
    ("Kamonyi Health Center",    "RW-KM-HC"),
    ("Gacurabwenge Health Center","RW-KM-GC"),
    ("Musambira Health Center",  "RW-KM-MS"),
    ("Gihundwe Health Center",   "RW-RS-GH"),
    ("Kamembe Health Center",    "RW-RS-KM"),
    ("Bugarama Health Center",   "RW-RS-BG"),
    ("Nyamasheke Health Center", "RW-NY-NH"),
    ("Shangi Health Center",     "RW-NY-SH"),
    ("Bushekeri Health Center",  "RW-NY-BK"),
    ("Karongi Health Center",    "RW-KR-KH"),
    ("Bwishyura Health Center",  "RW-KR-BW"),
    ("Gitesi Health Center",     "RW-KR-GT"),
]

for name, abbr in companies:
    r = subprocess.run([
        "curl", "-sf", f"{base_url}/api/resource/Company/{urllib.parse.quote(name)}",
        "-H", f"Authorization: {auth_header}",
    ], capture_output=True, text=True)
    if r.returncode == 0 and '"name"' in r.stdout:
        print(f"  Exists:  {name}")
        continue

    r2 = subprocess.run([
        "curl", "-s", "-X", "POST", f"{base_url}/api/resource/Company",
        "-H", f"Authorization: {auth_header}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"doctype": "Company", "company_name": name, "abbr": abbr,
                          "country": "Rwanda", "default_currency": "RWF"}),
    ], capture_output=True, text=True)
    resp = json.loads(r2.stdout) if r2.stdout else {}
    if "data" in resp:
        print(f"  Created: {name}")
    else:
        print(f"  ERROR:   {name}: {resp.get('exception', r2.stdout)[:80]}", file=sys.stderr)
PYEOF

# ── Add custom fields to Patient and Patient Appointment ─────────────────────
echo "  Adding custom fields to Patient doctype..."

NOW=$(date -u '+%Y-%m-%d %H:%M:%S')
$EXEC bench --site "$SITE" mariadb --execute "
INSERT IGNORE INTO \`tabCustom Field\`
  (name, dt, label, fieldname, fieldtype, creation, modified, modified_by, owner, docstatus)
VALUES
  ('Patient-custom_openmrs_uuid',         'Patient', 'OpenMRS UUID',          'custom_openmrs_uuid',         'Data', '$NOW', '$NOW', 'Administrator', 'Administrator', 0),
  ('Patient-custom_openmrs_id',           'Patient', 'OpenMRS ID',            'custom_openmrs_id',           'Data', '$NOW', '$NOW', 'Administrator', 'Administrator', 0),
  ('Patient-custom_referred_from',        'Patient', 'Referred From',         'custom_referred_from',        'Data', '$NOW', '$NOW', 'Administrator', 'Administrator', 0),
  ('Patient-custom_referral_condition',   'Patient', 'Referral Condition',    'custom_referral_condition',   'Data', '$NOW', '$NOW', 'Administrator', 'Administrator', 0),
  ('Patient Appointment-custom_source',   'Patient Appointment', 'Source',    'custom_source',               'Data', '$NOW', '$NOW', 'Administrator', 'Administrator', 0),
  ('Patient Appointment-custom_fossa_code','Patient Appointment','FOSSA Code','custom_fossa_code',           'Data', '$NOW', '$NOW', 'Administrator', 'Administrator', 0);
" 2>/dev/null

$EXEC bench --site "$SITE" mariadb --execute "
ALTER TABLE \`tabPatient\`
  ADD COLUMN IF NOT EXISTS \`custom_openmrs_uuid\`        varchar(140) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS \`custom_openmrs_id\`          varchar(140) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS \`custom_referred_from\`       varchar(140) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS \`custom_referral_condition\`  text DEFAULT NULL;
ALTER TABLE \`tabPatient Appointment\`
  ADD COLUMN IF NOT EXISTS \`custom_source\`     varchar(140) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS \`custom_fossa_code\` varchar(140) DEFAULT NULL;
" 2>/dev/null

$EXEC bench --site "$SITE" clear-cache 2>/dev/null
echo "  ✓ Custom fields added and cache cleared."

# ── Activate Healthcare domain ────────────────────────────────────────────────
# Healthcare doctypes (Patient, Patient Appointment, etc.) have restrict_to_domain='Healthcare'
# in tabDocType. Frappe's build_doctype_map() filters them out unless 'Healthcare' is in
# tabHas Domain (Domain Settings). Without this, /app/patient shows "Page not found".
echo "  Activating Healthcare domain..."
$EXEC bench --site "$SITE" mariadb --execute "
INSERT IGNORE INTO \`tabHas Domain\`
  (name, parent, parentfield, parenttype, idx, domain, creation, modified, modified_by, owner, docstatus)
VALUES
  ('Healthcare-Domain-Settings', 'Domain Settings', 'active_domains', 'Domain Settings', 1,
   'Healthcare', NOW(), NOW(), 'Administrator', 'Administrator', 0);
" 2>/dev/null
$EXEC bench --site "$SITE" clear-cache 2>/dev/null
echo "  ✓ Healthcare domain activated."

# ── Create Appointment Type and default Practitioner ─────────────────────────
echo "  Creating Appointment Type and Practitioner..."

python3 - <<PYEOF2
import subprocess, json

base_url = "${BASE_URL}"
api_key = "${API_KEY}"
api_secret = "${API_SECRET}"
auth = f"token {api_key}:{api_secret}"

def post(path, body):
    r = subprocess.run(["curl", "-s", "-X", "POST", f"{base_url}{path}",
        "-H", f"Authorization: {auth}", "-H", "Content-Type: application/json",
        "-d", json.dumps(body)], capture_output=True, text=True)
    return json.loads(r.stdout) if r.stdout else {}

# Appointment Type
r = post("/api/resource/Appointment Type", {"appointment_type": "NCD Follow-Up", "duration": 30})
print(f"  Appointment Type: {r.get('data',{}).get('name','exists or created')}")

# Medical Department
r = post("/api/resource/Medical Department", {"department": "General"})
print(f"  Medical Department: {r.get('data',{}).get('name','exists or created')}")

# Healthcare Practitioner
r = post("/api/resource/Healthcare Practitioner",
    {"first_name": "NCD", "last_name": "Screening Team", "department": "General"})
print(f"  Practitioner: {r.get('data',{}).get('name','exists or created')}")
PYEOF2

echo "  ✓ ERPNext setup complete."
echo "  Access ERPNext at http://localhost:8000 (site: ${SITE}, admin: ${ADMIN_PASS})"
