package application

import (
	"context"
	"strings"
	"testing"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
)

type fakeMemberDirectory []posdomain.PriveMember

func (d fakeMemberDirectory) MembersForTill(context.Context) ([]posdomain.PriveMember, error) {
	return d, nil
}

func count(calls []string, call string) int {
	n := 0
	for _, c := range calls {
		if c == call {
			n++
		}
	}
	return n
}

func TestMemberSyncReconcilesTheTill(t *testing.T) {
	db := newFakeSambaDB()
	db.tables["Entities"] = []map[string]any{
		customerRow(10, "Ada Obi", "KP-000001", SambaMemberNotes),    // in sync
		customerRow(11, "Old Name", "KP-000002", SambaMemberNotes),   // renamed member
		customerRow(12, "Walk In", "", ""),                           // same phone as KP-000003: adopted
		customerRow(13, "Gone Guest", "KP-000009", SambaMemberNotes), // erased member: removed
		customerRow(14, "Typed By Hand", "KP-999999", ""),            // unknown number, not ours: kept
		customerRow(15, "Ghost", "KP-888888", SambaMemberNotes),      // unknown number, ours: removed
	}
	db.tables["EntityStateValues"] = []map[string]any{
		{"Id": float64(70), "EntityId": float64(13)},
		{"Id": float64(71), "EntityId": float64(15)},
	}
	members := fakeMemberDirectory{
		{MemberNo: "KP-000001", FullName: "Ada Obi", Phone: "+2348000000001", Status: "active"},
		{MemberNo: "KP-000002", FullName: "Chidi  Eze", Phone: "+2348000000002", Status: "active"},
		{MemberNo: "kp-000003", FullName: "Tolu Ade", Phone: "+2348031234567", Status: "active"},
		{MemberNo: "KP-000004", FullName: "New Member", Phone: "+2348099999999", Status: "active"},
		{MemberNo: "KP-000009", FullName: "Gone Guest", Phone: "+2348000000009", Status: "erased"},
	}
	index := NewSambaCustomerIndex(testCustomerService(db), 0)
	sync := NewSambaMemberSync(SambaMemberSyncConfig{SourceKey: "oso-lounge", MaxWrites: 50}, members, testCustomerService(db), index, nil)

	result, err := sync.Run(context.Background(), "test")
	if err != nil {
		t.Fatalf("Run error = %v", err)
	}
	if result.ActiveMembers != 4 || result.AlreadyInSync != 1 || result.Renamed != 1 || result.Linked != 1 || result.Created != 1 || result.Removed != 2 || result.UnknownMemberNo != 1 {
		t.Fatalf("result = %+v", result)
	}
	if got := db.inserted["Entities"]; got["Name"] != "New Member" || got["Notes"] != SambaMemberNotes || !strings.Contains(got["CustomData"].(string), `"KP-000004"`) {
		t.Fatalf("created entity = %#v", got)
	}
	if got := db.inserted["Accounts"]["Name"]; got != "New Member-08099999999" {
		t.Fatalf("account name = %v", got)
	}
	if n := count(db.calls, "DELETE Entities"); n != 2 {
		t.Fatalf("entity deletes = %d (%v)", n, db.calls)
	}
	if n := count(db.calls, "DELETE EntityStateValues"); n != 2 {
		t.Fatalf("state deletes = %d (%v)", n, db.calls)
	}
	if status := sync.Status(); status.LastResult == nil || status.LastError != nil {
		t.Fatalf("status = %+v", status)
	}
}

func TestMemberSyncRespectsTheWriteBudget(t *testing.T) {
	db := newFakeSambaDB()
	members := fakeMemberDirectory{
		{MemberNo: "KP-000001", FullName: "One", Phone: "+2348000000001", Status: "active"},
		{MemberNo: "KP-000002", FullName: "Two", Phone: "+2348000000002", Status: "active"},
		{MemberNo: "KP-000003", FullName: "Three", Phone: "+2348000000003", Status: "active"},
	}
	sync := NewSambaMemberSync(SambaMemberSyncConfig{MaxWrites: 2}, members, testCustomerService(db), nil, nil)
	result, err := sync.Run(context.Background(), "test")
	if err != nil {
		t.Fatalf("Run error = %v", err)
	}
	if result.Created != 2 || result.Deferred != 1 {
		t.Fatalf("result = %+v", result)
	}
}

func TestMemberSyncRefusesAnEmptyMemberList(t *testing.T) {
	db := newFakeSambaDB()
	db.tables["Entities"] = []map[string]any{customerRow(10, "Ada Obi", "KP-000001", SambaMemberNotes)}
	sync := NewSambaMemberSync(SambaMemberSyncConfig{}, fakeMemberDirectory{}, testCustomerService(db), nil, nil)
	if _, err := sync.Run(context.Background(), "test"); err == nil {
		t.Fatalf("expected an error for an empty member list")
	}
	if len(db.calls) != 0 {
		t.Fatalf("no till writes expected, got %v", db.calls)
	}
}

func TestTillPhone(t *testing.T) {
	for in, want := range map[string]string{"+2348031234567": "08031234567", "+447700900123": "447700900123"} {
		if got := tillPhone(in); got != want {
			t.Fatalf("tillPhone(%q) = %q, want %q", in, got, want)
		}
	}
	if phoneKey("+2348031234567") != phoneKey("08031234567") {
		t.Fatalf("phoneKey should match local and international forms")
	}
}
