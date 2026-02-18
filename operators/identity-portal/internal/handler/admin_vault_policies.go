package handler

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// ListVaultPolicies handles GET /api/v1/admin/vault/policies
func (h *Handler) ListVaultPolicies(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	policies, err := h.Vault.ListPolicies(ctx)
	if err != nil {
		h.Logger.Error("failed to list vault policies", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to list vault policies")
		return
	}

	writeJSON(w, http.StatusOK, policies)
}

// GetVaultPolicy handles GET /api/v1/admin/vault/policies/{name}
func (h *Handler) GetVaultPolicy(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := pathParam(r, "name")

	if name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "policy name is required")
		return
	}

	policy, err := h.Vault.GetPolicy(ctx, name)
	if err != nil {
		h.Logger.Error("failed to get vault policy", zap.Error(err), zap.String("name", name),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "POLICY_NOT_FOUND", "vault policy not found")
		return
	}

	writeJSON(w, http.StatusOK, policy)
}

// CreateVaultPolicy handles POST /api/v1/admin/vault/policies
func (h *Handler) CreateVaultPolicy(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req model.CreateVaultPolicyRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "name is required")
		return
	}
	if req.Policy == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "policy is required")
		return
	}

	if err := h.Vault.PutPolicy(ctx, req.Name, req.Policy); err != nil {
		h.Logger.Error("failed to create vault policy", zap.Error(err), zap.String("name", req.Name),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to create vault policy")
		return
	}

	h.Logger.Info("vault policy created",
		zap.String("name", req.Name),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusCreated, map[string]string{"status": "created", "name": req.Name})
}

// UpdateVaultPolicy handles PUT /api/v1/admin/vault/policies/{name}
func (h *Handler) UpdateVaultPolicy(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := pathParam(r, "name")

	if name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "policy name is required")
		return
	}

	var req model.CreateVaultPolicyRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.Policy == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "policy is required")
		return
	}

	if err := h.Vault.PutPolicy(ctx, name, req.Policy); err != nil {
		h.Logger.Error("failed to update vault policy", zap.Error(err), zap.String("name", name),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to update vault policy")
		return
	}

	h.Logger.Info("vault policy updated",
		zap.String("name", name),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "updated"})
}

// DeleteVaultPolicy handles DELETE /api/v1/admin/vault/policies/{name}
func (h *Handler) DeleteVaultPolicy(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	name := pathParam(r, "name")

	if name == "" {
		writeError(w, http.StatusBadRequest, "MISSING_PARAM", "policy name is required")
		return
	}

	if err := h.Vault.DeletePolicy(ctx, name); err != nil {
		h.Logger.Error("failed to delete vault policy", zap.Error(err), zap.String("name", name),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to delete vault policy")
		return
	}

	h.Logger.Info("vault policy deleted",
		zap.String("name", name),
		zap.String("admin", middleware.GetClaims(ctx).PreferredUsername),
	)

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
