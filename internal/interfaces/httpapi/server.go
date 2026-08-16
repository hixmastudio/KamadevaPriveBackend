package httpapi

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/hixmastudio/kamadeva-prive-backend/internal/config"
	engagementapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/engagement/application"
	operationsapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/operations/application"
	posapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/application"
	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	reportingapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/reporting/application"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type Server struct {
	cfg          config.Config
	tickets      posapp.TicketIngestionService
	sambaPull    posapp.SambaPullService
	orchestrator *posapp.SambaTransactionOrchestrator
	sambaSources map[string]SambaSourceRuntime
	maintenance  operationsapp.MaintenanceService
	reports      reportingapp.CaptureRateQueryService
	webhooks     engagementapp.WebhookIntakeService
	mux          *http.ServeMux
	logger       *slog.Logger
}

type Dependencies struct {
	Config       config.Config
	Tickets      posapp.TicketIngestionService
	SambaPull    posapp.SambaPullService
	Orchestrator *posapp.SambaTransactionOrchestrator
	SambaSources map[string]SambaSourceRuntime
	Maintenance  operationsapp.MaintenanceService
	Reports      reportingapp.CaptureRateQueryService
	Webhooks     engagementapp.WebhookIntakeService
}

type SambaSourceRuntime struct {
	Key          string
	DisplayName  string
	VenueID      string
	Pull         posapp.SambaPullService
	CleanTickets posapp.CleanSambaTicketService
	Orchestrator *posapp.SambaTransactionOrchestrator
}

func NewServer(deps Dependencies) http.Handler {
	s := &Server{
		cfg:          deps.Config,
		tickets:      deps.Tickets,
		sambaPull:    deps.SambaPull,
		orchestrator: deps.Orchestrator,
		sambaSources: deps.SambaSources,
		maintenance:  deps.Maintenance,
		reports:      deps.Reports,
		webhooks:     deps.Webhooks,
		mux:          http.NewServeMux(),
		logger:       slog.Default(),
	}
	s.routes()
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.withRecovery(s.withSecurityHeaders(s.withRequestLog(s.mux))).ServeHTTP(w, r)
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /health", s.health)
	s.mux.HandleFunc("POST /integrations/pos/samba/heartbeat", s.auth(s.sambaHeartbeat))
	s.mux.HandleFunc("POST /integrations/pos/samba/tickets", s.auth(s.ingestSambaTicket))
	s.mux.HandleFunc("GET /integrations/pos/samba/source-health", s.auth(s.sambaSourceHealth))
	s.mux.HandleFunc("POST /integrations/pos/samba/pull-tickets", s.auth(s.pullSambaTickets))
	s.mux.HandleFunc("GET /integrations/pos/samba/orchestrator", s.auth(s.sambaOrchestratorStatus))
	s.mux.HandleFunc("POST /integrations/pos/samba/orchestrator/run", s.auth(s.runSambaOrchestrator))
	s.mux.HandleFunc("GET /integrations/pos/samba/{source}/clean/ticket", s.auth(s.cleanSambaTicketsForSource))
	s.mux.HandleFunc("GET /integrations/pos/samba/{source}/clean/ticket/{ticketNumber}", s.auth(s.cleanSambaTicketForSource))
	s.mux.HandleFunc("GET /integrations/pos/samba/sources", s.auth(s.listSambaSources))
	s.mux.HandleFunc("GET /integrations/pos/samba/sources/{source}/source-health", s.auth(s.sambaSourceHealthForSource))
	s.mux.HandleFunc("POST /integrations/pos/samba/sources/{source}/pull-tickets", s.auth(s.pullSambaTicketsForSource))
	s.mux.HandleFunc("GET /integrations/pos/samba/sources/{source}/clean/ticket", s.auth(s.cleanSambaTicketsForSource))
	s.mux.HandleFunc("GET /integrations/pos/samba/sources/{source}/clean/ticket/{ticketNumber}", s.auth(s.cleanSambaTicketForSource))
	s.mux.HandleFunc("GET /integrations/pos/samba/sources/{source}/orchestrator", s.auth(s.sambaOrchestratorStatusForSource))
	s.mux.HandleFunc("POST /integrations/pos/samba/sources/{source}/orchestrator/run", s.auth(s.runSambaOrchestratorForSource))
	s.mux.HandleFunc("GET /webhooks/whatsapp", s.whatsAppWebhookVerify)
	s.mux.HandleFunc("POST /webhooks/whatsapp", s.whatsAppWebhookPost)
	s.mux.HandleFunc("POST /integrations/whatsapp/inbound", s.auth(s.whatsAppWebhookPost))
	s.mux.HandleFunc("POST /integrations/wallet/cards/events", s.auth(s.genericWebhook))
	s.mux.HandleFunc("POST /integrations/payments/events", s.auth(s.genericWebhook))
	s.mux.HandleFunc("POST /jobs/tier-decay-sweep", s.auth(s.tierDecaySweep))
	s.mux.HandleFunc("POST /jobs/audit-partitions", s.auth(s.auditPartitions))
	s.mux.HandleFunc("GET /reports/capture-rate", s.auth(s.captureRateReport))
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "kamadeva-api"})
}

func (s *Server) sambaHeartbeat(w http.ResponseWriter, r *http.Request) {
	var heartbeat posdomain.SambaHeartbeat
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &heartbeat); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.tickets.AcceptSambaHeartbeat(r.Context(), heartbeat)
	writeResult(w, out, err)
}

func (s *Server) ingestSambaTicket(w http.ResponseWriter, r *http.Request) {
	var ticket posdomain.SambaTicket
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &ticket); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.tickets.IngestSambaTicket(r.Context(), ticket)
	writeResult(w, out, err)
}

func (s *Server) sambaSourceHealth(w http.ResponseWriter, r *http.Request) {
	out, err := s.sambaPull.Health(r.Context())
	writeResult(w, out, err)
}

func (s *Server) pullSambaTickets(w http.ResponseWriter, r *http.Request) {
	var payload posapp.PullSambaTicketsRequest
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := s.sambaPull.PullTickets(r.Context(), payload)
	writeResult(w, out, err)
}

func (s *Server) sambaOrchestratorStatus(w http.ResponseWriter, r *http.Request) {
	if s.orchestrator == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false, "running": false})
		return
	}
	writeJSON(w, http.StatusOK, s.orchestrator.Status())
}

func (s *Server) runSambaOrchestrator(w http.ResponseWriter, r *http.Request) {
	if s.orchestrator == nil {
		writeError(w, shareddomain.UpstreamError("Samba transaction orchestrator is not configured.", nil))
		return
	}
	var payload posapp.SambaTransactionOrchestratorRunRequest
	if err := readOptionalJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	applyRunQuery(r, &payload)
	out, err := s.orchestrator.Trigger(r.Context(), payload)
	writeResult(w, out, err)
}

func (s *Server) listSambaSources(w http.ResponseWriter, r *http.Request) {
	type source struct {
		Key         string `json:"key"`
		DisplayName string `json:"display_name"`
		VenueID     string `json:"venue_id"`
		Enabled     bool   `json:"orchestrator_enabled"`
	}
	out := []source{}
	for _, runtime := range s.sambaSources {
		enabled := false
		if runtime.Orchestrator != nil {
			enabled = runtime.Orchestrator.Status().Enabled
		}
		out = append(out, source{
			Key:         runtime.Key,
			DisplayName: runtime.DisplayName,
			VenueID:     runtime.VenueID,
			Enabled:     enabled,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"sources": out})
}

func (s *Server) sambaSourceHealthForSource(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Pull.Health(r.Context())
	writeResult(w, out, err)
}

func (s *Server) pullSambaTicketsForSource(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	var payload posapp.PullSambaTicketsRequest
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	if strings.TrimSpace(payload.VenueID) == "" {
		payload.VenueID = runtime.VenueID
	}
	out, err := runtime.Pull.PullTickets(r.Context(), payload)
	writeResult(w, out, err)
}

func (s *Server) cleanSambaTicketsForSource(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	req := posapp.CleanSambaTicketsRequest{
		From: q.Get("from"),
		To:   q.Get("to"),
		Page: q.Get("page"),
	}
	if strings.TrimSpace(req.Page) == "" {
		importResult, err := runtime.Pull.PullTickets(r.Context(), posapp.PullSambaTicketsRequest{
			VenueID: runtime.VenueID,
			From:    req.From,
			To:      req.To,
		})
		if err != nil {
			writeError(w, err)
			return
		}
		w.Header().Set("X-KP-Import-Source-Count", fmt.Sprintf("%d", importResult.Source))
		w.Header().Set("X-KP-Import-Imported-Count", fmt.Sprintf("%d", importResult.Imported))
		w.Header().Set("X-KP-Import-Failed-Count", fmt.Sprintf("%d", importResult.Failed))
	}
	out, err := runtime.CleanTickets.List(r.Context(), req)
	writeResult(w, out, err)
}

func (s *Server) cleanSambaTicketForSource(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.CleanTickets.Get(r.Context(), r.PathValue("ticketNumber"))
	writeResult(w, out, err)
}

func (s *Server) sambaOrchestratorStatusForSource(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	if runtime.Orchestrator == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false, "running": false})
		return
	}
	writeJSON(w, http.StatusOK, runtime.Orchestrator.Status())
}

func (s *Server) runSambaOrchestratorForSource(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	if runtime.Orchestrator == nil {
		writeError(w, shareddomain.UpstreamError("Samba transaction orchestrator is not configured.", nil))
		return
	}
	var payload posapp.SambaTransactionOrchestratorRunRequest
	if err := readOptionalJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	applyRunQuery(r, &payload)
	if strings.TrimSpace(payload.VenueID) == "" {
		payload.VenueID = runtime.VenueID
	}
	out, err := runtime.Orchestrator.Trigger(r.Context(), payload)
	writeResult(w, out, err)
}

func (s *Server) sambaSource(w http.ResponseWriter, r *http.Request) (SambaSourceRuntime, bool) {
	source := strings.TrimSpace(r.PathValue("source"))
	switch source {
	case "oso":
		source = "oso-lounge"
	case "bbr":
		source = "boom-boom-room"
	}
	runtime, ok := s.sambaSources[source]
	if !ok {
		writeError(w, shareddomain.ValidationError(map[string]string{"source": "unknown Samba source"}))
		return SambaSourceRuntime{}, false
	}
	return runtime, true
}

func (s *Server) whatsAppWebhookVerify(w http.ResponseWriter, r *http.Request) {
	query := map[string]string{}
	for key, values := range r.URL.Query() {
		if len(values) > 0 {
			query[key] = values[0]
		}
	}
	challenge, err := s.webhooks.VerifyWhatsAppWebhook(query)
	if err != nil {
		writeError(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(challenge))
}

func (s *Server) whatsAppWebhookPost(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.cfg.MaxRequestBytes))
	if err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "request body is too large or unreadable"}))
		return
	}
	_ = r.Body.Close()
	out, err := s.webhooks.AcceptWhatsAppWebhook(r.Context(), r.Header, body)
	writeResult(w, out, err)
}

func (s *Server) genericWebhook(w http.ResponseWriter, r *http.Request) {
	var payload map[string]any
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
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
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
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
		if s.requiresSambaSignature(r) {
			if err := s.verifySambaSignature(w, r); err != nil {
				writeError(w, err)
				return
			}
		}
		next(w, r)
	}
}

func (s *Server) requiresSambaSignature(r *http.Request) bool {
	return s.cfg.SambaWebhookSecret != "" && r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/integrations/pos/samba/")
}

func (s *Server) verifySambaSignature(w http.ResponseWriter, r *http.Request) error {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.cfg.MaxRequestBytes))
	if err != nil {
		return shareddomain.ValidationError(map[string]string{"body": "request body is too large or unreadable"})
	}
	_ = r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(body))

	supplied := r.Header.Get("X-KP-Signature")
	expected := hmacSHA256(s.cfg.SambaWebhookSecret, body)
	if supplied == "" || !secretEqual(supplied, expected) {
		return shareddomain.Unauthorized()
	}
	return nil
}

func readJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, out any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(out); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return fmt.Errorf("body must contain one JSON object")
	}
	return nil
}

func readOptionalJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, out any) error {
	if r.Body == nil || r.ContentLength == 0 {
		return nil
	}
	return readJSON(w, r, maxBytes, out)
}

func applyRunQuery(r *http.Request, payload *posapp.SambaTransactionOrchestratorRunRequest) {
	q := r.URL.Query()
	if from := strings.TrimSpace(q.Get("from")); from != "" {
		payload.From = from
	}
	if to := strings.TrimSpace(q.Get("to")); to != "" {
		payload.To = to
	}
	if venueID := strings.TrimSpace(q.Get("venue_id")); venueID != "" {
		payload.VenueID = venueID
	}
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

func hmacSHA256(secret string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (s *Server) withRequestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			requestID = fmt.Sprintf("%d", time.Now().UnixNano())
		}
		w.Header().Set("X-Request-ID", requestID)

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.logger.Info("http_request",
			"request_id", requestID,
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

func (s *Server) withSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withRecovery(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				s.logger.Error("panic_recovered", "path", r.URL.Path, "error", recovered)
				writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "Internal server error.", "code": "internal_error"})
			}
		}()
		next.ServeHTTP(w, r)
	})
}
