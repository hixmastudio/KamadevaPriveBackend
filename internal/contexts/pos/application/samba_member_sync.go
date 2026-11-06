package application

import (
	"context"
	"log/slog"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

// SambaMemberNotes marks till customers the sync created, so a row whose member
// has vanished entirely can be told apart from one a cashier typed by hand.
const SambaMemberNotes = "Kamadeva Privé member"

var memberNoPattern = regexp.MustCompile(`^KP-\d+$`)

// IsMemberNo reports whether a till "Customer ID" has the shape of a member_no.
func IsMemberNo(value string) bool {
	return memberNoPattern.MatchString(strings.ToUpper(strings.TrimSpace(value)))
}

type SambaMemberSyncConfig struct {
	Enabled    bool
	SourceKey  string
	SourceName string
	Interval   time.Duration
	// MaxWrites caps till writes per run (a create is three calls but counts
	// once), so the first push of every member spreads over a few runs instead
	// of hammering the till in one go.
	MaxWrites  int
	RunOnStart bool
}

// SambaMemberSync keeps every active Privé member on one till as a POS
// customer named after them, with their member_no in "Customer ID". It is a
// reconciler rather than an event stream: each run compares the member list
// with the till and fixes the difference, so a missed run, a till outage or a
// cashier deleting a row all heal on the next pass.
type SambaMemberSync struct {
	cfg       SambaMemberSyncConfig
	members   posdomain.MemberDirectory
	customers SambaCustomerService
	index     *SambaCustomerIndex
	logger    *slog.Logger

	mu      sync.Mutex
	running bool
	status  SambaMemberSyncStatus
}

type SambaMemberSyncStatus struct {
	Enabled      bool                   `json:"enabled"`
	Running      bool                   `json:"running"`
	SourceKey    string                 `json:"source_key"`
	SourceName   string                 `json:"source_name"`
	Interval     string                 `json:"interval"`
	MaxWrites    int                    `json:"max_writes_per_run"`
	LastStarted  *time.Time             `json:"last_started_at,omitempty"`
	LastFinished *time.Time             `json:"last_finished_at,omitempty"`
	LastError    *string                `json:"last_error,omitempty"`
	LastResult   *SambaMemberSyncResult `json:"last_result,omitempty"`
	NextRun      *time.Time             `json:"next_run_at,omitempty"`
}

type SambaMemberSyncResult struct {
	ActiveMembers   int                      `json:"active_members"`
	TillCustomers   int                      `json:"till_customers"`
	AlreadyInSync   int                      `json:"already_in_sync"`
	Created         int                      `json:"created"`
	Linked          int                      `json:"linked"`
	Renamed         int                      `json:"renamed"`
	Removed         int                      `json:"removed"`
	Anonymised      int                      `json:"anonymised"`
	Deferred        int                      `json:"deferred"`
	Duplicates      int                      `json:"duplicates"`
	UnknownMemberNo int                      `json:"unknown_member_no"`
	Failures        []SambaMemberSyncFailure `json:"failures,omitempty"`
}

type SambaMemberSyncFailure struct {
	MemberNo string `json:"member_no"`
	Action   string `json:"action"`
	Error    string `json:"error"`
}

func NewSambaMemberSync(cfg SambaMemberSyncConfig, members posdomain.MemberDirectory, customers SambaCustomerService, index *SambaCustomerIndex, logger *slog.Logger) *SambaMemberSync {
	if logger == nil {
		logger = slog.Default()
	}
	if cfg.Interval <= 0 {
		cfg.Interval = 5 * time.Minute
	}
	if cfg.MaxWrites <= 0 {
		cfg.MaxWrites = 100
	}
	return &SambaMemberSync{
		cfg:       cfg,
		members:   members,
		customers: customers,
		index:     index,
		logger:    logger,
		status: SambaMemberSyncStatus{
			Enabled:    cfg.Enabled,
			SourceKey:  cfg.SourceKey,
			SourceName: cfg.SourceName,
			Interval:   cfg.Interval.String(),
			MaxWrites:  cfg.MaxWrites,
		},
	}
}

func (m *SambaMemberSync) Start(ctx context.Context) {
	if !m.cfg.Enabled {
		m.logger.Info("samba_member_sync_disabled", "source", m.cfg.SourceKey)
		return
	}
	m.logger.Info("samba_member_sync_started", "source", m.cfg.SourceKey, "interval", m.cfg.Interval.String(), "max_writes", m.cfg.MaxWrites)
	go m.loop(ctx)
}

func (m *SambaMemberSync) loop(ctx context.Context) {
	if m.cfg.RunOnStart {
		_, _ = m.Run(ctx, "startup")
	}
	ticker := time.NewTicker(m.cfg.Interval)
	defer ticker.Stop()
	m.setNextRun(time.Now().Add(m.cfg.Interval))
	for {
		select {
		case <-ctx.Done():
			return
		case at := <-ticker.C:
			m.setNextRun(at.Add(m.cfg.Interval))
			_, _ = m.Run(ctx, "poll")
		}
	}
}

func (m *SambaMemberSync) Status() SambaMemberSyncStatus {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.status
}

// Run performs one reconciliation pass.
func (m *SambaMemberSync) Run(ctx context.Context, trigger string) (SambaMemberSyncResult, error) {
	started := time.Now()
	if !m.begin(started) {
		return SambaMemberSyncResult{}, shareddomain.ValidationError(map[string]string{"member_sync": "already running"})
	}
	result, err := m.reconcile(ctx)
	m.finish(result, err)
	if err != nil {
		m.logger.Error("samba_member_sync_failed", "source", m.cfg.SourceKey, "trigger", trigger, "duration_ms", time.Since(started).Milliseconds(), "error", err)
		return result, err
	}
	m.logger.Info("samba_member_sync_completed",
		"source", m.cfg.SourceKey,
		"trigger", trigger,
		"active_members", result.ActiveMembers,
		"till_customers", result.TillCustomers,
		"created", result.Created,
		"linked", result.Linked,
		"renamed", result.Renamed,
		"removed", result.Removed,
		"anonymised", result.Anonymised,
		"deferred", result.Deferred,
		"failed", len(result.Failures),
		"duration_ms", time.Since(started).Milliseconds(),
	)
	return result, nil
}

func (m *SambaMemberSync) reconcile(ctx context.Context) (SambaMemberSyncResult, error) {
	result := SambaMemberSyncResult{}
	if m.members == nil {
		return result, shareddomain.UpstreamError("Member directory is not configured.", nil)
	}
	members, err := m.members.MembersForTill(ctx)
	if err != nil {
		return result, err
	}
	byNo := map[string]posdomain.PriveMember{}
	active := []posdomain.PriveMember{}
	for _, member := range members {
		no := strings.ToUpper(strings.TrimSpace(member.MemberNo))
		if no == "" {
			continue
		}
		member.MemberNo = no
		byNo[no] = member
		if member.Status == "active" {
			active = append(active, member)
		}
	}
	result.ActiveMembers = len(active)
	// An empty member list is far more likely a broken query than a club with
	// no members, and acting on it would take everyone off the till.
	if len(active) == 0 {
		return result, shareddomain.UpstreamError("Member list came back empty; refusing to sync the till.", nil)
	}

	customers, err := m.customers.All(ctx)
	if err != nil {
		return result, err
	}
	result.TillCustomers = len(customers)
	if m.index != nil {
		m.index.Prime(customers)
	}

	byRef := map[string][]posdomain.SambaCustomer{}
	byPhone := map[string][]posdomain.SambaCustomer{}
	for _, customer := range customers {
		ref := strings.ToUpper(strings.TrimSpace(customer.CustomerID))
		switch {
		case IsMemberNo(ref):
			byRef[ref] = append(byRef[ref], customer)
		case ref == "":
			if key := phoneKey(customer.Phone); key != "" {
				byPhone[key] = append(byPhone[key], customer)
			}
		}
	}

	budget := m.cfg.MaxWrites
	wrote := false
	spend := func() bool {
		if budget <= 0 {
			result.Deferred++
			return false
		}
		budget--
		wrote = true
		return true
	}
	fail := func(no, action string, err error) {
		m.logger.Warn("samba_member_sync_write_failed", "source", m.cfg.SourceKey, "member_no", no, "action", action, "error", err)
		result.Failures = append(result.Failures, SambaMemberSyncFailure{MemberNo: no, Action: action, Error: err.Error()})
	}

	sort.Slice(active, func(i, j int) bool { return active[i].MemberNo < active[j].MemberNo })
	for _, member := range active {
		name := tillName(member)
		if rows := byRef[member.MemberNo]; len(rows) > 0 {
			if len(rows) > 1 {
				result.Duplicates += len(rows) - 1
			}
			current := rows[0]
			if current.Name == name {
				result.AlreadyInSync++
				continue
			}
			if !spend() {
				continue
			}
			if _, err := m.customers.update(ctx, current, UpdateSambaCustomerRequest{Name: &name}); err != nil {
				fail(member.MemberNo, "rename", err)
				continue
			}
			result.Renamed++
			continue
		}

		// A cashier may already have added this guest by hand. Adopt that row
		// rather than creating a second one, but only when exactly one
		// unlinked customer has the member's number.
		if rows := byPhone[phoneKey(member.Phone)]; len(rows) == 1 {
			if !spend() {
				continue
			}
			no := member.MemberNo
			if _, err := m.customers.update(ctx, rows[0], UpdateSambaCustomerRequest{Name: &name, CustomerID: &no}); err != nil {
				fail(member.MemberNo, "link", err)
				continue
			}
			delete(byPhone, phoneKey(member.Phone))
			result.Linked++
			continue
		}

		if !spend() {
			continue
		}
		no := member.MemberNo
		if _, err := m.customers.Create(ctx, CreateSambaCustomerRequest{
			Name:       name,
			Phone:      tillPhone(member.Phone),
			CustomerID: &no,
			Notes:      SambaMemberNotes,
		}); err != nil {
			fail(member.MemberNo, "create", err)
			continue
		}
		result.Created++
	}

	// Members who left (erased) come off the till. A member_no nobody holds is
	// removed only from rows this sync created; anything else was typed by a
	// person and is left for a person.
	var leaving []posdomain.SambaCustomer
	refs := make([]string, 0, len(byRef))
	for ref := range byRef {
		refs = append(refs, ref)
	}
	sort.Strings(refs)
	for _, ref := range refs {
		member, known := byNo[ref]
		for _, customer := range byRef[ref] {
			switch {
			case known && member.Status == "active":
			case known:
				leaving = append(leaving, customer)
			case strings.TrimSpace(customer.Notes) == SambaMemberNotes:
				leaving = append(leaving, customer)
			default:
				result.UnknownMemberNo++
			}
		}
	}
	if len(leaving) > 0 && budget > 0 {
		states, err := m.customers.entityStateIndex(ctx)
		if err != nil {
			return result, err
		}
		for _, customer := range leaving {
			if !spend() {
				continue
			}
			if _, err := m.customers.remove(ctx, customer, states[customer.ID]); err != nil {
				// Samba refuses to delete a customer that old tickets still
				// point at. Strip what identifies them instead, so the till no
				// longer carries a former member's name or number.
				if anonErr := m.anonymise(ctx, customer); anonErr != nil {
					fail(customer.CustomerID, "remove", err)
					continue
				}
				result.Anonymised++
				continue
			}
			result.Removed++
		}
	} else {
		result.Deferred += len(leaving)
	}

	if wrote && m.index != nil {
		m.index.Invalidate()
	}
	return result, nil
}

func (m *SambaMemberSync) anonymise(ctx context.Context, customer posdomain.SambaCustomer) error {
	name := "Former member"
	empty := ""
	_, err := m.customers.update(ctx, customer, UpdateSambaCustomerRequest{Name: &name, Phone: &empty, CustomerID: &empty, Notes: &empty})
	return err
}

func (m *SambaMemberSync) begin(started time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running {
		return false
	}
	m.running = true
	m.status.Running = true
	m.status.LastStarted = &started
	return true
}

func (m *SambaMemberSync) finish(result SambaMemberSyncResult, err error) {
	finished := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	m.running = false
	m.status.Running = false
	m.status.LastFinished = &finished
	m.status.LastResult = &result
	m.status.LastError = nil
	if err != nil {
		message := err.Error()
		m.status.LastError = &message
	}
}

func (m *SambaMemberSync) setNextRun(next time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.status.NextRun = &next
}

func tillName(member posdomain.PriveMember) string {
	name := strings.Join(strings.Fields(member.FullName), " ")
	if name == "" {
		return member.MemberNo
	}
	return name
}

// tillPhone writes a Nigerian number the way cashiers type it (0803…), which
// is also how the till's Name-Phone account names read.
func tillPhone(phone string) string {
	digits := digitsOnly(phone)
	if strings.HasPrefix(digits, "234") && len(digits) == 13 {
		return "0" + digits[3:]
	}
	if digits == "" {
		return strings.TrimSpace(phone)
	}
	return digits
}

// phoneKey compares numbers by their last ten digits, so +2348031234567 and
// 08031234567 are the same phone.
func phoneKey(phone string) string {
	digits := digitsOnly(phone)
	if len(digits) < 10 {
		return ""
	}
	return digits[len(digits)-10:]
}

// SambaCustomerIndex caches a till's customers by entity id, so ticket import
// can read the "Customer ID" behind a ticket's customer without scanning the
// whole Entities table for every ticket.
type SambaCustomerIndex struct {
	customers SambaCustomerService
	ttl       time.Duration
	now       func() time.Time

	mu      sync.Mutex
	byID    map[int64]posdomain.SambaCustomer
	fetched time.Time
}

func NewSambaCustomerIndex(customers SambaCustomerService, ttl time.Duration) *SambaCustomerIndex {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &SambaCustomerIndex{customers: customers, ttl: ttl, now: time.Now}
}

// Lookup returns the till customer with this entity id. An id the cache does
// not know triggers one refresh, since it is most likely a customer added
// since the last read.
func (i *SambaCustomerIndex) Lookup(ctx context.Context, entityID int64) (posdomain.SambaCustomer, bool, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	fresh := i.byID != nil && i.now().Sub(i.fetched) < i.ttl
	if fresh {
		if customer, ok := i.byID[entityID]; ok {
			return customer, true, nil
		}
		// Recently refreshed and still unknown: not a customer we can see.
		if i.now().Sub(i.fetched) < 30*time.Second {
			return posdomain.SambaCustomer{}, false, nil
		}
	}
	customers, err := i.customers.All(ctx)
	if err != nil {
		return posdomain.SambaCustomer{}, false, err
	}
	i.store(customers)
	customer, ok := i.byID[entityID]
	return customer, ok, nil
}

func (i *SambaCustomerIndex) Prime(customers []posdomain.SambaCustomer) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.store(customers)
}

func (i *SambaCustomerIndex) Invalidate() {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.byID = nil
}

func (i *SambaCustomerIndex) store(customers []posdomain.SambaCustomer) {
	i.byID = make(map[int64]posdomain.SambaCustomer, len(customers))
	for _, customer := range customers {
		i.byID[customer.ID] = customer
	}
	i.fetched = i.now()
}
