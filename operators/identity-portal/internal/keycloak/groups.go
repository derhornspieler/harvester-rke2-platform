package keycloak

import (
	"context"
	"fmt"

	"github.com/Nerzal/gocloak/v13"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetGroups returns all realm groups.
func (c *Client) GetGroups(ctx context.Context) ([]model.Group, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	groups, err := c.gc.GetGroups(ctx, token, c.cfg.KeycloakRealm, gocloak.GetGroupsParams{})
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_groups").Inc()
		return nil, fmt.Errorf("get groups: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_groups", "success").Inc()

	result := make([]model.Group, 0, len(groups))
	for _, g := range groups {
		result = append(result, mapGroup(g))
	}
	return result, nil
}

// GetGroup returns a single group by ID.
func (c *Client) GetGroup(ctx context.Context, groupID string) (*model.Group, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	g, err := c.gc.GetGroup(ctx, token, c.cfg.KeycloakRealm, groupID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_group").Inc()
		return nil, fmt.Errorf("get group %s: %w", groupID, err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_group", "success").Inc()

	group := mapGroup(g)
	return &group, nil
}

// CreateGroup creates a new top-level group and returns the ID.
func (c *Client) CreateGroup(ctx context.Context, name string) (string, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return "", err
	}

	group := gocloak.Group{
		Name: gocloak.StringP(name),
	}

	groupID, err := c.gc.CreateGroup(ctx, token, c.cfg.KeycloakRealm, group)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("create_group").Inc()
		return "", fmt.Errorf("create group: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("create_group", "success").Inc()
	return groupID, nil
}

// UpdateGroup updates an existing group.
func (c *Client) UpdateGroup(ctx context.Context, groupID string, name string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	existing, err := c.gc.GetGroup(ctx, token, c.cfg.KeycloakRealm, groupID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_group").Inc()
		return fmt.Errorf("get group for update: %w", err)
	}

	existing.Name = gocloak.StringP(name)

	if err := c.gc.UpdateGroup(ctx, token, c.cfg.KeycloakRealm, *existing); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("update_group").Inc()
		return fmt.Errorf("update group: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("update_group", "success").Inc()
	return nil
}

// DeleteGroup removes a group by ID.
func (c *Client) DeleteGroup(ctx context.Context, groupID string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.DeleteGroup(ctx, token, c.cfg.KeycloakRealm, groupID); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("delete_group").Inc()
		return fmt.Errorf("delete group: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("delete_group", "success").Inc()
	return nil
}

// AddUserToGroup adds a user to a group.
func (c *Client) AddUserToGroup(ctx context.Context, userID, groupID string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.AddUserToGroup(ctx, token, c.cfg.KeycloakRealm, userID, groupID); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("add_user_to_group").Inc()
		return fmt.Errorf("add user to group: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("add_user_to_group", "success").Inc()
	return nil
}

// RemoveUserFromGroup removes a user from a group.
func (c *Client) RemoveUserFromGroup(ctx context.Context, userID, groupID string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.DeleteUserFromGroup(ctx, token, c.cfg.KeycloakRealm, userID, groupID); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("remove_user_from_group").Inc()
		return fmt.Errorf("remove user from group: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("remove_user_from_group", "success").Inc()
	return nil
}

// GetGroupMembers returns the user IDs that are members of a group.
func (c *Client) GetGroupMembers(ctx context.Context, groupID string) ([]model.User, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	members, err := c.gc.GetGroupMembers(ctx, token, c.cfg.KeycloakRealm, groupID, gocloak.GetGroupsParams{})
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_group_members").Inc()
		return nil, fmt.Errorf("get group members: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_group_members", "success").Inc()

	result := make([]model.User, 0, len(members))
	for _, u := range members {
		result = append(result, mapUser(u))
	}
	return result, nil
}

// GetUserGroupsDetailed returns the groups a user belongs to with full details.
func (c *Client) GetUserGroupsDetailed(ctx context.Context, userID string) ([]model.Group, error) {
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

	result := make([]model.Group, 0, len(groups))
	for _, g := range groups {
		result = append(result, mapGroup(g))
	}
	return result, nil
}

func mapGroup(g *gocloak.Group) model.Group {
	group := model.Group{}
	if g.ID != nil {
		group.ID = *g.ID
	}
	if g.Name != nil {
		group.Name = *g.Name
	}
	if g.Path != nil {
		group.Path = *g.Path
	}
	if g.SubGroups != nil {
		group.SubGroups = make([]model.Group, 0, len(*g.SubGroups))
		for _, sg := range *g.SubGroups {
			group.SubGroups = append(group.SubGroups, mapGroup(&sg))
		}
	}
	return group
}
