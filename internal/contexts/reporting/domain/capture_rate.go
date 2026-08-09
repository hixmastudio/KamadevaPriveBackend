package domain

type CaptureRateRow struct {
	VenueID        string   `json:"venue_id"`
	VenueName      string   `json:"venue_name"`
	TotalEntries   int64    `json:"total_entries"`
	CapturedVisits int64    `json:"captured_visits"`
	CaptureRate    *float64 `json:"capture_rate"`
}

type CaptureRateReport struct {
	From   string           `json:"from"`
	To     string           `json:"to"`
	Venues []CaptureRateRow `json:"venues"`
}
