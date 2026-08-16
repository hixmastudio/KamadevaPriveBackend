package domain

import (
	"regexp"
	"strings"
	"time"

	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

type SambaTicketItem struct {
	Name          string  `json:"name"`
	Quantity      float64 `json:"quantity"`
	UnitPriceKobo int64   `json:"unit_price_kobo"`
}

type SambaTicket struct {
	VenueID            string            `json:"venue_id"`
	TicketNo           string            `json:"ticket_no"`
	OccurredAt         string            `json:"occurred_at"`
	Items              []SambaTicketItem `json:"items"`
	Cashier            *string           `json:"cashier,omitempty"`
	TableLabel         *string           `json:"table_label,omitempty"`
	VATKobo            *int64            `json:"vat_kobo,omitempty"`
	ConsumptionTaxKobo *int64            `json:"consumption_tax_kobo,omitempty"`
	DiscountKobo       *int64            `json:"discount_kobo,omitempty"`
	ServiceChargeKobo  *int64            `json:"service_charge_kobo,omitempty"`
	ChangeKobo         *int64            `json:"change_kobo,omitempty"`
	PaymentMethod      *string           `json:"payment_method,omitempty"`
	AcctNo             *string           `json:"acct_no,omitempty"`
	BankName           *string           `json:"bank_name,omitempty"`
	ExternalID         *string           `json:"external_id,omitempty"`
}

type SambaHeartbeat struct {
	VenueID          string `json:"venue_id"`
	TerminalID       string `json:"terminal_id"`
	ExtensionVersion string `json:"extension_version"`
	SambaVersion     string `json:"samba_version,omitempty"`
	ObservedAt       string `json:"observed_at,omitempty"`
}

func (t SambaTicket) Validate() error {
	if strings.TrimSpace(t.VenueID) == "" || strings.TrimSpace(t.TicketNo) == "" {
		return shareddomain.ValidationError(map[string]string{"ticket": "venue_id and ticket_no are required"})
	}
	if !uuidPattern.MatchString(t.VenueID) {
		return shareddomain.ValidationError(map[string]string{"venue_id": "must be a UUID"})
	}
	if len(strings.TrimSpace(t.TicketNo)) > 120 {
		return shareddomain.ValidationError(map[string]string{"ticket_no": "must be 120 characters or fewer"})
	}
	if _, err := time.Parse(time.RFC3339, t.OccurredAt); err != nil {
		return shareddomain.ValidationError(map[string]string{"occurred_at": "must be RFC3339 with timezone"})
	}
	if len(t.Items) == 0 {
		return shareddomain.ValidationError(map[string]string{"items": "at least one item is required"})
	}
	if len(t.Items) > 250 {
		return shareddomain.ValidationError(map[string]string{"items": "must contain 250 line items or fewer"})
	}
	for _, item := range t.Items {
		if strings.TrimSpace(item.Name) == "" || item.Quantity <= 0 || item.UnitPriceKobo < 0 {
			return shareddomain.ValidationError(map[string]string{"items": "each item needs name, positive quantity, and non-negative unit_price_kobo"})
		}
		if len(strings.TrimSpace(item.Name)) > 160 {
			return shareddomain.ValidationError(map[string]string{"items": "line item names must be 160 characters or fewer"})
		}
	}
	return nil
}

func (h SambaHeartbeat) Validate() error {
	if !uuidPattern.MatchString(strings.TrimSpace(h.VenueID)) {
		return shareddomain.ValidationError(map[string]string{"venue_id": "must be a UUID"})
	}
	if len(strings.TrimSpace(h.TerminalID)) < 2 || len(strings.TrimSpace(h.TerminalID)) > 120 {
		return shareddomain.ValidationError(map[string]string{"terminal_id": "must be between 2 and 120 characters"})
	}
	if len(strings.TrimSpace(h.ExtensionVersion)) < 1 || len(strings.TrimSpace(h.ExtensionVersion)) > 80 {
		return shareddomain.ValidationError(map[string]string{"extension_version": "must be between 1 and 80 characters"})
	}
	if h.ObservedAt != "" {
		if _, err := time.Parse(time.RFC3339, h.ObservedAt); err != nil {
			return shareddomain.ValidationError(map[string]string{"observed_at": "must be RFC3339 with timezone"})
		}
	}
	return nil
}
