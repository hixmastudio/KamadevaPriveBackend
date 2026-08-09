package domain

import "context"

type TicketRepository interface {
	SaveSambaTicket(ctx context.Context, ticket SambaTicket) (string, error)
}
