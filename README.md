# Kamadeva Privé Backend

Thin Go API backend for Kamadeva Privé integrations and privileged workflows.

This service is intentionally small. Supabase Postgres remains the source of
truth for CRUD, RLS, tier math, discounts, reservations, Muse approval rules,
and audit guarantees. The backend validates external/server-side requests,
authenticates integrations, and calls the existing Supabase RPC/table API with
the service-role key.

## Architecture

DDD + hexagonal layout:

- `internal/contexts/pos`: POS bounded context, including Samba ticket ingestion
- `internal/contexts/operations`: scheduled maintenance jobs
- `internal/contexts/reporting`: manager/audit reporting queries
- `internal/contexts/engagement`: WhatsApp booking assistant, conversation intake,
  AI orchestration, payment/wallet webhook intake
- `internal/shared/domain`: shared application errors
- `internal/interfaces/httpapi`: HTTP interface adapter
- `internal/infrastructure/supabase`: Supabase REST/RPC infrastructure adapter
- `cmd/api`: process entrypoint

## Endpoints

- `GET /health`
- `POST /integrations/pos/samba/heartbeat`
- `POST /integrations/pos/samba/tickets`
- `GET /integrations/pos/samba/source-health`
- `POST /integrations/pos/samba/pull-tickets`
- `POST /integrations/whatsapp/inbound`
- `GET /webhooks/whatsapp`
- `POST /webhooks/whatsapp`
- `POST /integrations/wallet/cards/events`
- `POST /integrations/payments/events`
- `POST /jobs/tier-decay-sweep`
- `POST /jobs/audit-partitions`
- `GET /reports/capture-rate?from=YYYY-MM-DD&to=YYYY-MM-DD`

All endpoints except `/health` require:

```http
X-KP-API-Key: $API_SHARED_SECRET
```

For Samba POS endpoints, set `SAMBA_WEBHOOK_SECRET` in production and send:

```http
X-KP-Signature: sha256=<hex hmac sha256 of raw JSON body>
```

Meta WhatsApp webhook callbacks use the official verification flow:

- `GET /webhooks/whatsapp` validates `WHATSAPP_VERIFY_TOKEN`
- `POST /webhooks/whatsapp` validates `X-Hub-Signature-256` with
  `WHATSAPP_APP_SECRET` when configured, deduplicates by WhatsApp message ID,
  enqueues inbound messages, and returns quickly

Booking confirmations and AI replies are processed by the engagement worker when
`WHATSAPP_WORKER_ENABLED=true`. Supabase remains the booking source of truth;
apply/adapt `devops/supabase-whatsapp-booking-assistant.sql` and map the listed
booking/customer RPCs to the production reservation schema.
Set `WHATSAPP_BOOKING_CONFIRMATION_TEMPLATE` to an approved Meta template name
when confirmations may be sent outside the customer service window.

## Docs

- Swagger/OpenAPI: `docs/openapi.yaml`
- Samba POS extension contract: `docs/samba-pos-integration.md`
- Oso Lounge Samba read API: `docs/oso-lounge-samba-api.md`
- Production readiness notes: `docs/production-readiness.md`

## Local Run

```bash
cp .env.example .env
go run ./cmd/api
```

Required env:

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
SAMBA_ORCHESTRATOR_POLL_INTERVAL=10s
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
BOOM_BOOM_ROOM_ORCHESTRATOR_POLL_INTERVAL=10s
BOOM_BOOM_ROOM_ORCHESTRATOR_LOOKBACK_DAYS=1
BOOM_BOOM_ROOM_ORCHESTRATOR_RUN_ON_START=false
WHATSAPP_ACCESS_TOKEN=
WHATSAPP_PHONE_NUMBER_ID=
WHATSAPP_VERIFY_TOKEN=
WHATSAPP_APP_SECRET=
WHATSAPP_API_VERSION=v20.0
WHATSAPP_BOOKING_CONFIRMATION_TEMPLATE=
WHATSAPP_WORKER_ENABLED=false
WHATSAPP_WORKER_INTERVAL=15s
AI_PROVIDER=disabled
OPENAI_API_KEY=
OPENAI_MODEL=gpt-4.1-mini
OPENAI_HTTP_TIMEOUT=30s
API_PORT=8787
SAMBA_HTTP_TIMEOUT=90s
```
