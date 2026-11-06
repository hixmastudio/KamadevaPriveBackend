package httpapi

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"

	posapp "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/application"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

// StaffAuthenticator resolves a Supabase access token to an active staff member.
type StaffAuthenticator interface {
	StaffFromAccessToken(ctx context.Context, accessToken string) (shareddomain.StaffPrincipal, error)
}

type principalKey struct{}

// servicePrincipal stands in for callers that authenticate with the shared
// X-KP-API-Key (Samba extension, cron, ops scripts).
var servicePrincipal = shareddomain.StaffPrincipal{StaffID: "service", Role: "founder"}

func (s *Server) sambaStaffRoutes() {
	const prefix = "/integrations/pos/samba/sources/{source}"
	s.mux.HandleFunc("GET "+prefix+"/payments", s.staffAuth(s.sambaPayments))
	s.mux.HandleFunc("GET "+prefix+"/sales-by-department", s.staffAuth(s.sambaSalesByDepartment))
	s.mux.HandleFunc("GET "+prefix+"/menu", s.staffAuth(s.sambaMenu))
	s.mux.HandleFunc("GET "+prefix+"/staff", s.staffAuth(s.sambaStaff))
	s.mux.HandleFunc("GET "+prefix+"/departments", s.staffAuth(s.sambaDepartments))
	s.mux.HandleFunc("GET "+prefix+"/db/tables", s.staffAuth(s.managerOnly(s.sambaTables)))
	s.mux.HandleFunc("GET "+prefix+"/db/tables/{table}", s.staffAuth(s.managerOnly(s.sambaTableRows)))
	s.mux.HandleFunc("GET "+prefix+"/customers", s.staffAuth(s.listSambaCustomers))
	s.mux.HandleFunc("POST "+prefix+"/customers", s.staffAuth(s.createSambaCustomer))
	s.mux.HandleFunc("GET "+prefix+"/customers/{id}", s.staffAuth(s.getSambaCustomer))
	s.mux.HandleFunc("PATCH "+prefix+"/customers/{id}", s.staffAuth(s.updateSambaCustomer))
	s.mux.HandleFunc("DELETE "+prefix+"/customers/{id}", s.staffAuth(s.managerOnly(s.deleteSambaCustomer)))
	s.mux.HandleFunc("GET "+prefix+"/member-sync", s.staffAuth(s.managerOnly(s.sambaMemberSyncStatus)))
	s.mux.HandleFunc("POST "+prefix+"/member-sync/run", s.staffAuth(s.managerOnly(s.runSambaMemberSync)))
}

func (s *Server) sambaMemberSyncStatus(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	if runtime.MemberSync == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false, "running": false, "source_key": runtime.Key})
		return
	}
	writeJSON(w, http.StatusOK, runtime.MemberSync.Status())
}

func (s *Server) runSambaMemberSync(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	if runtime.MemberSync == nil {
		writeError(w, shareddomain.UpstreamError("Member sync is not configured for this till.", nil))
		return
	}
	out, err := runtime.MemberSync.Run(r.Context(), "manual:"+principalFrom(r).StaffID)
	writeResult(w, out, err)
}

func (s *Server) sambaPayments(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	out, err := runtime.Reference.Payments(r.Context(), q.Get("from"), q.Get("to"))
	writeResult(w, out, err)
}

func (s *Server) sambaSalesByDepartment(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	out, err := runtime.Reference.SalesByDepartment(r.Context(), q.Get("from"), q.Get("to"))
	writeResult(w, out, err)
}

func (s *Server) sambaMenu(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Reference.Menu(r.Context())
	writeResult(w, out, err)
}

func (s *Server) sambaStaff(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Reference.Staff(r.Context())
	writeResult(w, out, err)
}

func (s *Server) sambaDepartments(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Reference.Departments(r.Context())
	writeResult(w, out, err)
}

func (s *Server) sambaTables(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Reference.Tables(r.Context())
	writeResult(w, out, err)
}

func (s *Server) sambaTableRows(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	out, err := runtime.Reference.TableRows(r.Context(), r.PathValue("table"), q.Get("page"), q.Get("pageSize"))
	writeResult(w, out, err)
}

func (s *Server) listSambaCustomers(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	out, err := runtime.Customers.List(r.Context(), posapp.SambaCustomerListRequest{
		Query:    q.Get("q"),
		Page:     q.Get("page"),
		PageSize: q.Get("page_size"),
	})
	writeResult(w, out, err)
}

func (s *Server) getSambaCustomer(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Customers.Get(r.Context(), r.PathValue("id"))
	writeResult(w, map[string]any{"customer": out}, err)
}

func (s *Server) createSambaCustomer(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	var payload posapp.CreateSambaCustomerRequest
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := runtime.Customers.Create(r.Context(), payload)
	if err == nil {
		s.logger.Info("samba_customer_created", "source", runtime.Key, "entity_id", out.ID, "account_id", out.AccountID, "staff_id", principalFrom(r).StaffID)
	}
	writeResult(w, map[string]any{"customer": out}, err)
}

func (s *Server) updateSambaCustomer(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	var payload posapp.UpdateSambaCustomerRequest
	if err := readJSON(w, r, s.cfg.MaxRequestBytes, &payload); err != nil {
		writeError(w, shareddomain.ValidationError(map[string]string{"body": "expected JSON request body"}))
		return
	}
	out, err := runtime.Customers.Update(r.Context(), r.PathValue("id"), payload)
	if err == nil {
		s.logger.Info("samba_customer_updated", "source", runtime.Key, "entity_id", out.ID, "staff_id", principalFrom(r).StaffID)
	}
	writeResult(w, map[string]any{"customer": out}, err)
}

func (s *Server) deleteSambaCustomer(w http.ResponseWriter, r *http.Request) {
	runtime, ok := s.sambaSource(w, r)
	if !ok {
		return
	}
	out, err := runtime.Customers.Delete(r.Context(), r.PathValue("id"))
	if err == nil {
		s.logger.Info("samba_customer_deleted", "source", runtime.Key, "entity_id", out.EntityID, "account_id", out.AccountID, "staff_id", principalFrom(r).StaffID)
	}
	writeResult(w, out, err)
}

// staffAuth accepts either the shared X-KP-API-Key or a Supabase access token
// (Authorization: Bearer) belonging to an active staff member, so the staff
// web app can call these routes without holding the shared secret.
func (s *Server) staffAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if secretEqual(r.Header.Get("X-KP-API-Key"), s.cfg.APISharedSecret) {
			next(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, servicePrincipal)))
			return
		}
		token, found := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		token = strings.TrimSpace(token)
		if !found || token == "" || s.staffAuthenticator == nil {
			writeError(w, shareddomain.Unauthorized())
			return
		}
		principal, err := s.staffTokens.resolve(r.Context(), token, s.staffAuthenticator)
		if err != nil {
			writeError(w, err)
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, principal)))
	}
}

func (s *Server) managerOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !principalFrom(r).IsManager() {
			writeError(w, shareddomain.Forbidden("A manager role is required."))
			return
		}
		next(w, r)
	}
}

func principalFrom(r *http.Request) shareddomain.StaffPrincipal {
	principal, _ := r.Context().Value(principalKey{}).(shareddomain.StaffPrincipal)
	return principal
}

const staffTokenTTL = time.Minute

// staffTokenCache avoids a Supabase round trip on every request. Entries live
// for a minute, so a deactivated staff member loses access within that window.
type staffTokenCache struct {
	mu      sync.Mutex
	entries map[string]staffTokenEntry
}

type staffTokenEntry struct {
	principal shareddomain.StaffPrincipal
	expires   time.Time
}

func (c *staffTokenCache) resolve(ctx context.Context, token string, auth StaffAuthenticator) (shareddomain.StaffPrincipal, error) {
	now := time.Now()
	c.mu.Lock()
	entry, ok := c.entries[token]
	c.mu.Unlock()
	if ok && now.Before(entry.expires) {
		return entry.principal, nil
	}

	principal, err := auth.StaffFromAccessToken(ctx, token)
	if err != nil {
		return shareddomain.StaffPrincipal{}, err
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = map[string]staffTokenEntry{}
	}
	if len(c.entries) > 1000 {
		for key, existing := range c.entries {
			if now.After(existing.expires) {
				delete(c.entries, key)
			}
		}
	}
	c.entries[token] = staffTokenEntry{principal: principal, expires: now.Add(staffTokenTTL)}
	return principal, nil
}
