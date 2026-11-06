package domain

import (
	"context"
	"encoding/json"
)

type TicketRepository interface {
	SaveSambaTicket(ctx context.Context, ticket SambaTicket) (string, error)
	ExistingSambaTickets(ctx context.Context, venueID string, ticketNumbers []string) (map[string]ExistingSambaTicket, error)
	// AttributeTillCustomer books a ticket to the member whose member_no the
	// till's selected customer carries. It returns the member id, or "" when
	// no active member has that number.
	AttributeTillCustomer(ctx context.Context, ticketID, memberNo string, entityID int64) (string, error)
}

type ExistingSambaTicket struct {
	ID         string
	Attributed bool
}

// MemberDirectory lists Privé members for the till sync, every status included
// so members who left can be taken off the till.
type MemberDirectory interface {
	MembersForTill(ctx context.Context) ([]PriveMember, error)
}

type PriveMember struct {
	ID       string `json:"id"`
	MemberNo string `json:"member_no"`
	FullName string `json:"full_name"`
	Phone    string `json:"phone"`
	Status   string `json:"status"`
}

type SambaTicketSource interface {
	FetchTickets(ctx context.Context, from, to string) (SambaTicketRange, error)
	FetchCleanTickets(ctx context.Context, query SambaCleanTicketQuery) (json.RawMessage, error)
	FetchCleanTicket(ctx context.Context, ticketNumber string) (json.RawMessage, error)
	Health(ctx context.Context) (SambaSourceHealth, error)
}
