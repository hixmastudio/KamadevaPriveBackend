package application

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"testing"
	"time"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
)

func TestWhatsAppWebhookVerification(t *testing.T) {
	svc := NewWebhookIntakeService(&fakeRepo{}, "verify-token-123456", "", nil)

	challenge, err := svc.VerifyWhatsAppWebhook(map[string]string{
		"hub.mode":         "subscribe",
		"hub.verify_token": "verify-token-123456",
		"hub.challenge":    "abc123",
	})
	if err != nil {
		t.Fatalf("expected verification success: %v", err)
	}
	if challenge != "abc123" {
		t.Fatalf("expected challenge abc123, got %q", challenge)
	}

	if _, err := svc.VerifyWhatsAppWebhook(map[string]string{
		"hub.mode":         "subscribe",
		"hub.verify_token": "wrong",
		"hub.challenge":    "abc123",
	}); err == nil {
		t.Fatalf("expected invalid verification to fail")
	}
}

func TestAcceptWhatsAppWebhookRejectsInvalidSignature(t *testing.T) {
	svc := NewWebhookIntakeService(&fakeRepo{}, "verify-token-123456", "app-secret-123456", nil)

	_, err := svc.AcceptWhatsAppWebhook(context.Background(), http.Header{}, []byte(`{"entry":[]}`))
	if err == nil {
		t.Fatalf("expected invalid signature to fail")
	}
}

func TestAcceptWhatsAppWebhookEnqueuesIncomingMessageOnce(t *testing.T) {
	repo := &fakeRepo{}
	svc := NewWebhookIntakeService(repo, "verify-token-123456", "app-secret-123456", nil)
	body := []byte(`{
		"object":"whatsapp_business_account",
		"entry":[{"changes":[{"value":{"messages":[{"from":"2348012345678","id":"wamid.1","timestamp":"1786752000","type":"text","text":{"body":"What time is my booking?"}}]}}]}]
	}`)
	headers := http.Header{}
	headers.Set("X-Hub-Signature-256", signBody("app-secret-123456", body))

	out, err := svc.AcceptWhatsAppWebhook(context.Background(), headers, body)
	if err != nil {
		t.Fatalf("expected webhook accepted: %v", err)
	}
	if out["accepted"] != 1 {
		t.Fatalf("expected one accepted message, got %#v", out)
	}
	if len(repo.inbound) != 1 {
		t.Fatalf("expected one queued inbound message, got %d", len(repo.inbound))
	}
	if repo.inbound[0].From != "+2348012345678" {
		t.Fatalf("expected normalized phone, got %q", repo.inbound[0].From)
	}

	repo.externalSeen["wamid.1"] = true
	out, err = svc.AcceptWhatsAppWebhook(context.Background(), headers, body)
	if err != nil {
		t.Fatalf("expected duplicate webhook accepted: %v", err)
	}
	if out["duplicates"] != 1 {
		t.Fatalf("expected duplicate counted, got %#v", out)
	}
}

func signBody(secret string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

type fakeRepo struct {
	externalSeen map[string]bool
	inbound      []engagementdomain.IncomingWhatsAppMessage
}

func (f *fakeRepo) ClaimPendingOutboxEvents(context.Context, int) ([]engagementdomain.OutboxEvent, error) {
	return nil, nil
}
func (f *fakeRepo) MarkOutboxEventDone(context.Context, string) error { return nil }
func (f *fakeRepo) MarkOutboxEventFailed(context.Context, string, string) error {
	return nil
}
func (f *fakeRepo) GetBooking(context.Context, string) (*engagementdomain.BookingSummary, error) {
	return &engagementdomain.BookingSummary{}, nil
}
func (f *fakeRepo) GetCustomerByPhone(context.Context, string) (*engagementdomain.CustomerSummary, error) {
	return &engagementdomain.CustomerSummary{}, nil
}
func (f *fakeRepo) GetCustomerActiveBookings(context.Context, string) ([]engagementdomain.BookingSummary, error) {
	return nil, nil
}
func (f *fakeRepo) FindOrCreateConversation(context.Context, string, string, string) (*engagementdomain.Conversation, error) {
	return &engagementdomain.Conversation{ID: "conv_1", Status: engagementdomain.ConversationAIActive}, nil
}
func (f *fakeRepo) GetConversation(context.Context, string) (*engagementdomain.Conversation, error) {
	return &engagementdomain.Conversation{}, nil
}
func (f *fakeRepo) SetConversationStatus(context.Context, string, string) error { return nil }
func (f *fakeRepo) SetPendingAction(context.Context, string, *engagementdomain.PendingAction) error {
	return nil
}
func (f *fakeRepo) RecentMessages(context.Context, string, int) ([]engagementdomain.ConversationMessage, error) {
	return nil, nil
}
func (f *fakeRepo) SaveMessage(context.Context, engagementdomain.ConversationMessage) (*engagementdomain.ConversationMessage, error) {
	return &engagementdomain.ConversationMessage{}, nil
}
func (f *fakeRepo) HasExternalMessage(_ context.Context, id string) (bool, error) {
	if f.externalSeen == nil {
		f.externalSeen = map[string]bool{}
	}
	return f.externalSeen[id], nil
}
func (f *fakeRepo) EnqueueIncomingWhatsApp(_ context.Context, message engagementdomain.IncomingWhatsAppMessage) error {
	if message.SentAt.IsZero() {
		message.SentAt = time.Now()
	}
	f.inbound = append(f.inbound, message)
	if f.externalSeen == nil {
		f.externalSeen = map[string]bool{}
	}
	f.externalSeen[message.MessageID] = true
	return nil
}
func (f *fakeRepo) UpdateWhatsAppStatus(context.Context, engagementdomain.WhatsAppStatus) error {
	return nil
}
func (f *fakeRepo) RecordAIAction(context.Context, string, string, string, string, any, any, string) error {
	return nil
}
func (f *fakeRepo) GetBusinessInformation(context.Context) (engagementdomain.BusinessInformation, error) {
	return engagementdomain.BusinessInformation{CompanyName: "Kamadeva Privé"}, nil
}
func (f *fakeRepo) CheckAvailability(context.Context, string, time.Time) ([]engagementdomain.AvailableSlot, error) {
	return nil, nil
}
func (f *fakeRepo) RescheduleBooking(context.Context, string, string) error { return nil }
func (f *fakeRepo) CancelBooking(context.Context, string) error             { return nil }
