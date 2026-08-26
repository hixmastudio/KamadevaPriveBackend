package application

import (
	"context"
	"encoding/json"
	"testing"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
)

func TestMapSourceTicketExcludesVoidsAndConvertsAmounts(t *testing.T) {
	ticket, matched := mapSourceTicket("11111111-1111-4111-8111-111111111111", posdomain.SambaSourceTicket{
		ID:                336737,
		TicketNumber:      "71357",
		Date:              "2026-07-04T20:38:29.447Z",
		LastPaymentDate:   "2026-07-05T00:56:23.503Z",
		TotalAmount:       169875,
		TotalAmountPreTax: 169869,
		CreatedUserName:   "JOSEPHINE",
		Orders: []posdomain.SambaSourceOrder{
			{MenuItemName: "Voss Sparkling Water", PortionName: "Normal", Price: 9500, Quantity: 1, CalculatePrice: true},
			{MenuItemName: "Voided Drink", PortionName: "Normal", Price: 1000, Quantity: 1, CalculatePrice: false, OrderStates: []map[string]any{{"S": "Void"}}},
		},
		Payments: []posdomain.SambaSourcePayment{
			{PaymentTypeName: "Credit Card", Amount: 169875},
		},
		Calculations: []posdomain.SambaSourceCalculation{
			{Name: "Discount", DecreaseAmount: 1000},
			{Name: "Service Charge", Amount: 500},
		},
		Entities: []posdomain.SambaSourceEntity{
			{EntityTypeName: "Tables", EntityName: "VIP 4"},
			{EntityTypeName: "Customer Account", EntityName: "KP-004521"},
		},
	})

	if !matched {
		t.Fatalf("expected customer account to be matched")
	}
	if ticket.TicketNo != "71357" {
		t.Fatalf("ticket number = %q", ticket.TicketNo)
	}
	if ticket.OccurredAt != "2026-07-05T00:56:23.503Z" {
		t.Fatalf("occurred_at = %q", ticket.OccurredAt)
	}
	if len(ticket.Items) != 1 {
		t.Fatalf("items length = %d", len(ticket.Items))
	}
	if ticket.Items[0].UnitPriceKobo != 950000 {
		t.Fatalf("unit price kobo = %d", ticket.Items[0].UnitPriceKobo)
	}
	if ticket.PaymentMethod == nil || *ticket.PaymentMethod != "Credit Card" {
		t.Fatalf("payment method = %#v", ticket.PaymentMethod)
	}
	if ticket.TableLabel == nil || *ticket.TableLabel != "VIP 4" {
		t.Fatalf("table label = %#v", ticket.TableLabel)
	}
	if ticket.AcctNo == nil || *ticket.AcctNo != "KP-004521" {
		t.Fatalf("account = %#v", ticket.AcctNo)
	}
	if ticket.ServiceChargeKobo == nil || *ticket.ServiceChargeKobo != 50000 {
		t.Fatalf("service charge = %#v", ticket.ServiceChargeKobo)
	}
	if ticket.DiscountKobo == nil || *ticket.DiscountKobo != 100000 {
		t.Fatalf("discount = %#v", ticket.DiscountKobo)
	}
}

func TestPullSambaTicketsRequestValidation(t *testing.T) {
	req := PullSambaTicketsRequest{
		VenueID: "not-a-uuid",
		From:    "2026-07-06",
		To:      "2026-07-05",
	}

	if err := req.Validate(); err == nil {
		t.Fatalf("expected validation error")
	}
}

func TestPullTicketsSkipsExistingTicketNumbers(t *testing.T) {
	repo := &fakeTicketRepository{
		existing: map[string]bool{"71357": true},
	}
	service := NewSambaPullService(fakeSambaTicketSource{
		tickets: []posdomain.SambaSourceTicket{
			sourceTicket("71357"),
			sourceTicket("71358"),
		},
	}, repo)

	result, err := service.PullTickets(context.Background(), PullSambaTicketsRequest{
		VenueID: "11111111-1111-4111-8111-111111111111",
		From:    "2026-07-05",
		To:      "2026-07-05",
	})
	if err != nil {
		t.Fatalf("PullTickets error = %v", err)
	}
	if result.Source != 2 {
		t.Fatalf("source count = %d", result.Source)
	}
	if result.SkippedExisting != 1 {
		t.Fatalf("skipped existing = %d", result.SkippedExisting)
	}
	if result.Imported != 1 {
		t.Fatalf("imported = %d", result.Imported)
	}
	if len(repo.saved) != 1 || repo.saved[0].TicketNo != "71358" {
		t.Fatalf("saved tickets = %#v", repo.saved)
	}
}

type fakeTicketRepository struct {
	existing map[string]bool
	saved    []posdomain.SambaTicket
}

func (r *fakeTicketRepository) SaveSambaTicket(ctx context.Context, ticket posdomain.SambaTicket) (string, error) {
	r.saved = append(r.saved, ticket)
	return "ticket-id-" + ticket.TicketNo, nil
}

func (r *fakeTicketRepository) ExistingSambaTicketNumbers(ctx context.Context, venueID string, ticketNumbers []string) (map[string]bool, error) {
	out := map[string]bool{}
	for _, number := range ticketNumbers {
		if r.existing[number] {
			out[number] = true
		}
	}
	return out, nil
}

type fakeSambaTicketSource struct {
	tickets []posdomain.SambaSourceTicket
}

func (s fakeSambaTicketSource) FetchTickets(ctx context.Context, from, to string) (posdomain.SambaTicketRange, error) {
	return posdomain.SambaTicketRange{
		From:    from,
		To:      to,
		Count:   len(s.tickets),
		Tickets: s.tickets,
	}, nil
}

func (s fakeSambaTicketSource) FetchCleanTickets(ctx context.Context, query posdomain.SambaCleanTicketQuery) (json.RawMessage, error) {
	return nil, nil
}

func (s fakeSambaTicketSource) FetchCleanTicket(ctx context.Context, ticketNumber string) (json.RawMessage, error) {
	return nil, nil
}

func (s fakeSambaTicketSource) Health(ctx context.Context) (posdomain.SambaSourceHealth, error) {
	return posdomain.SambaSourceHealth{OK: true}, nil
}

func sourceTicket(ticketNumber string) posdomain.SambaSourceTicket {
	return posdomain.SambaSourceTicket{
		ID:                336737,
		TicketNumber:      ticketNumber,
		Date:              "2026-07-05T00:56:23.503Z",
		LastPaymentDate:   "2026-07-05T00:56:23.503Z",
		TotalAmount:       9500,
		TotalAmountPreTax: 9500,
		Orders: []posdomain.SambaSourceOrder{
			{MenuItemName: "Voss Sparkling Water", PortionName: "Normal", Price: 9500, Quantity: 1, CalculatePrice: true},
		},
	}
}
