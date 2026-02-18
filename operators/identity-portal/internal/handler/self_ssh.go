package handler

import (
	"net/http"
	"strings"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// RequestSSHCertificate handles POST /api/v1/self/ssh/certificate
// Signs an SSH public key via Vault based on the user's group membership.
func (h *Handler) RequestSSHCertificate(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	var req model.SSHCertRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.PublicKey == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "public_key is required")
		return
	}

	// Basic validation: SSH public keys start with a key type prefix.
	if !strings.HasPrefix(req.PublicKey, "ssh-") &&
		!strings.HasPrefix(req.PublicKey, "ecdsa-") &&
		!strings.HasPrefix(req.PublicKey, "sk-") {
		writeError(w, http.StatusBadRequest, "INVALID_KEY", "public_key must be a valid SSH public key")
		return
	}

	// Use groups from the OIDC token for role resolution.
	cert, err := h.Vault.SignSSHPublicKey(ctx, req.PublicKey, claims.PreferredUsername, claims.Groups)
	if err != nil {
		h.Logger.Error("SSH certificate signing failed",
			zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.Strings("groups", claims.Groups),
			zap.String("request_id", middleware.GetRequestID(ctx)),
		)

		if strings.Contains(err.Error(), "no groups mapped") {
			writeError(w, http.StatusForbidden, "NO_SSH_ROLE", "your group membership does not grant SSH certificate access")
			return
		}

		writeError(w, http.StatusInternalServerError, "SSH_SIGN_ERROR", "failed to sign SSH certificate")
		return
	}

	h.Logger.Info("SSH certificate issued",
		zap.String("username", claims.PreferredUsername),
		zap.Strings("principals", cert.Principals),
		zap.String("ttl", cert.TTL),
		zap.String("request_id", middleware.GetRequestID(ctx)),
	)

	writeJSON(w, http.StatusOK, cert)
}

// GetSSHCA handles GET /api/v1/self/ssh/ca
// Returns the SSH CA public key for client-side trust configuration.
func (h *Handler) GetSSHCA(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	publicKey, err := h.Vault.GetSSHCAPublicKey(ctx)
	if err != nil {
		h.Logger.Error("failed to get SSH CA public key", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "VAULT_ERROR", "failed to get SSH CA public key")
		return
	}

	writeJSON(w, http.StatusOK, model.SSHCAResponse{PublicKey: publicKey})
}
