package whatsapp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"

	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
)

type MetaClient struct {
	baseURL       string
	accessToken   string
	phoneNumberID string
	client        *http.Client
}

func NewMetaClient(apiVersion, phoneNumberID, accessToken string, client *http.Client) *MetaClient {
	if strings.TrimSpace(accessToken) == "" || strings.TrimSpace(phoneNumberID) == "" {
		return nil
	}
	if client == nil {
		client = http.DefaultClient
	}
	version := strings.Trim(strings.TrimSpace(apiVersion), "/")
	if version == "" {
		version = "v25.0"
	}
	return &MetaClient{
		baseURL:       "https://graph.facebook.com/" + version,
		accessToken:   accessToken,
		phoneNumberID: phoneNumberID,
		client:        client,
	}
}

func (c *MetaClient) SendText(ctx context.Context, to string, message string) (*engagementdomain.MessageSendResult, error) {
	body := map[string]any{
		"messaging_product": "whatsapp",
		"recipient_type":    "individual",
		"to":                normalizeRecipient(to),
		"type":              "text",
		"text": map[string]any{
			"preview_url": false,
			"body":        message,
		},
	}
	return c.send(ctx, body)
}

func (c *MetaClient) SendTemplate(ctx context.Context, to string, template string, params map[string]string) (*engagementdomain.MessageSendResult, error) {
	if strings.TrimSpace(template) == "" {
		return nil, fmt.Errorf("whatsapp template name is required")
	}
	body := BuildTemplateMessagePayload(to, template, params)
	return c.send(ctx, body)
}

func BuildTemplateMessagePayload(to string, template string, params map[string]string) map[string]any {
	keys := orderedTemplateParamKeys(params)
	parameters := make([]map[string]string, 0, len(keys))
	for _, key := range keys {
		parameters = append(parameters, map[string]string{"type": "text", "text": params[key]})
	}
	components := make([]map[string]any, 0, 2)
	if headerImageURL := strings.TrimSpace(params["header_image_url"]); headerImageURL != "" {
		components = append(components, map[string]any{
			"type": "header",
			"parameters": []map[string]any{{
				"type": "image",
				"image": map[string]string{
					"link": headerImageURL,
				},
			}},
		})
	}
	components = append(components, map[string]any{
		"type":       "body",
		"parameters": parameters,
	})
	return map[string]any{
		"messaging_product": "whatsapp",
		"to":                normalizeRecipient(to),
		"type":              "template",
		"template": map[string]any{
			"name": template,
			"language": map[string]string{
				"code": "en",
			},
			"components": components,
		},
	}
}

func (c *MetaClient) send(ctx context.Context, body any) (*engagementdomain.MessageSendResult, error) {
	if c == nil {
		return nil, fmt.Errorf("whatsapp client is not configured")
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/"+c.phoneNumberID+"/messages", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.accessToken)
	req.Header.Set("Content-Type", "application/json")

	res, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("whatsapp send request failed: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		var details metaErrorResponse
		_ = json.NewDecoder(res.Body).Decode(&details)
		return nil, metaSendError{StatusCode: res.StatusCode, Response: details}
	}
	var out metaSendResponse
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("whatsapp send response decode failed: %w", err)
	}
	return &engagementdomain.MessageSendResult{MessageID: out.FirstMessageID()}, nil
}

func normalizeRecipient(to string) string {
	return strings.TrimPrefix(strings.TrimSpace(to), "+")
}

func orderedTemplateParamKeys(params map[string]string) []string {
	knownOrder := []string{"customer_name", "venue", "date", "time", "guests", "address", "booking_reference"}
	seen := map[string]bool{}
	keys := make([]string, 0, len(params))
	for _, key := range knownOrder {
		if _, ok := params[key]; ok {
			keys = append(keys, key)
			seen[key] = true
		}
	}

	rest := make([]string, 0, len(params)-len(keys))
	for key := range params {
		if key == "header_image_url" {
			continue
		}
		if !seen[key] {
			rest = append(rest, key)
		}
	}
	sort.Strings(rest)
	return append(keys, rest...)
}

type metaSendResponse struct {
	Messages []struct {
		ID string `json:"id"`
	} `json:"messages"`
}

func (r metaSendResponse) FirstMessageID() string {
	if len(r.Messages) == 0 {
		return ""
	}
	return r.Messages[0].ID
}

type metaErrorResponse struct {
	Error struct {
		Message      string `json:"message"`
		Type         string `json:"type"`
		Code         int    `json:"code"`
		ErrorSubcode int    `json:"error_subcode"`
		FBTraceID    string `json:"fbtrace_id"`
	} `json:"error"`
}

type metaSendError struct {
	StatusCode int
	Response   metaErrorResponse
}

func (e metaSendError) Error() string {
	meta := e.Response.Error
	parts := []string{fmt.Sprintf("whatsapp send failed: status=%d", e.StatusCode)}
	if meta.Code != 0 {
		parts = append(parts, fmt.Sprintf("code=%d", meta.Code))
	}
	if meta.ErrorSubcode != 0 {
		parts = append(parts, fmt.Sprintf("subcode=%d", meta.ErrorSubcode))
	}
	if meta.Type != "" {
		parts = append(parts, "type="+meta.Type)
	}
	if meta.Message != "" {
		parts = append(parts, "message="+meta.Message)
	}
	if meta.FBTraceID != "" {
		parts = append(parts, "fbtrace_id="+meta.FBTraceID)
	}
	return strings.Join(parts, " ")
}
