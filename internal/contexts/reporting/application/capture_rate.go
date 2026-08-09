package application

import (
	"context"
	"time"

	reportingdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type CaptureRateQueryService struct {
	reports reportingdomain.CaptureRateRepository
}

func NewCaptureRateQueryService(reports reportingdomain.CaptureRateRepository) CaptureRateQueryService {
	return CaptureRateQueryService{reports: reports}
}

func (s CaptureRateQueryService) GetCaptureRateReport(ctx context.Context, from, to string) (reportingdomain.CaptureRateReport, error) {
	if _, err := time.Parse(time.DateOnly, from); err != nil {
		return reportingdomain.CaptureRateReport{}, shareddomain.ValidationError(map[string]string{"from": "must be YYYY-MM-DD"})
	}
	if _, err := time.Parse(time.DateOnly, to); err != nil {
		return reportingdomain.CaptureRateReport{}, shareddomain.ValidationError(map[string]string{"to": "must be YYYY-MM-DD"})
	}
	if from > to {
		return reportingdomain.CaptureRateReport{}, shareddomain.ValidationError(map[string]string{"from": "must be before or equal to to"})
	}
	return s.reports.GetCaptureRateReport(ctx, from, to)
}
