COMPOSE := docker compose -f devops/docker-compose.yml
DEV_COMPOSE := $(COMPOSE) -f devops/docker-compose.dev.yml
PROD_COMPOSE := $(COMPOSE) -f devops/docker-compose.prod.yml

.PHONY: dev-up prod-up dev-down prod-down build-dev build-prod logs

dev-up:
	$(DEV_COMPOSE) up -d api

prod-up:
	$(PROD_COMPOSE) up -d --build api

dev-down:
	$(DEV_COMPOSE) down

prod-down:
	$(PROD_COMPOSE) down

build-dev:
	$(DEV_COMPOSE) pull api

build-prod:
	$(PROD_COMPOSE) build api

logs:
	$(COMPOSE) logs -f
