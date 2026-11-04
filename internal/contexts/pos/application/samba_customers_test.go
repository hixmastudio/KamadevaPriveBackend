package application

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	posdomain "github.com/hixmastudio/kamadeva-prive-backend/internal/contexts/pos/domain"
	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

type fakeSambaDB struct {
	tables   map[string][]map[string]any
	nextID   int64
	calls    []string
	failOn   string
	inserted map[string]map[string]any
	patched  map[string]map[string]any
}

func newFakeSambaDB() *fakeSambaDB {
	return &fakeSambaDB{
		tables:   map[string][]map[string]any{},
		nextID:   100,
		inserted: map[string]map[string]any{},
		patched:  map[string]map[string]any{},
	}
}

func (f *fakeSambaDB) ListTables(context.Context) (json.RawMessage, error) { return nil, nil }

func (f *fakeSambaDB) TableRows(_ context.Context, table string, page, pageSize int) (posdomain.SambaTablePage, error) {
	rows := f.tables[table]
	start := min((page-1)*pageSize, len(rows))
	end := min(start+pageSize, len(rows))
	return posdomain.SambaTablePage{Rows: rows[start:end], Total: len(rows), TotalPages: (len(rows) + pageSize - 1) / pageSize}, nil
}

func (f *fakeSambaDB) InsertRow(_ context.Context, table string, row map[string]any) (posdomain.SambaWriteResult, error) {
	f.calls = append(f.calls, "POST "+table)
	if f.failOn == "POST "+table {
		return posdomain.SambaWriteResult{}, shareddomain.UpstreamError("boom", nil)
	}
	f.nextID++
	f.inserted[table] = row
	return posdomain.SambaWriteResult{RowsAffected: 1, ID: f.nextID}, nil
}

func (f *fakeSambaDB) UpdateRow(_ context.Context, table string, id int64, fields map[string]any) (posdomain.SambaWriteResult, error) {
	f.calls = append(f.calls, "PATCH "+table)
	f.patched[table] = fields
	return posdomain.SambaWriteResult{RowsAffected: 1}, nil
}

func (f *fakeSambaDB) DeleteRow(_ context.Context, table string, id int64) (posdomain.SambaWriteResult, error) {
	f.calls = append(f.calls, "DELETE "+table)
	return posdomain.SambaWriteResult{RowsAffected: 1}, nil
}

func testCustomerService(db *fakeSambaDB) SambaCustomerService {
	svc := NewSambaCustomerService(db, nil)
	svc.now = func() time.Time { return time.Date(2026, 10, 23, 14, 40, 0, 0, time.UTC) }
	return svc
}

func TestCreateSambaCustomerFollowsPOSOrder(t *testing.T) {
	db := newFakeSambaDB()
	out, err := testCustomerService(db).Create(context.Background(), CreateSambaCustomerRequest{Name: " Alex ", Phone: "08012345678"})
	if err != nil {
		t.Fatalf("Create error = %v", err)
	}
	if got := strings.Join(db.calls, ","); got != "POST Accounts,POST Entities,POST EntityStateValues" {
		t.Fatalf("calls = %s", got)
	}
	if db.inserted["Accounts"]["Name"] != "Alex-08012345678" || db.inserted["Accounts"]["AccountTypeId"] != 5 {
		t.Fatalf("account = %#v", db.inserted["Accounts"])
	}
	entity := db.inserted["Entities"]
	if entity["AccountId"] != int64(101) || entity["EntityTypeId"] != 1 || entity["LastUpdateTime"] != "2026-10-23T15:40:00" {
		t.Fatalf("entity = %#v", entity)
	}
	if entity["CustomData"] != `[{"Name":"Phone","Value":"08012345678"}]` {
		t.Fatalf("custom data = %v", entity["CustomData"])
	}
	states := db.inserted["EntityStateValues"]
	if states["EntityId"] != int64(102) || states["EntityStates"] != `[{"D":"\/Date(1792766400000+0100)\/","S":"Available","SN":"Status"}]` {
		t.Fatalf("states = %#v", states)
	}
	if out.ID != 102 || out.AccountID != 101 || out.Phone != "08012345678" {
		t.Fatalf("customer = %#v", out)
	}
}

func TestCreateSambaCustomerRollsBackAccountWhenEntityFails(t *testing.T) {
	db := newFakeSambaDB()
	db.failOn = "POST Entities"
	if _, err := testCustomerService(db).Create(context.Background(), CreateSambaCustomerRequest{Name: "Alex", Phone: "080"}); err == nil {
		t.Fatal("expected error")
	}
	if got := strings.Join(db.calls, ","); got != "POST Accounts,POST Entities,DELETE Accounts" {
		t.Fatalf("calls = %s", got)
	}
}

func TestUpdateSambaCustomerKeepsOtherCustomFields(t *testing.T) {
	db := newFakeSambaDB()
	db.tables["Entities"] = []map[string]any{
		{"Id": float64(3445), "EntityTypeId": float64(1), "Name": "Alex", "AccountId": float64(2289),
			"CustomData": `[{"Name":"Phone","Value":"080"},{"Name":"Customer ID","Value":"4471"}]`},
	}
	phone := "081"
	out, err := testCustomerService(db).Update(context.Background(), "3445", UpdateSambaCustomerRequest{Phone: &phone})
	if err != nil {
		t.Fatalf("Update error = %v", err)
	}
	if db.patched["Entities"]["CustomData"] != `[{"Name":"Phone","Value":"081"},{"Name":"Customer ID","Value":"4471"}]` {
		t.Fatalf("patch = %#v", db.patched["Entities"])
	}
	if db.patched["Accounts"]["Name"] != "Alex-081" {
		t.Fatalf("account patch = %#v", db.patched["Accounts"])
	}
	if out.CustomerID != "4471" || out.Phone != "081" {
		t.Fatalf("customer = %#v", out)
	}
}

func TestDeleteSambaCustomerInReverseOrder(t *testing.T) {
	db := newFakeSambaDB()
	db.tables["Entities"] = []map[string]any{{"Id": float64(3445), "EntityTypeId": float64(1), "AccountId": float64(2289)}}
	db.tables["EntityStateValues"] = []map[string]any{{"Id": float64(9), "EntityId": float64(3445)}, {"Id": float64(8), "EntityId": float64(1)}}
	out, err := testCustomerService(db).Delete(context.Background(), "3445")
	if err != nil {
		t.Fatalf("Delete error = %v", err)
	}
	if got := strings.Join(db.calls, ","); got != "DELETE EntityStateValues,DELETE Entities,DELETE Accounts" {
		t.Fatalf("calls = %s", got)
	}
	if len(out.EntityStateValueID) != 1 || out.EntityStateValueID[0] != 9 || out.AccountID != 2289 {
		t.Fatalf("result = %#v", out)
	}
}

func TestListSambaCustomersFiltersTablesAndSearches(t *testing.T) {
	db := newFakeSambaDB()
	db.tables["Entities"] = []map[string]any{
		{"Id": float64(3), "EntityTypeId": float64(1), "Name": "Fortune", "CustomData": `[{"Name":"Phone","Value":"  08097654"}]`},
		{"Id": float64(2), "EntityTypeId": float64(2), "Name": "BR5"},
		{"Id": float64(1), "EntityTypeId": float64(1), "Name": "Kamsi", "CustomData": `[{"Name":"Phone","Value":"1"}]`},
	}
	svc := testCustomerService(db)
	all, err := svc.List(context.Background(), SambaCustomerListRequest{})
	if err != nil || all.Total != 2 {
		t.Fatalf("all = %#v, err = %v", all, err)
	}
	byPhone, _ := svc.List(context.Background(), SambaCustomerListRequest{Query: "0809 7654"})
	if byPhone.Total != 1 || byPhone.Customers[0].Name != "Fortune" || byPhone.Customers[0].Phone != "08097654" {
		t.Fatalf("byPhone = %#v", byPhone)
	}
	byName, _ := svc.List(context.Background(), SambaCustomerListRequest{Query: "kam"})
	if byName.Total != 1 || byName.Customers[0].ID != 1 {
		t.Fatalf("byName = %#v", byName)
	}
}
