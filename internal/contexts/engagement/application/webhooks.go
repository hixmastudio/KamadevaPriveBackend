package application

import shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"

type WebhookIntakeService struct{}

func NewWebhookIntakeService() WebhookIntakeService {
	return WebhookIntakeService{}
}

func (s WebhookIntakeService) AcceptWhatsAppInbound(payload map[string]any) (map[string]any, error) {
	if payload["from"] == nil || payload["text"] == nil {
		return nil, shareddomain.ValidationError(map[string]string{"webhook": "from and text are required"})
	}
	return map[string]any{
		"ok":       true,
		"accepted": true,
		"next":     "wire this to the selected WhatsApp provider and comms tables",
	}, nil
}

func (s WebhookIntakeService) AcceptGenericWebhook(payload map[string]any) (map[string]any, error) {
	if payload["event"] == nil {
		return nil, shareddomain.ValidationError(map[string]string{"webhook": "event is required"})
	}
	return map[string]any{"ok": true, "accepted": true}, nil
}
