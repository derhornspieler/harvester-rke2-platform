package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// GetSelfProfile handles GET /api/v1/self/profile
// Returns the authenticated user's profile from Keycloak, enriched with groups and roles.
func (h *Handler) GetSelfProfile(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	// Look up the user by username to get the Keycloak user ID.
	users, err := h.KC.GetUsers(ctx, 0, 1, claims.PreferredUsername)
	if err != nil || len(users) == 0 {
		h.Logger.Error("failed to find user profile", zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user profile not found")
		return
	}

	user := users[0]

	// Find the exact match.
	var matchedUser *model.User
	for i := range users {
		if users[i].Username == claims.PreferredUsername {
			matchedUser = &users[i]
			break
		}
	}
	if matchedUser == nil {
		matchedUser = &user
	}

	// Enrich with groups from Keycloak (authoritative, not just from token).
	groups, err := h.KC.GetUserGroups(ctx, matchedUser.ID)
	if err != nil {
		h.Logger.Warn("failed to get user groups for profile", zap.Error(err),
			zap.String("user_id", matchedUser.ID))
		// Fall back to groups from the OIDC token.
		groups = claims.Groups
	}

	// Get realm roles.
	roles, err := h.KC.GetUserRealmRoles(ctx, matchedUser.ID)
	if err != nil {
		h.Logger.Warn("failed to get user roles for profile", zap.Error(err),
			zap.String("user_id", matchedUser.ID))
		roles = []string{}
	}

	// Check MFA status.
	mfaEnabled := false
	creds, err := h.KC.GetCredentials(ctx, matchedUser.ID)
	if err == nil {
		for _, cred := range creds {
			if cred.Type != nil && (*cred.Type == "otp" || *cred.Type == "webauthn") {
				mfaEnabled = true
				break
			}
		}
	}

	profile := model.UserProfile{
		ID:            matchedUser.ID,
		Username:      matchedUser.Username,
		Email:         matchedUser.Email,
		FirstName:     matchedUser.FirstName,
		LastName:      matchedUser.LastName,
		EmailVerified: matchedUser.EmailVerified,
		Groups:        groups,
		RealmRoles:    roles,
		MFAEnabled:    mfaEnabled,
	}

	writeJSON(w, http.StatusOK, profile)
}

// GetPublicConfig handles GET /api/v1/config
// Returns public configuration needed by the frontend for OIDC login.
func (h *Handler) GetPublicConfig(w http.ResponseWriter, r *http.Request) {
	cfg := model.PublicConfig{
		KeycloakURL: h.Config.KeycloakURL,
		Realm:       h.Config.KeycloakRealm,
		ClientID:    h.Config.OIDCClientID,
		IssuerURL:   h.Config.OIDCIssuerURL,
	}

	writeJSON(w, http.StatusOK, cfg)
}
