package domain

import "context"

type MaintenanceRepository interface {
	RunTierDecaySweep(ctx context.Context) error
	EnsureAuditPartition(ctx context.Context, month string) error
}
