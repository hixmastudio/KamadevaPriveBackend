package whatsapp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

func TestOrderedTemplateParamKeysUsesBookingConfirmationOrder(t *testing.T) {
	params := map[string]string{
		"time":              "8:00 PM",
		"date":              "5 September 2026",
		"venue":             "Private lounge",
		"booking_reference": "BK-92821",
		"customer_name":     "Ada",
		"guests":            "5",
	}

	got := orderedTemplateParamKeys(params)
	want := []string{"customer_name", "venue", "date", "time", "guests", "booking_reference"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("expected %v, got %v", want, got)
	}
}

func TestOrderedTemplateParamKeysSortsUnknownKeysAfterKnownKeys(t *testing.T) {
	params := map[string]string{
		"zeta":              "z",
		"booking_reference": "BK-92821",
		"alpha":             "a",
	}

	got := orderedTemplateParamKeys(params)
	want := []string{"booking_reference", "alpha", "zeta"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("expected %v, got %v", want, got)
	}
}

func TestBuildTemplateMessagePayload(t *testing.T) {
	payload := BuildTemplateMessagePayload("+2348012345678", "booking_received", map[string]string{
		"customer_name":     "Ada",
		"venue":             "Oso Lounge",
		"date":              "5 September 2026",
		"time":              "8:30 PM",
		"guests":            "5",
		"booking_reference": "BK-92821",
	})

	if payload["to"] != "2348012345678" {
		t.Fatalf("expected recipient without plus, got %#v", payload["to"])
	}
	template := payload["template"].(map[string]any)
	if template["name"] != "booking_received" {
		t.Fatalf("expected booking_received template, got %#v", template["name"])
	}
}

func TestSendTemplateParsesSuccessfulMetaResponse(t *testing.T) {
	var auth string
	var path string
	var payload map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		path = r.URL.Path
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"messages":[{"id":"wamid.HBgM"}]}`))
	}))
	defer server.Close()

	client := NewMetaClient("v25.0", "12345", "secret-token", server.Client())
	client.baseURL = server.URL + "/v25.0"

	result, err := client.SendTemplate(context.Background(), "+2348012345678", "booking_received", map[string]string{"customer_name": "Ada"})
	if err != nil {
		t.Fatalf("expected send success: %v", err)
	}
	if result.MessageID != "wamid.HBgM" {
		t.Fatalf("expected message ID, got %#v", result)
	}
	if auth != "Bearer secret-token" {
		t.Fatalf("expected bearer auth header")
	}
	if path != "/v25.0/12345/messages" {
		t.Fatalf("expected graph path, got %q", path)
	}
	if payload["type"] != "template" {
		t.Fatalf("expected template payload, got %#v", payload)
	}
}

func TestSendTemplateReturnsMetaFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"Invalid OAuth access token.","type":"OAuthException","code":190,"fbtrace_id":"trace-1"}}`))
	}))
	defer server.Close()

	client := NewMetaClient("v25.0", "12345", "secret-token", server.Client())
	client.baseURL = server.URL + "/v25.0"

	_, err := client.SendTemplate(context.Background(), "2348012345678", "booking_received", map[string]string{"customer_name": "Ada"})
	if err == nil {
		t.Fatalf("expected failure")
	}
	if got := err.Error(); got == "" || got == "secret-token" {
		t.Fatalf("expected sanitized error, got %q", got)
	}
}
