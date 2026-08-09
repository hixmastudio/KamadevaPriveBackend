package domain

import (
	"strings"
	"time"

	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

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
	ServiceChargeKobo  *int64            `json:"service_charge_kobo,omitempty"`
	ChangeKobo         *int64            `json:"change_kobo,omitempty"`
	PaymentMethod      *string           `json:"payment_method,omitempty"`
	AcctNo             *string           `json:"acct_no,omitempty"`
	BankName           *string           `json:"bank_name,omitempty"`
	ExternalID         *string           `json:"external_id,omitempty"`
}

func (t SambaTicket) Validate() error {
	if strings.TrimSpace(t.VenueID) == "" || strings.TrimSpace(t.TicketNo) == "" {
		return shareddomain.ValidationError(map[string]string{"ticket": "venue_id and ticket_no are required"})
	}
	if _, err := time.Parse(time.RFC3339, t.OccurredAt); err != nil {
		return shareddomain.ValidationError(map[string]string{"occurred_at": "must be RFC3339 with timezone"})
	}
	if len(t.Items) == 0 {
		return shareddomain.ValidationError(map[string]string{"items": "at least one item is required"})
	}
	for _, item := range t.Items {
		if strings.TrimSpace(item.Name) == "" || item.Quantity <= 0 || item.UnitPriceKobo < 0 {
			return shareddomain.ValidationError(map[string]string{"items": "each item needs name, positive quantity, and non-negative unit_price_kobo"})
		}
	}
	return nil
}
