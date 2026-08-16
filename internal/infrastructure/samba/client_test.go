package samba

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestFetchTicketsCachesRawResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-API-Key") != "test-key-12345678901234567890" {
			t.Fatalf("missing api key")
		}
		if r.URL.Path != "/api/tickets" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"from":"2026-07-05","to":"2026-07-06","count":0,"tickets":[]}`))
	}))
	defer server.Close()

	cacheDir := t.TempDir()
	client := NewClient(server.URL, "test-key-12345678901234567890", cacheDir, server.Client())

	out, err := client.FetchTickets(context.Background(), "2026-07-05", "2026-07-06")
	if err != nil {
		t.Fatalf("FetchTickets error = %v", err)
	}
	if out.From != "2026-07-05" || out.To != "2026-07-06" {
		t.Fatalf("range = %#v", out)
	}

	latest := filepath.Join(cacheDir, "tickets", "latest_2026-07-05_2026-07-06.json")
	raw, err := os.ReadFile(latest)
	if err != nil {
		t.Fatalf("read cache: %v", err)
	}
	if string(raw) != `{"from":"2026-07-05","to":"2026-07-06","count":0,"tickets":[]}` {
		t.Fatalf("cache body = %s", raw)
	}
}
