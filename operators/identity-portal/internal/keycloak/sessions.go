package keycloak

import (
	"context"
	"fmt"

	"github.com/Nerzal/gocloak/v13"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
)

// SessionInfo represents an active user session.
type SessionInfo struct {
	ID         string `json:"id"`
	UserID     string `json:"user_id"`
	Username   string `json:"username"`
	IPAddress  string `json:"ip_address"`
	Start      int64  `json:"start"`
	LastAccess int64  `json:"last_access"`
	ClientID   string `json:"client_id"`
}

// GetUserSessions returns active sessions for a given user.
func (c *Client) GetUserSessions(ctx context.Context, userID string) ([]SessionInfo, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	sessions, err := c.gc.GetUserSessions(ctx, token, c.cfg.KeycloakRealm, userID)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_user_sessions").Inc()
		return nil, fmt.Errorf("get user sessions: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_user_sessions", "success").Inc()

	result := make([]SessionInfo, 0, len(sessions))
	for _, s := range sessions {
		result = append(result, mapSession(s))
	}
	return result, nil
}

// LogoutUser terminates all sessions for a user.
func (c *Client) LogoutUser(ctx context.Context, userID string) error {
	token, err := c.Token(ctx)
	if err != nil {
		return err
	}

	if err := c.gc.LogoutAllSessions(ctx, token, c.cfg.KeycloakRealm, userID); err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("logout_user").Inc()
		return fmt.Errorf("logout user: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("logout_user", "success").Inc()
	return nil
}

// GetClientSessionCount returns the number of active sessions for all clients.
func (c *Client) GetClientSessionCount(ctx context.Context) (int, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return 0, err
	}

	// Fetch all clients to get their session counts.
	clients, err := c.gc.GetClients(ctx, token, c.cfg.KeycloakRealm, gocloak.GetClientsParams{})
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_clients").Inc()
		return 0, fmt.Errorf("get clients: %w", err)
	}

	totalSessions := 0
	for _, client := range clients {
		if client.ID == nil {
			continue
		}
		sessions, err := c.gc.GetUserSessions(ctx, token, c.cfg.KeycloakRealm, *client.ID)
		if err != nil {
			// Some clients may not support sessions; skip them.
			continue
		}
		totalSessions += len(sessions)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_session_count", "success").Inc()
	return totalSessions, nil
}

func mapSession(s *gocloak.UserSessionRepresentation) SessionInfo {
	info := SessionInfo{}
	if s.ID != nil {
		info.ID = *s.ID
	}
	if s.UserID != nil {
		info.UserID = *s.UserID
	}
	if s.Username != nil {
		info.Username = *s.Username
	}
	if s.IPAddress != nil {
		info.IPAddress = *s.IPAddress
	}
	if s.Start != nil {
		info.Start = *s.Start
	}
	if s.LastAccess != nil {
		info.LastAccess = *s.LastAccess
	}
	return info
}
