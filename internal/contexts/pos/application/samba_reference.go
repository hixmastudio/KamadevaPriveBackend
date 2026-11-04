package application

import (
	"context"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

// SambaReferenceService exposes the vendor's read-only reporting, catalogue
// and table-browsing routes. Generic table writes are deliberately not exposed;
// the only writes go through SambaCustomerService.
type SambaReferenceService struct {
	source posdomain.SambaReferenceSource
	db     posdomain.SambaDatabase
}

func NewSambaReferenceService(source posdomain.SambaReferenceSource, db posdomain.SambaDatabase) SambaReferenceService {
	return SambaReferenceService{source: source, db: db}
}

func (s SambaReferenceService) Payments(ctx context.Context, from, to string) (json.RawMessage, error) {
	if err := s.ready(); err != nil {
		return nil, err
	}
	from, to = strings.TrimSpace(from), strings.TrimSpace(to)
	if err := validateSambaDateRange(from, to, ""); err != nil {
		return nil, err
	}
	return s.source.FetchPayments(ctx, from, to)
}

func (s SambaReferenceService) SalesByDepartment(ctx context.Context, from, to string) (json.RawMessage, error) {
	if err := s.ready(); err != nil {
		return nil, err
	}
	from, to = strings.TrimSpace(from), strings.TrimSpace(to)
	if err := validateSambaDateRange(from, to, ""); err != nil {
		return nil, err
	}
	return s.source.FetchSalesByDepartment(ctx, from, to)
}

func (s SambaReferenceService) Menu(ctx context.Context) (json.RawMessage, error) {
	if err := s.ready(); err != nil {
		return nil, err
	}
	return s.source.FetchMenu(ctx)
}

func (s SambaReferenceService) Staff(ctx context.Context) (json.RawMessage, error) {
	if err := s.ready(); err != nil {
		return nil, err
	}
	return s.source.FetchStaff(ctx)
}

func (s SambaReferenceService) Departments(ctx context.Context) (json.RawMessage, error) {
	if err := s.ready(); err != nil {
		return nil, err
	}
	return s.source.FetchDepartments(ctx)
}

func (s SambaReferenceService) Tables(ctx context.Context) (json.RawMessage, error) {
	if err := s.ready(); err != nil {
		return nil, err
	}
	return s.db.ListTables(ctx)
}

var sambaTableName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

func (s SambaReferenceService) TableRows(ctx context.Context, table, page, pageSize string) (posdomain.SambaTablePage, error) {
	if err := s.ready(); err != nil {
		return posdomain.SambaTablePage{}, err
	}
	table = strings.TrimSpace(table)
	fields := map[string]string{}
	if !sambaTableName.MatchString(table) {
		fields["table"] = "must be a Samba table name"
	}
	pageNo, ok := optionalPositiveInt(page)
	if !ok {
		fields["page"] = "must be a positive integer"
	}
	size, ok := optionalPositiveInt(pageSize)
	if !ok || size > 500 {
		fields["pageSize"] = "must be between 1 and 500"
	}
	if len(fields) > 0 {
		return posdomain.SambaTablePage{}, shareddomain.ValidationError(fields)
	}
	return s.db.TableRows(ctx, table, pageNo, size)
}

func (s SambaReferenceService) ready() error {
	if s.source == nil || s.db == nil {
		return shareddomain.UpstreamError("Samba API is not configured.", nil)
	}
	return nil
}

// optionalPositiveInt returns 0 for an empty value.
func optionalPositiveInt(raw string) (int, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, true
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 {
		return 0, false
	}
	return value, true
}
