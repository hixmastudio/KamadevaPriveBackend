#!/usr/bin/env sh
set -eu

ACTION="${1:-up}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$ENV_FILE}"
COMPOSE_FILES="${COMPOSE_FILES:-$ROOT_DIR/devops/docker-compose.yml -f $ROOT_DIR/devops/docker-compose.prod.yml}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$ROOT_DIR/db/migrations}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-$ROOT_DIR/db/bootstrap}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:-kamadeva}"
POSTGRES_DB="${POSTGRES_DB:-kamadeva}"

compose() {
  if [ -f "$COMPOSE_ENV_FILE" ]; then
    # shellcheck disable=SC2086
    docker compose --env-file "$COMPOSE_ENV_FILE" -f $COMPOSE_FILES "$@"
  else
    # shellcheck disable=SC2086
    docker compose -f $COMPOSE_FILES "$@"
  fi
}

psql_db() {
  compose exec -T db psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

wait_for_db() {
  compose up -d db
  i=0
  until compose exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then
      echo "Postgres did not become ready." >&2
      exit 1
    fi
    sleep 1
  done
}

migrate_up() {
  wait_for_db

  for file in "$BOOTSTRAP_DIR"/*.sql; do
    [ -e "$file" ] || continue
    echo "bootstrap $(basename "$file")"
    psql_db -f - < "$file"
  done

  psql_db -c "create table if not exists public.schema_migrations (version text primary key, applied_at timestamptz not null default now());"

  for file in "$MIGRATIONS_DIR"/*.sql; do
    [ -e "$file" ] || continue
    version="$(basename "$file" .sql)"
    applied="$(psql_db -At -c "select 1 from public.schema_migrations where version = '$version'")"
    if [ "$applied" = "1" ]; then
      echo "skip $version"
      continue
    fi
    echo "apply $version"
    psql_db -f - < "$file"
    psql_db -c "insert into public.schema_migrations(version) values ('$version');"
  done
}

migrate_down() {
  if [ "${CONFIRM:-}" != "drop" ]; then
    echo "This will drop the local Postgres app schemas and data." >&2
    echo "Run: make migrate-down CONFIRM=drop" >&2
    exit 1
  fi
  wait_for_db
  psql_db -c "drop schema if exists public cascade; create schema public; grant all on schema public to public;"
  psql_db -c "drop schema if exists muse cascade;"
  psql_db -c "drop schema if exists auth cascade;"
  psql_db -c "drop schema if exists extensions cascade;"
}

case "$ACTION" in
  up) migrate_up ;;
  down) migrate_down ;;
  *) echo "Usage: $0 up|down" >&2; exit 2 ;;
esac
