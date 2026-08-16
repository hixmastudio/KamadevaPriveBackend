package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
)

type OpenAIClient struct {
	apiKey string
	model  string
	client *http.Client
}

func NewOpenAIClient(apiKey, model string, client *http.Client) *OpenAIClient {
	if strings.TrimSpace(apiKey) == "" {
		return nil
	}
	if client == nil {
		client = http.DefaultClient
	}
	if strings.TrimSpace(model) == "" {
		model = "gpt-4.1-mini"
	}
	return &OpenAIClient{apiKey: apiKey, model: model, client: client}
}

func (c *OpenAIClient) ProcessConversation(ctx context.Context, input engagementdomain.ConversationInput) (engagementdomain.ConversationResult, error) {
	promptPayload, err := json.Marshal(input)
	if err != nil {
		return engagementdomain.ConversationResult{}, err
	}
	body := map[string]any{
		"model":        c.model,
		"instructions": systemInstructions(input.BusinessInfo.CompanyName),
		"input":        string(promptPayload),
		"store":        false,
		"text": map[string]any{
			"format": map[string]string{"type": "json_object"},
		},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return engagementdomain.ConversationResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.openai.com/v1/responses", bytes.NewReader(payload))
	if err != nil {
		return engagementdomain.ConversationResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.client.Do(req)
	if err != nil {
		return engagementdomain.ConversationResult{}, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		var details any
		_ = json.NewDecoder(res.Body).Decode(&details)
		return engagementdomain.ConversationResult{}, fmt.Errorf("ai request failed: status=%d details=%v", res.StatusCode, details)
	}
	var response struct {
		Output []struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
		OutputText string `json:"output_text"`
	}
	if err := json.NewDecoder(res.Body).Decode(&response); err != nil {
		return engagementdomain.ConversationResult{}, err
	}
	text := response.OutputText
	if text == "" {
		for _, item := range response.Output {
			for _, content := range item.Content {
				if content.Text != "" {
					text = content.Text
					break
				}
			}
		}
	}
	var result engagementdomain.ConversationResult
	if err := json.Unmarshal([]byte(text), &result); err != nil {
		return engagementdomain.ConversationResult{Reply: strings.TrimSpace(text)}, nil
	}
	return result, nil
}

func systemInstructions(company string) string {
	if strings.TrimSpace(company) == "" {
		company = "Kamadeva Privé"
	}
	return `You are the virtual booking assistant for ` + company + `.
Return only JSON matching this shape:
{"reply":"short WhatsApp response","escalate":false,"pending_action":null,"tool_calls":[]}
You may answer booking questions, retrieve booking information using supplied context, check available booking times, help reschedule bookings, help cancel bookings, answer approved company questions, and escalate to a human.
Never invent booking, business, pricing, refund, location, service, or policy information.
Never claim an action succeeded unless a backend tool returned success.
Never modify booking information yourself.
Never request direct database access.
If information is unavailable, say so or escalate.
Before destructive or significant actions such as cancellation or rescheduling, obtain explicit confirmation and return a pending_action instead of a direct tool call.
If multiple active bookings make the intended booking ambiguous, ask for clarification.
Keep responses concise, friendly, and natural for WhatsApp.
Available tool call names are get_booking, get_customer_active_bookings, check_availability, request_reschedule_booking, cancel_booking, get_business_information, request_human_agent.`
}
