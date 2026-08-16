package config

import (
	"bufio"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

type Config struct {
	Port                                string
	APISharedSecret                     string
	SambaWebhookSecret                  string
	SambaAPIURL                         string
	SambaAPIKey                         string
	SambaVenueID                        string
	SambaCacheDir                       string
	SambaOrchestratorEnabled            bool
	SambaOrchestratorInterval           time.Duration
	SambaOrchestratorLookback           int
	SambaOrchestratorOnStart            bool
	SambaDailyPullEnabled               bool
	SambaDailyPullTime                  string
	SambaDailyPullLookback              int
	SambaDailyPullOnStart               bool
	BoomBoomRoomSambaAPIURL             string
	BoomBoomRoomSambaAPIKey             string
	BoomBoomRoomVenueID                 string
	BoomBoomRoomOrchestratorEnabled     bool
	BoomBoomRoomOrchestratorInterval    time.Duration
	BoomBoomRoomOrchestratorLookback    int
	BoomBoomRoomOrchestratorOnStart     bool
	WhatsAppAccessToken                 string
	WhatsAppPhoneNumberID               string
	WhatsAppVerifyToken                 string
	WhatsAppAppSecret                   string
	WhatsAppAPIVersion                  string
	WhatsAppBookingConfirmationTemplate string
	WhatsAppWorkerEnabled               bool
	WhatsAppWorkerInterval              time.Duration
	AIProvider                          string
	OpenAIAPIKey                        string
	OpenAIModel                         string
	OpenAIHTTPTimeout                   time.Duration
	SupabaseURL                         string
	SupabaseServiceRoleKey              string
	MaxRequestBytes                     int64
	ShutdownTimeout                     time.Duration
	ReadHeaderTimeout                   time.Duration
	ReadTimeout                         time.Duration
	WriteTimeout                        time.Duration
	IdleTimeout                         time.Duration
	SupabaseHTTPTimeout                 time.Duration
	SambaHTTPTimeout                    time.Duration
}

func Load() (Config, error) {
	loadNearestDotEnv()

	cfg := Config{
		Port:                                valueOrDefault(os.Getenv("API_PORT"), "8787"),
		APISharedSecret:                     os.Getenv("API_SHARED_SECRET"),
		SambaWebhookSecret:                  os.Getenv("SAMBA_WEBHOOK_SECRET"),
		SambaAPIURL:                         os.Getenv("SAMBA_API_URL"),
		SambaAPIKey:                         os.Getenv("SAMBA_API_KEY"),
		SambaVenueID:                        os.Getenv("SAMBA_VENUE_ID"),
		SambaCacheDir:                       valueOrDefault(os.Getenv("SAMBA_CACHE_DIR"), "var/cache/samba"),
		SambaOrchestratorEnabled:            boolFromEnv("SAMBA_ORCHESTRATOR_ENABLED", false),
		SambaOrchestratorInterval:           durationFromEnv("SAMBA_ORCHESTRATOR_POLL_INTERVAL", 5*time.Minute),
		SambaOrchestratorLookback:           intFromEnv("SAMBA_ORCHESTRATOR_LOOKBACK_DAYS", 1),
		SambaOrchestratorOnStart:            boolFromEnv("SAMBA_ORCHESTRATOR_RUN_ON_START", false),
		SambaDailyPullEnabled:               boolFromEnv("SAMBA_DAILY_PULL_ENABLED", false),
		SambaDailyPullTime:                  valueOrDefault(os.Getenv("SAMBA_DAILY_PULL_TIME"), "03:15"),
		SambaDailyPullLookback:              intFromEnv("SAMBA_DAILY_PULL_LOOKBACK_DAYS", 1),
		SambaDailyPullOnStart:               boolFromEnv("SAMBA_DAILY_PULL_RUN_ON_START", false),
		BoomBoomRoomSambaAPIURL:             os.Getenv("BOOM_BOOM_ROOM_SAMBA_API_URL"),
		BoomBoomRoomSambaAPIKey:             os.Getenv("BOOM_BOOM_ROOM_SAMBA_API_KEY"),
		BoomBoomRoomVenueID:                 os.Getenv("BOOM_BOOM_ROOM_SAMBA_VENUE_ID"),
		BoomBoomRoomOrchestratorEnabled:     boolFromEnv("BOOM_BOOM_ROOM_ORCHESTRATOR_ENABLED", false),
		BoomBoomRoomOrchestratorInterval:    durationFromEnv("BOOM_BOOM_ROOM_ORCHESTRATOR_POLL_INTERVAL", 5*time.Minute),
		BoomBoomRoomOrchestratorLookback:    intFromEnv("BOOM_BOOM_ROOM_ORCHESTRATOR_LOOKBACK_DAYS", 1),
		BoomBoomRoomOrchestratorOnStart:     boolFromEnv("BOOM_BOOM_ROOM_ORCHESTRATOR_RUN_ON_START", false),
		WhatsAppAccessToken:                 os.Getenv("WHATSAPP_ACCESS_TOKEN"),
		WhatsAppPhoneNumberID:               os.Getenv("WHATSAPP_PHONE_NUMBER_ID"),
		WhatsAppVerifyToken:                 os.Getenv("WHATSAPP_VERIFY_TOKEN"),
		WhatsAppAppSecret:                   os.Getenv("WHATSAPP_APP_SECRET"),
		WhatsAppAPIVersion:                  valueOrDefault(os.Getenv("WHATSAPP_API_VERSION"), "v20.0"),
		WhatsAppBookingConfirmationTemplate: os.Getenv("WHATSAPP_BOOKING_CONFIRMATION_TEMPLATE"),
		WhatsAppWorkerEnabled:               boolFromEnv("WHATSAPP_WORKER_ENABLED", false),
		WhatsAppWorkerInterval:              durationFromEnv("WHATSAPP_WORKER_INTERVAL", 15*time.Second),
		AIProvider:                          valueOrDefault(os.Getenv("AI_PROVIDER"), "disabled"),
		OpenAIAPIKey:                        os.Getenv("OPENAI_API_KEY"),
		OpenAIModel:                         valueOrDefault(os.Getenv("OPENAI_MODEL"), "gpt-4.1-mini"),
		OpenAIHTTPTimeout:                   durationFromEnv("OPENAI_HTTP_TIMEOUT", 30*time.Second),
		SupabaseURL:                         os.Getenv("SUPABASE_URL"),
		SupabaseServiceRoleKey:              os.Getenv("SUPABASE_SERVICE_ROLE_KEY"),
		MaxRequestBytes:                     int64FromEnv("MAX_REQUEST_BYTES", 1<<20),
		ShutdownTimeout:                     durationFromEnv("SHUTDOWN_TIMEOUT", 10*time.Second),
		ReadHeaderTimeout:                   durationFromEnv("READ_HEADER_TIMEOUT", 5*time.Second),
		ReadTimeout:                         durationFromEnv("READ_TIMEOUT", 10*time.Second),
		WriteTimeout:                        durationFromEnv("WRITE_TIMEOUT", 20*time.Second),
		IdleTimeout:                         durationFromEnv("IDLE_TIMEOUT", 60*time.Second),
		SupabaseHTTPTimeout:                 durationFromEnv("SUPABASE_HTTP_TIMEOUT", 15*time.Second),
		SambaHTTPTimeout:                    durationFromEnv("SAMBA_HTTP_TIMEOUT", 90*time.Second),
	}

	if cfg.SupabaseURL == "" {
		return Config{}, errors.New("SUPABASE_URL is required")
	}
	if cfg.SupabaseServiceRoleKey == "" {
		return Config{}, errors.New("SUPABASE_SERVICE_ROLE_KEY is required")
	}
	if len(cfg.APISharedSecret) < 24 {
		return Config{}, errors.New("API_SHARED_SECRET must be at least 24 characters")
	}
	if cfg.SambaWebhookSecret != "" && len(cfg.SambaWebhookSecret) < 32 {
		return Config{}, errors.New("SAMBA_WEBHOOK_SECRET must be at least 32 characters when set")
	}
	if (cfg.SambaAPIURL == "") != (cfg.SambaAPIKey == "") {
		return Config{}, errors.New("SAMBA_API_URL and SAMBA_API_KEY must be configured together")
	}
	if cfg.SambaAPIURL != "" {
		if err := validateHTTPURL(cfg.SambaAPIURL); err != nil {
			return Config{}, err
		}
		if len(cfg.SambaAPIKey) < 24 {
			return Config{}, errors.New("SAMBA_API_KEY must be at least 24 characters when set")
		}
	}
	if cfg.SambaDailyPullEnabled {
		if !uuidPattern.MatchString(strings.TrimSpace(cfg.SambaVenueID)) {
			return Config{}, errors.New("SAMBA_VENUE_ID must be a UUID when SAMBA_DAILY_PULL_ENABLED is true")
		}
		if _, err := parseClockTime(cfg.SambaDailyPullTime); err != nil {
			return Config{}, errors.New("SAMBA_DAILY_PULL_TIME must be HH:MM")
		}
		if cfg.SambaDailyPullLookback < 1 || cfg.SambaDailyPullLookback > 92 {
			return Config{}, errors.New("SAMBA_DAILY_PULL_LOOKBACK_DAYS must be between 1 and 92")
		}
	}
	if cfg.SambaOrchestratorEnabled {
		if !uuidPattern.MatchString(strings.TrimSpace(cfg.SambaVenueID)) {
			return Config{}, errors.New("SAMBA_VENUE_ID must be a UUID when SAMBA_ORCHESTRATOR_ENABLED is true")
		}
		if cfg.SambaOrchestratorInterval < time.Minute {
			return Config{}, errors.New("SAMBA_ORCHESTRATOR_POLL_INTERVAL must be at least 1m")
		}
		if cfg.SambaOrchestratorLookback < 1 || cfg.SambaOrchestratorLookback > 92 {
			return Config{}, errors.New("SAMBA_ORCHESTRATOR_LOOKBACK_DAYS must be between 1 and 92")
		}
	}
	if (cfg.BoomBoomRoomSambaAPIURL == "") != (cfg.BoomBoomRoomSambaAPIKey == "") {
		return Config{}, errors.New("BOOM_BOOM_ROOM_SAMBA_API_URL and BOOM_BOOM_ROOM_SAMBA_API_KEY must be configured together")
	}
	if cfg.BoomBoomRoomSambaAPIURL != "" {
		if err := validateHTTPURL(cfg.BoomBoomRoomSambaAPIURL); err != nil {
			return Config{}, errors.New("BOOM_BOOM_ROOM_SAMBA_API_URL must be a valid absolute URL")
		}
		if len(cfg.BoomBoomRoomSambaAPIKey) < 24 {
			return Config{}, errors.New("BOOM_BOOM_ROOM_SAMBA_API_KEY must be at least 24 characters when set")
		}
	}
	if cfg.BoomBoomRoomOrchestratorEnabled {
		if !uuidPattern.MatchString(strings.TrimSpace(cfg.BoomBoomRoomVenueID)) {
			return Config{}, errors.New("BOOM_BOOM_ROOM_SAMBA_VENUE_ID must be a UUID when BOOM_BOOM_ROOM_ORCHESTRATOR_ENABLED is true")
		}
		if cfg.BoomBoomRoomOrchestratorInterval < time.Minute {
			return Config{}, errors.New("BOOM_BOOM_ROOM_ORCHESTRATOR_POLL_INTERVAL must be at least 1m")
		}
		if cfg.BoomBoomRoomOrchestratorLookback < 1 || cfg.BoomBoomRoomOrchestratorLookback > 92 {
			return Config{}, errors.New("BOOM_BOOM_ROOM_ORCHESTRATOR_LOOKBACK_DAYS must be between 1 and 92")
		}
	}
	if cfg.WhatsAppWorkerEnabled {
		if cfg.WhatsAppAccessToken == "" {
			return Config{}, errors.New("WHATSAPP_ACCESS_TOKEN is required when WHATSAPP_WORKER_ENABLED is true")
		}
		if cfg.WhatsAppPhoneNumberID == "" {
			return Config{}, errors.New("WHATSAPP_PHONE_NUMBER_ID is required when WHATSAPP_WORKER_ENABLED is true")
		}
	}
	if cfg.WhatsAppVerifyToken != "" && len(cfg.WhatsAppVerifyToken) < 16 {
		return Config{}, errors.New("WHATSAPP_VERIFY_TOKEN must be at least 16 characters when set")
	}
	if cfg.WhatsAppAppSecret != "" && len(cfg.WhatsAppAppSecret) < 16 {
		return Config{}, errors.New("WHATSAPP_APP_SECRET must be at least 16 characters when set")
	}
	if cfg.AIProvider == "openai" && cfg.OpenAIAPIKey == "" {
		return Config{}, errors.New("OPENAI_API_KEY is required when AI_PROVIDER=openai")
	}

	return cfg, nil
}

func loadNearestDotEnv() {
	dir, err := os.Getwd()
	if err != nil {
		loadDotEnv(".env")
		return
	}

	var paths []string
	for {
		paths = append(paths, filepath.Join(dir, ".env"))
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	for i := len(paths) - 1; i >= 0; i-- {
		loadDotEnv(paths[i])
	}
}

func loadDotEnv(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if key != "" && value != "" {
			_ = os.Setenv(key, value)
		}
	}
	return true
}

func valueOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func int64FromEnv(key string, fallback int64) int64 {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func intFromEnv(key string, fallback int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func boolFromEnv(key string, fallback bool) bool {
	raw := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if raw == "" {
		return fallback
	}
	return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
}

func durationFromEnv(key string, fallback time.Duration) time.Duration {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func validateHTTPURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return errors.New("SAMBA_API_URL must be a valid absolute URL")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return errors.New("SAMBA_API_URL must use http or https")
	}
	return nil
}

func parseClockTime(raw string) (time.Duration, error) {
	parsed, err := time.Parse("15:04", raw)
	if err != nil {
		return 0, err
	}
	return time.Duration(parsed.Hour())*time.Hour + time.Duration(parsed.Minute())*time.Minute, nil
}
