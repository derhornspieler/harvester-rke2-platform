package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/handler"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/keycloak"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/server"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/vault"
)

func main() {
	// Initialize structured JSON logger.
	logCfg := zap.NewProductionConfig()
	logCfg.EncoderConfig.TimeKey = "timestamp"
	logCfg.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	logCfg.EncoderConfig.StacktraceKey = "stacktrace"

	logger, err := logCfg.Build()
	if err != nil {
		panic("failed to initialize logger: " + err.Error())
	}
	defer func() { _ = logger.Sync() }()

	logger.Info("starting identity-portal")

	// Load configuration.
	cfg, err := config.Load()
	if err != nil {
		logger.Fatal("failed to load configuration", zap.Error(err))
	}

	logger.Info("configuration loaded",
		zap.String("port", cfg.Port),
		zap.String("keycloak_url", cfg.KeycloakURL),
		zap.String("keycloak_realm", cfg.KeycloakRealm),
		zap.String("vault_addr", cfg.VaultAddr),
		zap.String("domain", cfg.Domain),
		zap.String("cluster_name", cfg.ClusterName),
		zap.Strings("admin_groups", cfg.AdminGroups),
	)

	// Initialize Keycloak client.
	kc, err := keycloak.NewClient(cfg, logger)
	if err != nil {
		logger.Fatal("failed to initialize keycloak client", zap.Error(err))
	}
	logger.Info("keycloak client initialized")

	// Initialize Vault client.
	vc, err := vault.NewClient(cfg, logger)
	if err != nil {
		logger.Fatal("failed to initialize vault client", zap.Error(err))
	}
	logger.Info("vault client initialized")

	// Create handlers.
	h := handler.NewHandler(cfg, kc, vc, logger)

	// Create and start the server.
	srv := server.New(cfg, h, kc, logger)

	// Graceful shutdown handling.
	shutdownCh := make(chan os.Signal, 1)
	signal.Notify(shutdownCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		if err := srv.Start(); err != nil {
			logger.Fatal("server failed", zap.Error(err))
		}
	}()

	// Wait for shutdown signal.
	sig := <-shutdownCh
	logger.Info("received shutdown signal", zap.String("signal", sig.String()))

	// Give outstanding requests up to 30 seconds to complete.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("server shutdown error", zap.Error(err))
	}

	logger.Info("identity-portal stopped")
}
