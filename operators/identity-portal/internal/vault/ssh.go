package vault

import (
	"context"
	"fmt"
	"time"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// SSHRoleMapping defines the mapping from Keycloak group to Vault SSH role.
type SSHRoleMapping struct {
	VaultRole string
	TTL       string
}

// DefaultGroupRoleMappings returns the standard group-to-SSH-role mappings.
func DefaultGroupRoleMappings() map[string]SSHRoleMapping {
	return map[string]SSHRoleMapping{
		"platform-admins":   {VaultRole: "admin-role", TTL: "24h"},
		"infra-engineers":   {VaultRole: "infra-role", TTL: "8h"},
		"network-engineers": {VaultRole: "infra-role", TTL: "8h"},
		"developers":        {VaultRole: "developer-role", TTL: "4h"},
		"senior-developers": {VaultRole: "developer-role", TTL: "4h"},
	}
}

// ResolveSSHRole determines the Vault SSH role and TTL based on a user's groups.
// It picks the highest-privilege match (admin > infra > developer).
func ResolveSSHRole(groups []string) (*SSHRoleMapping, error) {
	mappings := DefaultGroupRoleMappings()

	// Priority order: admin-role > infra-role > developer-role
	priorityOrder := []string{
		"platform-admins",
		"infra-engineers",
		"network-engineers",
		"developers",
		"senior-developers",
	}

	for _, group := range priorityOrder {
		for _, userGroup := range groups {
			if userGroup == group {
				mapping := mappings[group]
				return &mapping, nil
			}
		}
	}

	return nil, fmt.Errorf("user has no groups mapped to an SSH signing role")
}

// SignSSHPublicKey signs an SSH public key using the appropriate Vault role.
func (c *Client) SignSSHPublicKey(ctx context.Context, publicKey string, username string, groups []string) (*model.SSHCertResponse, error) {
	roleMapping, err := ResolveSSHRole(groups)
	if err != nil {
		metrics.SSHCertErrorsTotal.WithLabelValues("unknown", "no_role_mapping").Inc()
		return nil, err
	}

	logical, err := c.Logical(ctx)
	if err != nil {
		metrics.SSHCertErrorsTotal.WithLabelValues(roleMapping.VaultRole, "auth_error").Inc()
		return nil, fmt.Errorf("vault auth for SSH signing: %w", err)
	}

	signPath := fmt.Sprintf("%s/sign/%s", c.cfg.VaultSSHMount, roleMapping.VaultRole)

	c.logger.Info("signing SSH public key",
		zap.String("username", username),
		zap.String("vault_role", roleMapping.VaultRole),
		zap.String("ttl", roleMapping.TTL),
		zap.String("path", signPath),
	)

	secret, err := logical.WriteWithContext(ctx, signPath, map[string]interface{}{
		"public_key":       publicKey,
		"valid_principals": username,
		"cert_type":        "user",
		"ttl":              roleMapping.TTL,
	})
	if err != nil {
		metrics.SSHCertErrorsTotal.WithLabelValues(roleMapping.VaultRole, "sign_error").Inc()
		metrics.VaultErrorsTotal.WithLabelValues("ssh_sign").Inc()
		return nil, fmt.Errorf("vault SSH sign: %w", err)
	}

	if secret == nil || secret.Data == nil {
		metrics.SSHCertErrorsTotal.WithLabelValues(roleMapping.VaultRole, "empty_response").Inc()
		metrics.VaultErrorsTotal.WithLabelValues("ssh_sign").Inc()
		return nil, fmt.Errorf("vault SSH sign returned empty response")
	}

	signedKey, ok := secret.Data["signed_key"].(string)
	if !ok || signedKey == "" {
		metrics.SSHCertErrorsTotal.WithLabelValues(roleMapping.VaultRole, "invalid_response").Inc()
		return nil, fmt.Errorf("vault SSH sign response missing signed_key")
	}

	now := time.Now()
	ttlDuration, _ := time.ParseDuration(roleMapping.TTL)

	metrics.SSHCertsIssuedTotal.WithLabelValues(roleMapping.VaultRole, username).Inc()
	metrics.VaultRequestsTotal.WithLabelValues("ssh_sign", "success").Inc()

	return &model.SSHCertResponse{
		SignedCertificate: signedKey,
		Principals:        []string{username},
		ValidAfter:        now.Unix(),
		ValidBefore:       now.Add(ttlDuration).Unix(),
		TTL:               roleMapping.TTL,
	}, nil
}

// GetSSHCAPublicKey retrieves the SSH CA public key from Vault.
func (c *Client) GetSSHCAPublicKey(ctx context.Context) (string, error) {
	logical, err := c.Logical(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("ssh_ca").Inc()
		return "", fmt.Errorf("vault auth for SSH CA: %w", err)
	}

	path := fmt.Sprintf("%s/config/ca", c.cfg.VaultSSHMount)
	secret, err := logical.ReadWithContext(ctx, path)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("ssh_ca").Inc()
		return "", fmt.Errorf("read SSH CA: %w", err)
	}

	if secret == nil || secret.Data == nil {
		metrics.VaultErrorsTotal.WithLabelValues("ssh_ca").Inc()
		return "", fmt.Errorf("SSH CA config not found")
	}

	publicKey, ok := secret.Data["public_key"].(string)
	if !ok || publicKey == "" {
		metrics.VaultErrorsTotal.WithLabelValues("ssh_ca").Inc()
		return "", fmt.Errorf("SSH CA public key not found in response")
	}

	metrics.VaultRequestsTotal.WithLabelValues("ssh_ca", "success").Inc()
	return publicKey, nil
}

// ListSSHRoles lists all SSH signing roles.
func (c *Client) ListSSHRoles(ctx context.Context) ([]string, error) {
	logical, err := c.Logical(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("list_ssh_roles").Inc()
		return nil, fmt.Errorf("vault auth for list SSH roles: %w", err)
	}

	path := fmt.Sprintf("%s/roles", c.cfg.VaultSSHMount)
	secret, err := logical.ListWithContext(ctx, path)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("list_ssh_roles").Inc()
		return nil, fmt.Errorf("list SSH roles: %w", err)
	}

	if secret == nil || secret.Data == nil {
		return []string{}, nil
	}

	keysRaw, ok := secret.Data["keys"].([]interface{})
	if !ok {
		return []string{}, nil
	}

	roles := make([]string, 0, len(keysRaw))
	for _, k := range keysRaw {
		if s, ok := k.(string); ok {
			roles = append(roles, s)
		}
	}

	metrics.VaultRequestsTotal.WithLabelValues("list_ssh_roles", "success").Inc()
	return roles, nil
}

// GetSSHRole reads the configuration for a specific SSH signing role.
func (c *Client) GetSSHRole(ctx context.Context, roleName string) (*model.SSHRoleConfig, error) {
	if err := ValidatePathSegment(roleName); err != nil {
		return nil, fmt.Errorf("invalid SSH role name: %w", err)
	}

	logical, err := c.Logical(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("get_ssh_role").Inc()
		return nil, fmt.Errorf("vault auth for get SSH role: %w", err)
	}

	path := fmt.Sprintf("%s/roles/%s", c.cfg.VaultSSHMount, roleName)
	secret, err := logical.ReadWithContext(ctx, path)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("get_ssh_role").Inc()
		return nil, fmt.Errorf("read SSH role %s: %w", roleName, err)
	}

	if secret == nil || secret.Data == nil {
		return nil, fmt.Errorf("SSH role %s not found", roleName)
	}

	role := &model.SSHRoleConfig{Name: roleName}
	if v, ok := secret.Data["default_user"].(string); ok {
		role.DefaultUser = v
	}
	if v, ok := secret.Data["allowed_users"].(string); ok {
		role.AllowedUsers = v
	}
	if v, ok := secret.Data["allowed_extensions"].(string); ok {
		role.AllowedExtensions = v
	}
	if v, ok := secret.Data["ttl"].(string); ok {
		role.TTL = v
	}
	if v, ok := secret.Data["max_ttl"].(string); ok {
		role.MaxTTL = v
	}
	if v, ok := secret.Data["key_type"].(string); ok {
		role.KeyType = v
	}
	if v, ok := secret.Data["algorithm_signer"].(string); ok {
		role.AlgorithmSigner = v
	}
	if v, ok := secret.Data["default_extensions"].(map[string]interface{}); ok {
		role.DefaultExtensions = make(map[string]string)
		for k, val := range v {
			if s, ok := val.(string); ok {
				role.DefaultExtensions[k] = s
			}
		}
	}

	metrics.VaultRequestsTotal.WithLabelValues("get_ssh_role", "success").Inc()
	return role, nil
}

// CreateSSHRole creates or updates an SSH signing role.
func (c *Client) CreateSSHRole(ctx context.Context, roleName string, req model.CreateSSHRoleRequest) error {
	if err := ValidatePathSegment(roleName); err != nil {
		return fmt.Errorf("invalid SSH role name: %w", err)
	}

	logical, err := c.Logical(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("create_ssh_role").Inc()
		return fmt.Errorf("vault auth for create SSH role: %w", err)
	}

	path := fmt.Sprintf("%s/roles/%s", c.cfg.VaultSSHMount, roleName)
	data := map[string]interface{}{
		"key_type":  "ca",
		"cert_type": "user",
	}
	if req.DefaultUser != "" {
		data["default_user"] = req.DefaultUser
	}
	if req.AllowedUsers != "" {
		data["allowed_users"] = req.AllowedUsers
	}
	if req.AllowedExtensions != "" {
		data["allowed_extensions"] = req.AllowedExtensions
	}
	if req.DefaultExtensions != nil {
		data["default_extensions"] = req.DefaultExtensions
	}
	if req.TTL != "" {
		data["ttl"] = req.TTL
	}
	if req.MaxTTL != "" {
		data["max_ttl"] = req.MaxTTL
	}

	_, err = logical.WriteWithContext(ctx, path, data)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("create_ssh_role").Inc()
		return fmt.Errorf("create SSH role %s: %w", roleName, err)
	}

	metrics.VaultRequestsTotal.WithLabelValues("create_ssh_role", "success").Inc()
	return nil
}

// DeleteSSHRole deletes an SSH signing role.
func (c *Client) DeleteSSHRole(ctx context.Context, roleName string) error {
	if err := ValidatePathSegment(roleName); err != nil {
		return fmt.Errorf("invalid SSH role name: %w", err)
	}

	logical, err := c.Logical(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("delete_ssh_role").Inc()
		return fmt.Errorf("vault auth for delete SSH role: %w", err)
	}

	path := fmt.Sprintf("%s/roles/%s", c.cfg.VaultSSHMount, roleName)
	_, err = logical.DeleteWithContext(ctx, path)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("delete_ssh_role").Inc()
		return fmt.Errorf("delete SSH role %s: %w", roleName, err)
	}

	metrics.VaultRequestsTotal.WithLabelValues("delete_ssh_role", "success").Inc()
	return nil
}
