package samba

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type Client struct {
	baseURL string
	apiKey  string
	client  *http.Client
	cache   *TicketCache
	logger  *slog.Logger
}

func NewClient(baseURL, apiKey, cacheDir string, client *http.Client) *Client {
	if strings.TrimSpace(baseURL) == "" || strings.TrimSpace(apiKey) == "" {
		return nil
	}
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		client:  client,
		cache:   NewTicketCache(cacheDir),
		logger:  slog.Default(),
	}
}

func (c *Client) Health(ctx context.Context) (posdomain.SambaSourceHealth, error) {
	var out posdomain.SambaSourceHealth
	if err := c.get(ctx, "/healthz", nil, &out, nil); err != nil {
		return posdomain.SambaSourceHealth{}, err
	}
	return out, nil
}

func (c *Client) FetchTickets(ctx context.Context, from, to string) (posdomain.SambaTicketRange, error) {
	var out posdomain.SambaTicketRange
	query := url.Values{
		"from": {from},
		"to":   {to},
	}
	raw, err := c.getRaw(ctx, "/api/tickets", query)
	if err != nil {
		cached, cacheErr := c.loadCachedTickets(from, to, err)
		if cacheErr != nil {
			return posdomain.SambaTicketRange{}, err
		}
		raw = cached
	}
	if c.cache != nil && err == nil {
		if cacheErr := c.saveTicketCache(from, to, raw); cacheErr != nil {
			return posdomain.SambaTicketRange{}, cacheErr
		}
	}
	if decodeErr := json.Unmarshal(raw, &out); decodeErr != nil {
		c.logger.Error("samba_api_response_decode_failed",
			"method", http.MethodGet,
			"path", "/api/tickets",
			"query", query.Encode(),
			"body_bytes", len(raw),
			"error", decodeErr,
		)
		return posdomain.SambaTicketRange{}, fmt.Errorf("decode Samba API GET /api/tickets: %w", decodeErr)
	}
	return out, nil
}

func (c *Client) saveTicketCache(from, to string, raw []byte) error {
	if c.cache == nil {
		return nil
	}
	write, err := c.cache.SaveTickets(from, to, raw)
	if err != nil {
		return err
	}
	c.logger.Info("samba_ticket_cache_saved",
		"from", from,
		"to", to,
		"bytes", write.Bytes,
		"snapshot_path", write.SnapshotPath,
		"latest_path", write.LatestPath,
	)
	return nil
}

func (c *Client) loadCachedTickets(from, to string, upstreamErr error) (json.RawMessage, error) {
	if c.cache == nil {
		return nil, fmt.Errorf("ticket cache is not configured")
	}
	read, err := c.cache.LoadLatest(from, to)
	if err != nil {
		c.logger.Warn("samba_ticket_cache_miss",
			"from", from,
			"to", to,
			"upstream_error", upstreamErr,
			"cache_error", err,
		)
		return nil, err
	}
	c.logger.Warn("samba_ticket_cache_used",
		"from", from,
		"to", to,
		"bytes", read.Bytes,
		"path", read.Path,
		"upstream_error", upstreamErr,
	)
	return read.Raw, nil
}

func (c *Client) get(ctx context.Context, path string, query url.Values, out any, onSuccess func([]byte) error) error {
	raw, err := c.getRaw(ctx, path, query)
	if err != nil {
		return err
	}
	if onSuccess != nil {
		if err := onSuccess(raw); err != nil {
			c.logger.Error("samba_api_response_cache_failed",
				"method", http.MethodGet,
				"path", path,
				"query", query.Encode(),
				"body_bytes", len(raw),
				"error", err,
			)
			return err
		}
	}
	if err := json.Unmarshal(raw, out); err != nil {
		c.logger.Error("samba_api_response_decode_failed",
			"method", http.MethodGet,
			"path", path,
			"query", query.Encode(),
			"body_bytes", len(raw),
			"error", err,
		)
		return fmt.Errorf("decode Samba API GET %s: %w", path, err)
	}
	return nil
}

func (c *Client) FetchCleanTickets(ctx context.Context, query posdomain.SambaCleanTicketQuery) (json.RawMessage, error) {
	values := url.Values{}
	switch {
	case query.Page > 0:
		values.Set("page", fmt.Sprintf("%d", query.Page))
	default:
		values.Set("from", query.From)
		values.Set("to", query.To)
	}
	return c.getRaw(ctx, "/clean/ticket", values)
}

func (c *Client) FetchCleanTicket(ctx context.Context, ticketNumber string) (json.RawMessage, error) {
	return c.getRaw(ctx, "/clean/ticket/"+url.PathEscape(ticketNumber), nil)
}

func (c *Client) getRaw(ctx context.Context, path string, query url.Values) (json.RawMessage, error) {
	endpoint := c.baseURL + path
	if len(query) > 0 {
		endpoint += "?" + query.Encode()
	}
	start := time.Now()
	c.logger.Info("samba_api_request_started",
		"method", http.MethodGet,
		"path", path,
		"query", query.Encode(),
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", c.apiKey)
	req.Header.Set("Accept", "application/json")

	res, err := c.client.Do(req)
	if err != nil {
		c.logger.Error("samba_api_request_failed",
			"method", http.MethodGet,
			"path", path,
			"query", query.Encode(),
			"duration_ms", time.Since(start).Milliseconds(),
			"error", err,
		)
		return nil, err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode > 299 {
		raw, readErr := io.ReadAll(res.Body)
		if readErr != nil {
			c.logger.Error("samba_api_error_body_read_failed",
				"method", http.MethodGet,
				"path", path,
				"query", query.Encode(),
				"status", res.StatusCode,
				"duration_ms", time.Since(start).Milliseconds(),
				"error", readErr,
			)
			return nil, readErr
		}
		var details any
		_ = json.Unmarshal(raw, &details)
		c.logger.Error("samba_api_request_upstream_error",
			append([]any{
				"method", http.MethodGet,
				"path", path,
				"query", query.Encode(),
				"status", res.StatusCode,
				"duration_ms", time.Since(start).Milliseconds(),
				"body_bytes", len(raw),
			}, upstreamDetailLogAttrs(details)...)...,
		)
		return nil, shareddomain.UpstreamError(fmt.Sprintf("Samba API GET %s failed", path), details)
	}

	raw, err := io.ReadAll(res.Body)
	if err != nil {
		c.logger.Error("samba_api_response_read_failed",
			"method", http.MethodGet,
			"path", path,
			"query", query.Encode(),
			"status", res.StatusCode,
			"duration_ms", time.Since(start).Milliseconds(),
			"error", err,
		)
		return nil, fmt.Errorf("read Samba API GET %s: %w", path, err)
	}
	c.logger.Info("samba_api_request_completed",
		"method", http.MethodGet,
		"path", path,
		"query", query.Encode(),
		"status", res.StatusCode,
		"duration_ms", time.Since(start).Milliseconds(),
		"body_bytes", len(raw),
	)
	return json.RawMessage(raw), nil
}

type TicketCache struct {
	dir string
}

type TicketCacheWrite struct {
	SnapshotPath string
	LatestPath   string
	Bytes        int
}

type TicketCacheRead struct {
	Path  string
	Raw   []byte
	Bytes int
}

func NewTicketCache(dir string) *TicketCache {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return nil
	}
	return &TicketCache{dir: filepath.Join(dir, "tickets")}
}

func (c *TicketCache) SaveTickets(from, to string, raw []byte) (TicketCacheWrite, error) {
	if c == nil {
		return TicketCacheWrite{}, nil
	}
	if err := os.MkdirAll(c.dir, 0o750); err != nil {
		return TicketCacheWrite{}, err
	}
	prefix := safeFilename(from + "_" + to)
	timestamp := time.Now().UTC().Format("20060102T150405Z")
	write := TicketCacheWrite{
		SnapshotPath: filepath.Join(c.dir, prefix+"_"+timestamp+".json"),
		LatestPath:   filepath.Join(c.dir, "latest_"+prefix+".json"),
		Bytes:        len(raw),
	}
	if err := os.WriteFile(write.SnapshotPath, raw, 0o640); err != nil {
		return TicketCacheWrite{}, err
	}
	if err := os.WriteFile(write.LatestPath, raw, 0o640); err != nil {
		return TicketCacheWrite{}, err
	}
	return write, nil
}

func (c *TicketCache) LoadLatest(from, to string) (TicketCacheRead, error) {
	if c == nil {
		return TicketCacheRead{}, fmt.Errorf("ticket cache is not configured")
	}
	path := filepath.Join(c.dir, "latest_"+safeFilename(from+"_"+to)+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return TicketCacheRead{}, err
	}
	return TicketCacheRead{Path: path, Raw: raw, Bytes: len(raw)}, nil
}

var unsafeFilenameChars = regexp.MustCompile(`[^a-zA-Z0-9_.-]+`)

func safeFilename(value string) string {
	value = unsafeFilenameChars.ReplaceAllString(value, "_")
	return strings.Trim(value, "._")
}

func upstreamDetailLogAttrs(details any) []any {
	values, ok := details.(map[string]any)
	if !ok {
		return []any{"upstream_details", details}
	}

	attrs := []any{"upstream_details", values}
	for _, key := range []string{
		"status",
		"error",
		"error_code",
		"error_name",
		"error_category",
		"title",
		"type",
		"retryable",
		"retry_after",
		"cloudflare_error",
		"owner_action_required",
		"ray_id",
	} {
		if value, ok := values[key]; ok {
			attrs = append(attrs, "upstream_"+key, value)
		}
	}
	return attrs
}
