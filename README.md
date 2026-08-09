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
- `internal/contexts/engagement`: WhatsApp/payment/wallet webhook intake
- `internal/shared/domain`: shared application errors
- `internal/interfaces/httpapi`: HTTP interface adapter
- `internal/infrastructure/supabase`: Supabase REST/RPC infrastructure adapter
- `cmd/api`: process entrypoint

## Endpoints

- `GET /health`
- `POST /integrations/pos/samba/tickets`
- `POST /integrations/whatsapp/inbound`
- `POST /integrations/wallet/cards/events`
- `POST /integrations/payments/events`
- `POST /jobs/tier-decay-sweep`
- `POST /jobs/audit-partitions`
- `GET /reports/capture-rate?from=YYYY-MM-DD&to=YYYY-MM-DD`

All endpoints except `/health` require:

```http
X-KP-API-Key: $API_SHARED_SECRET
```

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
API_PORT=8787
```
