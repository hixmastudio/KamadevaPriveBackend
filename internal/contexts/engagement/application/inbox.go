package application

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type InboxService struct {
	repo     engagementdomain.Repository
	messages engagementdomain.MessagingClient
	logger   *slog.Logger
}

func NewInboxService(repo engagementdomain.Repository, messages engagementdomain.MessagingClient, logger *slog.Logger) InboxService {
	if logger == nil {
		logger = slog.Default()
	}
	return InboxService{repo: repo, messages: messages, logger: logger}
}

func (s InboxService) ListConversations(ctx context.Context, status string, limit int) ([]engagementdomain.ConversationOverview, error) {
	if s.repo == nil {
		return nil, fmt.Errorf("engagement repository is not configured")
	}
	return s.repo.ListConversations(ctx, strings.TrimSpace(status), limit)
}

func (s InboxService) Messages(ctx context.Context, conversationID string, limit int) ([]engagementdomain.ConversationMessage, error) {
	if s.repo == nil {
		return nil, fmt.Errorf("engagement repository is not configured")
	}
	if strings.TrimSpace(conversationID) == "" {
		return nil, shareddomain.ValidationError(map[string]string{"conversation_id": "required"})
	}
	return s.repo.RecentMessages(ctx, conversationID, limit)
}

func (s InboxService) SendHumanReply(ctx context.Context, conversationID, body string) (*engagementdomain.ConversationMessage, error) {
	if s.repo == nil || s.messages == nil {
		return nil, fmt.Errorf("WhatsApp inbox is not configured")
	}
	conversationID = strings.TrimSpace(conversationID)
	body = strings.TrimSpace(body)
	if conversationID == "" || body == "" {
		return nil, shareddomain.ValidationError(map[string]string{
			"conversation_id": "required",
			"body":            "required",
		})
	}
	conversation, err := s.repo.GetConversation(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	customer, err := s.repo.GetCustomer(ctx, conversation.CustomerID)
	if err != nil {
		return nil, err
	}
	to := NormalizePhone(customer.Phone)
	if to == "" {
		return nil, shareddomain.ValidationError(map[string]string{"customer_phone": "missing or invalid"})
	}
	result, err := s.messages.SendText(ctx, to, body)
	if err != nil {
		s.logger.Error("whatsapp_admin_reply_failed", "conversation_id", conversation.ID, "to", to, "error", err)
		return nil, err
	}
	messageID := ""
	if result != nil {
		messageID = result.MessageID
	}
	if err := s.repo.SetConversationStatus(ctx, conversation.ID, engagementdomain.ConversationHumanActive); err != nil {
		return nil, err
	}
	message, err := s.repo.SaveMessage(ctx, engagementdomain.ConversationMessage{
		ConversationID:    conversation.ID,
		ExternalMessageID: messageID,
		Direction:         engagementdomain.DirectionOutbound,
		SenderType:        engagementdomain.SenderHuman,
		Body:              body,
		CreatedAt:         time.Now(),
	})
	if err != nil {
		return nil, err
	}
	s.logger.Info("whatsapp_admin_reply_sent", "conversation_id", conversation.ID, "to", to, "message_id", messageID)
	return message, nil
}

func (s InboxService) SetConversationStatus(ctx context.Context, conversationID, status string) error {
	if s.repo == nil {
		return fmt.Errorf("engagement repository is not configured")
	}
	conversationID = strings.TrimSpace(conversationID)
	status = strings.ToUpper(strings.TrimSpace(status))
	if conversationID == "" || !validConversationStatus(status) {
		return shareddomain.ValidationError(map[string]string{
			"conversation_id": "required",
			"status":          "must be AI_ACTIVE, WAITING_FOR_HUMAN, HUMAN_ACTIVE, or CLOSED",
		})
	}
	return s.repo.SetConversationStatus(ctx, conversationID, status)
}

func validConversationStatus(status string) bool {
	switch status {
	case engagementdomain.ConversationAIActive,
		engagementdomain.ConversationWaitingForHuman,
		engagementdomain.ConversationHumanActive,
		engagementdomain.ConversationClosed:
		return true
	default:
		return false
	}
}
