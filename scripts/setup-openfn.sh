#!/usr/bin/env bash
set -euo pipefail
[ -f .env ] && set -o allexport && source .env && set +o allexport

OPENFN_URL="http://localhost:4000"
ADMIN_EMAIL="${OPENFN_ADMIN_EMAIL:-admin@local.dev}"
GENERATED_DIR="config/generated"
OPENFN_CONTAINER="${OPENFN_CONTAINER:-ncd-dev-env-openfn-1}"
mkdir -p "$GENERATED_DIR"

# ── Wait for OpenFn Lightning to be ready ────────────────────────────────────
echo "  Waiting for OpenFn Lightning..."
until curl -sfL "${OPENFN_URL}" | grep -q "Lightning" 2>/dev/null || \
      curl -sf "${OPENFN_URL}/health_check" -o /dev/null 2>/dev/null; do
  printf "."
  sleep 5
done
echo ""
echo "  OpenFn Lightning is ready."

# ── Generate API token via Lightning runtime ──────────────────────────────────
# Lightning v2.16+ removed the username/password token endpoint.
# PATs are JWT (RS256) that must be generated and stored in user_tokens via RPC.
echo "  Generating API token via Lightning runtime..."

API_TOKEN=$(docker exec "${OPENFN_CONTAINER}" /app/bin/lightning rpc "
  user = Lightning.Repo.get_by!(Lightning.Accounts.User, email: \"${ADMIN_EMAIL}\")
  {token_bin, changeset} = Lightning.Accounts.UserToken.build_token(user, \"api\")
  {:ok, _} = Lightning.Repo.insert(changeset)
  IO.puts(token_bin)
" 2>/dev/null | tail -1)

if [ -z "$API_TOKEN" ]; then
  echo "  ERROR: Could not generate API token. Is ${OPENFN_CONTAINER} running?"
  echo "  If the admin user doesn't exist, visit ${OPENFN_URL} and register"
  echo "  with email ${ADMIN_EMAIL}, then re-run 'make setup-openfn'."
  exit 1
fi

echo "$API_TOKEN" > "${GENERATED_DIR}/openfn-token.txt"
echo "  ✓ Token generated and saved to ${GENERATED_DIR}/openfn-token.txt"

AUTH_HEADER="Authorization: Bearer ${API_TOKEN}"

# ── Create or find the project ───────────────────────────────────────────────
echo "  Creating OpenFn project (if not exists)..."

PROJECT_ID=$(docker exec "${OPENFN_CONTAINER}" /app/bin/lightning rpc "
  alias Lightning.{Repo, Projects}
  import Ecto.Query

  user = Repo.get_by!(Lightning.Accounts.User, email: \"${ADMIN_EMAIL}\")

  existing = Repo.get_by(Lightning.Projects.Project, name: \"ncd-community-referral\")
  project = if existing do
    existing
  else
    {:ok, p} = Projects.create_project(%{
      name: \"ncd-community-referral\",
      description: \"Routes high NCD screening readings from OpenMRS to E-Buzima health centers\",
      project_users: [%{user_id: user.id, role: :owner}]
    })
    p
  end
  IO.puts(project.id)
" 2>/dev/null | tail -1)

echo "$PROJECT_ID" > "${GENERATED_DIR}/openfn-project-id.txt"
echo "  ✓ Project ID: ${PROJECT_ID}"

# ── Create Collections (if not exist) ─────────────────────────────────────────
echo "  Creating Collections (if not exist)..."

docker exec "${OPENFN_CONTAINER}" /app/bin/lightning rpc "
  alias Lightning.{Repo, Collections}

  project = Repo.get_by!(Lightning.Projects.Project, name: \"ncd-community-referral\")

  for cname <- [\"ncd-screening-config\", \"rw-facility-routing\"] do
    case Collections.get_collection(cname) do
      nil ->
        {:ok, _} = Collections.create_collection(%{name: cname, project_id: project.id})
        IO.puts(\"  created: #{cname}\")
      _ ->
        IO.puts(\"  exists: #{cname}\")
    end
  end
" 2>/dev/null

echo "  ✓ Collections ready."

# ── Upload ncd-screening-config ───────────────────────────────────────────────
echo "  Uploading ncd-screening-config..."

WORKFLOW_DIR="../ncd-community-referral"
if [ ! -d "$WORKFLOW_DIR" ]; then
  WORKFLOW_DIR="."
  echo "  Warning: ../ncd-community-referral not found. Looking for seed files in current directory."
fi

# Collections API stores values as JSON-encoded strings (not raw objects)
CONDITIONS_VALUE=$(python3 -c "
import json, pathlib
d = json.loads(pathlib.Path('${WORKFLOW_DIR}/seed/ncd-screening-config.json').read_text())
print(json.dumps({'value': json.dumps(d['value'])}))
")

curl -sf -X PUT "${OPENFN_URL}/collections/ncd-screening-config/conditions" \
  -H "Content-Type: application/json" \
  -H "${AUTH_HEADER}" \
  -d "$CONDITIONS_VALUE" > /dev/null && echo "  ✓ ncd-screening-config/conditions uploaded"

# ── Upload rw-facility-routing ────────────────────────────────────────────────
echo "  Uploading rw-facility-routing (12 health center entries)..."

python3 - <<PYEOF
import json, subprocess, pathlib, sys

routing_file = pathlib.Path("${WORKFLOW_DIR}/seed/rw-facility-routing.json")
routing = json.loads(routing_file.read_text())
api_token = pathlib.Path("${GENERATED_DIR}/openfn-token.txt").read_text().strip()

ok = 0
for loc_uuid, val in routing.items():
    if loc_uuid == "description":
        continue
    val = dict(val)
    val["erp_base_url"] = "http://erpnext-frontend:8080"
    r = subprocess.run([
        "curl", "-sf", "-X", "PUT",
        f"${OPENFN_URL}/collections/rw-facility-routing/{loc_uuid}",
        "-H", "Content-Type: application/json",
        "-H", f"Authorization: Bearer {api_token}",
        "-d", json.dumps({"value": json.dumps(val)}),
    ], capture_output=True, text=True)
    if r.returncode == 0:
        ok += 1
        print(f"  ✓ {val.get('hc_name','?')} ({loc_uuid})")
    else:
        print(f"  ✗ {val.get('hc_name','?')}: {r.stderr[:80]}", file=sys.stderr)

print(f"  {ok} entries uploaded.")
PYEOF

# ── Create credentials (if not exist) ────────────────────────────────────────
echo "  Creating credentials (if not exist)..."

API_KEY=$(python3 -c "import json; d=json.load(open('${GENERATED_DIR}/erpnext-api-credentials.json')); print(d['api_key'])" 2>/dev/null || echo "")
API_SECRET=$(python3 -c "import json; d=json.load(open('${GENERATED_DIR}/erpnext-api-credentials.json')); print(d['api_secret'])" 2>/dev/null || echo "")

OPENMRS_PASSWORD="${OPENMRS_ADMIN_PASSWORD:-Admin123}"

docker exec "${OPENFN_CONTAINER}" /app/bin/lightning rpc "
  import Ecto.Query
  alias Lightning.{Repo, Credentials}

  user = Repo.get_by!(Lightning.Accounts.User, email: \"${ADMIN_EMAIL}\")
  project = Repo.get_by!(Lightning.Projects.Project, name: \"ncd-community-referral\")

  cred_defs = [
    {\"OpenMRS\", %{\"instanceUrl\" => \"http://openmrs:8080/openmrs\", \"username\" => \"admin\", \"password\" => \"${OPENMRS_PASSWORD}\"}},
    {\"EBuzima API\", %{\"api_key\" => \"${API_KEY}\", \"api_secret\" => \"${API_SECRET}\", \"baseUrl\" => \"http://erpnext-frontend:8080\"}},
    {\"WhatsApp Meta API\", %{\"accessToken\" => \"test-token\", \"phoneNumberId\" => \"123456789\", \"baseUrl\" => \"http://mock-whatsapp:9000\"}}
  ]

  for {name, body} <- cred_defs do
    case Repo.get_by(Lightning.Credentials.Credential, name: name) do
      nil ->
        {:ok, cred} = Credentials.create_credential(%{
          name: name,
          schema: \"raw\",
          user_id: user.id,
          body: body,
          project_credentials: [%{project_id: project.id}]
        })
        IO.puts(\"  created: #{name} (#{cred.id})\")
      existing ->
        IO.puts(\"  exists: #{name} (#{existing.id})\")
    end
  end
" 2>/dev/null

echo "  ✓ Credentials ready."
echo "  ✓ OpenFn setup complete."
echo "  Visit ${OPENFN_URL} and log in with ${ADMIN_EMAIL}"
