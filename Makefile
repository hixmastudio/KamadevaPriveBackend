COMPOSE := docker compose -f devops/docker-compose.yml
DEV_COMPOSE := $(COMPOSE) -f devops/docker-compose.dev.yml
PROD_COMPOSE := $(COMPOSE) -f devops/docker-compose.prod.yml

.PHONY: dev-up prod-up db-up dev-down prod-down db-down build-dev build-prod migrate-up migrate-down logs

dev-up:
	$(DEV_COMPOSE) up -d api

prod-up:
	$(PROD_COMPOSE) up -d --build api

db-up:
	$(PROD_COMPOSE) up -d db

dev-down:
	$(DEV_COMPOSE) down

prod-down:
	$(PROD_COMPOSE) down

db-down:
	$(PROD_COMPOSE) stop db

build-dev:
	$(DEV_COMPOSE) pull api

build-prod:
	$(PROD_COMPOSE) build api

migrate-up:
	COMPOSE_FILES="devops/docker-compose.yml -f devops/docker-compose.prod.yml" sh db/scripts/migrate.sh up

migrate-down:
	COMPOSE_FILES="devops/docker-compose.yml -f devops/docker-compose.prod.yml" CONFIRM=$(CONFIRM) sh db/scripts/migrate.sh down

logs:
	$(COMPOSE) logs -f
