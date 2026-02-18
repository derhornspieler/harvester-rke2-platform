package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// ListSSHRoles handles GET /api/v1/admin/vault/ssh/roles
func (h *Handler) ListSSHRoles(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	roles, err := h.Vault.ListSSHRoles(ctx)
	if err != nil {
		h.Logger.Error("failed to list SSH roles", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to list SSH roles")
		return
	}

	writeJSON(w, http.StatusOK, roles)
}

// GetSSHRole handles GET /api/v1/admin/vault/ssh/roles/{name}
func (h *Handler) GetSSHRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	role, err := h.Vault.GetSSHRole(ctx, roleName)
	if err != nil {
		h.Logger.Error("failed to get SSH role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "SSH_ROLE_NOT_FOUND", "SSH role not found")
		return
	}

	writeJSON(w, http.StatusOK, role)
}

// CreateSSHRole handles POST /api/v1/admin/vault/ssh/roles/{name}
func (h *Handler) CreateSSHRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	var req model.CreateSSHRoleRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if err := h.Vault.CreateSSHRole(ctx, roleName, req); err != nil {
		h.Logger.Error("failed to create SSH role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to create SSH role")
		return
	}

	h.Logger.Info("SSH role created",
		zap.String("role", roleName),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusCreated, map[string]string{"status": "created", "name": roleName})
}

// UpdateSSHRole handles PUT /api/v1/admin/vault/ssh/roles/{name}
func (h *Handler) UpdateSSHRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	var req model.CreateSSHRoleRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if err := h.Vault.CreateSSHRole(ctx, roleName, req); err != nil {
		h.Logger.Error("failed to update SSH role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to update SSH role")
		return
	}

	h.Logger.Info("SSH role updated",
		zap.String("role", roleName),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

// DeleteSSHRole handles DELETE /api/v1/admin/vault/ssh/roles/{name}
func (h *Handler) DeleteSSHRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	if err := h.Vault.DeleteSSHRole(ctx, roleName); err != nil {
		h.Logger.Error("failed to delete SSH role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to delete SSH role")
		return
	}

	h.Logger.Info("SSH role deleted",
		zap.String("role", roleName),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
