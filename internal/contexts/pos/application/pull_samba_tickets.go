package application

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"regexp"
	"strings"
	"time"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

type SambaPullService struct {
	source  posdomain.SambaTicketSource
	tickets posdomain.TicketRepository
	logger  *slog.Logger
}

type PullSambaTicketsRequest struct {
	VenueID string `json:"venue_id"`
	From    string `json:"from"`
	To      string `json:"to"`
}

type PullSambaTicketsResult struct {
	From            string                       `json:"from"`
	To              string                       `json:"to"`
	Source          int                          `json:"source_count"`
	Imported        int                          `json:"imported_count"`
	SkippedExisting int                          `json:"skipped_existing_count"`
	Failed          int                          `json:"failed_count"`
	Tickets         []ImportedSambaTicket        `json:"tickets"`
	Failures        []FailedSambaTicketImport    `json:"failures,omitempty"`
	Unmatched       int                          `json:"unmatched_customer_count"`
	Health          *posdomain.SambaSourceHealth `json:"health,omitempty"`
}

type ImportedSambaTicket struct {
	SourceID     int64  `json:"source_id"`
	TicketNumber string `json:"ticket_number"`
	TicketID     string `json:"ticket_id"`
}

type FailedSambaTicketImport struct {
	SourceID     int64  `json:"source_id"`
	TicketNumber string `json:"ticket_number"`
	Error        string `json:"error"`
	Details      any    `json:"details,omitempty"`
}

func NewSambaPullService(source posdomain.SambaTicketSource, tickets posdomain.TicketRepository) SambaPullService {
	return SambaPullService{source: source, tickets: tickets, logger: slog.Default()}
}

func (s SambaPullService) Health(ctx context.Context) (posdomain.SambaSourceHealth, error) {
	if s.source == nil {
		return posdomain.SambaSourceHealth{}, shareddomain.UpstreamError("Samba API is not configured.", nil)
	}
	return s.source.Health(ctx)
}

func (s SambaPullService) PullTickets(ctx context.Context, req PullSambaTicketsRequest) (PullSambaTicketsResult, error) {
	start := time.Now()
	s.logger.Info("samba_pull_started",
		"venue_id", req.VenueID,
		"from", req.From,
		"to", req.To,
	)
	if err := req.Validate(); err != nil {
		s.logger.Warn("samba_pull_validation_failed",
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
			"error", err,
		)
		return PullSambaTicketsResult{}, err
	}
	if s.source == nil {
		s.logger.Error("samba_pull_source_not_configured",
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
		)
		return PullSambaTicketsResult{}, shareddomain.UpstreamError("Samba API is not configured.", nil)
	}

	health, healthErr := s.source.Health(ctx)
	if healthErr != nil {
		s.logger.Warn("samba_pull_source_health_failed",
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
			"error", healthErr,
		)
	} else {
		s.logger.Info("samba_pull_source_health_ok",
			"venue_id", req.VenueID,
			"site", health.Site,
			"samba", health.Samba,
			"database", health.Database,
		)
	}
	sourceRange, err := s.source.FetchTickets(ctx, req.From, req.To)
	if err != nil {
		s.logger.Error("samba_pull_fetch_failed",
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
			"duration_ms", time.Since(start).Milliseconds(),
			"error", err,
		)
		return PullSambaTicketsResult{}, err
	}

	result := PullSambaTicketsResult{
		From:   sourceRange.From,
		To:     sourceRange.To,
		Source: sourceRange.Count,
		Health: &health,
	}

	existing, err := s.existingTicketNumbers(ctx, req.VenueID, sourceRange.Tickets)
	if err != nil {
		s.logger.Error("samba_pull_existing_ticket_lookup_failed",
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
			"duration_ms", time.Since(start).Milliseconds(),
			"error", err,
		)
		return PullSambaTicketsResult{}, err
	}

	for _, sourceTicket := range sourceRange.Tickets {
		ticketNumber := strings.TrimSpace(sourceTicket.TicketNumber)
		if existing[ticketNumber] {
			result.SkippedExisting++
			continue
		}

		ticket, matchedCustomer := mapSourceTicket(req.VenueID, sourceTicket)
		if !matchedCustomer {
			result.Unmatched++
		}

		id, err := s.saveSambaTicketWithRetry(ctx, ticket, sourceTicket)
		if err != nil {
			details := appErrorDetails(err)
			s.logger.Error("samba_pull_ticket_import_failed",
				"venue_id", req.VenueID,
				"source_id", sourceTicket.ID,
				"ticket_number", sourceTicket.TicketNumber,
				"error", err,
				"details", details,
			)
			result.Failed++
			result.Failures = append(result.Failures, FailedSambaTicketImport{
				SourceID:     sourceTicket.ID,
				TicketNumber: sourceTicket.TicketNumber,
				Error:        err.Error(),
				Details:      details,
			})
			continue
		}

		result.Imported++
		result.Tickets = append(result.Tickets, ImportedSambaTicket{
			SourceID:     sourceTicket.ID,
			TicketNumber: sourceTicket.TicketNumber,
			TicketID:     id,
		})
	}

	s.logger.Info("samba_pull_completed",
		"venue_id", req.VenueID,
		"from", result.From,
		"to", result.To,
		"source_count", result.Source,
		"imported_count", result.Imported,
		"skipped_existing_count", result.SkippedExisting,
		"failed_count", result.Failed,
		"unmatched_customer_count", result.Unmatched,
		"duration_ms", time.Since(start).Milliseconds(),
	)
	return result, nil
}

func (s SambaPullService) existingTicketNumbers(ctx context.Context, venueID string, sourceTickets []posdomain.SambaSourceTicket) (map[string]bool, error) {
	numbers := make([]string, 0, len(sourceTickets))
	for _, ticket := range sourceTickets {
		numbers = append(numbers, ticket.TicketNumber)
	}
	return s.tickets.ExistingSambaTicketNumbers(ctx, venueID, numbers)
}

func (s SambaPullService) saveSambaTicketWithRetry(ctx context.Context, ticket posdomain.SambaTicket, sourceTicket posdomain.SambaSourceTicket) (string, error) {
	var lastErr error
	for attempt := 1; attempt <= 4; attempt++ {
		id, err := s.tickets.SaveSambaTicket(ctx, ticket)
		if err == nil {
			if attempt > 1 {
				s.logger.Info("samba_pull_ticket_import_retry_succeeded",
					"venue_id", ticket.VenueID,
					"source_id", sourceTicket.ID,
					"ticket_number", sourceTicket.TicketNumber,
					"attempt", attempt,
				)
			}
			return id, nil
		}
		lastErr = err
		if attempt == 4 {
			break
		}
		delay := time.Duration(attempt*attempt) * time.Second
		s.logger.Warn("samba_pull_ticket_import_retrying",
			"venue_id", ticket.VenueID,
			"source_id", sourceTicket.ID,
			"ticket_number", sourceTicket.TicketNumber,
			"attempt", attempt,
			"next_attempt", attempt+1,
			"delay", delay.String(),
			"error", err,
		)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", ctx.Err()
		case <-timer.C:
		}
	}
	return "", lastErr
}

func appErrorDetails(err error) any {
	var appErr *shareddomain.AppError
	if errors.As(err, &appErr) {
		return appErr.Details
	}
	return nil
}

func (r PullSambaTicketsRequest) Validate() error {
	fields := map[string]string{}
	if !uuidPattern.MatchString(strings.TrimSpace(r.VenueID)) {
		fields["venue_id"] = "must be a UUID"
	}
	from, err := time.Parse(time.DateOnly, r.From)
	if err != nil {
		fields["from"] = "must be YYYY-MM-DD"
	}
	to, err := time.Parse(time.DateOnly, r.To)
	if err != nil {
		fields["to"] = "must be YYYY-MM-DD"
	}
	if len(fields) == 0 {
		if to.Before(from) {
			fields["to"] = "must be on or after from"
		}
		if to.Sub(from).Hours()/24 > 92 {
			fields["range"] = "must be 92 days or fewer"
		}
	}
	if len(fields) > 0 {
		return shareddomain.ValidationError(fields)
	}
	return nil
}

func mapSourceTicket(venueID string, source posdomain.SambaSourceTicket) (posdomain.SambaTicket, bool) {
	items := make([]posdomain.SambaTicketItem, 0, len(source.Orders))
	for _, order := range source.Orders {
		if isVoidedOrder(order) || !order.CalculatePrice || order.Quantity <= 0 {
			continue
		}
		name := strings.TrimSpace(order.MenuItemName)
		if order.PortionName != "" && !strings.EqualFold(order.PortionName, "Normal") {
			name = strings.TrimSpace(name + " - " + order.PortionName)
		}
		items = append(items, posdomain.SambaTicketItem{
			Name:          name,
			Quantity:      order.Quantity,
			UnitPriceKobo: nairaToKobo(order.Price),
		})
	}
	if len(items) == 0 {
		items = append(items, posdomain.SambaTicketItem{
			Name:          "Samba ticket " + source.TicketNumber,
			Quantity:      1,
			UnitPriceKobo: nairaToKobo(source.TotalAmount),
		})
	}

	occurredAt := firstNonEmpty(source.LastPaymentDate, source.LastOrderDate, source.Date)
	cashier := pointerToNonEmpty(firstNonEmpty(source.LastModifiedUserName, source.CreatedUserName))
	paymentMethod := pointerToNonEmpty(firstPaymentMethod(source.Payments))
	tableLabel := pointerToNonEmpty(firstEntityName(source.Entities, "table"))
	serviceCharge := sumServiceCharges(source.Calculations)
	discount := sumDiscounts(source.Calculations)
	externalID := pointerToNonEmpty(fmt.Sprintf("%d", source.ID))
	acctNo, matchedCustomer := customerAccount(source.Entities)

	return posdomain.SambaTicket{
		VenueID:           venueID,
		TicketNo:          source.TicketNumber,
		OccurredAt:        occurredAt,
		Items:             items,
		Cashier:           cashier,
		TableLabel:        tableLabel,
		ServiceChargeKobo: pointerToInt64(nairaToKobo(serviceCharge)),
		DiscountKobo:      pointerToInt64(nairaToKobo(discount)),
		ChangeKobo:        pointerToInt64(0),
		PaymentMethod:     paymentMethod,
		AcctNo:            acctNo,
		ExternalID:        externalID,
		VATKobo:           pointerToInt64(nairaToKobo(source.TotalAmount - source.TotalAmountPreTax)),
	}, matchedCustomer
}

func isVoidedOrder(order posdomain.SambaSourceOrder) bool {
	for _, state := range order.OrderStates {
		if value, ok := state["S"].(string); ok && strings.EqualFold(value, "Void") {
			return true
		}
	}
	return false
}

func firstPaymentMethod(payments []posdomain.SambaSourcePayment) string {
	for _, payment := range payments {
		if strings.TrimSpace(payment.PaymentTypeName) != "" {
			return payment.PaymentTypeName
		}
		if strings.TrimSpace(payment.PaymentName) != "" {
			return payment.PaymentName
		}
	}
	return ""
}

func firstEntityName(entities []posdomain.SambaSourceEntity, entityType string) string {
	for _, entity := range entities {
		if strings.Contains(strings.ToLower(entity.EntityTypeName), entityType) && strings.TrimSpace(entity.EntityName) != "" {
			return entity.EntityName
		}
	}
	return ""
}

func customerAccount(entities []posdomain.SambaSourceEntity) (*string, bool) {
	for _, entity := range entities {
		entityType := strings.ToLower(entity.EntityTypeName)
		if strings.Contains(entityType, "customer") || strings.Contains(entityType, "account") || strings.Contains(entityType, "member") {
			return pointerToNonEmpty(firstNonEmpty(entity.EntityName, entity.Notes)), true
		}
	}
	return nil, false
}

func sumServiceCharges(calculations []posdomain.SambaSourceCalculation) float64 {
	var total float64
	for _, calculation := range calculations {
		name := strings.ToLower(calculation.Name)
		amount := calculation.Amount.Float64()
		if strings.Contains(name, "service") && amount > 0 {
			total += amount
		}
	}
	return total
}

func sumDiscounts(calculations []posdomain.SambaSourceCalculation) float64 {
	var total float64
	for _, calculation := range calculations {
		name := strings.ToLower(calculation.Name)
		decreaseAmount := calculation.DecreaseAmount.Float64()
		amount := calculation.Amount.Float64()
		calculationAmount := calculation.CalculationAmount.Float64()
		if strings.Contains(name, "discount") || decreaseAmount > 0 || amount < 0 {
			total += math.Abs(firstNonZero(decreaseAmount, amount, calculationAmount))
		}
	}
	return total
}

func nairaToKobo(value float64) int64 {
	return int64(math.Round(value * 100))
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func firstNonZero(values ...float64) float64 {
	for _, value := range values {
		if value != 0 {
			return value
		}
	}
	return 0
}

func pointerToNonEmpty(value string) *string {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	return &value
}

func pointerToInt64(value int64) *int64 {
	return &value
}
