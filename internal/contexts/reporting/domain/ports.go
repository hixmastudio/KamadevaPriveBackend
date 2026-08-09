package domain

import "context"

type CaptureRateRepository interface {
	GetCaptureRateReport(ctx context.Context, from, to string) (CaptureRateReport, error)
}
