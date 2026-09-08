package application

import (
	"context"
	"testing"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
)

func TestInboxSendHumanReplySendsWhatsAppAndPersistsMessage(t *testing.T) {
	repo := &inboxRepo{
		customer: engagementdomain.CustomerSummary{
			ID:    "cust_1",
			Name:  "Ada",
			Phone: "+2348012345678",
		},
		conversation: engagementdomain.Conversation{
			ID:         "conv_1",
			CustomerID: "cust_1",
			Channel:    engagementdomain.ChannelWhatsApp,
			Status:     engagementdomain.ConversationWaitingForHuman,
		},
	}
	messages := &fakeMessenger{}
	service := NewInboxService(repo, messages, nil)

	saved, err := service.SendHumanReply(context.Background(), "conv_1", "Good evening, your table is ready.")
	if err != nil {
		t.Fatalf("expected reply to send: %v", err)
	}
	if len(messages.sent) != 1 || messages.sent[0] != "Good evening, your table is ready." {
		t.Fatalf("expected WhatsApp text sent, got %#v", messages.sent)
	}
	if repo.status != engagementdomain.ConversationHumanActive {
		t.Fatalf("expected conversation human-active, got %q", repo.status)
	}
	if saved.Direction != engagementdomain.DirectionOutbound || saved.SenderType != engagementdomain.SenderHuman {
		t.Fatalf("expected outbound human message, got %#v", saved)
	}
}

type inboxRepo struct {
	fakeRepo
	customer     engagementdomain.CustomerSummary
	conversation engagementdomain.Conversation
	status       string
	message      engagementdomain.ConversationMessage
}

func (r *inboxRepo) GetConversation(context.Context, string) (*engagementdomain.Conversation, error) {
	return &r.conversation, nil
}

func (r *inboxRepo) GetCustomer(context.Context, string) (*engagementdomain.CustomerSummary, error) {
	return &r.customer, nil
}

func (r *inboxRepo) SetConversationStatus(_ context.Context, _ string, status string) error {
	r.status = status
	return nil
}

func (r *inboxRepo) SaveMessage(_ context.Context, message engagementdomain.ConversationMessage) (*engagementdomain.ConversationMessage, error) {
	r.message = message
	return &r.message, nil
}
