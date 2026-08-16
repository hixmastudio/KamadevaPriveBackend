package main

import (
	"context"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/hixmastudio/kamadeva-prive-backend/internal/config"
	engagementapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/application"
	engagementdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/domain"
	operationsapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/operations/application"
	posapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/application"
	reportingapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/application"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/infrastructure/ai"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/infrastructure/samba"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/infrastructure/supabase"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/infrastructure/whatsapp"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/interfaces/httpapi"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	supabaseHTTPClient := &http.Client{Timeout: cfg.SupabaseHTTPTimeout}
	sambaHTTPClient := &http.Client{Timeout: cfg.SambaHTTPTimeout}
	openAIHTTPClient := &http.Client{Timeout: cfg.OpenAIHTTPTimeout}
	ops := supabase.NewOperations(cfg.SupabaseURL, cfg.SupabaseServiceRoleKey, supabaseHTTPClient)
	whatsAppClient := whatsapp.NewMetaClient(cfg.WhatsAppAPIVersion, cfg.WhatsAppPhoneNumberID, cfg.WhatsAppAccessToken, &http.Client{Timeout: cfg.WriteTimeout})
	var aiClient engagementdomain.AIClient
	if cfg.AIProvider == "openai" {
		aiClient = ai.NewOpenAIClient(cfg.OpenAIAPIKey, cfg.OpenAIModel, openAIHTTPClient)
	}
	sambaClient := samba.NewClient(cfg.SambaAPIURL, cfg.SambaAPIKey, cfg.SambaCacheDir+"/oso-lounge", sambaHTTPClient)
	sambaPull := posapp.NewSambaPullService(sambaClient, ops)
	orchestrator := posapp.NewSambaTransactionOrchestrator(posapp.SambaTransactionOrchestratorConfig{
		Enabled:    cfg.SambaOrchestratorEnabled,
		SourceKey:  "oso-lounge",
		SourceName: "Oso Lounge",
		VenueID:    cfg.SambaVenueID,
		Interval:   cfg.SambaOrchestratorInterval,
		Lookback:   cfg.SambaOrchestratorLookback,
		RunOnStart: cfg.SambaOrchestratorOnStart,
	}, sambaPull, slog.Default())

	boomBoomClient := samba.NewClient(cfg.BoomBoomRoomSambaAPIURL, cfg.BoomBoomRoomSambaAPIKey, cfg.SambaCacheDir+"/boom-boom-room", sambaHTTPClient)
	boomBoomPull := posapp.NewSambaPullService(boomBoomClient, ops)
	boomBoomOrchestrator := posapp.NewSambaTransactionOrchestrator(posapp.SambaTransactionOrchestratorConfig{
		Enabled:    cfg.BoomBoomRoomOrchestratorEnabled,
		SourceKey:  "boom-boom-room",
		SourceName: "Boom Boom Room",
		VenueID:    cfg.BoomBoomRoomVenueID,
		Interval:   cfg.BoomBoomRoomOrchestratorInterval,
		Lookback:   cfg.BoomBoomRoomOrchestratorLookback,
		RunOnStart: cfg.BoomBoomRoomOrchestratorOnStart,
	}, boomBoomPull, slog.Default())

	sambaSources := map[string]httpapi.SambaSourceRuntime{
		"oso-lounge": {
			Key:          "oso-lounge",
			DisplayName:  "Oso Lounge",
			VenueID:      cfg.SambaVenueID,
			Pull:         sambaPull,
			CleanTickets: posapp.NewCleanSambaTicketService(sambaClient),
			Orchestrator: orchestrator,
		},
	}
	if boomBoomClient != nil {
		sambaSources["boom-boom-room"] = httpapi.SambaSourceRuntime{
			Key:          "boom-boom-room",
			DisplayName:  "Boom Boom Room",
			VenueID:      cfg.BoomBoomRoomVenueID,
			Pull:         boomBoomPull,
			CleanTickets: posapp.NewCleanSambaTicketService(boomBoomClient),
			Orchestrator: boomBoomOrchestrator,
		}
	}
	handler := httpapi.NewServer(httpapi.Dependencies{
		Config:       cfg,
		Tickets:      posapp.NewTicketIngestionService(ops),
		SambaPull:    sambaPull,
		Orchestrator: orchestrator,
		SambaSources: sambaSources,
		Maintenance:  operationsapp.NewMaintenanceService(ops),
		Reports:      reportingapp.NewCaptureRateQueryService(ops),
		Webhooks:     engagementapp.NewWebhookIntakeService(ops, cfg.WhatsAppVerifyToken, cfg.WhatsAppAppSecret, slog.Default()),
	})

	appCtx, cancelApp := context.WithCancel(context.Background())
	defer cancelApp()
	if cfg.WhatsAppWorkerEnabled {
		engagementapp.NewWorker(
			ops,
			whatsAppClient,
			aiClient,
			cfg.WhatsAppWorkerInterval,
			slog.Default(),
			engagementapp.WithBookingConfirmationTemplate(cfg.WhatsAppBookingConfirmationTemplate),
		).Start(appCtx)
	}
	orchestrator.Start(appCtx)
	boomBoomOrchestrator.Start(appCtx)
	posapp.NewSambaDailyPullScheduler(posapp.SambaDailyPullConfig{
		Enabled:    cfg.SambaDailyPullEnabled,
		VenueID:    cfg.SambaVenueID,
		RunAt:      cfg.SambaDailyPullTime,
		Lookback:   cfg.SambaDailyPullLookback,
		RunOnStart: cfg.SambaDailyPullOnStart,
	}, sambaPull, slog.Default()).Start(appCtx)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler,
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
		ReadTimeout:       cfg.ReadTimeout,
		WriteTimeout:      cfg.WriteTimeout,
		IdleTimeout:       cfg.IdleTimeout,
	}

	errs := make(chan error, 1)
	go func() {
		log.Printf("Kamadeva API listening on http://localhost:%s", cfg.Port)
		errs <- server.ListenAndServe()
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-errs:
		if err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	case <-stop:
		cancelApp()
		ctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			log.Fatal(err)
		}
		log.Println("Kamadeva API stopped")
	}
}
