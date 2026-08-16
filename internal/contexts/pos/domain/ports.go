package domain

import (
	"context"
	"encoding/json"
)

type TicketRepository interface {
	SaveSambaTicket(ctx context.Context, ticket SambaTicket) (string, error)
}

type SambaTicketSource interface {
	FetchTickets(ctx context.Context, from, to string) (SambaTicketRange, error)
	FetchCleanTickets(ctx context.Context, query SambaCleanTicketQuery) (json.RawMessage, error)
	FetchCleanTicket(ctx context.Context, ticketNumber string) (json.RawMessage, error)
	Health(ctx context.Context) (SambaSourceHealth, error)
}
