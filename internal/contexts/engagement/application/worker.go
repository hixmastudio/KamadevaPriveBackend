package application

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
)

type Worker struct {
	repo                        engagementdomain.Repository
	messages                    engagementdomain.MessagingClient
	ai                          engagementdomain.AIClient
	interval                    time.Duration
	logger                      *slog.Logger
	bookingConfirmationTemplate string
}

type WorkerOption func(*Worker)

func WithBookingConfirmationTemplate(template string) WorkerOption {
	return func(w *Worker) {
		w.bookingConfirmationTemplate = strings.TrimSpace(template)
	}
}

func NewWorker(repo engagementdomain.Repository, messages engagementdomain.MessagingClient, ai engagementdomain.AIClient, interval time.Duration, logger *slog.Logger, options ...WorkerOption) *Worker {
	if logger == nil {
		logger = slog.Default()
	}
	if interval <= 0 {
		interval = 15 * time.Second
	}
	worker := &Worker{repo: repo, messages: messages, ai: ai, interval: interval, logger: logger}
	for _, option := range options {
		option(worker)
	}
	return worker
}

func (w *Worker) Start(ctx context.Context) {
	if w == nil || w.repo == nil || w.messages == nil {
		return
	}
	go func() {
		w.runOnce(ctx)
		ticker := time.NewTicker(w.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				w.runOnce(ctx)
			}
		}
	}()
}

func (w *Worker) runOnce(ctx context.Context) {
	events, err := w.repo.ClaimPendingOutboxEvents(ctx, 10)
	if err != nil {
		w.logger.Error("engagement_outbox_claim_failed", "error", err)
		return
	}
	for _, event := range events {
		if err := w.ProcessEvent(ctx, event); err != nil {
			w.logger.Error("engagement_outbox_event_failed", "event_id", event.ID, "event_type", event.Type, "error", err)
			_ = w.repo.MarkOutboxEventFailed(ctx, event.ID, err.Error())
			continue
		}
		_ = w.repo.MarkOutboxEventDone(ctx, event.ID)
	}
}

func (w *Worker) ProcessEvent(ctx context.Context, event engagementdomain.OutboxEvent) error {
	switch event.Type {
	case engagementdomain.EventBookingCreated:
		return w.sendBookingConfirmation(ctx, event)
	case engagementdomain.EventWhatsAppInboundReceived:
		return w.processInbound(ctx, event)
	default:
		return fmt.Errorf("unsupported engagement event type %q", event.Type)
	}
}

func (w *Worker) sendBookingConfirmation(ctx context.Context, event engagementdomain.OutboxEvent) error {
	var payload struct {
		BookingID string `json:"booking_id"`
		Phone     string `json:"phone"`
	}
	_ = json.Unmarshal(event.Payload, &payload)
	bookingID := firstNonEmpty(payload.BookingID, event.AggregateID)
	booking, err := w.repo.GetBooking(ctx, bookingID)
	if err != nil {
		return err
	}
	to := NormalizePhone(payload.Phone)
	if to == "" {
		return fmt.Errorf("booking %s has no WhatsApp destination", bookingID)
	}
	message := bookingConfirmationMessage(*booking)
	if w.bookingConfirmationTemplate != "" {
		if err := w.messages.SendTemplate(ctx, to, w.bookingConfirmationTemplate, bookingConfirmationTemplateParams(*booking)); err != nil {
			return err
		}
	} else {
		if err := w.messages.SendText(ctx, to, message); err != nil {
			return err
		}
	}
	conversation, err := w.repo.FindOrCreateConversation(ctx, booking.CustomerID, booking.ID, engagementdomain.ChannelWhatsApp)
	if err != nil {
		return err
	}
	_, err = w.repo.SaveMessage(ctx, engagementdomain.ConversationMessage{
		ConversationID: conversation.ID,
		Direction:      engagementdomain.DirectionOutbound,
		SenderType:     engagementdomain.SenderSystem,
		Body:           message,
		CreatedAt:      time.Now(),
	})
	return err
}

func (w *Worker) processInbound(ctx context.Context, event engagementdomain.OutboxEvent) error {
	var inbound engagementdomain.IncomingWhatsAppMessage
	if err := json.Unmarshal(event.Payload, &inbound); err != nil {
		return err
	}
	customer, err := w.repo.GetCustomerByPhone(ctx, NormalizePhone(inbound.From))
	if err != nil {
		return err
	}
	bookings, err := w.repo.GetCustomerActiveBookings(ctx, customer.ID)
	if err != nil {
		return err
	}
	bookingID := ""
	if len(bookings) == 1 {
		bookingID = bookings[0].ID
	}
	conversation, err := w.repo.FindOrCreateConversation(ctx, customer.ID, bookingID, engagementdomain.ChannelWhatsApp)
	if err != nil {
		return err
	}
	if conversation.Status == engagementdomain.ConversationHumanActive || conversation.Status == engagementdomain.ConversationClosed {
		_, err = w.repo.SaveMessage(ctx, engagementdomain.ConversationMessage{
			ConversationID:    conversation.ID,
			ExternalMessageID: inbound.MessageID,
			Direction:         engagementdomain.DirectionInbound,
			SenderType:        engagementdomain.SenderCustomer,
			Body:              inbound.Body,
			CreatedAt:         inbound.SentAt,
		})
		return err
	}
	if _, err := w.repo.SaveMessage(ctx, engagementdomain.ConversationMessage{
		ConversationID:    conversation.ID,
		ExternalMessageID: inbound.MessageID,
		Direction:         engagementdomain.DirectionInbound,
		SenderType:        engagementdomain.SenderCustomer,
		Body:              inbound.Body,
		CreatedAt:         inbound.SentAt,
	}); err != nil {
		return err
	}
	if handled, err := w.handlePendingConfirmation(ctx, conversation, customer.ID, NormalizePhone(inbound.From), inbound.Body); handled || err != nil {
		return err
	}

	if w.ai == nil {
		return w.reply(ctx, conversation, NormalizePhone(inbound.From), "Thanks for your message. A team member will follow up shortly.", engagementdomain.SenderSystem)
	}

	var booking *engagementdomain.BookingSummary
	if conversation.BookingID != "" {
		booking, _ = w.repo.GetBooking(ctx, conversation.BookingID)
	}
	history, err := w.repo.RecentMessages(ctx, conversation.ID, 12)
	if err != nil {
		return err
	}
	info, _ := w.repo.GetBusinessInformation(ctx)
	result, err := w.ai.ProcessConversation(ctx, engagementdomain.ConversationInput{
		Conversation:  *conversation,
		Customer:      *customer,
		Booking:       booking,
		Bookings:      bookings,
		Messages:      history,
		BusinessInfo:  info,
		LatestMessage: inbound.Body,
	})
	if err != nil {
		_ = w.repo.SetConversationStatus(ctx, conversation.ID, engagementdomain.ConversationWaitingForHuman)
		return w.reply(ctx, conversation, NormalizePhone(inbound.From), "I’m having trouble with this request. A team member will follow up shortly.", engagementdomain.SenderSystem)
	}
	if result.Escalate {
		if err := w.repo.SetConversationStatus(ctx, conversation.ID, engagementdomain.ConversationWaitingForHuman); err != nil {
			return err
		}
	}
	if result.PendingAction != nil {
		if err := w.repo.SetPendingAction(ctx, conversation.ID, result.PendingAction); err != nil {
			return err
		}
	}
	for _, call := range result.ToolCalls {
		if err := w.executeToolCall(ctx, conversation, customer.ID, call); err != nil {
			w.logger.Error("ai_tool_call_failed", "conversation_id", conversation.ID, "action", call.Name, "error", err)
		}
	}
	if strings.TrimSpace(result.Reply) == "" {
		return nil
	}
	return w.reply(ctx, conversation, NormalizePhone(inbound.From), result.Reply, engagementdomain.SenderAI)
}

func (w *Worker) handlePendingConfirmation(ctx context.Context, conversation *engagementdomain.Conversation, customerID, to, body string) (bool, error) {
	if len(conversation.PendingAction) == 0 || string(conversation.PendingAction) == "null" {
		return false, nil
	}
	if isNegative(body) {
		if err := w.repo.SetPendingAction(ctx, conversation.ID, nil); err != nil {
			return true, err
		}
		return true, w.reply(ctx, conversation, to, "No problem. I have not changed your booking.", engagementdomain.SenderAI)
	}
	if !isAffirmative(body) {
		return false, nil
	}

	var action engagementdomain.PendingAction
	if err := json.Unmarshal(conversation.PendingAction, &action); err != nil {
		if setErr := w.repo.SetConversationStatus(ctx, conversation.ID, engagementdomain.ConversationWaitingForHuman); setErr != nil {
			return true, setErr
		}
		return true, w.reply(ctx, conversation, to, "I’m having trouble confirming that request. A team member will follow up shortly.", engagementdomain.SenderSystem)
	}
	call := engagementdomain.AIToolCall{Name: action.Action, Args: action.Arguments}
	if action.BookingID != "" {
		args := map[string]any{}
		_ = json.Unmarshal(action.Arguments, &args)
		args["booking_id"] = action.BookingID
		call.Args, _ = json.Marshal(args)
	}
	if err := w.executeToolCall(ctx, conversation, customerID, call); err != nil {
		return true, w.reply(ctx, conversation, to, "I couldn’t complete that change. A team member will follow up shortly.", engagementdomain.SenderSystem)
	}
	if err := w.repo.SetPendingAction(ctx, conversation.ID, nil); err != nil {
		return true, err
	}
	switch action.Action {
	case "cancel_booking":
		return true, w.reply(ctx, conversation, to, "Your booking has been cancelled.", engagementdomain.SenderAI)
	case "request_reschedule_booking":
		return true, w.reply(ctx, conversation, to, "Your booking has been rescheduled.", engagementdomain.SenderAI)
	default:
		return true, w.reply(ctx, conversation, to, "Done.", engagementdomain.SenderAI)
	}
}

func (w *Worker) executeToolCall(ctx context.Context, conversation *engagementdomain.Conversation, customerID string, call engagementdomain.AIToolCall) error {
	if call.RequiresConfirmation {
		return w.repo.SetPendingAction(ctx, conversation.ID, &engagementdomain.PendingAction{Action: call.Name, BookingID: conversation.BookingID, Arguments: call.Args})
	}

	var result any
	status := engagementdomain.ActionStatusSuccess
	err := error(nil)
	switch call.Name {
	case "request_human_agent":
		err = w.repo.SetConversationStatus(ctx, conversation.ID, engagementdomain.ConversationWaitingForHuman)
	case "cancel_booking":
		var args struct {
			BookingID string `json:"booking_id"`
		}
		_ = json.Unmarshal(call.Args, &args)
		err = w.repo.CancelBooking(ctx, firstNonEmpty(args.BookingID, conversation.BookingID))
	case "request_reschedule_booking":
		var args struct {
			BookingID string `json:"booking_id"`
			SlotID    string `json:"slot_id"`
		}
		_ = json.Unmarshal(call.Args, &args)
		err = w.repo.RescheduleBooking(ctx, firstNonEmpty(args.BookingID, conversation.BookingID), args.SlotID)
	default:
		result = "ignored informational tool"
	}
	if err != nil {
		status = engagementdomain.ActionStatusFailed
		result = map[string]string{"error": err.Error()}
	}
	_ = w.repo.RecordAIAction(ctx, conversation.ID, customerID, conversation.BookingID, call.Name, call.Args, result, status)
	return err
}

func isAffirmative(body string) bool {
	normalized := strings.ToLower(strings.TrimSpace(body))
	switch normalized {
	case "yes", "y", "yeah", "yep", "confirm", "confirmed", "please do", "go ahead", "ok", "okay":
		return true
	default:
		return false
	}
}

func isNegative(body string) bool {
	normalized := strings.ToLower(strings.TrimSpace(body))
	switch normalized {
	case "no", "n", "nope", "cancel", "do not", "don't", "dont", "stop":
		return true
	default:
		return false
	}
}

func (w *Worker) reply(ctx context.Context, conversation *engagementdomain.Conversation, to, body, sender string) error {
	if err := w.messages.SendText(ctx, to, body); err != nil {
		return err
	}
	_, err := w.repo.SaveMessage(ctx, engagementdomain.ConversationMessage{
		ConversationID: conversation.ID,
		Direction:      engagementdomain.DirectionOutbound,
		SenderType:     sender,
		Body:           body,
		CreatedAt:      time.Now(),
	})
	return err
}

func bookingConfirmationMessage(booking engagementdomain.BookingSummary) string {
	name := strings.TrimSpace(booking.ServiceName)
	if name == "" {
		name = "Booking"
	}
	return fmt.Sprintf("Hello,\n\nYour booking has been confirmed.\n\nBooking ID: %s\nService: %s\nDate: %s\nTime: %s\n\nYou can reply to this message if you need help with your booking.",
		booking.ID,
		name,
		booking.StartsAt.Format("2 January 2006"),
		booking.StartsAt.Format("3:04 PM"),
	)
}

func bookingConfirmationTemplateParams(booking engagementdomain.BookingSummary) map[string]string {
	service := strings.TrimSpace(booking.ServiceName)
	if service == "" {
		service = "Booking"
	}
	return map[string]string{
		"booking_id": booking.ID,
		"service":    service,
		"date":       booking.StartsAt.Format("2 January 2006"),
		"time":       booking.StartsAt.Format("3:04 PM"),
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
