package application

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

const (
	sambaEntitiesTable    = "Entities"
	sambaAccountsTable    = "Accounts"
	sambaEntityStateTable = "EntityStateValues"
	sambaMaxPageSize      = 500
	sambaMaxScanPages     = 200
)

// sambaTillZone is the till's wall clock. Samba stores Lagos local time with a
// trailing Z, so timestamps we write must be Lagos local too.
var sambaTillZone = time.FixedZone("WAT", 60*60)

// SambaCustomerService manages POS customers. Samba has no customer route:
// customers are Entities rows with EntityTypeId 1, each normally linked to an
// Accounts row (for a balance) and an EntityStateValues row (for a status).
type SambaCustomerService struct {
	db     posdomain.SambaDatabase
	now    func() time.Time
	logger *slog.Logger
}

type SambaCustomerListRequest struct {
	Query    string
	Page     string
	PageSize string
}

type SambaCustomerList struct {
	Page       int                       `json:"page"`
	PageSize   int                       `json:"page_size"`
	Total      int                       `json:"total"`
	TotalPages int                       `json:"total_pages"`
	Customers  []posdomain.SambaCustomer `json:"customers"`
}

type CreateSambaCustomerRequest struct {
	Name       string  `json:"name"`
	Phone      string  `json:"phone"`
	CustomerID *string `json:"customer_id,omitempty"`
	Notes      string  `json:"notes"`
}

type UpdateSambaCustomerRequest struct {
	Name       *string `json:"name,omitempty"`
	Phone      *string `json:"phone,omitempty"`
	CustomerID *string `json:"customer_id,omitempty"`
	Notes      *string `json:"notes,omitempty"`
}

type DeleteSambaCustomerResult struct {
	Deleted            bool    `json:"deleted"`
	EntityID           int64   `json:"entity_id"`
	AccountID          int64   `json:"account_id,omitempty"`
	EntityStateValueID []int64 `json:"entity_state_value_ids"`
}

func NewSambaCustomerService(db posdomain.SambaDatabase, logger *slog.Logger) SambaCustomerService {
	if logger == nil {
		logger = slog.Default()
	}
	return SambaCustomerService{db: db, now: time.Now, logger: logger}
}

func (s SambaCustomerService) List(ctx context.Context, req SambaCustomerListRequest) (SambaCustomerList, error) {
	if err := s.ready(); err != nil {
		return SambaCustomerList{}, err
	}
	page, ok := optionalPositiveInt(req.Page)
	if !ok {
		return SambaCustomerList{}, shareddomain.ValidationError(map[string]string{"page": "must be a positive integer"})
	}
	pageSize, ok := optionalPositiveInt(req.PageSize)
	if !ok || pageSize > sambaMaxPageSize {
		return SambaCustomerList{}, shareddomain.ValidationError(map[string]string{"page_size": "must be between 1 and 500"})
	}
	if page == 0 {
		page = 1
	}
	if pageSize == 0 {
		pageSize = 50
	}

	all, err := s.allCustomers(ctx)
	if err != nil {
		return SambaCustomerList{}, err
	}
	matches := filterSambaCustomers(all, req.Query)
	total := len(matches)
	start := min((page-1)*pageSize, total)
	end := min(start+pageSize, total)
	return SambaCustomerList{
		Page:       page,
		PageSize:   pageSize,
		Total:      total,
		TotalPages: (total + pageSize - 1) / pageSize,
		Customers:  matches[start:end],
	}, nil
}

func (s SambaCustomerService) Get(ctx context.Context, rawID string) (posdomain.SambaCustomer, error) {
	if err := s.ready(); err != nil {
		return posdomain.SambaCustomer{}, err
	}
	id, err := parseSambaID(rawID)
	if err != nil {
		return posdomain.SambaCustomer{}, err
	}
	return s.find(ctx, id)
}

// Create mirrors how the POS creates a customer: Account, then Entity linked
// to it, then its Available status. Earlier steps are rolled back on failure
// so a half-created customer is never left behind.
func (s SambaCustomerService) Create(ctx context.Context, req CreateSambaCustomerRequest) (posdomain.SambaCustomer, error) {
	if err := s.ready(); err != nil {
		return posdomain.SambaCustomer{}, err
	}
	name := strings.TrimSpace(req.Name)
	phone := strings.TrimSpace(req.Phone)
	fields := map[string]string{}
	if name == "" {
		fields["name"] = "is required"
	}
	if phone == "" {
		fields["phone"] = "is required"
	}
	if len(fields) > 0 {
		return posdomain.SambaCustomer{}, shareddomain.ValidationError(fields)
	}

	customData := setCustomField(nil, "Phone", phone)
	if req.CustomerID != nil && strings.TrimSpace(*req.CustomerID) != "" {
		customData = setCustomField(customData, "Customer ID", strings.TrimSpace(*req.CustomerID))
	}
	customDataJSON, err := json.Marshal(customData)
	if err != nil {
		return posdomain.SambaCustomer{}, err
	}
	now := s.now()

	account, err := s.db.InsertRow(ctx, sambaAccountsTable, map[string]any{
		"AccountTypeId":     posdomain.SambaCustomerAccountTypeID,
		"ForeignCurrencyId": 0,
		"Name":              sambaAccountName(name, phone),
	})
	if err != nil {
		return posdomain.SambaCustomer{}, err
	}

	entity, err := s.db.InsertRow(ctx, sambaEntitiesTable, map[string]any{
		"EntityTypeId":   posdomain.SambaCustomerEntityTypeID,
		"Name":           name,
		"AccountId":      account.ID,
		"CustomData":     string(customDataJSON),
		"SearchString":   "",
		"Notes":          strings.TrimSpace(req.Notes),
		"WarehouseId":    0,
		"LastUpdateTime": sambaTillTime(now),
	})
	if err != nil {
		s.rollback(ctx, sambaAccountsTable, account.ID)
		return posdomain.SambaCustomer{}, err
	}

	if _, err := s.db.InsertRow(ctx, sambaEntityStateTable, map[string]any{
		"EntityId":     entity.ID,
		"EntityStates": availableEntityStates(now),
	}); err != nil {
		s.rollback(ctx, sambaEntitiesTable, entity.ID)
		s.rollback(ctx, sambaAccountsTable, account.ID)
		return posdomain.SambaCustomer{}, err
	}

	return posdomain.SambaCustomer{
		ID:             entity.ID,
		Name:           name,
		Phone:          phone,
		CustomerID:     customFieldValue(customData, "Customer ID"),
		CustomData:     customData,
		Notes:          strings.TrimSpace(req.Notes),
		AccountID:      account.ID,
		LastUpdateTime: sambaTillTime(now),
	}, nil
}

// Update patches the entity. CustomData is replaced, not merged, by Samba, so
// the full array is rebuilt from the current row. The linked account is
// renamed when the name or phone changes so it keeps the POS's Name-Phone form.
func (s SambaCustomerService) Update(ctx context.Context, rawID string, req UpdateSambaCustomerRequest) (posdomain.SambaCustomer, error) {
	if err := s.ready(); err != nil {
		return posdomain.SambaCustomer{}, err
	}
	id, err := parseSambaID(rawID)
	if err != nil {
		return posdomain.SambaCustomer{}, err
	}
	if req.Name == nil && req.Phone == nil && req.CustomerID == nil && req.Notes == nil {
		return posdomain.SambaCustomer{}, shareddomain.ValidationError(map[string]string{"body": "at least one of name, phone, customer_id, notes is required"})
	}
	if req.Name != nil && strings.TrimSpace(*req.Name) == "" {
		return posdomain.SambaCustomer{}, shareddomain.ValidationError(map[string]string{"name": "cannot be empty"})
	}

	current, err := s.find(ctx, id)
	if err != nil {
		return posdomain.SambaCustomer{}, err
	}
	updated := current
	patch := map[string]any{}
	if req.Name != nil {
		updated.Name = strings.TrimSpace(*req.Name)
		patch["Name"] = updated.Name
	}
	if req.Notes != nil {
		updated.Notes = strings.TrimSpace(*req.Notes)
		patch["Notes"] = updated.Notes
	}
	if req.Phone != nil || req.CustomerID != nil {
		customData := append([]posdomain.SambaCustomField(nil), current.CustomData...)
		if req.Phone != nil {
			customData = setCustomField(customData, "Phone", strings.TrimSpace(*req.Phone))
		}
		if req.CustomerID != nil {
			customData = setCustomField(customData, "Customer ID", strings.TrimSpace(*req.CustomerID))
		}
		raw, err := json.Marshal(customData)
		if err != nil {
			return posdomain.SambaCustomer{}, err
		}
		patch["CustomData"] = string(raw)
		updated.CustomData = customData
		updated.Phone = customFieldValue(customData, "Phone")
		updated.CustomerID = customFieldValue(customData, "Customer ID")
	}
	updated.LastUpdateTime = sambaTillTime(s.now())
	patch["LastUpdateTime"] = updated.LastUpdateTime

	if _, err := s.db.UpdateRow(ctx, sambaEntitiesTable, id, patch); err != nil {
		return posdomain.SambaCustomer{}, err
	}
	if current.AccountID > 0 && (updated.Name != current.Name || updated.Phone != current.Phone) {
		if _, err := s.db.UpdateRow(ctx, sambaAccountsTable, current.AccountID, map[string]any{
			"Name": sambaAccountName(updated.Name, updated.Phone),
		}); err != nil {
			s.logger.Warn("samba_customer_account_rename_failed", "entity_id", id, "account_id", current.AccountID, "error", err)
		}
	}
	return updated, nil
}

// Delete removes the customer in reverse creation order:
// EntityStateValues, then Entities, then Accounts.
func (s SambaCustomerService) Delete(ctx context.Context, rawID string) (DeleteSambaCustomerResult, error) {
	if err := s.ready(); err != nil {
		return DeleteSambaCustomerResult{}, err
	}
	id, err := parseSambaID(rawID)
	if err != nil {
		return DeleteSambaCustomerResult{}, err
	}
	customer, err := s.find(ctx, id)
	if err != nil {
		return DeleteSambaCustomerResult{}, err
	}
	stateIDs, err := s.entityStateIDs(ctx, id)
	if err != nil {
		return DeleteSambaCustomerResult{}, err
	}
	for _, stateID := range stateIDs {
		if _, err := s.db.DeleteRow(ctx, sambaEntityStateTable, stateID); err != nil && !isNotFound(err) {
			return DeleteSambaCustomerResult{}, err
		}
	}
	if _, err := s.db.DeleteRow(ctx, sambaEntitiesTable, id); err != nil {
		return DeleteSambaCustomerResult{}, err
	}
	result := DeleteSambaCustomerResult{Deleted: true, EntityID: id, EntityStateValueID: stateIDs}
	if customer.AccountID > 0 {
		if _, err := s.db.DeleteRow(ctx, sambaAccountsTable, customer.AccountID); err != nil && !isNotFound(err) {
			s.logger.Warn("samba_customer_account_delete_failed", "entity_id", id, "account_id", customer.AccountID, "error", err)
		} else {
			result.AccountID = customer.AccountID
		}
	}
	return result, nil
}

func (s SambaCustomerService) ready() error {
	if s.db == nil {
		return shareddomain.UpstreamError("Samba API is not configured.", nil)
	}
	return nil
}

func (s SambaCustomerService) find(ctx context.Context, id int64) (posdomain.SambaCustomer, error) {
	all, err := s.allCustomers(ctx)
	if err != nil {
		return posdomain.SambaCustomer{}, err
	}
	for _, customer := range all {
		if customer.ID == id {
			return customer, nil
		}
	}
	return posdomain.SambaCustomer{}, shareddomain.NotFound("Samba customer not found.")
}

// allCustomers reads every Entities row (Samba has no server-side filter) and
// keeps the customers. Rows come back newest first.
func (s SambaCustomerService) allCustomers(ctx context.Context) ([]posdomain.SambaCustomer, error) {
	customers := []posdomain.SambaCustomer{}
	err := s.scan(ctx, sambaEntitiesTable, func(row map[string]any) {
		if rowInt(row, "EntityTypeId") == posdomain.SambaCustomerEntityTypeID {
			customers = append(customers, customerFromRow(row))
		}
	})
	return customers, err
}

func (s SambaCustomerService) entityStateIDs(ctx context.Context, entityID int64) ([]int64, error) {
	ids := []int64{}
	err := s.scan(ctx, sambaEntityStateTable, func(row map[string]any) {
		if rowInt(row, "EntityId") == entityID {
			ids = append(ids, rowInt(row, "Id"))
		}
	})
	return ids, err
}

func (s SambaCustomerService) scan(ctx context.Context, table string, visit func(map[string]any)) error {
	for page := 1; page <= sambaMaxScanPages; page++ {
		result, err := s.db.TableRows(ctx, table, page, sambaMaxPageSize)
		if err != nil {
			return err
		}
		for _, row := range result.Rows {
			visit(row)
		}
		if page >= result.TotalPages || len(result.Rows) == 0 {
			return nil
		}
	}
	return nil
}

func (s SambaCustomerService) rollback(ctx context.Context, table string, id int64) {
	if id <= 0 {
		return
	}
	if _, err := s.db.DeleteRow(context.WithoutCancel(ctx), table, id); err != nil {
		s.logger.Error("samba_customer_rollback_failed", "table", table, "id", id, "error", err)
	}
}

func filterSambaCustomers(customers []posdomain.SambaCustomer, query string) []posdomain.SambaCustomer {
	query = strings.ToLower(strings.TrimSpace(query))
	if query == "" {
		return customers
	}
	queryDigits := digitsOnly(query)
	out := []posdomain.SambaCustomer{}
	for _, customer := range customers {
		switch {
		case strings.Contains(strings.ToLower(customer.Name), query),
			customer.CustomerID != "" && strings.EqualFold(customer.CustomerID, query),
			len(queryDigits) >= 4 && strings.Contains(digitsOnly(customer.Phone), queryDigits):
			out = append(out, customer)
		}
	}
	return out
}

func customerFromRow(row map[string]any) posdomain.SambaCustomer {
	customData := parseCustomData(rowString(row, "CustomData"))
	return posdomain.SambaCustomer{
		ID:             rowInt(row, "Id"),
		Name:           strings.TrimSpace(rowString(row, "Name")),
		Phone:          strings.TrimSpace(customFieldValue(customData, "Phone")),
		CustomerID:     strings.TrimSpace(customFieldValue(customData, "Customer ID")),
		CustomData:     customData,
		Notes:          rowString(row, "Notes"),
		AccountID:      rowInt(row, "AccountId"),
		LastUpdateTime: rowString(row, "LastUpdateTime"),
	}
}

func parseCustomData(raw string) []posdomain.SambaCustomField {
	fields := []posdomain.SambaCustomField{}
	if strings.TrimSpace(raw) == "" {
		return fields
	}
	if err := json.Unmarshal([]byte(raw), &fields); err != nil {
		return []posdomain.SambaCustomField{}
	}
	return fields
}

func setCustomField(fields []posdomain.SambaCustomField, name, value string) []posdomain.SambaCustomField {
	for i := range fields {
		if strings.EqualFold(fields[i].Name, name) {
			if value == "" {
				return append(fields[:i:i], fields[i+1:]...)
			}
			fields[i].Value = value
			return fields
		}
	}
	if value == "" {
		return fields
	}
	return append(fields, posdomain.SambaCustomField{Name: name, Value: value})
}

func customFieldValue(fields []posdomain.SambaCustomField, name string) string {
	for _, field := range fields {
		if strings.EqualFold(field.Name, name) {
			return field.Value
		}
	}
	return ""
}

func sambaAccountName(name, phone string) string {
	return name + "-" + phone
}

func sambaTillTime(t time.Time) string {
	return t.In(sambaTillZone).Format("2006-01-02T15:04:05")
}

// availableEntityStates renders the status list exactly as the POS writes it,
// including the WCF date form with escaped slashes: \/Date(<unix ms>+0100)\/.
func availableEntityStates(t time.Time) string {
	return fmt.Sprintf(`[{"D":"\/Date(%d+0100)\/","S":"Available","SN":"Status"}]`, t.UnixMilli())
}

func parseSambaID(raw string) (int64, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || id < 1 {
		return 0, shareddomain.ValidationError(map[string]string{"id": "must be a positive integer"})
	}
	return id, nil
}

func isNotFound(err error) bool {
	appErr, ok := err.(*shareddomain.AppError)
	return ok && appErr.Status == 404
}

func rowInt(row map[string]any, key string) int64 {
	switch value := row[key].(type) {
	case float64:
		return int64(value)
	case json.Number:
		parsed, _ := value.Int64()
		return parsed
	case string:
		parsed, _ := strconv.ParseInt(value, 10, 64)
		return parsed
	}
	return 0
}

func rowString(row map[string]any, key string) string {
	value, _ := row[key].(string)
	return value
}

func digitsOnly(value string) string {
	var b strings.Builder
	for _, r := range value {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}
