package supabase

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	reportingdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type Operations struct {
	baseURL    string
	serviceKey string
	client     *http.Client
	logger     *slog.Logger
}

func NewOperations(supabaseURL, serviceKey string, client *http.Client) *Operations {
	return &Operations{
		baseURL:    strings.TrimRight(supabaseURL, "/") + "/rest/v1",
		serviceKey: serviceKey,
		client:     client,
		logger:     slog.Default(),
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

func (o *Operations) ClaimPendingOutboxEvents(ctx context.Context, limit int) ([]engagementdomain.OutboxEvent, error) {
	var events []engagementdomain.OutboxEvent
	if err := o.rpc(ctx, "engagement_claim_outbox_events", map[string]any{"p_limit": limit}, &events); err != nil {
		return nil, err
	}
	return events, nil
}

func (o *Operations) MarkOutboxEventDone(ctx context.Context, eventID string) error {
	return o.rpc(ctx, "engagement_mark_outbox_done", map[string]any{"p_event_id": eventID}, nil)
}

func (o *Operations) MarkOutboxEventFailed(ctx context.Context, eventID string, reason string) error {
	return o.rpc(ctx, "engagement_mark_outbox_failed", map[string]any{"p_event_id": eventID, "p_reason": reason}, nil)
}

func (o *Operations) GetBooking(ctx context.Context, bookingID string) (*engagementdomain.BookingSummary, error) {
	var booking engagementdomain.BookingSummary
	if err := o.rpc(ctx, "engagement_get_booking", map[string]any{"p_booking_id": bookingID}, &booking); err != nil {
		return nil, err
	}
	return &booking, nil
}

func (o *Operations) GetCustomerByPhone(ctx context.Context, phone string) (*engagementdomain.CustomerSummary, error) {
	var customer engagementdomain.CustomerSummary
	if err := o.rpc(ctx, "engagement_get_customer_by_phone", map[string]any{"p_phone": phone}, &customer); err != nil {
		return nil, err
	}
	return &customer, nil
}

func (o *Operations) GetCustomerActiveBookings(ctx context.Context, customerID string) ([]engagementdomain.BookingSummary, error) {
	var bookings []engagementdomain.BookingSummary
	if err := o.rpc(ctx, "engagement_get_customer_active_bookings", map[string]any{"p_customer_id": customerID}, &bookings); err != nil {
		return nil, err
	}
	return bookings, nil
}

func (o *Operations) FindOrCreateConversation(ctx context.Context, customerID, bookingID, channel string) (*engagementdomain.Conversation, error) {
	var conversation engagementdomain.Conversation
	if err := o.rpc(ctx, "engagement_find_or_create_conversation", map[string]any{
		"p_customer_id": customerID,
		"p_booking_id":  nullableString(bookingID),
		"p_channel":     channel,
	}, &conversation); err != nil {
		return nil, err
	}
	return &conversation, nil
}

func (o *Operations) GetConversation(ctx context.Context, conversationID string) (*engagementdomain.Conversation, error) {
	var conversation engagementdomain.Conversation
	if err := o.rpc(ctx, "engagement_get_conversation", map[string]any{"p_conversation_id": conversationID}, &conversation); err != nil {
		return nil, err
	}
	return &conversation, nil
}

func (o *Operations) SetConversationStatus(ctx context.Context, conversationID, status string) error {
	return o.rpc(ctx, "engagement_set_conversation_status", map[string]any{"p_conversation_id": conversationID, "p_status": status}, nil)
}

func (o *Operations) SetPendingAction(ctx context.Context, conversationID string, action *engagementdomain.PendingAction) error {
	return o.rpc(ctx, "engagement_set_pending_action", map[string]any{"p_conversation_id": conversationID, "p_pending_action": action}, nil)
}

func (o *Operations) RecentMessages(ctx context.Context, conversationID string, limit int) ([]engagementdomain.ConversationMessage, error) {
	var messages []engagementdomain.ConversationMessage
	if err := o.rpc(ctx, "engagement_recent_messages", map[string]any{"p_conversation_id": conversationID, "p_limit": limit}, &messages); err != nil {
		return nil, err
	}
	return messages, nil
}

func (o *Operations) SaveMessage(ctx context.Context, message engagementdomain.ConversationMessage) (*engagementdomain.ConversationMessage, error) {
	var saved engagementdomain.ConversationMessage
	if err := o.rpc(ctx, "engagement_save_message", map[string]any{
		"p_conversation_id":     message.ConversationID,
		"p_external_message_id": nullableString(message.ExternalMessageID),
		"p_direction":           message.Direction,
		"p_sender_type":         message.SenderType,
		"p_body":                message.Body,
		"p_created_at":          message.CreatedAt,
	}, &saved); err != nil {
		return nil, err
	}
	return &saved, nil
}

func (o *Operations) HasExternalMessage(ctx context.Context, externalMessageID string) (bool, error) {
	if externalMessageID == "" {
		return false, nil
	}
	var rows []struct {
		ID string `json:"id"`
	}
	if err := o.selectRows(ctx, "/conversation_messages", url.Values{
		"select":              {"id"},
		"external_message_id": {"eq." + externalMessageID},
		"limit":               {"1"},
	}, &rows); err != nil {
		return false, err
	}
	return len(rows) > 0, nil
}

func (o *Operations) EnqueueIncomingWhatsApp(ctx context.Context, message engagementdomain.IncomingWhatsAppMessage) error {
	return o.rpc(ctx, "engagement_enqueue_whatsapp_inbound", map[string]any{
		"p_message_id": message.MessageID,
		"p_from":       message.From,
		"p_body":       message.Body,
		"p_sent_at":    message.SentAt,
	}, nil)
}

func (o *Operations) UpdateWhatsAppStatus(ctx context.Context, status engagementdomain.WhatsAppStatus) error {
	return o.rpc(ctx, "engagement_update_whatsapp_status", map[string]any{
		"p_message_id": status.MessageID,
		"p_status":     status.Status,
		"p_error_code": nullableString(status.ErrorCode),
		"p_error_text": nullableString(status.ErrorText),
	}, nil)
}

func (o *Operations) RecordAIAction(ctx context.Context, conversationID, customerID, bookingID, action string, args any, result any, status string) error {
	return o.rpc(ctx, "engagement_record_ai_action", map[string]any{
		"p_conversation_id": conversationID,
		"p_customer_id":     customerID,
		"p_booking_id":      nullableString(bookingID),
		"p_action":          action,
		"p_arguments":       args,
		"p_result":          result,
		"p_status":          status,
	}, nil)
}

func (o *Operations) GetBusinessInformation(ctx context.Context) (engagementdomain.BusinessInformation, error) {
	var info engagementdomain.BusinessInformation
	if err := o.rpc(ctx, "engagement_get_business_information", map[string]any{}, &info); err != nil {
		return engagementdomain.BusinessInformation{}, err
	}
	return info, nil
}

func (o *Operations) CheckAvailability(ctx context.Context, serviceID string, requestedTime time.Time) ([]engagementdomain.AvailableSlot, error) {
	var slots []engagementdomain.AvailableSlot
	if err := o.rpc(ctx, "booking_check_availability", map[string]any{"p_service_id": serviceID, "p_requested_time": requestedTime}, &slots); err != nil {
		return nil, err
	}
	return slots, nil
}

func (o *Operations) RescheduleBooking(ctx context.Context, bookingID, slotID string) error {
	return o.rpc(ctx, "booking_reschedule", map[string]any{"p_booking_id": bookingID, "p_slot_id": slotID, "p_source": "whatsapp_ai"}, nil)
}

func (o *Operations) CancelBooking(ctx context.Context, bookingID string) error {
	return o.rpc(ctx, "booking_cancel", map[string]any{"p_booking_id": bookingID, "p_source": "whatsapp_ai"}, nil)
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
		o.logger.Error("supabase_request_failed",
			"method", req.Method,
			"path", req.URL.Path,
			"status", res.StatusCode,
			"message", message,
			"details", details,
		)
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

func nullableString(value string) any {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return value
}
