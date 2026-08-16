package application

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type CleanSambaTicketService struct {
	source posdomain.SambaTicketSource
}

type CleanSambaTicketsRequest struct {
	From string
	To   string
	Page string
}

func NewCleanSambaTicketService(source posdomain.SambaTicketSource) CleanSambaTicketService {
	return CleanSambaTicketService{source: source}
}

func (s CleanSambaTicketService) List(ctx context.Context, req CleanSambaTicketsRequest) (json.RawMessage, error) {
	if s.source == nil {
		return nil, shareddomain.UpstreamError("Samba API is not configured.", nil)
	}
	query, err := req.query()
	if err != nil {
		return nil, err
	}
	return s.source.FetchCleanTickets(ctx, query)
}

func (s CleanSambaTicketService) Get(ctx context.Context, ticketNumber string) (json.RawMessage, error) {
	if s.source == nil {
		return nil, shareddomain.UpstreamError("Samba API is not configured.", nil)
	}
	ticketNumber = strings.TrimSpace(ticketNumber)
	if ticketNumber == "" {
		return nil, shareddomain.ValidationError(map[string]string{"ticketNumber": "is required"})
	}
	return s.source.FetchCleanTicket(ctx, ticketNumber)
}

func (r CleanSambaTicketsRequest) query() (posdomain.SambaCleanTicketQuery, error) {
	fields := map[string]string{}
	from := strings.TrimSpace(r.From)
	to := strings.TrimSpace(r.To)
	pageText := strings.TrimSpace(r.Page)

	if pageText != "" {
		if from != "" || to != "" {
			return posdomain.SambaCleanTicketQuery{}, shareddomain.ValidationError(map[string]string{"query": "use either page or from/to, not both"})
		}
		page, err := strconv.Atoi(pageText)
		if err != nil || page < 1 {
			return posdomain.SambaCleanTicketQuery{}, shareddomain.ValidationError(map[string]string{"page": "must be a positive integer"})
		}
		return posdomain.SambaCleanTicketQuery{Page: page}, nil
	}

	if from == "" {
		fields["from"] = "is required unless page is set"
	}
	if to == "" {
		fields["to"] = "is required unless page is set"
	}
	fromDate, fromErr := time.Parse(time.DateOnly, from)
	if from != "" && fromErr != nil {
		fields["from"] = "must be YYYY-MM-DD"
	}
	toDate, toErr := time.Parse(time.DateOnly, to)
	if to != "" && toErr != nil {
		fields["to"] = "must be YYYY-MM-DD"
	}
	if len(fields) == 0 {
		if toDate.Before(fromDate) {
			fields["to"] = "must be on or after from"
		}
		if toDate.Sub(fromDate).Hours()/24 > 92 {
			fields["range"] = "must be 92 days or fewer"
		}
	}
	if len(fields) > 0 {
		return posdomain.SambaCleanTicketQuery{}, shareddomain.ValidationError(fields)
	}
	return posdomain.SambaCleanTicketQuery{From: from, To: to}, nil
}
