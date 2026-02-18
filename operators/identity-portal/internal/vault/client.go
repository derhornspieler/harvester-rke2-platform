package vault

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	vaultapi "github.com/hashicorp/vault/api"
	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
)

// ValidatePathSegment ensures a Vault path segment doesn't contain traversal characters.
func ValidatePathSegment(s string) error {
	if s == "" || s == "." || s == ".." ||
		strings.Contains(s, "/") || strings.Contains(s, "\\") {
		return fmt.Errorf("invalid path segment: %q", s)
	}
	return nil
}

const (
	k8sSATokenPath      = "/var/run/secrets/kubernetes.io/serviceaccount/token" //nolint:gosec // Not a credential, it's a file path
	k8sAuthPath         = "auth/kubernetes/login"
	tokenRenewThreshold = 60 * time.Second
)

// Client wraps the Vault API client with automatic Kubernetes auth and renewal.
type Client struct {
	client      *vaultapi.Client
	cfg         *config.Config
	logger      *zap.Logger
	mu          sync.RWMutex
	secret      *vaultapi.Secret
	tokenExpiry time.Time
}

// NewClient creates a Vault client and authenticates via Kubernetes auth.
func NewClient(cfg *config.Config, logger *zap.Logger) (*Client, error) {
	vaultCfg := vaultapi.DefaultConfig()
	vaultCfg.Address = cfg.VaultAddr
	vaultCfg.Timeout = 30 * time.Second

	// Configure TLS with custom CA certificate for Vault's self-signed cert.
	if cfg.VaultRootCAPath != "" {
		tlsCfg := &vaultapi.TLSConfig{
			CACert: cfg.VaultRootCAPath,
		}
		if err := vaultCfg.ConfigureTLS(tlsCfg); err != nil {
			return nil, fmt.Errorf("configure vault TLS: %w", err)
		}
	}

	vc, err := vaultapi.NewClient(vaultCfg)
	if err != nil {
		return nil, fmt.Errorf("create vault client: %w", err)
	}

	c := &Client{
		client: vc,
		cfg:    cfg,
		logger: logger.Named("vault"),
	}

	if err := c.authenticate(context.Background()); err != nil {
		return nil, fmt.Errorf("initial vault auth: %w", err)
	}

	return c, nil
}

// authenticate performs Kubernetes auth against Vault.
func (c *Client) authenticate(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after acquiring lock.
	if c.secret != nil && time.Now().Before(c.tokenExpiry) {
		return nil
	}

	jwt, err := os.ReadFile(k8sSATokenPath)
	if err != nil {
		return fmt.Errorf("read service account token: %w", err)
	}

	c.logger.Debug("authenticating to vault via kubernetes auth",
		zap.String("role", c.cfg.VaultAuthRole),
	)

	secret, err := c.client.Logical().WriteWithContext(ctx, k8sAuthPath, map[string]interface{}{
		"role": c.cfg.VaultAuthRole,
		"jwt":  string(jwt),
	})
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("authenticate").Inc()
		return fmt.Errorf("vault kubernetes login: %w", err)
	}

	if secret == nil || secret.Auth == nil {
		metrics.VaultErrorsTotal.WithLabelValues("authenticate").Inc()
		return fmt.Errorf("vault kubernetes login returned nil auth")
	}

	c.client.SetToken(secret.Auth.ClientToken)
	c.secret = secret

	// Calculate expiry with a buffer.
	leaseDuration := time.Duration(secret.Auth.LeaseDuration) * time.Second
	c.tokenExpiry = time.Now().Add(leaseDuration - tokenRenewThreshold)

	metrics.VaultRequestsTotal.WithLabelValues("authenticate", "success").Inc()
	c.logger.Info("vault token acquired",
		zap.Duration("lease_duration", leaseDuration),
		zap.Time("expires", c.tokenExpiry),
	)

	return nil
}

// ensureAuthenticated checks the token and re-authenticates if needed.
func (c *Client) ensureAuthenticated(ctx context.Context) error {
	c.mu.RLock()
	valid := c.secret != nil && time.Now().Before(c.tokenExpiry)
	c.mu.RUnlock()

	if valid {
		return nil
	}

	return c.authenticate(ctx)
}

// Logical returns the Vault logical client after ensuring auth.
func (c *Client) Logical(ctx context.Context) (*vaultapi.Logical, error) {
	if err := c.ensureAuthenticated(ctx); err != nil {
		return nil, err
	}
	return c.client.Logical(), nil
}

// Healthy checks Vault connectivity by looking up the current token.
func (c *Client) Healthy(ctx context.Context) error {
	if err := c.ensureAuthenticated(ctx); err != nil {
		return fmt.Errorf("vault auth: %w", err)
	}

	secret, err := c.client.Auth().Token().LookupSelfWithContext(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("health_check").Inc()
		return fmt.Errorf("vault token lookup: %w", err)
	}
	if secret == nil {
		metrics.VaultErrorsTotal.WithLabelValues("health_check").Inc()
		return fmt.Errorf("vault token lookup returned nil")
	}

	metrics.VaultRequestsTotal.WithLabelValues("health_check", "success").Inc()
	return nil
}

// RawClient returns the underlying Vault API client. Use sparingly.
func (c *Client) RawClient() *vaultapi.Client {
	return c.client
}
