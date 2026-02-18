package config

import (
	"fmt"
	"os"
	"strings"
)

// Config holds all configuration for the identity-portal service.
type Config struct {
	Port                 string   `json:"port"`
	OIDCIssuerURL        string   `json:"oidcIssuerUrl"`
	OIDCClientID         string   `json:"oidcClientId"`
	KeycloakURL          string   `json:"-"`
	KeycloakRealm        string   `json:"keycloakRealm"`
	KeycloakClientID     string   `json:"-"`
	KeycloakClientSecret string   `json:"-"`
	VaultAddr            string   `json:"-"`
	VaultSSHMount        string   `json:"-"`
	VaultAuthRole        string   `json:"-"`
	Domain               string   `json:"domain"`
	ClusterName          string   `json:"clusterName"`
	KubeAPIServer        string   `json:"-"`
	AdminGroups          []string `json:"-"`
	VaultRootCAPath      string   `json:"-"`
	CORSOrigin           string   `json:"-"`
}

// Load reads configuration from environment variables, applying defaults
// where appropriate, and validates that all required values are present.
func Load() (*Config, error) {
	cfg := &Config{
		Port:                 envOrDefault("PORT", "8080"),
		OIDCIssuerURL:        os.Getenv("OIDC_ISSUER_URL"),
		OIDCClientID:         os.Getenv("OIDC_CLIENT_ID"),
		KeycloakURL:          envOrDefault("KEYCLOAK_URL", "http://keycloak.keycloak.svc.cluster.local:8080"),
		KeycloakRealm:        envOrDefault("KEYCLOAK_REALM", "master"),
		KeycloakClientID:     envOrDefault("KEYCLOAK_CLIENT_ID", "identity-portal"),
		KeycloakClientSecret: os.Getenv("KEYCLOAK_CLIENT_SECRET"),
		VaultAddr:            os.Getenv("VAULT_ADDR"),
		VaultSSHMount:        envOrDefault("VAULT_SSH_MOUNT", "ssh-client-signer"),
		VaultAuthRole:        envOrDefault("VAULT_AUTH_ROLE", "identity-portal"),
		Domain:               os.Getenv("DOMAIN"),
		ClusterName:          os.Getenv("CLUSTER_NAME"),
		KubeAPIServer:        os.Getenv("KUBE_API_SERVER"),
		VaultRootCAPath:      envOrDefault("VAULT_ROOT_CA_PATH", "/etc/ssl/certs/vault-root-ca.pem"),
		CORSOrigin:           os.Getenv("CORS_ORIGIN"),
	}

	adminGroupsStr := envOrDefault("ADMIN_GROUPS", "platform-admins,infra-engineers")
	cfg.AdminGroups = splitAndTrim(adminGroupsStr)

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	// Derive CORS origin from domain if not explicitly set.
	if cfg.CORSOrigin == "" && cfg.Domain != "" {
		cfg.CORSOrigin = fmt.Sprintf("https://identity.%s", cfg.Domain)
	}

	return cfg, nil
}

func (c *Config) validate() error {
	required := map[string]string{
		"OIDC_ISSUER_URL":        c.OIDCIssuerURL,
		"OIDC_CLIENT_ID":         c.OIDCClientID,
		"KEYCLOAK_CLIENT_SECRET": c.KeycloakClientSecret,
		"VAULT_ADDR":             c.VaultAddr,
		"DOMAIN":                 c.Domain,
		"CLUSTER_NAME":           c.ClusterName,
		"KUBE_API_SERVER":        c.KubeAPIServer,
	}

	var missing []string
	for name, value := range required {
		if value == "" {
			missing = append(missing, name)
		}
	}

	if len(missing) > 0 {
		return fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}

	return nil
}

func envOrDefault(key, defaultValue string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultValue
}

func splitAndTrim(s string) []string {
	parts := strings.Split(s, ",")
	result := make([]string, 0, len(parts))
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}
