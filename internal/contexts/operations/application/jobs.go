package application

import (
	"context"
	"regexp"

	operationsdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/operations/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

var firstDayOfMonth = regexp.MustCompile(`^\d{4}-\d{2}-01$`)

type MaintenanceService struct {
	maintenance operationsdomain.MaintenanceRepository
}

func NewMaintenanceService(maintenance operationsdomain.MaintenanceRepository) MaintenanceService {
	return MaintenanceService{maintenance: maintenance}
}

func (s MaintenanceService) RunTierDecaySweep(ctx context.Context) (map[string]bool, error) {
	if err := s.maintenance.RunTierDecaySweep(ctx); err != nil {
		return nil, err
	}
	return map[string]bool{"ok": true}, nil
}

func (s MaintenanceService) EnsureAuditPartition(ctx context.Context, month string) (map[string]bool, error) {
	if !firstDayOfMonth.MatchString(month) {
		return nil, shareddomain.ValidationError(map[string]string{"month": "use first day of month, e.g. 2026-09-01"})
	}
	if err := s.maintenance.EnsureAuditPartition(ctx, month); err != nil {
		return nil, err
	}
	return map[string]bool{"ok": true}, nil
}
