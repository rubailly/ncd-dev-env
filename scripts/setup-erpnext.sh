#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && export $(grep -v '^#' .env | xargs)

SITE="${ERPNEXT_SITE:-local.ebuzima}"
ADMIN_PASS="${ERPNEXT_ADMIN_PASSWORD:-admin}"
DB_ROOT_PASS="${ERPNEXT_DB_ROOT_PASSWORD:-erpnext_root}"
GENERATED_DIR="config/generated"
mkdir -p "$GENERATED_DIR"

EXEC="docker compose exec -T erpnext-backend"

# ── Wait for ERPNext backend to be ready ─────────────────────────────────────
echo "  Waiting for ERPNext backend..."
until docker compose exec -T erpnext-backend bench version &>/dev/null; do
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
healthcare_installed=$($EXEC bench --site "$SITE" list-apps 2>/dev/null | grep -c "healthcare" || echo "0")

if [ "$healthcare_installed" -eq 0 ]; then
  echo "  Installing Healthcare app (requires internet access)..."
  $EXEC bench get-app healthcare
  $EXEC bench --site "$SITE" install-app healthcare
  echo "  ✓ Healthcare app installed."
else
  echo "  ✓ Healthcare app already installed."
fi

# ── Create health center companies ───────────────────────────────────────────
echo "  Creating health center companies..."

python3 - <<PYEOF
import subprocess, json

SITE = "${SITE}"
EXEC = "docker compose exec -T erpnext-backend"

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

script = """
import frappe
frappe.init(site='{site}')
frappe.connect()

companies = {companies}
for name, abbr in companies:
    if not frappe.db.exists('Company', name):
        doc = frappe.get_doc({{
            'doctype': 'Company',
            'company_name': name,
            'abbr': abbr,
            'country': 'Rwanda',
            'default_currency': 'RWF',
        }})
        doc.insert(ignore_permissions=True)
        frappe.db.commit()
        print(f'  Created company: {{name}}')
    else:
        print(f'  Company already exists: {{name}}')

frappe.destroy()
""".format(site=SITE, companies=repr(companies))

result = subprocess.run(
    ["docker", "compose", "exec", "-T", "erpnext-backend", "bench", "--site", SITE, "execute", "frappe.core.api.file.list_folder_contents"],
    capture_output=True, text=True
)

# Use bench execute with a Python script file approach
with open('/tmp/create_companies.py', 'w') as f:
    f.write(script)

subprocess.run(["docker", "cp", "/tmp/create_companies.py", "ncd-dev-env-erpnext-backend-1:/tmp/create_companies.py"], check=False)
result = subprocess.run(
    ["docker", "compose", "exec", "-T", "erpnext-backend", "python3", "/tmp/create_companies.py"],
    capture_output=False, text=True
)
PYEOF

# ── Generate API key ─────────────────────────────────────────────────────────
echo "  Generating ERPNext API key for Administrator..."

API_DETAILS=$($EXEC bench --site "$SITE" execute frappe.core.doctype.user.user.generate_keys \
  --args '["Administrator"]' 2>/dev/null || echo "")

if [ -n "$API_DETAILS" ]; then
  echo "$API_DETAILS" > "${GENERATED_DIR}/erpnext-api-credentials.json"
  echo "  ✓ API credentials saved to ${GENERATED_DIR}/erpnext-api-credentials.json"
else
  # Fallback: create via REST API after site is up
  echo "  API key generation skipped — run 'make setup-erpnext' again after ERPNext frontend is ready,"
  echo "  or generate manually at http://localhost:8000 → Administrator → API Access."
fi

echo "  ✓ ERPNext setup complete."
echo "  Access ERPNext at http://localhost:8000 (site: ${SITE}, admin password: ${ADMIN_PASS})"
