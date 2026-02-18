package keycloak

import (
	"context"
	"fmt"

	"github.com/Nerzal/gocloak/v13"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetRealmRoles returns all realm-level roles.
func (c *Client) GetRealmRoles(ctx context.Context) ([]model.Role, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	roles, err := c.gc.GetRealmRoles(ctx, token, c.cfg.KeycloakRealm, gocloak.GetRoleParams{})
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_realm_roles").Inc()
		return nil, fmt.Errorf("get realm roles: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_realm_roles", "success").Inc()

	result := make([]model.Role, 0, len(roles))
	for _, r := range roles {
		result = append(result, mapRole(r))
	}
	return result, nil
}

// GetRealmRole returns a single realm role by name.
func (c *Client) GetRealmRole(ctx context.Context, roleName string) (*model.Role, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	r, err := c.gc.GetRealmRole(ctx, token, c.cfg.KeycloakRealm, roleName)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_realm_role").Inc()
		return nil, fmt.Errorf("get realm role %s: %w", roleName, err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_realm_role", "success").Inc()

	role := mapRole(r)
	return &role, nil
}

// CreateRealmRole creates a new realm-level role.
func (c *Client) CreateRealmRole(ctx context.Context, name, description string) (string, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return "", err
	}

	role := gocloak.Role{
		Name:        gocloak.StringP(name),
		Description: gocloak.StringP(description),
	}

	roleID, err := c.gc.CreateRealmRole(ctx, token, c.cfg.KeycloakRealm, role)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("create_realm_role").Inc()
		return "", fmt.Errorf("create realm role: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("create_realm_role", "success").Inc()
	return roleID, nil
}

// UpdateRealmRole updates a realm role's description.
func (c *Client) UpdateRealmRole(ctx context.Context, roleName string, description string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	existing, err := c.gc.GetRealmRole(ctx, token, c.cfg.KeycloakRealm, roleName)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_realm_role").Inc()
		return fmt.Errorf("get role for update: %w", err)
	}

	existing.Description = gocloak.StringP(description)

	if err := c.gc.UpdateRealmRole(ctx, token, c.cfg.KeycloakRealm, roleName, *existing); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("update_realm_role").Inc()
		return fmt.Errorf("update realm role: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("update_realm_role", "success").Inc()
	return nil
}

// DeleteRealmRole removes a realm role by name.
func (c *Client) DeleteRealmRole(ctx context.Context, roleName string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.DeleteRealmRole(ctx, token, c.cfg.KeycloakRealm, roleName); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("delete_realm_role").Inc()
		return fmt.Errorf("delete realm role: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("delete_realm_role", "success").Inc()
	return nil
}

// AssignRealmRolesToUser assigns realm roles to a user.
func (c *Client) AssignRealmRolesToUser(ctx context.Context, userID string, roleNames []string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	roles := make([]gocloak.Role, 0, len(roleNames))
	for _, name := range roleNames {
		r, err := c.gc.GetRealmRole(ctx, token, c.cfg.KeycloakRealm, name)
		if err != nil {
			metrics.KeycloakErrorsTotal.WithLabelValues("get_realm_role").Inc()
			return fmt.Errorf("get role %s: %w", name, err)
		}
		roles = append(roles, *r)
	}

	if err := c.gc.AddRealmRoleToUser(ctx, token, c.cfg.KeycloakRealm, userID, roles); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("assign_roles").Inc()
		return fmt.Errorf("assign roles to user: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("assign_roles", "success").Inc()
	return nil
}

// UnassignRealmRolesFromUser removes realm roles from a user.
func (c *Client) UnassignRealmRolesFromUser(ctx context.Context, userID string, roleNames []string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	roles := make([]gocloak.Role, 0, len(roleNames))
	for _, name := range roleNames {
		r, err := c.gc.GetRealmRole(ctx, token, c.cfg.KeycloakRealm, name)
		if err != nil {
			metrics.KeycloakErrorsTotal.WithLabelValues("get_realm_role").Inc()
			return fmt.Errorf("get role %s: %w", name, err)
		}
		roles = append(roles, *r)
	}

	if err := c.gc.DeleteRealmRoleFromUser(ctx, token, c.cfg.KeycloakRealm, userID, roles); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("unassign_roles").Inc()
		return fmt.Errorf("unassign roles from user: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("unassign_roles", "success").Inc()
	return nil
}

// GetUserRealmRolesDetailed returns realm roles for a user with full details.
func (c *Client) GetUserRealmRolesDetailed(ctx context.Context, userID string) ([]model.Role, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	roles, err := c.gc.GetRealmRolesByUserID(ctx, token, c.cfg.KeycloakRealm, userID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_user_roles").Inc()
		return nil, fmt.Errorf("get user realm roles: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_user_roles", "success").Inc()

	result := make([]model.Role, 0, len(roles))
	for _, r := range roles {
		role := model.Role{}
		if r.ID != nil {
			role.ID = *r.ID
		}
		if r.Name != nil {
			role.Name = *r.Name
		}
		if r.Description != nil {
			role.Description = *r.Description
		}
		if r.Composite != nil {
			role.Composite = *r.Composite
		}
		if r.ClientRole != nil {
			role.ClientRole = *r.ClientRole
		}
		if r.ContainerID != nil {
			role.ContainerID = *r.ContainerID
		}
		result = append(result, role)
	}
	return result, nil
}

func mapRole(r *gocloak.Role) model.Role {
	role := model.Role{
		Composite: derefBool(r.Composite),
	}
	if r.ID != nil {
		role.ID = *r.ID
	}
	if r.Name != nil {
		role.Name = *r.Name
	}
	if r.Description != nil {
		role.Description = *r.Description
	}
	if r.ClientRole != nil {
		role.ClientRole = *r.ClientRole
	}
	if r.ContainerID != nil {
		role.ContainerID = *r.ContainerID
	}
	return role
}
