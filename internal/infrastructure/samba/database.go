package samba

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
)

func (c *Client) FetchPayments(ctx context.Context, from, to string) (json.RawMessage, error) {
	return c.getRaw(ctx, "/api/payments", url.Values{"from": {from}, "to": {to}})
}

func (c *Client) FetchSalesByDepartment(ctx context.Context, from, to string) (json.RawMessage, error) {
	return c.getRaw(ctx, "/api/sales-by-department", url.Values{"from": {from}, "to": {to}})
}

func (c *Client) FetchMenu(ctx context.Context) (json.RawMessage, error) {
	return c.getRaw(ctx, "/api/menu", nil)
}

func (c *Client) FetchStaff(ctx context.Context) (json.RawMessage, error) {
	return c.getRaw(ctx, "/api/staff", nil)
}

func (c *Client) FetchDepartments(ctx context.Context) (json.RawMessage, error) {
	return c.getRaw(ctx, "/api/departments", nil)
}

func (c *Client) ListTables(ctx context.Context) (json.RawMessage, error) {
	return c.getRaw(ctx, "/api/db/tables", nil)
}

func (c *Client) TableRows(ctx context.Context, table string, page, pageSize int) (posdomain.SambaTablePage, error) {
	query := url.Values{}
	if page > 0 {
		query.Set("page", strconv.Itoa(page))
	}
	if pageSize > 0 {
		query.Set("pageSize", strconv.Itoa(pageSize))
	}
	var out posdomain.SambaTablePage
	err := c.decode(ctx, http.MethodGet, tablePath(table), query, nil, &out)
	return out, err
}

func (c *Client) InsertRow(ctx context.Context, table string, row map[string]any) (posdomain.SambaWriteResult, error) {
	var out posdomain.SambaWriteResult
	err := c.decode(ctx, http.MethodPost, tablePath(table), nil, row, &out)
	return out, err
}

func (c *Client) UpdateRow(ctx context.Context, table string, id int64, fields map[string]any) (posdomain.SambaWriteResult, error) {
	var out posdomain.SambaWriteResult
	err := c.decode(ctx, http.MethodPatch, rowPath(table, id), nil, fields, &out)
	return out, err
}

func (c *Client) DeleteRow(ctx context.Context, table string, id int64) (posdomain.SambaWriteResult, error) {
	var out posdomain.SambaWriteResult
	err := c.decode(ctx, http.MethodDelete, rowPath(table, id), nil, nil, &out)
	return out, err
}

func (c *Client) decode(ctx context.Context, method, path string, query url.Values, body any, out any) error {
	raw, err := c.send(ctx, method, path, query, body)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("decode Samba API %s %s: %w", method, path, err)
	}
	return nil
}

func tablePath(table string) string {
	return "/api/db/tables/" + url.PathEscape(table)
}

func rowPath(table string, id int64) string {
	return tablePath(table) + "/" + strconv.FormatInt(id, 10)
}
