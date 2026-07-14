.PHONY: up down clean setup setup-openmrs setup-erpnext setup-openfn seed deploy trigger logs ps

# ── Lifecycle ────────────────────────────────────────────────────────────────

up:
	docker compose up -d
	@echo ""
	@echo "Services starting. Run 'make logs' to watch, or 'make ps' to check health."
	@echo "  OpenMRS UI  → http://localhost:18081/openmrs/spa  (admin / Admin123)"
	@echo "  OpenMRS API → http://localhost:18080/openmrs      (admin / Admin123)"
	@echo "  OpenFn   → http://localhost:4000          ($$(grep OPENFN_ADMIN_EMAIL .env 2>/dev/null | cut -d= -f2 || echo 'see .env'))"
	@echo "  ERPNext  → http://localhost:8000          (admin / admin)"
	@echo "  WhatsApp mock → http://localhost:9000"

down:
	docker compose down

clean:
	docker compose down -v
	@echo "All volumes removed. Run 'make up && make setup' for a fresh start."

ps:
	docker compose ps

logs:
	docker compose logs -f --tail=100

logs-%:
	docker compose logs -f --tail=100 $*

# ── First-time setup (run once after 'make up') ──────────────────────────────

setup: setup-openmrs setup-erpnext setup-openfn
	@echo ""
	@echo "✓ Setup complete. Run 'make seed' to load test data, then 'make deploy' to push the workflow."

setup-openmrs:
	@echo "── Setting up OpenMRS..."
	bash scripts/setup-openmrs.sh

setup-erpnext:
	@echo "── Setting up ERPNext..."
	bash scripts/setup-erpnext.sh

setup-openfn:
	@echo "── Setting up OpenFn..."
	bash scripts/setup-openfn.sh

# ── Development workflow ─────────────────────────────────────────────────────

seed:
	@echo "── Seeding OpenMRS with test patients and NCD encounters..."
	bash scripts/seed-openmrs.sh

deploy:
	@echo "── Deploying workflow to local OpenFn..."
	bash scripts/deploy-workflow.sh

trigger:
	@echo "── Triggering one workflow run manually..."
	bash scripts/trigger-workflow.sh
