package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// ListRoles handles GET /api/v1/admin/roles
func (h *Handler) ListRoles(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	roles, err := h.KC.GetRealmRoles(ctx)
	if err != nil {
		h.Logger.Error("failed to list roles", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to list roles")
		return
	}

	writeJSON(w, http.StatusOK, roles)
}

// GetRole handles GET /api/v1/admin/roles/{name}
func (h *Handler) GetRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	role, err := h.KC.GetRealmRole(ctx, roleName)
	if err != nil {
		h.Logger.Error("failed to get role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "ROLE_NOT_FOUND", "role not found")
		return
	}

	writeJSON(w, http.StatusOK, role)
}

// CreateRole handles POST /api/v1/admin/roles
func (h *Handler) CreateRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req model.CreateRoleRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "name is required")
		return
	}

	roleID, err := h.KC.CreateRealmRole(ctx, req.Name, req.Description)
	if err != nil {
		h.Logger.Error("failed to create role", zap.Error(err), zap.String("name", req.Name),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to create role")
		return
	}

	h.Logger.Info("role created",
		zap.String("role_id", roleID),
		zap.String("name", req.Name),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusCreated, map[string]string{"id": roleID, "name": req.Name})
}

// UpdateRole handles PUT /api/v1/admin/roles/{name}
func (h *Handler) UpdateRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	var req model.UpdateRoleRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Description == nil {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "description is required")
		return
	}

	if err := h.KC.UpdateRealmRole(ctx, roleName, *req.Description); err != nil {
		h.Logger.Error("failed to update role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to update role")
		return
	}

	h.Logger.Info("role updated",
		zap.String("role", roleName),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	w.WriteHeader(http.StatusNoContent)
}

// DeleteRole handles DELETE /api/v1/admin/roles/{name}
func (h *Handler) DeleteRole(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	roleName := pathParam(r, "name")

	if roleName == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "role name is required")
		return
	}

	if err := h.KC.DeleteRealmRole(ctx, roleName); err != nil {
		h.Logger.Error("failed to delete role", zap.Error(err), zap.String("role", roleName),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to delete role")
		return
	}

	h.Logger.Info("role deleted",
		zap.String("role", roleName),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	w.WriteHeader(http.StatusNoContent)
}
