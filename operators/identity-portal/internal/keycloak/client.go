package keycloak

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/Nerzal/gocloak/v13"
	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
)

// Client wraps GoCloak and manages service-account token lifecycle.
type Client struct {
	gc          *gocloak.GoCloak
	cfg         *config.Config
	logger      *zap.Logger
	mu          sync.RWMutex
	token       *gocloak.JWT
	tokenExpiry time.Time
}

// NewClient creates a new Keycloak client and performs an initial login.
func NewClient(cfg *config.Config, logger *zap.Logger) (*Client, error) {
	gc := gocloak.NewClient(cfg.KeycloakURL)

	c := &Client{
		gc:     gc,
		cfg:    cfg,
		logger: logger.Named("keycloak"),
	}

	if err := c.refreshToken(context.Background()); err != nil {
		return nil, fmt.Errorf("initial keycloak login: %w", err)
	}

	return c, nil
}

// Token returns a valid access token, refreshing if needed.
func (c *Client) Token(ctx context.Context) (string, error) {
	c.mu.RLock()
	if c.token != nil && time.Now().Before(c.tokenExpiry) {
		tok := c.token.AccessToken
		c.mu.RUnlock()
		return tok, nil
	}
	c.mu.RUnlock()

	if err := c.refreshToken(ctx); err != nil {
		return "", err
	}

	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.token.AccessToken, nil
}

func (c *Client) refreshToken(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after acquiring write lock.
	if c.token != nil && time.Now().Before(c.tokenExpiry) {
		return nil
	}

	c.logger.Debug("refreshing service account token",
		zap.String("client_id", c.cfg.KeycloakClientID),
		zap.String("realm", c.cfg.KeycloakRealm),
	)

	token, err := c.gc.LoginClient(ctx, c.cfg.KeycloakClientID, c.cfg.KeycloakClientSecret, c.cfg.KeycloakRealm)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("login").Inc()
		return fmt.Errorf("keycloak client login: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("login", "success").Inc()

	c.token = token
	// Set expiry with a 30-second buffer to avoid using a nearly-expired token.
	c.tokenExpiry = time.Now().Add(time.Duration(token.ExpiresIn-30) * time.Second)

	c.logger.Info("keycloak token refreshed", zap.Time("expires", c.tokenExpiry))
	return nil
}

// GoCloak returns the underlying GoCloak client for direct access.
func (c *Client) GoCloak() *gocloak.GoCloak {
	return c.gc
}

// Realm returns the configured realm name.
func (c *Client) Realm() string {
	return c.cfg.KeycloakRealm
}

// Healthy checks connectivity by fetching realm info.
func (c *Client) Healthy(ctx context.Context) error {
	token, err := c.Token(ctx)
	if err != nil {
		return fmt.Errorf("get token: %w", err)
	}

	_, err = c.gc.GetRealm(ctx, token, c.cfg.KeycloakRealm)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("health_check").Inc()
		return fmt.Errorf("get realm: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("health_check", "success").Inc()
	return nil
}
