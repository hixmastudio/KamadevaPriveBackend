package main

import (
	"log"
	"net/http"

	"github.com/hixmastudio/kamadeva-prive-backend/internal/config"
	engagementapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/application"
	operationsapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/operations/application"
	posapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/application"
	reportingapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/application"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/infrastructure/supabase"
	"github.com/hixmastudio/kamadeva-prive-backend/internal/interfaces/httpapi"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	ops := supabase.NewOperations(cfg.SupabaseURL, cfg.SupabaseServiceRoleKey, http.DefaultClient)
	server := httpapi.NewServer(httpapi.Dependencies{
		Config:      cfg,
		Tickets:     posapp.NewTicketIngestionService(ops),
		Maintenance: operationsapp.NewMaintenanceService(ops),
		Reports:     reportingapp.NewCaptureRateQueryService(ops),
		Webhooks:    engagementapp.NewWebhookIntakeService(),
	})

	log.Printf("Kamadeva API listening on http://localhost:%s", cfg.Port)
	if err := http.ListenAndServe(":"+cfg.Port, server); err != nil {
		log.Fatal(err)
	}
}
