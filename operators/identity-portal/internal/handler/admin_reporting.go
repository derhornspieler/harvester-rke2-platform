package handler

import (
	"math"
	"net/http"
	"strings"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetDashboardStats handles GET /api/v1/admin/dashboard
func (h *Handler) GetDashboardStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	stats := model.DashboardStats{}

	// Count total users.
	totalUsers, err := h.KC.CountUsers(ctx)
	if err != nil {
		h.Logger.Error("failed to count users", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get dashboard stats")
		return
	}
	stats.TotalUsers = totalUsers

	// Get all users to compute enabled/disabled/MFA counts.
	// For large deployments, this should be optimized with Keycloak queries.
	users, err := h.KC.GetUsers(ctx, 0, totalUsers, "")
	if err != nil {
		h.Logger.Error("failed to get users for stats", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get dashboard stats")
		return
	}

	for _, u := range users {
		if u.Enabled {
			stats.ActiveUsers++
		}

		// Check MFA via credentials.
		creds, err := h.KC.GetCredentials(ctx, u.ID)
		if err == nil {
			for _, cred := range creds {
				if cred.Type != nil && (*cred.Type == "otp" || *cred.Type == "webauthn") {
					stats.MFAEnrolled++
					break
				}
			}
		}
	}

	if stats.TotalUsers > 0 {
		stats.MFAPercentage = math.Round(float64(stats.MFAEnrolled)/float64(stats.TotalUsers)*1000) / 10
	}

	// Approximate session count.
	sessionCount, err := h.KC.GetClientSessionCount(ctx)
	if err == nil {
		stats.ActiveSessions = sessionCount
	}

	writeJSON(w, http.StatusOK, stats)
}

// GetEvents handles GET /api/v1/admin/events
func (h *Handler) GetEvents(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	first := queryIntBounded(r, "first", 0, 10000)
	max := queryIntBounded(r, "max", 100, 500)
	userID := queryString(r, "user_id", "")
	typesStr := queryString(r, "types", "")

	var eventTypes []string
	if typesStr != "" {
		eventTypes = strings.Split(typesStr, ",")
	}

	events, err := h.KC.GetEvents(ctx, eventTypes, userID, first, max)
	if err != nil {
		h.Logger.Error("failed to get events", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get events")
		return
	}

	writeJSON(w, http.StatusOK, events)
}
