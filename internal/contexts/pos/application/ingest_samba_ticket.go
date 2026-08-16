package application

import (
	"context"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
)

type TicketIngestionService struct {
	tickets posdomain.TicketRepository
}

func NewTicketIngestionService(tickets posdomain.TicketRepository) TicketIngestionService {
	return TicketIngestionService{tickets: tickets}
}

func (s TicketIngestionService) IngestSambaTicket(ctx context.Context, ticket posdomain.SambaTicket) (map[string]string, error) {
	if err := ticket.Validate(); err != nil {
		return nil, err
	}
	id, err := s.tickets.SaveSambaTicket(ctx, ticket)
	if err != nil {
		return nil, err
	}
	return map[string]string{"ticket_id": id}, nil
}

func (s TicketIngestionService) AcceptSambaHeartbeat(_ context.Context, heartbeat posdomain.SambaHeartbeat) (map[string]any, error) {
	if err := heartbeat.Validate(); err != nil {
		return nil, err
	}
	return map[string]any{
		"ok":       true,
		"accepted": true,
		"next":     "continue syncing closed tickets",
	}, nil
}
