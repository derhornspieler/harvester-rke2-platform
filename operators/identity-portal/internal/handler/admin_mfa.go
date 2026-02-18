package handler

import (
	"net/http"
	"time"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetUserMFAStatus handles GET /api/v1/admin/users/{id}/mfa
func (h *Handler) GetUserMFAStatus(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	creds, err := h.KC.GetCredentials(ctx, userID)
	if err != nil {
		h.Logger.Error("failed to get MFA status", zap.Error(err), zap.String("user_id", userID),
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

// ResetUserMFA handles DELETE /api/v1/admin/users/{id}/mfa
// This removes all OTP/WebAuthn credentials, effectively resetting MFA.
func (h *Handler) ResetUserMFA(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
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
		h.Logger.Error("failed to get credentials for MFA reset", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get user credentials")
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

	h.Logger.Info("MFA reset",
		zap.String("user_id", userID),
		zap.Int("credentials_removed", removed),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":              "mfa_reset",
		"credentials_removed": removed,
	})
}
