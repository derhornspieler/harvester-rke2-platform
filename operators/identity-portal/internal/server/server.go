package server

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/handler"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/keycloak"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
)

// Server encapsulates the HTTP server and its dependencies.
type Server struct {
	httpServer *http.Server
	cfg        *config.Config
	kc         *keycloak.Client
	logger     *zap.Logger
	cancelFunc context.CancelFunc
}

// New creates and configures a new Server.
func New(cfg *config.Config, h *handler.Handler, kc *keycloak.Client, logger *zap.Logger) *Server {
	router := NewRouter(cfg, h, logger)

	srv := &http.Server{
		Addr:              fmt.Sprintf(":%s", cfg.Port),
		Handler:           router,
		ReadTimeout:       15 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20, // 1 MB
	}

	return &Server{
		httpServer: srv,
		cfg:        cfg,
		kc:         kc,
		logger:     logger,
	}
}

// Start begins listening and starts the periodic metrics collector.
func (s *Server) Start() error {
	// Start periodic gauge collector for Keycloak stats.
	ctx, cancel := context.WithCancel(context.Background())
	s.cancelFunc = cancel
	go s.collectGaugeMetrics(ctx)

	s.logger.Info("starting identity-portal server",
		zap.String("addr", s.httpServer.Addr),
	)

	if err := s.httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("server listen: %w", err)
	}
	return nil
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	s.logger.Info("shutting down server")
	if s.cancelFunc != nil {
		s.cancelFunc()
	}
	return s.httpServer.Shutdown(ctx)
}

// collectGaugeMetrics periodically fetches user/session/MFA counts from Keycloak
// and updates the Prometheus gauges.
func (s *Server) collectGaugeMetrics(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	// Collect once immediately at startup.
	s.updateGauges(ctx)

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug("stopping gauge metrics collector")
			return
		case <-ticker.C:
			s.updateGauges(ctx)
		}
	}
}

func (s *Server) updateGauges(ctx context.Context) {
	s.logger.Debug("collecting gauge metrics from keycloak")

	// Total active (enabled) users.
	totalUsers, err := s.kc.CountUsers(ctx)
	if err != nil {
		s.logger.Warn("failed to count users for metrics", zap.Error(err))
	} else {
		metrics.ActiveUsersTotal.Set(float64(totalUsers))
	}

	// Count MFA-enrolled users by fetching all users and checking credentials.
	// For large deployments, consider caching or a more efficient approach.
	users, err := s.kc.GetUsers(ctx, 0, totalUsers, "")
	if err != nil {
		s.logger.Warn("failed to get users for MFA metrics", zap.Error(err))
	} else {
		mfaCount := 0
		for _, u := range users {
			creds, err := s.kc.GetCredentials(ctx, u.ID)
			if err != nil {
				continue
			}
			for _, cred := range creds {
				if cred.Type != nil && (*cred.Type == "otp" || *cred.Type == "webauthn") {
					mfaCount++
					break
				}
			}
		}
		metrics.MFAEnrolledUsersTotal.Set(float64(mfaCount))
	}

	// Active session count.
	sessionCount, err := s.kc.GetClientSessionCount(ctx)
	if err != nil {
		s.logger.Warn("failed to get session count for metrics", zap.Error(err))
	} else {
		metrics.ActiveSessionsTotal.Set(float64(sessionCount))
	}

	s.logger.Debug("gauge metrics updated",
		zap.Int("total_users", totalUsers),
	)
}
