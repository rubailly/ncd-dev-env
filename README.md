# NCD Community Referral — Local Development Environment

Spins up OpenMRS, OpenFn Lightning, and ERPNext locally via Docker so you can develop and test the NCD referral integration without relying on any remote instances.

## Prerequisites

- Docker Desktop (or Docker Engine + Compose plugin)
- Node.js 18+ (for `openfn` CLI used in deploy script)
- `ncd-community-referral` repo cloned **alongside** this one:
  ```
  eclipse-workspace/
  ├── ncd-community-referral/   ← the OpenFn workflow project
  └── ncd-dev-env/              ← this repo
  ```

## Services

| Service | URL | Default credentials |
|---|---|---|
| OpenMRS UI | http://localhost:18081/openmrs/spa | admin / Admin123 |
| OpenMRS API (backend) | http://localhost:18080/openmrs | admin / Admin123 |
| OpenFn Lightning | http://localhost:4000 | see `.env` |
| ERPNext | http://localhost:8000 | admin / admin |
| WhatsApp mock | http://localhost:9000 | no auth; logs all requests |

## Quick start

```bash
# 1. Clone both repos side by side
git clone https://github.com/rubailly/ncd-community-referral
git clone https://github.com/rubailly/ncd-dev-env
cd ncd-dev-env

# 2. Configure environment
cp .env.example .env
# Edit .env if you want to change passwords

# 3. Start all services
make up

# 4. One-time setup (wait for services to be healthy — ~5 min first time)
make setup

# 5. Load test data
make seed

# 6. Deploy the workflow to local OpenFn
make deploy

# 7. Trigger a manual run and watch the logs
make trigger
make logs-openfn
```

## How it works

### Architecture

Community health workers record NCD screenings in OpenMRS. Every 15 minutes (or on a webhook trigger) OpenFn polls OpenMRS, checks readings against configured thresholds, and — for any patient with a high reading — creates a referral in the E-Buzima ERPNext instance for their nearest health center and sends WhatsApp notifications to both the health center and the patient.

```
OpenMRS ──poll──► OpenFn Lightning ──► ERPNext (E-Buzima)
                        │
                        └──────────────► WhatsApp (Meta API / mock)
```

### The 5-job pipeline

The workflow in `../ncd-community-referral/` defines a linear pipeline. Each job receives state from the previous one.

**Job 1 — Fetch NCD Encounters from OpenMRS**

Queries the OpenMRS FHIR API for encounters of the configured NCD screening type recorded since the last run (15-minute default lookback, with a 2-minute overlap to avoid gaps at boundaries). Filters out encounter UUIDs already marked as processed, then fetches full REST details — including obs values — for each new one. Stores `encounters` on state and records `lastRunAt`.

**Job 2 — Check Obs Against NCD Thresholds**

Reads the `conditions` key from the `ncd-screening-config` Collection (see [Collections](#collections) below). For each encounter, checks every obs value against the configured concept UUIDs and numeric thresholds. Only encounters with at least one reading at or above a threshold continue as `flaggedEncounters`, each annotated with a human-readable `conditionSummary` (e.g. `"Hypertension, Diabetes"`).

**Job 3 — Fetch Patient Details and Route to Health Center**

For each flagged encounter, fetches full patient details from OpenMRS (name, date of birth, gender, phone number) and looks up the encounter's `location.uuid` in the `rw-facility-routing` Collection to find the target health center — its name, ERPNext URL, WhatsApp number, and FOSSA code. Builds a `referrals` array with all of this attached.

**Job 4 — Create Patient and Referral in E-Buzima**

For each referral, upserts the patient in ERPNext (searches by `custom_openmrs_uuid`, creates if not found) and then creates a `Patient Appointment` record as the referral, recording the condition, source location, and OpenMRS encounter UUID in the notes. Produces `createdReferrals`.

**Job 5 — Send WhatsApp Notifications**

Sends two WhatsApp template messages per referral:
- **Health center** (`ncd_referral_hc_notify`): patient name, DOB, screened-at location, date, condition summary, OpenMRS ID.
- **Patient** (`ncd_referral_patient_notify`): first name, appointment date, health center name. Skipped if no phone number is recorded in OpenMRS.

After all messages are sent, the encounter UUIDs are appended to `processedUuids` in state (capped at 10,000 entries) so they are not reprocessed on the next run.

### Collections

Two OpenFn Collections drive the pipeline's configuration without requiring code changes.

**`ncd-screening-config`**

Stores a single key, `conditions`, whose value is a JSON array of NCD conditions. Each condition lists the OpenMRS concept UUIDs to watch and the numeric threshold above which a referral is triggered.

Out of the box:

| Condition | Obs | Concept UUID | Threshold |
|---|---|---|---|
| Hypertension | Systolic BP | `5085AAAA…` | ≥ 140 mmHg |
| Hypertension | Diastolic BP | `5086AAAA…` | ≥ 90 mmHg |
| Diabetes | Fasting glucose | `887AAAAA…` | ≥ 126 mg/dL |
| Diabetes | Random glucose | `888AAAAA…` | ≥ 200 mg/dL |

To add a new condition or adjust a threshold, update the Collection entry in the OpenFn UI — no deployment required.

A second key, `encounter-type-uuid`, controls which OpenMRS encounter type is polled. It defaults to the local dev UUID baked into Job 1 if the key is absent.

**`rw-facility-routing`**

Stores one key per OpenMRS community location UUID. The value is a health center record used by Jobs 3, 4, and 5:

```json
{
  "hc_name": "Kamonyi Health Center",
  "district": "Kamonyi",
  "fossa_code": "4/1/5/2",
  "erp_base_url": "https://kamonyi-hc.ebuzima.rw",
  "hc_whatsapp": "+250788100001"
}
```

12 entries cover 4 districts: Kamonyi, Rusizi, Nyamasheke, and Karongi. In production each health center has its own ERPNext tenant URL. Locally, `make setup` rewrites all `erp_base_url` values to `http://erpnext-frontend:8080` so all referrals route to the single local ERPNext instance.

To add a new community screening site, PUT a new entry into this Collection keyed by its OpenMRS location UUID — again, no code change or redeployment needed.

### Triggers

The pipeline runs on two triggers (both configured in `project.yaml`):
- **Cron** — fires every 15 minutes automatically once deployed.
- **Webhook** — `make trigger` POSTs to the webhook URL for immediate one-shot runs during development.

## Development loop

```bash
# Edit a job file in ../ncd-community-referral/jobs/
# Then redeploy:
make deploy

# Trigger a fresh run:
make seed     # creates new encounters with high readings
make trigger  # runs the pipeline against them

# Watch WhatsApp notifications rendered as recipients would see them:
bash scripts/watch-whatsapp.sh
# (or make logs-mock-whatsapp for the raw echoed requests)

# Check ERPNext for created patients:
# http://localhost:8000 → Healthcare → Patients
```

## Resetting

```bash
make down     # stop containers (data persists in Docker volumes)
make clean    # stop + wipe all volumes — full fresh start
make up && make setup && make seed
```

## Notes on ERPNext

ERPNext runs as a single site (`local.ebuzima`) with multiple **companies**, one per health center. In production each health center is a separate URL tenant; locally `make setup` points every routing entry at the single local instance (see [Collections](#collections)) and the `company` field distinguishes them.

## Notes on WhatsApp

The mock at `localhost:9000` accepts any POST and returns `200 OK`, logging the full request body. This lets the full pipeline run end-to-end without a real Meta Business account. To see what messages would be sent, check the mock-whatsapp container logs:

```bash
make logs-mock-whatsapp
```
