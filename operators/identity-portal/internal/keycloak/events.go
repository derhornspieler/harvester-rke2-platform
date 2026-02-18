package keycloak

import (
	"context"
	"fmt"

	"github.com/Nerzal/gocloak/v13"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
)

// EventInfo represents a Keycloak audit event.
type EventInfo struct {
	Time      int64             `json:"time"`
	Type      string            `json:"type"`
	RealmID   string            `json:"realm_id"`
	ClientID  string            `json:"client_id"`
	UserID    string            `json:"user_id"`
	IPAddress string            `json:"ip_address"`
	Details   map[string]string `json:"details,omitempty"`
}

// GetEvents returns realm events with optional filtering.
func (c *Client) GetEvents(ctx context.Context, eventTypes []string, userID string, first, max int) ([]EventInfo, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return nil, err
	}

	first32 := int32(first)
	max32 := int32(max)
	params := gocloak.GetEventsParams{
		First: &first32,
		Max:   &max32,
	}
	if len(eventTypes) > 0 {
		params.Type = eventTypes
	}
	if userID != "" {
		params.UserID = gocloak.StringP(userID)
	}

	events, err := c.gc.GetEvents(ctx, token, c.cfg.KeycloakRealm, params)
	if err != nil {
		metrics.KeycloakErrorsTotal.WithLabelValues("get_events").Inc()
		return nil, fmt.Errorf("get events: %w", err)
	}

	metrics.KeycloakRequestsTotal.WithLabelValues("get_events", "success").Inc()

	result := make([]EventInfo, 0, len(events))
	for _, e := range events {
		result = append(result, mapEvent(e))
	}
	return result, nil
}

func mapEvent(e *gocloak.EventRepresentation) EventInfo {
	info := EventInfo{}
	info.Time = e.Time
	if e.Type != nil {
		info.Type = *e.Type
	}
	if e.RealmID != nil {
		info.RealmID = *e.RealmID
	}
	if e.ClientID != nil {
		info.ClientID = *e.ClientID
	}
	if e.UserID != nil {
		info.UserID = *e.UserID
	}
	if e.IPAddress != nil {
		info.IPAddress = *e.IPAddress
	}
	if e.Details != nil {
		info.Details = make(map[string]string)
		for k, v := range e.Details {
			info.Details[k] = v
		}
	}
	return info
}
