package config

import (
	"bufio"
	"errors"
	"os"
	"strings"
)

type Config struct {
	Port                   string
	APISharedSecret        string
	SupabaseURL            string
	SupabaseServiceRoleKey string
}

func Load() (Config, error) {
	loadDotEnv(".env")

	cfg := Config{
		Port:                   valueOrDefault(os.Getenv("API_PORT"), "8787"),
		APISharedSecret:        os.Getenv("API_SHARED_SECRET"),
		SupabaseURL:            os.Getenv("SUPABASE_URL"),
		SupabaseServiceRoleKey: os.Getenv("SUPABASE_SERVICE_ROLE_KEY"),
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

	return cfg, nil
}

func loadDotEnv(path string) {
	file, err := os.Open(path)
	if err != nil {
		return
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
		if key != "" && os.Getenv(key) == "" {
			_ = os.Setenv(key, value)
		}
	}
}

func valueOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
