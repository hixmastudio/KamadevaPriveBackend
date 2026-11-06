package application

import (
	"context"
	"log/slog"
	"sync"
	"time"

	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type SambaTransactionOrchestratorConfig struct {
	Enabled    bool
	SourceKey  string
	SourceName string
	VenueID    string
	Interval   time.Duration
	Lookback   int
	RunOnStart bool
}

type SambaTransactionOrchestrator struct {
	cfg     SambaTransactionOrchestratorConfig
	service SambaPullService
	logger  *slog.Logger

	mu      sync.Mutex
	running bool
	status  SambaTransactionOrchestratorStatus

	// fetchedThrough is the last date a scheduled pull fetched successfully.
	// Scheduled pulls start from it, so days missed while the till was
	// unreachable are fetched on the first pull that gets through.
	fetchedThrough string
	now            func() time.Time
}

// maxCatchUpDays bounds how far back a catch-up reaches after an outage, so a
// long one cannot turn every poll into a huge request to the till.
const maxCatchUpDays = 30

type SambaTransactionOrchestratorStatus struct {
	Enabled      bool                    `json:"enabled"`
	Running      bool                    `json:"running"`
	SourceKey    string                  `json:"source_key,omitempty"`
	SourceName   string                  `json:"source_name,omitempty"`
	VenueID      string                  `json:"venue_id,omitempty"`
	Interval     string                  `json:"interval,omitempty"`
	Lookback     int                     `json:"lookback_days,omitempty"`
	LastStarted  *time.Time              `json:"last_started_at,omitempty"`
	LastFinished *time.Time              `json:"last_finished_at,omitempty"`
	LastError    *string                 `json:"last_error,omitempty"`
	LastResult   *PullSambaTicketsResult `json:"last_result,omitempty"`
	NextRun      *time.Time              `json:"next_run_at,omitempty"`
}

type SambaTransactionOrchestratorRunRequest struct {
	VenueID string `json:"venue_id,omitempty"`
	From    string `json:"from,omitempty"`
	To      string `json:"to,omitempty"`
}

func NewSambaTransactionOrchestrator(cfg SambaTransactionOrchestratorConfig, service SambaPullService, logger *slog.Logger) *SambaTransactionOrchestrator {
	if logger == nil {
		logger = slog.Default()
	}
	if cfg.Lookback <= 0 {
		cfg.Lookback = 1
	}
	if cfg.Interval <= 0 {
		cfg.Interval = 5 * time.Minute
	}
	return &SambaTransactionOrchestrator{
		cfg:     cfg,
		service: service,
		logger:  logger,
		now:     time.Now,
		status: SambaTransactionOrchestratorStatus{
			Enabled:    cfg.Enabled,
			SourceKey:  cfg.SourceKey,
			SourceName: cfg.SourceName,
			VenueID:    cfg.VenueID,
			Interval:   cfg.Interval.String(),
			Lookback:   cfg.Lookback,
		},
	}
}

func (o *SambaTransactionOrchestrator) Start(ctx context.Context) {
	if !o.cfg.Enabled {
		o.logger.Info("samba_transaction_orchestrator_disabled",
			"source", o.cfg.SourceKey,
			"source_name", o.cfg.SourceName,
			"venue_id", o.cfg.VenueID,
		)
		return
	}
	o.logger.Info("samba_transaction_orchestrator_started",
		"source", o.cfg.SourceKey,
		"source_name", o.cfg.SourceName,
		"venue_id", o.cfg.VenueID,
		"interval", o.cfg.Interval.String(),
		"lookback_days", o.cfg.Lookback,
		"run_on_start", o.cfg.RunOnStart,
	)
	go o.loop(ctx)
}

func (o *SambaTransactionOrchestrator) Status() SambaTransactionOrchestratorStatus {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.status
}

func (o *SambaTransactionOrchestrator) Trigger(ctx context.Context, req SambaTransactionOrchestratorRunRequest) (PullSambaTicketsResult, error) {
	pullReq := o.pullRequest(ctx, req)
	return o.run(ctx, "manual", pullReq)
}

func (o *SambaTransactionOrchestrator) loop(ctx context.Context) {
	if o.cfg.RunOnStart {
		o.logger.Info("samba_transaction_orchestrator_startup_run_queued",
			"source", o.cfg.SourceKey,
			"source_name", o.cfg.SourceName,
			"venue_id", o.cfg.VenueID,
		)
		_, _ = o.run(ctx, "startup", o.pullRequest(ctx, SambaTransactionOrchestratorRunRequest{}))
	}

	ticker := time.NewTicker(o.cfg.Interval)
	defer ticker.Stop()
	nextRun := time.Now().Add(o.cfg.Interval)
	o.setNextRun(nextRun)
	o.logger.Info("samba_transaction_orchestrator_listening",
		"source", o.cfg.SourceKey,
		"source_name", o.cfg.SourceName,
		"venue_id", o.cfg.VenueID,
		"poll_interval", o.cfg.Interval.String(),
		"next_run_at", nextRun,
	)

	for {
		select {
		case <-ctx.Done():
			o.logger.Info("samba_transaction_orchestrator_stopped",
				"source", o.cfg.SourceKey,
				"source_name", o.cfg.SourceName,
				"venue_id", o.cfg.VenueID,
			)
			return
		case at := <-ticker.C:
			nextRun := at.Add(o.cfg.Interval)
			o.setNextRun(nextRun)
			o.logger.Info("samba_transaction_orchestrator_poll_tick",
				"source", o.cfg.SourceKey,
				"source_name", o.cfg.SourceName,
				"venue_id", o.cfg.VenueID,
				"tick_at", at,
				"next_run_at", nextRun,
			)
			_, _ = o.run(ctx, "poll", o.pullRequest(ctx, SambaTransactionOrchestratorRunRequest{}))
			o.logger.Info("samba_transaction_orchestrator_waiting",
				"source", o.cfg.SourceKey,
				"source_name", o.cfg.SourceName,
				"venue_id", o.cfg.VenueID,
				"next_run_at", nextRun,
			)
		}
	}
}

func (o *SambaTransactionOrchestrator) run(ctx context.Context, trigger string, req PullSambaTicketsRequest) (PullSambaTicketsResult, error) {
	started := time.Now()
	if !o.beginRun(started) {
		o.logger.Warn("samba_transaction_orchestrator_run_skipped",
			"source", o.cfg.SourceKey,
			"source_name", o.cfg.SourceName,
			"trigger", trigger,
			"reason", "already_running",
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
		)
		return PullSambaTicketsResult{}, shareddomain.ValidationError(map[string]string{"orchestrator": "already running"})
	}

	o.logger.Info("samba_transaction_orchestration_started",
		"source", o.cfg.SourceKey,
		"source_name", o.cfg.SourceName,
		"trigger", trigger,
		"venue_id", req.VenueID,
		"from", req.From,
		"to", req.To,
	)

	result, err := o.service.PullTickets(ctx, req)
	o.finishRun(trigger, req, result, err)
	if err != nil {
		o.logger.Error("samba_transaction_orchestration_failed",
			"source", o.cfg.SourceKey,
			"source_name", o.cfg.SourceName,
			"trigger", trigger,
			"venue_id", req.VenueID,
			"from", req.From,
			"to", req.To,
			"duration_ms", time.Since(started).Milliseconds(),
			"error", err,
		)
		return PullSambaTicketsResult{}, err
	}

	o.logger.Info("samba_transaction_orchestration_completed",
		"source", o.cfg.SourceKey,
		"source_name", o.cfg.SourceName,
		"trigger", trigger,
		"venue_id", req.VenueID,
		"from", result.From,
		"to", result.To,
		"source_count", result.Source,
		"imported_count", result.Imported,
		"skipped_existing_count", result.SkippedExisting,
		"failed_count", result.Failed,
		"unmatched_customer_count", result.Unmatched,
		"duration_ms", time.Since(started).Milliseconds(),
	)
	return result, nil
}

func (o *SambaTransactionOrchestrator) pullRequest(ctx context.Context, req SambaTransactionOrchestratorRunRequest) PullSambaTicketsRequest {
	venueID := firstNonEmpty(req.VenueID, o.cfg.VenueID)
	if req.From != "" && req.To != "" {
		return PullSambaTicketsRequest{VenueID: venueID, From: req.From, To: req.To}
	}
	now := o.now()
	to := now.Format(time.DateOnly)
	from := now.AddDate(0, 0, -o.cfg.Lookback+1).Format(time.DateOnly)
	if since := o.catchUpFrom(ctx, venueID); since != "" && since < from {
		floor := now.AddDate(0, 0, -maxCatchUpDays+1).Format(time.DateOnly)
		from = max(since, floor)
		o.logger.Info("samba_transaction_orchestrator_catching_up",
			"source", o.cfg.SourceKey,
			"venue_id", venueID,
			"from", from,
			"to", to,
		)
	}
	return PullSambaTicketsRequest{VenueID: venueID, From: from, To: to}
}

// catchUpFrom is the first date a scheduled pull still owes. After a restart
// it falls back to the newest stored ticket, so an outage that spanned a
// deploy is caught up too.
func (o *SambaTransactionOrchestrator) catchUpFrom(ctx context.Context, venueID string) string {
	o.mu.Lock()
	since := o.fetchedThrough
	o.mu.Unlock()
	if since != "" {
		return since
	}
	latest, err := o.service.LatestImportedDate(ctx, venueID)
	if err != nil {
		o.logger.Warn("samba_transaction_orchestrator_latest_ticket_lookup_failed", "source", o.cfg.SourceKey, "venue_id", venueID, "error", err)
		return ""
	}
	return latest
}

func (o *SambaTransactionOrchestrator) beginRun(started time.Time) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.running {
		return false
	}
	o.running = true
	o.status.Running = true
	o.status.LastStarted = &started
	o.status.LastError = nil
	return true
}

func (o *SambaTransactionOrchestrator) finishRun(trigger string, req PullSambaTicketsRequest, result PullSambaTicketsResult, err error) {
	finished := time.Now()
	o.mu.Lock()
	defer o.mu.Unlock()
	o.running = false
	o.status.Running = false
	o.status.LastFinished = &finished
	if err != nil {
		message := err.Error()
		o.status.LastError = &message
		o.status.LastResult = nil
		return
	}
	o.status.LastError = nil
	o.status.LastResult = &result
	// Only a scheduled pull, which always starts from the owed date, may mark
	// the gap as filled. A manual pull of one day must not skip the rest.
	if trigger != "manual" && req.To > o.fetchedThrough {
		o.fetchedThrough = req.To
	}
}

func (o *SambaTransactionOrchestrator) setNextRun(next time.Time) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.status.NextRun = &next
}
