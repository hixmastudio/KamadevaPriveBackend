# Samba POS Integration

This document is the contract for the Samba POS extension that will run inside
each venue POS installation.

## Direction

The extension pushes closed tickets to the backend over HTTPS. That is the
production-safe direction for venue networks because the POS machine does not
need an inbound public port. The backend can later add command polling for
two-way tasks, but the first production slice is outbound sync from extension to
backend.

## Required Extension Behavior

- Send a heartbeat when the extension starts and then every 60 seconds.
- Send every closed ticket to `POST /integrations/pos/samba/tickets`.
- Persist an outbound queue locally if the network is down.
- Retry failed syncs with exponential backoff.
- Re-send historical tickets when requested by an operator.
- Use the same `ticket_no` for the same Samba ticket forever. The backend is
  idempotent on `(venue_id, ticket_no)`, so retries are safe.
- Send money in kobo, never naira floats.
- Send `occurred_at` in RFC3339 with timezone, for example
  `2026-08-10T21:34:12+01:00`.

## Authentication

Every request must include:

```http
X-KP-API-Key: <API_SHARED_SECRET>
```

In production, also set `SAMBA_WEBHOOK_SECRET` on the backend and send:

```http
X-KP-Signature: sha256=<hex hmac sha256 of the raw JSON request body>
```

The HMAC must be computed on the exact raw UTF-8 JSON bytes sent in the request.
Do not pretty-print, reorder, or reserialize after signing.

## Backend-to-Extension API

If the Samba vendor exposes a hosted extension API for commands, configure:

```env
SAMBA_API_URL=https://oso-lounge.backhaus.website
SAMBA_API_KEY=<vendor-issued api key>
```

Use this channel for backend-initiated actions such as requesting a historical
ticket re-sync, checking terminal status, or sending controlled command
messages. Do not use the Supabase service-role key for Samba calls.

The Oso Lounge vendor API contract lives in `docs/oso-lounge-samba-api.md`.

## Heartbeat

`POST /integrations/pos/samba/heartbeat`

```json
{
  "venue_id": "11111111-1111-4111-8111-111111111111",
  "terminal_id": "oso-bar-01",
  "extension_version": "1.0.0",
  "samba_version": "5.7.0",
  "observed_at": "2026-08-10T19:15:00+01:00"
}
```

Expected response:

```json
{
  "ok": true,
  "accepted": true,
  "next": "continue syncing closed tickets"
}
```

## Ticket Sync

`POST /integrations/pos/samba/tickets`

```json
{
  "venue_id": "11111111-1111-4111-8111-111111111111",
  "ticket_no": "OSO-20260810-00042",
  "external_id": "samba-ticket-guid-or-integer",
  "occurred_at": "2026-08-10T21:34:12+01:00",
  "cashier": "Ada",
  "table_label": "VIP 4",
  "payment_method": "card",
  "service_charge_kobo": 0,
  "change_kobo": 0,
  "items": [
    {
      "name": "HONEY BBQ WINGS",
      "quantity": 1,
      "unit_price_kobo": 1850000
    },
    {
      "name": "CASAMIGOS SHOT",
      "quantity": 2,
      "unit_price_kobo": 650000
    }
  ]
}
```

Expected response:

```json
{
  "ticket_id": "3d74182d-8b4d-4775-a312-8d77ce66e981"
}
```

## Status Codes

- `200`: accepted
- `400`: invalid payload
- `401`: missing/invalid API key or HMAC signature
- `502`: backend could not write to Supabase

The extension should retry only network errors, `408`, `429`, and `5xx`.
Do not retry `400` or `401`; those require configuration or payload fixes.

## Example HMAC

Pseudo-code:

```text
rawBody = utf8Bytes(jsonBody)
signature = "sha256=" + hex(hmac_sha256(SAMBA_WEBHOOK_SECRET, rawBody))
sendHeader("X-KP-Signature", signature)
```

## Production Checklist

- Use HTTPS only.
- Use a unique `terminal_id` per installed extension.
- Store queued payloads durably on the POS machine.
- Include a visible sync status in the extension UI.
- Keep the backend URL, API key, venue ID, and webhook secret out of source code.
- Store `SAMBA_API_KEY` only in the backend runtime secret store.
- Rotate `API_SHARED_SECRET` and `SAMBA_WEBHOOK_SECRET` on staff/vendor changes.
- Monitor heartbeat gaps per terminal.
