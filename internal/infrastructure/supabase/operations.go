package supabase

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	reportingdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type Operations struct {
	baseURL    string
	serviceKey string
	client     *http.Client
}

func NewOperations(supabaseURL, serviceKey string, client *http.Client) *Operations {
	return &Operations{
		baseURL:    strings.TrimRight(supabaseURL, "/") + "/rest/v1",
		serviceKey: serviceKey,
		client:     client,
	}
}

func (o *Operations) SaveSambaTicket(ctx context.Context, ticket posdomain.SambaTicket) (string, error) {
	body := map[string]any{
		"p_venue_id":             ticket.VenueID,
		"p_ticket_no":            ticket.TicketNo,
		"p_occurred_at":          ticket.OccurredAt,
		"p_items":                ticket.Items,
		"p_cashier":              ticket.Cashier,
		"p_table_label":          ticket.TableLabel,
		"p_vat_kobo":             ticket.VATKobo,
		"p_consumption_tax_kobo": ticket.ConsumptionTaxKobo,
		"p_service_charge_kobo":  valueOrDefaultInt(ticket.ServiceChargeKobo, 0),
		"p_change_kobo":          valueOrDefaultInt(ticket.ChangeKobo, 0),
		"p_payment_method":       ticket.PaymentMethod,
		"p_acct_no":              ticket.AcctNo,
		"p_bank_name":            ticket.BankName,
		"p_source":               "samba",
		"p_external_id":          ticket.ExternalID,
	}
	var ticketID string
	if err := o.rpc(ctx, "pos_ingest_ticket", body, &ticketID); err != nil {
		return "", err
	}
	return ticketID, nil
}

func (o *Operations) RunTierDecaySweep(ctx context.Context) error {
	return o.rpc(ctx, "sweep_tier_decay", map[string]any{}, nil)
}

func (o *Operations) EnsureAuditPartition(ctx context.Context, month string) error {
	return o.rpc(ctx, "ensure_audit_partition", map[string]any{"p_month": month}, nil)
}

func (o *Operations) GetCaptureRateReport(ctx context.Context, from, to string) (reportingdomain.CaptureRateReport, error) {
	var venues []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := o.selectRows(ctx, "/venues", url.Values{
		"select":    {"id,name"},
		"is_active": {"eq.true"},
		"order":     {"name.asc"},
	}, &venues); err != nil {
		return reportingdomain.CaptureRateReport{}, err
	}

	var headcounts []struct {
		VenueID      string `json:"venue_id"`
		TotalEntries int64  `json:"total_entries"`
	}
	if err := o.selectRows(ctx, "/shift_entry_counts", url.Values{
		"select":        {"venue_id,total_entries"},
		"business_date": {"gte." + from, "lte." + to},
	}, &headcounts); err != nil {
		return reportingdomain.CaptureRateReport{}, err
	}

	var visits []struct {
		VenueID string `json:"venue_id"`
	}
	if err := o.selectRows(ctx, "/visits", url.Values{
		"select":        {"venue_id"},
		"business_date": {"gte." + from, "lte." + to},
		"voided_at":     {"is.null"},
	}, &visits); err != nil {
		return reportingdomain.CaptureRateReport{}, err
	}

	entriesByVenue := map[string]int64{}
	for _, row := range headcounts {
		entriesByVenue[row.VenueID] += row.TotalEntries
	}
	visitsByVenue := map[string]int64{}
	for _, row := range visits {
		visitsByVenue[row.VenueID]++
	}

	report := reportingdomain.CaptureRateReport{From: from, To: to}
	for _, venue := range venues {
		total := entriesByVenue[venue.ID]
		captured := visitsByVenue[venue.ID]
		var rate *float64
		if total > 0 {
			value := float64(captured) / float64(total)
			rate = &value
		}
		report.Venues = append(report.Venues, reportingdomain.CaptureRateRow{
			VenueID:        venue.ID,
			VenueName:      venue.Name,
			TotalEntries:   total,
			CapturedVisits: captured,
			CaptureRate:    rate,
		})
	}
	return report, nil
}

func (o *Operations) rpc(ctx context.Context, name string, body any, out any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/rpc/"+name, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	o.setHeaders(req)
	req.Header.Set("Content-Type", "application/json")

	return o.do(req, out, "Supabase RPC "+name+" failed")
}

func (o *Operations) selectRows(ctx context.Context, path string, query url.Values, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, o.baseURL+path+"?"+query.Encode(), nil)
	if err != nil {
		return err
	}
	o.setHeaders(req)
	return o.do(req, out, "Supabase select "+path+" failed")
}

func (o *Operations) setHeaders(req *http.Request) {
	req.Header.Set("apikey", o.serviceKey)
	req.Header.Set("Authorization", "Bearer "+o.serviceKey)
}

func (o *Operations) do(req *http.Request, out any, message string) error {
	res, err := o.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode > 299 {
		var details any
		_ = json.NewDecoder(res.Body).Decode(&details)
		return shareddomain.UpstreamError(message, details)
	}

	if out == nil {
		return nil
	}
	if err := json.NewDecoder(res.Body).Decode(out); err != nil {
		return fmt.Errorf("%s: %w", message, err)
	}
	return nil
}

func valueOrDefaultInt(value *int64, fallback int64) int64 {
	if value == nil {
		return fallback
	}
	return *value
}
