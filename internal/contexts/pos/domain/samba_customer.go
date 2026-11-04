package domain

import (
	"context"
	"encoding/json"
)

// Samba entity and account type IDs, identical at both sites.
const (
	SambaCustomerEntityTypeID  = 1
	SambaTableEntityTypeID     = 2
	SambaCustomerAccountTypeID = 5
)

// SambaDatabase is the vendor's generic table API (/api/db/tables).
type SambaDatabase interface {
	ListTables(ctx context.Context) (json.RawMessage, error)
	TableRows(ctx context.Context, table string, page, pageSize int) (SambaTablePage, error)
	InsertRow(ctx context.Context, table string, row map[string]any) (SambaWriteResult, error)
	UpdateRow(ctx context.Context, table string, id int64, fields map[string]any) (SambaWriteResult, error)
	DeleteRow(ctx context.Context, table string, id int64) (SambaWriteResult, error)
}

// SambaReferenceSource covers the read-only reporting and catalogue routes.
type SambaReferenceSource interface {
	FetchPayments(ctx context.Context, from, to string) (json.RawMessage, error)
	FetchSalesByDepartment(ctx context.Context, from, to string) (json.RawMessage, error)
	FetchMenu(ctx context.Context) (json.RawMessage, error)
	FetchStaff(ctx context.Context) (json.RawMessage, error)
	FetchDepartments(ctx context.Context) (json.RawMessage, error)
}

type SambaTablePage struct {
	Table         string           `json:"table"`
	Page          int              `json:"page"`
	PageSize      int              `json:"pageSize"`
	Total         int              `json:"total"`
	TotalPages    int              `json:"totalPages"`
	WritesEnabled bool             `json:"writesEnabled"`
	Columns       []map[string]any `json:"columns"`
	Rows          []map[string]any `json:"rows"`
}

type SambaWriteResult struct {
	RowsAffected int   `json:"rowsAffected"`
	ID           int64 `json:"id,omitempty"`
}

type SambaCustomField struct {
	Name  string `json:"Name"`
	Value string `json:"Value"`
}

type SambaCustomer struct {
	ID             int64              `json:"id"`
	Name           string             `json:"name"`
	Phone          string             `json:"phone"`
	CustomerID     string             `json:"customer_id"`
	CustomData     []SambaCustomField `json:"custom_data"`
	Notes          string             `json:"notes"`
	AccountID      int64              `json:"account_id"`
	LastUpdateTime string             `json:"last_update_time"`
}
