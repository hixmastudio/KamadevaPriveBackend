package application

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
)

func TestBookingConfirmationSendsMessageAndPersistsOutbound(t *testing.T) {
	repo := &workerRepo{
		booking: engagementdomain.BookingSummary{
			ID:           "BK-92821",
			CustomerID:   "cust_1",
			CustomerName: "Ada",
			ServiceName:  "Haircut",
			StartsAt:     time.Date(2026, 8, 20, 14, 0, 0, 0, time.UTC),
			PartySize:    3,
		},
	}
	messages := &fakeMessenger{}
	worker := NewWorker(repo, messages, nil, time.Second, nil)
	payload, _ := json.Marshal(map[string]string{"booking_id": "BK-92821", "phone": "+2348012345678"})

	err := worker.ProcessEvent(context.Background(), engagementdomain.OutboxEvent{
		ID:          "evt_1",
		Type:        engagementdomain.EventBookingCreated,
		AggregateID: "BK-92821",
		Payload:     payload,
	})
	if err != nil {
		t.Fatalf("expected confirmation processed: %v", err)
	}
	if len(messages.sent) != 1 {
		t.Fatalf("expected one WhatsApp message, got %d", len(messages.sent))
	}
	if len(repo.messages) != 1 || repo.messages[0].Direction != engagementdomain.DirectionOutbound {
		t.Fatalf("expected outbound message persisted, got %#v", repo.messages)
	}
}

func TestBookingRemainsSuccessfulWhenWhatsAppSendingFails(t *testing.T) {
	repo := &workerRepo{booking: engagementdomain.BookingSummary{ID: "BK-1", CustomerID: "cust_1", StartsAt: time.Now()}}
	worker := NewWorker(repo, &fakeMessenger{err: errors.New("meta unavailable")}, nil, time.Second, nil)
	payload, _ := json.Marshal(map[string]string{"booking_id": "BK-1", "phone": "+2348012345678"})

	err := worker.ProcessEvent(context.Background(), engagementdomain.OutboxEvent{
		ID:          "evt_1",
		Type:        engagementdomain.EventBookingCreated,
		AggregateID: "BK-1",
		Payload:     payload,
	})
	if err != nil {
		t.Fatalf("expected WhatsApp failure not to fail booking outbox event: %v", err)
	}
	if len(repo.messages) != 0 {
		t.Fatalf("should not persist outbound success when send fails")
	}
}

func TestNormalizePhone(t *testing.T) {
	tests := map[string]string{
		"08012345678":     "2348012345678",
		"+2348012345678":  "2348012345678",
		"2348012345678":   "2348012345678",
		"+14155550100":    "14155550100",
		"14155550100":     "14155550100",
		"004414812345678": "4414812345678",
		" 0801 234 5678 ": "2348012345678",
	}
	for input, want := range tests {
		if got := NormalizePhone(input); got != want {
			t.Fatalf("NormalizePhone(%q): expected %q, got %q", input, want, got)
		}
	}
}

func TestBookingConfirmationTemplateParams(t *testing.T) {
	booking := engagementdomain.BookingSummary{
		ID:           "BK-92821",
		CustomerName: "Ada",
		ServiceName:  "Oso Lounge",
		StartsAt:     time.Date(2026, 9, 5, 20, 30, 0, 0, time.UTC),
		PartySize:    5,
	}
	got := bookingConfirmationTemplateParams(booking)
	want := map[string]string{
		"customer_name":     "Ada",
		"venue":             "Oso Lounge",
		"date":              "5 September 2026",
		"time":              "8:30 PM",
		"guests":            "5",
		"booking_reference": "BK-92821",
	}
	for key, value := range want {
		if got[key] != value {
			t.Fatalf("template param %s: expected %q, got %q", key, value, got[key])
		}
	}
}

func TestHumanActiveConversationDisablesAIResponse(t *testing.T) {
	inbound, _ := json.Marshal(engagementdomain.IncomingWhatsAppMessage{
		MessageID: "wamid.2",
		From:      "+2348012345678",
		Body:      "Can I speak to someone?",
		SentAt:    time.Now(),
	})
	repo := &workerRepo{
		customer: engagementdomain.CustomerSummary{ID: "cust_1", Phone: "+2348012345678"},
		conversation: engagementdomain.Conversation{
			ID:         "conv_1",
			CustomerID: "cust_1",
			Status:     engagementdomain.ConversationHumanActive,
			Channel:    engagementdomain.ChannelWhatsApp,
		},
	}
	messages := &fakeMessenger{}
	ai := &fakeAI{reply: "AI should not send this"}
	worker := NewWorker(repo, messages, ai, time.Second, nil)

	err := worker.ProcessEvent(context.Background(), engagementdomain.OutboxEvent{
		ID:      "evt_2",
		Type:    engagementdomain.EventWhatsAppInboundReceived,
		Payload: inbound,
	})
	if err != nil {
		t.Fatalf("expected inbound persisted without AI: %v", err)
	}
	if ai.called {
		t.Fatalf("expected AI not to be called for human-active conversation")
	}
	if len(messages.sent) != 0 {
		t.Fatalf("expected no automated WhatsApp reply")
	}
}

func TestAdminReplyEventSendsWhatsAppAndPersistsHumanMessage(t *testing.T) {
	payload, _ := json.Marshal(map[string]string{
		"conversation_id": "conv_1",
		"customer_id":     "cust_1",
		"body":            "Good evening, your table is ready.",
	})
	repo := &workerRepo{
		customer: engagementdomain.CustomerSummary{ID: "cust_1", Phone: "+2348012345678"},
		conversation: engagementdomain.Conversation{
			ID:         "conv_1",
			CustomerID: "cust_1",
			Status:     engagementdomain.ConversationWaitingForHuman,
			Channel:    engagementdomain.ChannelWhatsApp,
		},
	}
	messages := &fakeMessenger{}
	worker := NewWorker(repo, messages, nil, time.Second, nil)

	err := worker.ProcessEvent(context.Background(), engagementdomain.OutboxEvent{
		ID:          "evt_4",
		Type:        engagementdomain.EventWhatsAppAdminReply,
		AggregateID: "conv_1",
		Payload:     payload,
	})
	if err != nil {
		t.Fatalf("expected admin reply sent: %v", err)
	}
	if len(messages.sent) != 1 || messages.sent[0] != "Good evening, your table is ready." {
		t.Fatalf("expected WhatsApp reply sent, got %#v", messages.sent)
	}
	if repo.status != engagementdomain.ConversationHumanActive {
		t.Fatalf("expected human-active status, got %q", repo.status)
	}
	if len(repo.messages) != 1 || repo.messages[0].SenderType != engagementdomain.SenderHuman {
		t.Fatalf("expected persisted human outbound message, got %#v", repo.messages)
	}
}

func TestPendingCancellationRequiresExplicitConfirmation(t *testing.T) {
	args, _ := json.Marshal(map[string]string{"booking_id": "BK-1"})
	pending, _ := json.Marshal(engagementdomain.PendingAction{
		Action:    "cancel_booking",
		BookingID: "BK-1",
		Arguments: args,
	})
	inbound, _ := json.Marshal(engagementdomain.IncomingWhatsAppMessage{
		MessageID: "wamid.3",
		From:      "+2348012345678",
		Body:      "yes",
		SentAt:    time.Now(),
	})
	repo := &workerRepo{
		customer: engagementdomain.CustomerSummary{ID: "cust_1", Phone: "+2348012345678"},
		conversation: engagementdomain.Conversation{
			ID:            "conv_1",
			CustomerID:    "cust_1",
			BookingID:     "BK-1",
			Status:        engagementdomain.ConversationAIActive,
			Channel:       engagementdomain.ChannelWhatsApp,
			PendingAction: pending,
		},
	}
	messages := &fakeMessenger{}
	ai := &fakeAI{reply: "AI should not be needed"}
	worker := NewWorker(repo, messages, ai, time.Second, nil)

	err := worker.ProcessEvent(context.Background(), engagementdomain.OutboxEvent{
		ID:      "evt_3",
		Type:    engagementdomain.EventWhatsAppInboundReceived,
		Payload: inbound,
	})
	if err != nil {
		t.Fatalf("expected pending cancellation confirmed: %v", err)
	}
	if ai.called {
		t.Fatalf("expected pending confirmation to bypass AI")
	}
	if !repo.cancelled {
		t.Fatalf("expected cancellation tool to run")
	}
	if !repo.pendingCleared {
		t.Fatalf("expected pending action cleared")
	}
	if len(messages.sent) != 1 || messages.sent[0] != "Your booking has been cancelled." {
		t.Fatalf("expected cancellation confirmation reply, got %#v", messages.sent)
	}
}

type fakeMessenger struct {
	sent []string
	err  error
}

func (m *fakeMessenger) SendText(_ context.Context, _ string, message string) (*engagementdomain.MessageSendResult, error) {
	if m.err != nil {
		return nil, m.err
	}
	m.sent = append(m.sent, message)
	return &engagementdomain.MessageSendResult{MessageID: "wamid.fake"}, nil
}

func (m *fakeMessenger) SendTemplate(context.Context, string, string, map[string]string) (*engagementdomain.MessageSendResult, error) {
	if m.err != nil {
		return nil, m.err
	}
	m.sent = append(m.sent, "template")
	return &engagementdomain.MessageSendResult{MessageID: "wamid.template"}, nil
}

type fakeAI struct {
	called bool
	reply  string
}

func (a *fakeAI) ProcessConversation(context.Context, engagementdomain.ConversationInput) (engagementdomain.ConversationResult, error) {
	a.called = true
	return engagementdomain.ConversationResult{Reply: a.reply}, nil
}

type workerRepo struct {
	fakeRepo
	booking        engagementdomain.BookingSummary
	customer       engagementdomain.CustomerSummary
	conversation   engagementdomain.Conversation
	messages       []engagementdomain.ConversationMessage
	status         string
	cancelled      bool
	pendingCleared bool
}

func (r *workerRepo) GetBooking(context.Context, string) (*engagementdomain.BookingSummary, error) {
	return &r.booking, nil
}

func (r *workerRepo) GetCustomer(context.Context, string) (*engagementdomain.CustomerSummary, error) {
	return &r.customer, nil
}

func (r *workerRepo) GetCustomerByPhone(context.Context, string) (*engagementdomain.CustomerSummary, error) {
	return &r.customer, nil
}

func (r *workerRepo) FindOrCreateConversation(context.Context, string, string, string) (*engagementdomain.Conversation, error) {
	if r.conversation.ID == "" {
		r.conversation = engagementdomain.Conversation{ID: "conv_1", Status: engagementdomain.ConversationAIActive}
	}
	return &r.conversation, nil
}

func (r *workerRepo) SaveMessage(_ context.Context, message engagementdomain.ConversationMessage) (*engagementdomain.ConversationMessage, error) {
	r.messages = append(r.messages, message)
	return &message, nil
}

func (r *workerRepo) SetPendingAction(_ context.Context, _ string, action *engagementdomain.PendingAction) error {
	if action == nil {
		r.pendingCleared = true
	}
	return nil
}

func (r *workerRepo) SetConversationStatus(_ context.Context, _ string, status string) error {
	r.status = status
	return nil
}

func (r *workerRepo) CancelBooking(context.Context, string) error {
	r.cancelled = true
	return nil
}
