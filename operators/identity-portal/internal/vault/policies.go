package vault

import (
	"context"
	"fmt"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// ListPolicies returns all Vault ACL policy names.
func (c *Client) ListPolicies(ctx context.Context) ([]string, error) {
	if err := c.ensureAuthenticated(ctx); err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("list_policies").Inc()
		return nil, fmt.Errorf("vault auth for list policies: %w", err)
	}

	policies, err := c.client.Sys().ListPoliciesWithContext(ctx)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("list_policies").Inc()
		return nil, fmt.Errorf("list vault policies: %w", err)
	}

	metrics.VaultRequestsTotal.WithLabelValues("list_policies", "success").Inc()
	return policies, nil
}

// GetPolicy returns a single Vault policy by name.
func (c *Client) GetPolicy(ctx context.Context, name string) (*model.VaultPolicy, error) {
	if err := c.ensureAuthenticated(ctx); err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("get_policy").Inc()
		return nil, fmt.Errorf("vault auth for get policy: %w", err)
	}

	policy, err := c.client.Sys().GetPolicyWithContext(ctx, name)
	if err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("get_policy").Inc()
		return nil, fmt.Errorf("get vault policy %s: %w", name, err)
	}

	metrics.VaultRequestsTotal.WithLabelValues("get_policy", "success").Inc()
	return &model.VaultPolicy{
		Name:   name,
		Policy: policy,
	}, nil
}

// PutPolicy creates or updates a Vault ACL policy.
func (c *Client) PutPolicy(ctx context.Context, name, policy string) error {
	if err := c.ensureAuthenticated(ctx); err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("put_policy").Inc()
		return fmt.Errorf("vault auth for put policy: %w", err)
	}

	if err := c.client.Sys().PutPolicyWithContext(ctx, name, policy); err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("put_policy").Inc()
		return fmt.Errorf("put vault policy %s: %w", name, err)
	}

	metrics.VaultRequestsTotal.WithLabelValues("put_policy", "success").Inc()
	return nil
}

// DeletePolicy removes a Vault ACL policy.
func (c *Client) DeletePolicy(ctx context.Context, name string) error {
	if err := c.ensureAuthenticated(ctx); err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("delete_policy").Inc()
		return fmt.Errorf("vault auth for delete policy: %w", err)
	}

	if err := c.client.Sys().DeletePolicyWithContext(ctx, name); err != nil {
		metrics.VaultErrorsTotal.WithLabelValues("delete_policy").Inc()
		return fmt.Errorf("delete vault policy %s: %w", name, err)
	}

	metrics.VaultRequestsTotal.WithLabelValues("delete_policy", "success").Inc()
	return nil
}
