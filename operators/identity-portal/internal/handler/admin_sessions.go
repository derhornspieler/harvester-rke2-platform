package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
)

// GetUserSessions handles GET /api/v1/admin/users/{id}/sessions
func (h *Handler) GetUserSessions(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	sessions, err := h.KC.GetUserSessions(ctx, userID)
	if err != nil {
		h.Logger.Error("failed to get user sessions", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get user sessions")
		return
	}

	writeJSON(w, http.StatusOK, sessions)
}

// LogoutUser handles POST /api/v1/admin/users/{id}/logout
func (h *Handler) LogoutUser(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	if err := h.KC.LogoutUser(ctx, userID); err != nil {
		h.Logger.Error("failed to logout user", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to logout user")
		return
	}

	h.Logger.Info("user logged out",
		zap.String("user_id", userID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "logged_out"})
}
