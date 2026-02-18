package keycloak

import (
	"context"
	"fmt"

	"github.com/Nerzal/gocloak/v13"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetUsers returns a paginated list of users.
func (c *Client) GetUsers(ctx context.Context, first, max int, search string) ([]model.User, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	params := gocloak.GetUsersParams{
		First: gocloak.IntP(first),
		Max:   gocloak.IntP(max),
	}
	if search != "" {
		params.Search = gocloak.StringP(search)
	}

	users, err := c.gc.GetUsers(ctx, token, c.cfg.KeycloakRealm, params)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_users").Inc()
		return nil, fmt.Errorf("get users: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_users", "success").Inc()

	result := make([]model.User, 0, len(users))
	for _, u := range users {
		result = append(result, mapUser(u))
	}
	return result, nil
}

// GetUser returns a single user by ID.
func (c *Client) GetUser(ctx context.Context, userID string) (*model.User, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	u, err := c.gc.GetUserByID(ctx, token, c.cfg.KeycloakRealm, userID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_user").Inc()
		return nil, fmt.Errorf("get user %s: %w", userID, err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_user", "success").Inc()

	user := mapUser(u)
	return &user, nil
}

// CreateUser creates a new user and returns the ID.
func (c *Client) CreateUser(ctx context.Context, req model.CreateUserRequest) (string, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return "", err
	}

	user := gocloak.User{
		Username:  gocloak.StringP(req.Username),
		Email:     gocloak.StringP(req.Email),
		FirstName: gocloak.StringP(req.FirstName),
		LastName:  gocloak.StringP(req.LastName),
		Enabled:   gocloak.BoolP(req.Enabled),
	}

	userID, err := c.gc.CreateUser(ctx, token, c.cfg.KeycloakRealm, user)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("create_user").Inc()
		return "", fmt.Errorf("create user: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("create_user", "success").Inc()

	if req.Password != "" {
		if err := c.gc.SetPassword(ctx, token, userID, c.cfg.KeycloakRealm, req.Password, true); err != nil {
			metrics.KeycloakErrorsTotal.WithLabelValues("set_password").Inc()
			return userID, fmt.Errorf("set initial password: %w", err)
		}
		metrics.KeycloakRequestsTotal.WithLabelValues("set_password", "success").Inc()
	}

	return userID, nil
}

// UpdateUser updates an existing user.
func (c *Client) UpdateUser(ctx context.Context, userID string, req model.UpdateUserRequest) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	existing, err := c.gc.GetUserByID(ctx, token, c.cfg.KeycloakRealm, userID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_user").Inc()
		return fmt.Errorf("get user for update: %w", err)
	}

	if req.Email != nil {
		existing.Email = req.Email
	}
	if req.FirstName != nil {
		existing.FirstName = req.FirstName
	}
	if req.LastName != nil {
		existing.LastName = req.LastName
	}
	if req.Enabled != nil {
		existing.Enabled = req.Enabled
	}

	if err := c.gc.UpdateUser(ctx, token, c.cfg.KeycloakRealm, *existing); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("update_user").Inc()
		return fmt.Errorf("update user: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("update_user", "success").Inc()
	return nil
}

// DeleteUser removes a user by ID.
func (c *Client) DeleteUser(ctx context.Context, userID string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.DeleteUser(ctx, token, c.cfg.KeycloakRealm, userID); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("delete_user").Inc()
		return fmt.Errorf("delete user: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("delete_user", "success").Inc()
	return nil
}

// ResetPassword sets a new password for a user (admin action).
func (c *Client) ResetPassword(ctx context.Context, userID string, password string, temporary bool) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.SetPassword(ctx, token, userID, c.cfg.KeycloakRealm, password, temporary); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("reset_password").Inc()
		return fmt.Errorf("reset password: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("reset_password", "success").Inc()
	return nil
}

// GetUserGroups returns the groups a user belongs to.
func (c *Client) GetUserGroups(ctx context.Context, userID string) ([]string, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	groups, err := c.gc.GetUserGroups(ctx, token, c.cfg.KeycloakRealm, userID, gocloak.GetGroupsParams{})
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_user_groups").Inc()
		return nil, fmt.Errorf("get user groups: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_user_groups", "success").Inc()

	names := make([]string, 0, len(groups))
	for _, g := range groups {
		if g.Name != nil {
			names = append(names, *g.Name)
		}
	}
	return names, nil
}

// GetUserRealmRoles returns the realm-level role mappings for a user.
func (c *Client) GetUserRealmRoles(ctx context.Context, userID string) ([]string, error) {
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

	names := make([]string, 0, len(roles))
	for _, r := range roles {
		if r.Name != nil {
			names = append(names, *r.Name)
		}
	}
	return names, nil
}

// CountUsers returns the total number of users in the realm.
func (c *Client) CountUsers(ctx context.Context) (int, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return 0, err
	}

	count, err := c.gc.GetUserCount(ctx, token, c.cfg.KeycloakRealm, gocloak.GetUsersParams{})
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("count_users").Inc()
		return 0, fmt.Errorf("count users: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("count_users", "success").Inc()
	return count, nil
}

// GetCredentials returns the credential representations for a user.
func (c *Client) GetCredentials(ctx context.Context, userID string) ([]*gocloak.CredentialRepresentation, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	creds, err := c.gc.GetCredentials(ctx, token, c.cfg.KeycloakRealm, userID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_credentials").Inc()
		return nil, fmt.Errorf("get credentials: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_credentials", "success").Inc()
	return creds, nil
}

// mapUser converts a GoCloak user to our model.
func mapUser(u *gocloak.User) model.User {
	user := model.User{
		Enabled:       derefBool(u.Enabled),
		EmailVerified: derefBool(u.EmailVerified),
	}
	if u.ID != nil {
		user.ID = *u.ID
	}
	if u.Username != nil {
		user.Username = *u.Username
	}
	if u.Email != nil {
		user.Email = *u.Email
	}
	if u.FirstName != nil {
		user.FirstName = *u.FirstName
	}
	if u.LastName != nil {
		user.LastName = *u.LastName
	}
	if u.CreatedTimestamp != nil {
		user.CreatedAt = *u.CreatedTimestamp
	}
	if u.RequiredActions != nil {
		user.RequiredActions = *u.RequiredActions
	}
	if u.Attributes != nil {
		attrs := make(map[string]string)
		for k, v := range *u.Attributes {
			if len(v) > 0 {
				attrs[k] = v[0]
			}
		}
		user.Attributes = attrs
	}
	return user
}

func derefBool(b *bool) bool {
	if b == nil {
		return false
	}
	return *b
}
