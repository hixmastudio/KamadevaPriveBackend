# Oso Lounge Samba API

This is the vendor-provided Samba POS read API used by the backend to pull data
from the Oso Lounge till service.

## Base URLs

Production tunnel:

```text
https://oso-lounge.backhaus.website
```

Till PC local service:

```text
http://127.0.0.1:9100
```

Configure the backend with:

```env
SAMBA_API_URL=https://oso-lounge.backhaus.website
SAMBA_API_KEY=<vendor-issued api key>
SAMBA_CACHE_DIR=var/cache/samba
```

## Authentication

Every request must include:

```http
X-API-Key: <SAMBA_API_KEY>
```

Missing or incorrect keys return:

```json
{ "error": "..." }
```

All routes are `GET`. Other HTTP methods return `405`.

## Endpoints

### `GET /healthz`

Checks service and database connectivity.

Example response:

```json
{
  "ok": true,
  "samba": "connected",
  "site": "oso-lounge",
  "database": "SambaPOS4",
  "server": "DESKTOP-JAGC5KJ\\SAMBAPOS4"
}
```

### `GET /api/tickets?from=YYYY-MM-DD&to=YYYY-MM-DD`

Returns full tickets for an inclusive date range. The maximum range is 92 days.
Tickets are bucketed by paid time, falling back to open time.

Response shape:

```json
{
  "from": "2026-08-09",
  "to": "2026-08-10",
  "count": 0,
  "tickets": []
}
```

Each ticket contains:

- `header`: `id`, `ticketNumber`, `ticketUid`, `date`, `lastOrderDate`,
  `lastPaymentDate`, `isClosed`, `isLocked`, `preOrder`, `totalAmount`,
  `remainingAmount`, `totalAmountPreTax`, `departmentId`, `departmentName`,
  `terminalId`, `ticketTypeId`, `note`, `createdUserName`,
  `lastModifiedUserName`, `taxIncluded`, `exchangeRate`, `ticketTags`,
  `ticketStates`
- `orders[]`: all order lines, including voided lines. Voided lines have
  `calculatePrice: false` and `{ "S": "Void" }` in `orderStates`; exclude them
  from revenue.
- `payments[]`: `paymentTypeId`, `paymentTypeName`, `paymentName`, `amount`,
  `tenderedAmount`, `date`, `userId`
- `calculations[]`: service charges and discounts, including `name`, `amount`,
  `calculationAmount`, `decreaseAmount`, `includeTax`
- `entities[]`: tables and customer accounts, including `entityId`,
  `entityName`, `entityTypeName`, `notes`

### `GET /api/menu`

Returns menu departments, items, portions, and prices.

Response shape:

```json
{
  "departments": [{ "id": 1, "name": "Restaurant" }],
  "menuItems": [{ "id": 1, "name": "Item", "groupCode": "Group" }],
  "portions": [{ "id": 1, "menuItemId": 1, "name": "Normal" }],
  "prices": [{ "id": 1, "portionId": 1, "priceTag": "Default", "price": 0 }]
}
```

Current vendor counts: 1 department, 561 items, 582 portions, 979 prices.

### `GET /api/staff`

Returns staff IDs and names only. PINs are never exposed.

Response shape:

```json
{
  "users": [{ "id": 1, "name": "Staff Name" }]
}
```

Current vendor count: 15 users.

### `GET /api/departments`

Returns departments.

Response shape:

```json
{
  "departments": [{ "id": 1, "name": "Restaurant" }]
}
```

Current vendor state: Restaurant only.

### `GET /api/payments?from=YYYY-MM-DD&to=YYYY-MM-DD`

Returns a flat payment list across the inclusive date range. Payment rows use
the same payment shape as ticket payments and include `ticketNumber`.

Response shape:

```json
{
  "from": "2026-08-09",
  "to": "2026-08-10",
  "count": 0,
  "payments": []
}
```

### `GET /api/sales-by-department?from=YYYY-MM-DD&to=YYYY-MM-DD`

Returns aggregated sales totals by department.

Response shape:

```json
{
  "from": "2026-08-09",
  "to": "2026-08-10",
  "rows": [{ "department": "Restaurant", "count": 0, "amount": 0 }]
}
```

## Date Rules

- `from` and `to` must use `YYYY-MM-DD`.
- `from` must be before or equal to `to`.
- Date span must be 92 days or less.
- Invalid dates return `400`.
- Timestamps are the till PC wall-clock with a trailing `Z`; consumers should
  apply their own business-day bucketing.

## Implementation Readiness

This API is enough to start backend work for:

- Samba health checks.
- Pulling paid tickets by date range.
- Importing ticket headers, order lines, payments, service charges, discounts,
  table/customer-account entities, waiter tags, and staff names.
- Calculating gross amount, discount, net paid, payment method, and paid status.
- Building daily sales and department reports.

The main unresolved business-matching fields are:

- Kamadeva customer ID.
- Kamadeva member ID.
- Customer name.
- Customer phone.

Those fields are not guaranteed from the documented response. During
implementation, inspect `entities[]`, `ticketTags`, `ticketStates`, and `note`
from real tickets. If Samba does not reliably include customer identity, the
backend must match POS spend to members through another workflow, such as a
member code entered on the ticket, phone capture, QR/member card scan, or a
manager reconciliation screen.

## Transaction Mapping

Use this initial mapping for imported transactions:

| Kamadeva field | Samba source |
| --- | --- |
| Transaction date | `lastPaymentDate`, falling back to `date` |
| Ticket ID | `id` |
| Ticket number | `ticketNumber` |
| Venue | Backend venue config, initially `Oso Lounge` |
| Gross amount | `totalAmount` or sum of non-void `orders[]` |
| Discount | `calculations[]` where discount/decrease amount is present |
| Net amount paid | Sum of `payments[].amount` |
| Status | `Paid` ticket state, or `isClosed=true` and `remainingAmount=0` |
| Payment method | `payments[].paymentTypeName` |
| Cashier/waiter | `createdUserName`, `lastModifiedUserName`, or waiter `ticketTags` |
| Customer/member | Pending validation from `entities[]`, tags, or another capture flow |
 
Treat Samba money values as naira major units unless the vendor confirms
otherwise. Convert to kobo only at the backend persistence boundary.

## Test Commands

These commands read the API key from the backend `.env` file:

```bash
set -a
source .env
set +a

curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/healthz"
curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/api/tickets?from=2026-08-09&to=2026-08-10"
curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/api/menu"
curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/api/staff"
curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/api/departments"
curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/api/payments?from=2026-08-09&to=2026-08-10"
curl -sS -H "X-API-Key: $SAMBA_API_KEY" "$SAMBA_API_URL/api/sales-by-department?from=2026-08-09&to=2026-08-10"
```

## Backend Test Endpoints

The Kamadeva backend exposes authenticated endpoints for testing this source.
They use `X-KP-API-Key`, not the Samba vendor key.

Check the configured Samba source:

```bash
curl -sS \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  "http://localhost:8787/integrations/pos/samba/source-health"
```

Pull and import tickets for a date range:

```bash
curl -sS \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  -d '{"venue_id":"11111111-1111-4111-8111-111111111111","from":"2026-07-05","to":"2026-07-06"}' \
  "http://localhost:8787/integrations/pos/samba/pull-tickets"
```

Use the real Oso Lounge venue UUID before importing production data.

Check transaction orchestrator status:

```bash
curl -sS \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  "http://localhost:8787/integrations/pos/samba/orchestrator"
```

List all configured Samba sources:

```bash
curl -sS \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  "http://localhost:8787/integrations/pos/samba/sources"
```

Check Boom Boom Room source health:

```bash
curl -sS \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  "http://localhost:8787/integrations/pos/samba/sources/boom-boom-room/source-health"
```

Trigger one orchestrated transaction pull:

```bash
curl -sS \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  -d '{"venue_id":"11111111-1111-4111-8111-111111111111","from":"2026-07-05","to":"2026-07-06"}' \
  "http://localhost:8787/integrations/pos/samba/orchestrator/run"
```

Trigger one Boom Boom Room orchestration run:

```bash
curl -sS \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-KP-API-Key: $API_SHARED_SECRET" \
  -d '{"from":"2026-07-05","to":"2026-07-06"}' \
  "http://localhost:8787/integrations/pos/samba/sources/boom-boom-room/orchestrator/run"
```

## Cache Strategy

Every successful backend fetch of:

```text
GET /api/tickets?from=YYYY-MM-DD&to=YYYY-MM-DD
```

writes the raw upstream JSON response to:

```text
$SAMBA_CACHE_DIR/tickets/
```

For each date range, the backend writes:

- a timestamped immutable snapshot:
  `YYYY-MM-DD_YYYY-MM-DD_YYYYMMDDTHHMMSSZ.json`
- a latest pointer for quick inspection:
  `latest_YYYY-MM-DD_YYYY-MM-DD.json`

The cache is intentionally raw vendor JSON. It is used for audit/debugging and
for comparing mapper behavior against the original Samba response. The import
flow still treats Supabase as the durable application database.

## Transaction Orchestrator

The transaction orchestrator is the preferred automated workflow. It polls Samba
on an interval and coordinates the full transaction workflow:

1. Check/source-call Samba.
2. Pull ticket range.
3. Save raw JSON cache.
4. Map Samba tickets to Kamadeva POS commands.
5. Save/update Supabase tickets.
6. Log result counts and failures.

It is disabled by default. Enable it only after `SUPABASE_SERVICE_ROLE_KEY` and
the venue UUID are configured:

```env
SAMBA_VENUE_ID=11111111-1111-4111-8111-111111111111
SAMBA_ORCHESTRATOR_ENABLED=true
SAMBA_ORCHESTRATOR_POLL_INTERVAL=5m
SAMBA_ORCHESTRATOR_LOOKBACK_DAYS=1
SAMBA_ORCHESTRATOR_RUN_ON_START=true
```

With the default lookback, each run fetches yesterday's tickets. Increase
`SAMBA_ORCHESTRATOR_LOOKBACK_DAYS` when recovering from tunnel downtime.

## Daily Pull Job

The older daily pull scheduler is still available when you want exactly one
fixed import per day instead of continuous polling:

```env
SAMBA_VENUE_ID=<oso lounge venue uuid>
SAMBA_DAILY_PULL_ENABLED=true
SAMBA_DAILY_PULL_TIME=03:15
SAMBA_DAILY_PULL_LOOKBACK_DAYS=1
SAMBA_DAILY_PULL_RUN_ON_START=false
```

With the default lookback, the job imports yesterday's tickets once per day.
Increase `SAMBA_DAILY_PULL_LOOKBACK_DAYS` when recovering from tunnel downtime.
