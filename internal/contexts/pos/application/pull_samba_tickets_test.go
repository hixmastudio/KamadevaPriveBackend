package application

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

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
			{MenuItemName: "Voided Drink", PortionName: "Normal", Price: 1000, Quantity: 1, CalculatePrice: false, OrderStates: posdomain.SambaJSONList{{"S": "Void"}}},
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
	if ticket.BillName == nil || *ticket.BillName != "KP-004521" {
		t.Fatalf("bill name = %#v", ticket.BillName)
	}
	if ticket.AcctNo != nil {
		t.Fatalf("acct_no is the settlement account, got %#v", ticket.AcctNo)
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
		existing: map[string]posdomain.ExistingSambaTicket{"71357": {ID: "t-71357", Attributed: true}},
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
	existing   map[string]posdomain.ExistingSambaTicket
	saved      []posdomain.SambaTicket
	attributed []string
	members    map[string]string
	latest     string
}

func (r *fakeTicketRepository) SaveSambaTicket(ctx context.Context, ticket posdomain.SambaTicket) (string, error) {
	r.saved = append(r.saved, ticket)
	return "ticket-id-" + ticket.TicketNo, nil
}

func (r *fakeTicketRepository) ExistingSambaTickets(ctx context.Context, venueID string, ticketNumbers []string) (map[string]posdomain.ExistingSambaTicket, error) {
	out := map[string]posdomain.ExistingSambaTicket{}
	for _, number := range ticketNumbers {
		if existing, ok := r.existing[number]; ok {
			out[number] = existing
		}
	}
	return out, nil
}

func (r *fakeTicketRepository) LatestSambaTicketDate(ctx context.Context, venueID string) (string, error) {
	return r.latest, nil
}

func (r *fakeTicketRepository) AttributeTillCustomer(ctx context.Context, ticketID, memberNo string, entityID int64) (string, error) {
	r.attributed = append(r.attributed, fmt.Sprintf("%s:%s:%d", ticketID, memberNo, entityID))
	return r.members[memberNo], nil
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

func customerRow(id int64, name, customerID, notes string) map[string]any {
	data := `[{"Name":"Phone","Value":"08031234567"}`
	if customerID != "" {
		data += `,{"Name":"Customer ID","Value":"` + customerID + `"}`
	}
	data += `]`
	return map[string]any{"Id": float64(id), "EntityTypeId": float64(1), "Name": name, "CustomData": data, "Notes": notes, "AccountId": float64(id + 1000)}
}

func TestPullTicketsAttributesTheTillCustomer(t *testing.T) {
	db := newFakeSambaDB()
	db.tables["Entities"] = []map[string]any{
		customerRow(4293, "Adaeze Okonkwo", "KP-000123", SambaMemberNotes),
		customerRow(4294, "Alex PRO", "", ""),
	}
	index := NewSambaCustomerIndex(testCustomerService(db), 0)
	repo := &fakeTicketRepository{
		existing: map[string]posdomain.ExistingSambaTicket{
			"100": {ID: "t-100", Attributed: false},
			"101": {ID: "t-101", Attributed: false},
		},
		members: map[string]string{"KP-000123": "member-1"},
	}
	withCustomer := func(number string, entityID int64, name string) posdomain.SambaSourceTicket {
		ticket := sourceTicket(number)
		ticket.Entities = []posdomain.SambaSourceEntity{
			{EntityTypeID: 2, EntityTypeName: "Tables", EntityName: "B14"},
			{EntityTypeID: 1, EntityID: entityID, EntityTypeName: "Customers", EntityName: name},
		}
		return ticket
	}
	service := NewSambaPullService(fakeSambaTicketSource{tickets: []posdomain.SambaSourceTicket{
		withCustomer("100", 4293, "Adaeze Okonkwo"), // imported earlier, member: attribute now
		withCustomer("101", 4294, "Alex PRO"),       // imported earlier, not a member: leave alone
		withCustomer("102", 4293, "Adaeze Okonkwo"), // new, member
		withCustomer("103", 4294, "Alex PRO"),       // new, not a member: still recorded
		sourceTicket("104"),                         // new, walk-in
	}}, repo).WithCustomerIndex(index)

	result, err := service.PullTickets(context.Background(), PullSambaTicketsRequest{
		VenueID: "11111111-1111-4111-8111-111111111111", From: "2026-07-05", To: "2026-07-05",
	})
	if err != nil {
		t.Fatalf("PullTickets error = %v", err)
	}
	if result.Attributed != 2 {
		t.Fatalf("attributed = %d", result.Attributed)
	}
	want := "t-100:KP-000123:4293,ticket-id-102:KP-000123:4293,ticket-id-103::4294"
	if got := strings.Join(repo.attributed, ","); got != want {
		t.Fatalf("attribution calls = %s, want %s", got, want)
	}
	if bill := repo.saved[0].BillName; bill == nil || *bill != "Adaeze Okonkwo" {
		t.Fatalf("bill name = %#v", bill)
	}
}

func TestOrchestratorCatchesUpAfterAnOutage(t *testing.T) {
	repo := &fakeTicketRepository{latest: "2026-11-01"}
	o := NewSambaTransactionOrchestrator(SambaTransactionOrchestratorConfig{VenueID: "11111111-1111-4111-8111-111111111111", Lookback: 1},
		NewSambaPullService(fakeSambaTicketSource{}, repo), nil)
	o.now = func() time.Time { return time.Date(2026, 11, 6, 15, 0, 0, 0, time.UTC) }

	req := o.pullRequest(context.Background(), SambaTransactionOrchestratorRunRequest{})
	if req.From != "2026-11-01" || req.To != "2026-11-06" {
		t.Fatalf("first pull after restart = %s..%s, want 2026-11-01..2026-11-06", req.From, req.To)
	}

	// A manual one-day pull must not mark the gap as filled.
	if _, err := o.run(context.Background(), "manual", PullSambaTicketsRequest{VenueID: req.VenueID, From: "2026-11-06", To: "2026-11-06"}); err != nil {
		t.Fatalf("manual run: %v", err)
	}
	if again := o.pullRequest(context.Background(), SambaTransactionOrchestratorRunRequest{}); again.From != "2026-11-01" {
		t.Fatalf("after manual pull from = %s, want 2026-11-01", again.From)
	}

	// Once a scheduled pull succeeds, the next one is back to the lookback.
	if _, err := o.run(context.Background(), "poll", req); err != nil {
		t.Fatalf("poll run: %v", err)
	}
	o.now = func() time.Time { return time.Date(2026, 11, 6, 15, 1, 0, 0, time.UTC) }
	if next := o.pullRequest(context.Background(), SambaTransactionOrchestratorRunRequest{}); next.From != "2026-11-06" {
		t.Fatalf("steady state from = %s, want 2026-11-06", next.From)
	}

	// A very long outage is capped.
	o.fetchedThrough = ""
	repo.latest = "2026-01-01"
	if capped := o.pullRequest(context.Background(), SambaTransactionOrchestratorRunRequest{}); capped.From != "2026-10-08" {
		t.Fatalf("capped from = %s, want 2026-10-08", capped.From)
	}
}
