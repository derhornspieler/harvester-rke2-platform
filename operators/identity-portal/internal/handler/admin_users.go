package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// ListUsers handles GET /api/v1/admin/users
func (h *Handler) ListUsers(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	first := queryInt(r, "first", 0)
	max := queryInt(r, "max", 50)
	search := queryString(r, "search", "")

	users, err := h.KC.GetUsers(ctx, first, max, search)
	if err != nil {
		h.Logger.Error("failed to list users", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to list users")
		return
	}

	writeJSON(w, http.StatusOK, users)
}

// GetUser handles GET /api/v1/admin/users/{id}
func (h *Handler) GetUser(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	user, err := h.KC.GetUser(ctx, userID)
	if err != nil {
		h.Logger.Error("failed to get user", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
		return
	}

	// Enrich with groups and roles.
	groups, err := h.KC.GetUserGroups(ctx, userID)
	if err == nil {
		user.Groups = groups
	}

	roles, err := h.KC.GetUserRealmRoles(ctx, userID)
	if err == nil {
		user.RealmRoles = roles
	}

	// Check MFA status.
	creds, err := h.KC.GetCredentials(ctx, userID)
	if err == nil {
		for _, cred := range creds {
			if cred.Type != nil && *cred.Type == "otp" {
				user.MFAEnabled = true
				break
			}
		}
	}

	writeJSON(w, http.StatusOK, user)
}

// CreateUser handles POST /api/v1/admin/users
func (h *Handler) CreateUser(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req model.CreateUserRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Username == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "username is required")
		return
	}

	userID, err := h.KC.CreateUser(ctx, req)
	if err != nil {
		h.Logger.Error("failed to create user", zap.Error(err),
			zap.String("username", req.Username),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to create user")
		return
	}

	h.Logger.Info("user created",
		zap.String("user_id", userID),
		zap.String("username", req.Username),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusCreated, map[string]string{"id": userID})
}

// UpdateUser handles PUT /api/v1/admin/users/{id}
func (h *Handler) UpdateUser(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	var req model.UpdateUserRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if err := h.KC.UpdateUser(ctx, userID, req); err != nil {
		h.Logger.Error("failed to update user", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to update user")
		return
	}

	h.Logger.Info("user updated",
		zap.String("user_id", userID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

// DeleteUser handles DELETE /api/v1/admin/users/{id}
func (h *Handler) DeleteUser(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	if err := h.KC.DeleteUser(ctx, userID); err != nil {
		h.Logger.Error("failed to delete user", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to delete user")
		return
	}

	h.Logger.Info("user deleted",
		zap.String("user_id", userID),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// ResetUserPassword handles POST /api/v1/admin/users/{id}/reset-password
func (h *Handler) ResetUserPassword(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	var req model.ResetPasswordRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Password == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "password is required")
		return
	}

	if err := h.KC.ResetPassword(ctx, userID, req.Password, req.Temporary); err != nil {
		h.Logger.Error("failed to reset password", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to reset password")
		return
	}

	h.Logger.Info("password reset",
		zap.String("user_id", userID),
		zap.Bool("temporary", req.Temporary),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "password_reset"})
}

// AssignUserRoles handles POST /api/v1/admin/users/{id}/roles
func (h *Handler) AssignUserRoles(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	var req model.RoleAssignmentRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if len(req.RoleNames) == 0 {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "role_names is required")
		return
	}

	if err := h.KC.AssignRealmRolesToUser(ctx, userID, req.RoleNames); err != nil {
		h.Logger.Error("failed to assign roles", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to assign roles")
		return
	}

	h.Logger.Info("roles assigned",
		zap.String("user_id", userID),
		zap.Strings("roles", req.RoleNames),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "roles_assigned"})
}

// UnassignUserRoles handles DELETE /api/v1/admin/users/{id}/roles
func (h *Handler) UnassignUserRoles(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	userID := pathParam(r, "id")

	if userID == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "user id is required")
		return
	}

	var req model.RoleAssignmentRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if len(req.RoleNames) == 0 {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "role_names is required")
		return
	}

	if err := h.KC.UnassignRealmRolesFromUser(ctx, userID, req.RoleNames); err != nil {
		h.Logger.Error("failed to unassign roles", zap.Error(err), zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to unassign roles")
		return
	}

	h.Logger.Info("roles unassigned",
		zap.String("user_id", userID),
		zap.Strings("roles", req.RoleNames),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "roles_unassigned"})
}
