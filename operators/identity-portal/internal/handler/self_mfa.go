package handler

import (
	"net/http"
	"time"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetSelfMFAStatus handles GET /api/v1/self/mfa/status
// Returns the MFA enrollment status for the authenticated user.
func (h *Handler) GetSelfMFAStatus(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	// Find the user by username to get their Keycloak ID.
	users, err := h.KC.GetUsers(ctx, 0, 1, claims.PreferredUsername)
	if err != nil || len(users) == 0 {
		h.Logger.Error("failed to find user for MFA status", zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
		return
	}

	// Find the exact match.
	var userID string
	for _, u := range users {
		if u.Username == claims.PreferredUsername {
			userID = u.ID
			break
		}
	}
	if userID == "" {
		userID = users[0].ID
	}

	creds, err := h.KC.GetCredentials(ctx, userID)
	if err != nil {
		h.Logger.Error("failed to get credentials for MFA status", zap.Error(err),
			zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get MFA status")
		return
	}

	status := model.MFAStatus{
		Enrolled: false,
		Methods:  []string{},
	}

	for _, cred := range creds {
		if cred.Type != nil && (*cred.Type == "otp" || *cred.Type == "webauthn") {
			status.Enrolled = true
			status.Type = *cred.Type
			status.Methods = append(status.Methods, *cred.Type)
			if cred.CreatedDate != nil && status.ConfiguredAt == "" {
				t := time.UnixMilli(*cred.CreatedDate)
				status.ConfiguredAt = t.UTC().Format(time.RFC3339)
			}
		}
	}

	writeJSON(w, http.StatusOK, status)
}

// ResetSelfMFA handles DELETE /api/v1/self/mfa
// Allows users to reset their own MFA credentials.
func (h *Handler) ResetSelfMFA(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	// Find the user by username to get their Keycloak ID.
	users, err := h.KC.GetUsers(ctx, 0, 1, claims.PreferredUsername)
	if err != nil || len(users) == 0 {
		h.Logger.Error("failed to find user for MFA reset", zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
		return
	}

	var userID string
	for _, u := range users {
		if u.Username == claims.PreferredUsername {
			userID = u.ID
			break
		}
	}
	if userID == "" {
		userID = users[0].ID
	}

	token, err := h.KC.Token(ctx)
	if err != nil {
		h.Logger.Error("failed to get keycloak token", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to authenticate to keycloak")
		return
	}

	creds, err := h.KC.GetCredentials(ctx, userID)
	if err != nil {
		h.Logger.Error("failed to get credentials for self MFA reset", zap.Error(err),
			zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get credentials")
		return
	}

	removed := 0
	for _, cred := range creds {
		if cred.Type != nil && (*cred.Type == "otp" || *cred.Type == "webauthn") {
			if cred.ID != nil {
				if err := h.KC.GoCloak().DeleteCredentials(ctx, token, h.KC.Realm(), userID, *cred.ID); err != nil {
					h.Logger.Error("failed to delete credential", zap.Error(err),
						zap.String("user_id", userID), zap.String("credential_id", *cred.ID),
						zap.String("request_id", middleware.GetRequestID(ctx)))
					continue
				}
				removed++
			}
		}
	}

	h.Logger.Info("self-service MFA reset",
		zap.String("username", claims.PreferredUsername),
		zap.String("user_id", userID),
		zap.Int("credentials_removed", removed),
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":              "mfa_reset",
		"credentials_removed": removed,
	})
}
