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
| OpenMRS backend | http://localhost:8080/openmrs | admin / Admin123 |
| OpenMRS frontend | http://localhost:8081 | admin / Admin123 |
| OpenFn Lightning | http://localhost:4000 | see `.env` |
| ERPNext | http://localhost:8000 | admin / admin |
| WhatsApp mock | http://localhost:9000 | (no auth — logs all requests) |

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

## Development loop

```bash
# Edit a job file in ../ncd-community-referral/jobs/
# Then redeploy:
make deploy

# Trigger a fresh run:
make seed     # creates new encounters with high readings
make trigger  # runs the pipeline against them

# Check WhatsApp mock received notifications:
# Open http://localhost:9000 — it echoes all incoming requests

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

ERPNext runs as a single site (`local.ebuzima`) with multiple **companies**, one per health center. In production each health center is a separate URL tenant — locally all referrals go to `http://erpnext-backend:8000` and the `company` field distinguishes them. The routing Collection is pre-configured to use the local URL.

## Notes on WhatsApp

The mock at `localhost:9000` accepts any POST and returns `200 OK`, logging the full request body. This lets the full pipeline run end-to-end without a real Meta Business account. To see what messages would be sent, check the mock-whatsapp container logs:

```bash
make logs-mock-whatsapp
```
