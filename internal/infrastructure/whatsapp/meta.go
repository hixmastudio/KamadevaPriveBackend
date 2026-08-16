package whatsapp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
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
		version = "v20.0"
	}
	return &MetaClient{
		baseURL:       "https://graph.facebook.com/" + version,
		accessToken:   accessToken,
		phoneNumberID: phoneNumberID,
		client:        client,
	}
}

func (c *MetaClient) SendText(ctx context.Context, to string, message string) error {
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

func (c *MetaClient) SendTemplate(ctx context.Context, to string, template string, params map[string]string) error {
	keys := make([]string, 0, len(params))
	for key := range params {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parameters := make([]map[string]string, 0, len(keys))
	for _, key := range keys {
		parameters = append(parameters, map[string]string{"type": "text", "text": params[key]})
	}
	body := map[string]any{
		"messaging_product": "whatsapp",
		"to":                normalizeRecipient(to),
		"type":              "template",
		"template": map[string]any{
			"name": template,
			"language": map[string]string{
				"code": "en",
			},
			"components": []map[string]any{{
				"type":       "body",
				"parameters": parameters,
			}},
		},
	}
	return c.send(ctx, body)
}

func (c *MetaClient) send(ctx context.Context, body any) error {
	if c == nil {
		return fmt.Errorf("whatsapp client is not configured")
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/"+c.phoneNumberID+"/messages", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.accessToken)
	req.Header.Set("Content-Type", "application/json")

	res, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		var details any
		_ = json.NewDecoder(res.Body).Decode(&details)
		return fmt.Errorf("whatsapp send failed: status=%d details=%v", res.StatusCode, details)
	}
	return nil
}

func normalizeRecipient(to string) string {
	return strings.TrimPrefix(strings.TrimSpace(to), "+")
}
