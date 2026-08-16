package application

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type WebhookIntakeService struct {
	repo        engagementdomain.Repository
	verifyToken string
	appSecret   string
	logger      *slog.Logger
}

func NewWebhookIntakeService(repo engagementdomain.Repository, verifyToken, appSecret string, logger *slog.Logger) WebhookIntakeService {
	if logger == nil {
		logger = slog.Default()
	}
	return WebhookIntakeService{repo: repo, verifyToken: verifyToken, appSecret: appSecret, logger: logger}
}

func (s WebhookIntakeService) VerifyWhatsAppWebhook(query map[string]string) (string, error) {
	if s.verifyToken == "" {
		return "", shareddomain.Unauthorized()
	}
	if query["hub.mode"] != "subscribe" || query["hub.verify_token"] != s.verifyToken {
		return "", shareddomain.Unauthorized()
	}
	challenge := strings.TrimSpace(query["hub.challenge"])
	if challenge == "" {
		return "", shareddomain.ValidationError(map[string]string{"hub.challenge": "required"})
	}
	return challenge, nil
}

func (s WebhookIntakeService) AcceptWhatsAppWebhook(ctx context.Context, headers http.Header, body []byte) (map[string]any, error) {
	if s.appSecret != "" && !validMetaSignature(headers, body, s.appSecret) {
		return nil, shareddomain.Unauthorized()
	}

	var payload whatsAppWebhookPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, shareddomain.ValidationError(map[string]string{"body": "expected WhatsApp webhook JSON"})
	}

	accepted := 0
	duplicates := 0
	statuses := 0
	for _, entry := range payload.Entry {
		for _, change := range entry.Changes {
			for _, status := range change.Value.Statuses {
				statuses++
				_ = s.repo.UpdateWhatsAppStatus(ctx, engagementdomain.WhatsAppStatus{
					MessageID: status.ID,
					Status:    strings.ToUpper(status.Status),
					ErrorCode: firstStatusErrorCode(status.Errors),
					ErrorText: firstStatusErrorText(status.Errors),
				})
			}
			for _, msg := range change.Value.Messages {
				if msg.ID == "" {
					continue
				}
				exists, err := s.repo.HasExternalMessage(ctx, msg.ID)
				if err != nil {
					return nil, err
				}
				if exists {
					duplicates++
					continue
				}
				body := msg.Text.Body
				if strings.TrimSpace(body) == "" {
					body = unsupportedMessageText(msg.Type)
				}
				sentAt := time.Now()
				if msg.Timestamp != "" {
					if unix, err := strconv.ParseInt(msg.Timestamp, 10, 64); err == nil {
						sentAt = time.Unix(unix, 0)
					}
				}
				if err := s.repo.EnqueueIncomingWhatsApp(ctx, engagementdomain.IncomingWhatsAppMessage{
					MessageID: msg.ID,
					From:      NormalizePhone(msg.From),
					Body:      body,
					SentAt:    sentAt,
				}); err != nil {
					return nil, err
				}
				accepted++
			}
		}
	}
	return map[string]any{"ok": true, "accepted": accepted, "duplicates": duplicates, "statuses": statuses}, nil
}

func (s WebhookIntakeService) AcceptGenericWebhook(payload map[string]any) (map[string]any, error) {
	if payload["event"] == nil {
		return nil, shareddomain.ValidationError(map[string]string{"webhook": "event is required"})
	}
	return map[string]any{"ok": true, "accepted": true}, nil
}

func NormalizePhone(raw string) string {
	digits := strings.Builder{}
	for _, r := range raw {
		if r >= '0' && r <= '9' {
			digits.WriteRune(r)
		}
	}
	value := digits.String()
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "00") {
		value = value[2:]
	}
	return "+" + value
}

func validMetaSignature(headers http.Header, body []byte, secret string) bool {
	signature := headers.Get("X-Hub-Signature-256")
	if signature != "" {
		return hmacEqual(signature, "sha256=", secret, body, sha256.New)
	}
	signature = headers.Get("X-Hub-Signature")
	if signature != "" {
		return hmacEqual(signature, "sha1=", secret, body, sha1.New)
	}
	return false
}

func hmacEqual(supplied, prefix, secret string, body []byte, newHash func() hash.Hash) bool {
	mac := hmac.New(newHash, []byte(secret))
	_, _ = mac.Write(body)
	expected := prefix + hex.EncodeToString(mac.Sum(nil))
	return subtle.ConstantTimeCompare([]byte(supplied), []byte(expected)) == 1
}

func unsupportedMessageText(messageType string) string {
	if strings.TrimSpace(messageType) == "" {
		return "[unsupported WhatsApp message]"
	}
	return fmt.Sprintf("[unsupported WhatsApp %s message]", messageType)
}

type whatsAppWebhookPayload struct {
	Object string `json:"object"`
	Entry  []struct {
		ID      string `json:"id"`
		Changes []struct {
			Field string `json:"field"`
			Value struct {
				Messages []struct {
					From      string `json:"from"`
					ID        string `json:"id"`
					Timestamp string `json:"timestamp"`
					Type      string `json:"type"`
					Text      struct {
						Body string `json:"body"`
					} `json:"text"`
				} `json:"messages"`
				Statuses []struct {
					ID     string `json:"id"`
					Status string `json:"status"`
					Errors []struct {
						Code  int    `json:"code"`
						Title string `json:"title"`
					} `json:"errors"`
				} `json:"statuses"`
			} `json:"value"`
		} `json:"changes"`
	} `json:"entry"`
}

func firstStatusErrorCode(errors []struct {
	Code  int    `json:"code"`
	Title string `json:"title"`
}) string {
	if len(errors) == 0 {
		return ""
	}
	return strconv.Itoa(errors[0].Code)
}

func firstStatusErrorText(errors []struct {
	Code  int    `json:"code"`
	Title string `json:"title"`
}) string {
	if len(errors) == 0 {
		return ""
	}
	return errors[0].Title
}
