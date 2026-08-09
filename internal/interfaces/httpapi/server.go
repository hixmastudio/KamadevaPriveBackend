package httpapi

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/hixmastudio/kamadeva-prive-backend/internal/config"
	engagementapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/application"
	operationsapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/operations/application"
	posapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/application"
	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	reportingapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/application"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type Server struct {
	cfg         config.Config
	tickets     posapp.TicketIngestionService
	maintenance operationsapp.MaintenanceService
	reports     reportingapp.CaptureRateQueryService
	webhooks    engagementapp.WebhookIntakeService
	mux         *http.ServeMux
}

type Dependencies struct {
	Config      config.Config
	Tickets     posapp.TicketIngestionService
	Maintenance operationsapp.MaintenanceService
	Reports     reportingapp.CaptureRateQueryService
	Webhooks    engagementapp.WebhookIntakeService
}

func NewServer(deps Dependencies) http.Handler {
	s := &Server{
		cfg:         deps.Config,
		tickets:     deps.Tickets,
		maintenance: deps.Maintenance,
		reports:     deps.Reports,
		webhooks:    deps.Webhooks,
		mux:         http.NewServeMux(),
	}
	s.routes()
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /health", s.health)
	s.mux.HandleFunc("POST /integrations/pos/samba/tickets", s.auth(s.ingestSambaTicket))
	s.mux.HandleFunc("POST /integrations/whatsapp/inbound", s.auth(s.whatsAppInbound))
	s.mux.HandleFunc("POST /integrations/wallet/cards/events", s.auth(s.genericWebhook))
	s.mux.HandleFunc("POST /integrations/payments/events", s.auth(s.genericWebhook))
	s.mux.HandleFunc("POST /jobs/tier-decay-sweep", s.auth(s.tierDecaySweep))
	s.mux.HandleFunc("POST /jobs/audit-partitions", s.auth(s.auditPartitions))
	s.mux.HandleFunc("GET /reports/capture-rate", s.auth(s.captureRateReport))
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "kamadeva-api"})
}

func (s *Server) ingestSambaTicket(w http.ResponseWriter, r *http.Request) {
	var ticket posdomain.SambaTicket
	if err := readJSON(r, &ticket); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.tickets.IngestSambaTicket(r.Context(), ticket)
	writeResult(w, out, err)
}

func (s *Server) whatsAppInbound(w http.ResponseWriter, r *http.Request) {
	var payload map[string]any
	if err := readJSON(r, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.webhooks.AcceptWhatsAppInbound(payload)
	writeResult(w, out, err)
}

func (s *Server) genericWebhook(w http.ResponseWriter, r *http.Request) {
	var payload map[string]any
	if err := readJSON(r, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.webhooks.AcceptGenericWebhook(payload)
	writeResult(w, out, err)
}

func (s *Server) tierDecaySweep(w http.ResponseWriter, r *http.Request) {
	out, err := s.maintenance.RunTierDecaySweep(r.Context())
	writeResult(w, out, err)
}

func (s *Server) auditPartitions(w http.ResponseWriter, r *http.Request) {
	var payload struct {
		Month string `json:"month"`
	}
	if err := readJSON(r, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.maintenance.EnsureAuditPartition(r.Context(), payload.Month)
	writeResult(w, out, err)
}

func (s *Server) captureRateReport(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	out, err := s.reports.GetCaptureRateReport(r.Context(), q.Get("from"), q.Get("to"))
	writeResult(w, out, err)
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !secretEqual(r.Header.Get("X-KP-API-Key"), s.cfg.APISharedSecret) {
			writeError(w, shareddomain.Unauthorized())
			return
		}
		next(w, r)
	}
}

func readJSON(r *http.Request, out any) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(out)
}

func writeResult(w http.ResponseWriter, body any, err error) {
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func writeError(w http.ResponseWriter, err error) {
	var appErr *shareddomain.AppError
	if errors.As(err, &appErr) {
		writeJSON(w, appErr.Status, map[string]any{
			"error":   appErr.Message,
			"code":    appErr.Code,
			"details": appErr.Details,
		})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "Internal server error.", "code": "internal_error"})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func secretEqual(supplied, expected string) bool {
	if supplied == "" || expected == "" {
		return false
	}
	suppliedHash := sha256.Sum256([]byte(supplied))
	expectedHash := sha256.Sum256([]byte(expected))
	return subtle.ConstantTimeCompare(suppliedHash[:], expectedHash[:]) == 1
}
