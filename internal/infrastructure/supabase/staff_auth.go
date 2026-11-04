package supabase

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"

	shareddomain "github.com/hixmastudio/kamadeva-prive-backend/internal/shared/domain"
)

// StaffFromAccessToken verifies a Supabase user access token with Supabase
// Auth and returns the active staff profile behind it.
func (o *Operations) StaffFromAccessToken(ctx context.Context, accessToken string) (shareddomain.StaffPrincipal, error) {
	authURL := strings.TrimSuffix(o.baseURL, "/rest/v1") + "/auth/v1/user"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, authURL, nil)
	if err != nil {
		return shareddomain.StaffPrincipal{}, err
	}
	req.Header.Set("apikey", o.serviceKey)
	req.Header.Set("Authorization", "Bearer "+accessToken)
	res, err := o.client.Do(req)
	if err != nil {
		return shareddomain.StaffPrincipal{}, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusForbidden {
		return shareddomain.StaffPrincipal{}, shareddomain.Unauthorized()
	}
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return shareddomain.StaffPrincipal{}, shareddomain.UpstreamError("Supabase Auth user lookup failed", nil)
	}
	var user struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(res.Body).Decode(&user); err != nil || user.ID == "" {
		return shareddomain.StaffPrincipal{}, shareddomain.Unauthorized()
	}

	var profiles []struct {
		ID       string `json:"id"`
		FullName string `json:"full_name"`
		Role     string `json:"role"`
		IsActive bool   `json:"is_active"`
	}
	query := url.Values{
		"select":       {"id,full_name,role,is_active"},
		"auth_user_id": {"eq." + user.ID},
		"limit":        {"1"},
	}
	if err := o.selectRows(ctx, "/staff_profiles", query, &profiles); err != nil {
		return shareddomain.StaffPrincipal{}, err
	}
	if len(profiles) == 0 || !profiles[0].IsActive {
		return shareddomain.StaffPrincipal{}, shareddomain.Forbidden("Staff access required.")
	}
	return shareddomain.StaffPrincipal{
		UserID:   user.ID,
		StaffID:  profiles[0].ID,
		FullName: profiles[0].FullName,
		Role:     profiles[0].Role,
	}, nil
}
