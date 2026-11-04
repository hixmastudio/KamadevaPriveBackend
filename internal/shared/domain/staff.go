package domain

// StaffPrincipal is an active Kamadeva staff member resolved from a Supabase
// access token.
type StaffPrincipal struct {
	UserID   string `json:"user_id"`
	StaffID  string `json:"staff_id"`
	FullName string `json:"full_name"`
	Role     string `json:"role"`
}

// IsManager reports whether the role may make destructive changes.
func (p StaffPrincipal) IsManager() bool {
	switch p.Role {
	case "founder", "hosl", "venue_manager":
		return true
	}
	return false
}
