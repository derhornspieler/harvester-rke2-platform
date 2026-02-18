package vault

import (
	"fmt"
	"os"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
)

// ReadRootCACert reads the root CA certificate from the configured path.
func ReadRootCACert(cfg *config.Config) ([]byte, error) {
	data, err := os.ReadFile(cfg.VaultRootCAPath)
	if err != nil {
		return nil, fmt.Errorf("read root CA cert from %s: %w", cfg.VaultRootCAPath, err)
	}
	return data, nil
}
