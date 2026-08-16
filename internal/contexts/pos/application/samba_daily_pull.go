package application

import (
	"context"
	"log/slog"
	"time"
)

type SambaDailyPullConfig struct {
	Enabled    bool
	VenueID    string
	RunAt      string
	Lookback   int
	RunOnStart bool
}

type SambaDailyPullScheduler struct {
	cfg     SambaDailyPullConfig
	service SambaPullService
	logger  *slog.Logger
}

func NewSambaDailyPullScheduler(cfg SambaDailyPullConfig, service SambaPullService, logger *slog.Logger) SambaDailyPullScheduler {
	if logger == nil {
		logger = slog.Default()
	}
	return SambaDailyPullScheduler{cfg: cfg, service: service, logger: logger}
}

func (s SambaDailyPullScheduler) Start(ctx context.Context) {
	if !s.cfg.Enabled {
		return
	}
	go s.run(ctx)
}

func (s SambaDailyPullScheduler) run(ctx context.Context) {
	if s.cfg.RunOnStart {
		s.pull(ctx)
	}

	for {
		nextRun := nextClockTime(time.Now(), s.cfg.RunAt)
		timer := time.NewTimer(time.Until(nextRun))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
			s.pull(ctx)
		}
	}
}

func (s SambaDailyPullScheduler) pull(ctx context.Context) {
	to := time.Now().AddDate(0, 0, -1).Format(time.DateOnly)
	from := time.Now().AddDate(0, 0, -s.cfg.Lookback).Format(time.DateOnly)
	result, err := s.service.PullTickets(ctx, PullSambaTicketsRequest{
		VenueID: s.cfg.VenueID,
		From:    from,
		To:      to,
	})
	if err != nil {
		s.logger.Error("samba_daily_pull_failed", "from", from, "to", to, "error", err)
		return
	}
	s.logger.Info("samba_daily_pull_completed",
		"from", result.From,
		"to", result.To,
		"source_count", result.Source,
		"imported_count", result.Imported,
		"failed_count", result.Failed,
		"unmatched_customer_count", result.Unmatched,
	)
}

func nextClockTime(now time.Time, clock string) time.Time {
	parsed, err := time.Parse("15:04", clock)
	if err != nil {
		parsed, _ = time.Parse("15:04", "03:15")
	}
	next := time.Date(now.Year(), now.Month(), now.Day(), parsed.Hour(), parsed.Minute(), 0, 0, now.Location())
	if !next.After(now) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}
