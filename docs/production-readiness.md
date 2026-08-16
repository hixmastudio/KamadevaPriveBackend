# Production Readiness

## Runtime

- Go stdlib HTTP server with read, write, idle, and header timeouts.
- Graceful shutdown on `SIGINT` and `SIGTERM`.
- Supabase outbound HTTP timeout.
- Request body size limit via `MAX_REQUEST_BYTES`.
- Panic recovery middleware.
- Structured request logs through `log/slog`.
- `X-Request-ID` propagated or generated per request.
- Security headers: `X-Content-Type-Options`, `Referrer-Policy`.
- Samba ticket pulls cache raw upstream JSON under `SAMBA_CACHE_DIR`.
- Optional in-process daily Samba ticket pull can be enabled after venue and
  Supabase production secrets are configured.

## Secrets

- `SUPABASE_SERVICE_ROLE_KEY` is server-only.
- `API_SHARED_SECRET` protects all non-health endpoints.
- `SAMBA_WEBHOOK_SECRET` enables HMAC verification for Samba POS endpoints.
- `SAMBA_API_KEY` authenticates backend-to-Samba extension calls when the
  extension exposes a command API.
- `.env` is ignored by Git.

## Deployment Env

```env
SUPABASE_URL=https://vouormpeyrdxpxytvfce.supabase.co
SUPABASE_SERVICE_ROLE_KEY=
API_SHARED_SECRET=
SAMBA_WEBHOOK_SECRET=
SAMBA_API_URL=https://oso-lounge.backhaus.website
SAMBA_API_KEY=
SAMBA_VENUE_ID=
SAMBA_CACHE_DIR=var/cache/samba
SAMBA_ORCHESTRATOR_ENABLED=false
SAMBA_ORCHESTRATOR_POLL_INTERVAL=5m
SAMBA_ORCHESTRATOR_LOOKBACK_DAYS=1
SAMBA_ORCHESTRATOR_RUN_ON_START=false
SAMBA_DAILY_PULL_ENABLED=false
SAMBA_DAILY_PULL_TIME=03:15
SAMBA_DAILY_PULL_LOOKBACK_DAYS=1
SAMBA_DAILY_PULL_RUN_ON_START=false
BOOM_BOOM_ROOM_SAMBA_API_URL=
BOOM_BOOM_ROOM_SAMBA_API_KEY=
BOOM_BOOM_ROOM_SAMBA_VENUE_ID=
BOOM_BOOM_ROOM_ORCHESTRATOR_ENABLED=false
BOOM_BOOM_ROOM_ORCHESTRATOR_POLL_INTERVAL=5m
BOOM_BOOM_ROOM_ORCHESTRATOR_LOOKBACK_DAYS=1
BOOM_BOOM_ROOM_ORCHESTRATOR_RUN_ON_START=false
API_PORT=8787
MAX_REQUEST_BYTES=1048576
READ_HEADER_TIMEOUT=5s
READ_TIMEOUT=10s
WRITE_TIMEOUT=20s
IDLE_TIMEOUT=60s
SHUTDOWN_TIMEOUT=10s
SUPABASE_HTTP_TIMEOUT=15s
SAMBA_HTTP_TIMEOUT=90s
```

## Swagger

The OpenAPI contract lives at:

```text
docs/openapi.yaml
```

Load it into Swagger UI, Stoplight, Postman, or Insomnia.
