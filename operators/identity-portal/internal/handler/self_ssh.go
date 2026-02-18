package handler

import (
	"crypto/rsa"
	"fmt"
	"net/http"
	"strings"

	"go.uber.org/zap"
	"golang.org/x/crypto/ssh"

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
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "publicKey is required")
		return
	}

	// Reject excessively large keys (max 16 KB).
	if len(req.PublicKey) > 16384 {
		writeError(w, http.StatusBadRequest, "INVALID_KEY", "public key exceeds maximum size")
		return
	}

	// Validate SSH public key format using proper RFC 4253 parsing.
	parsedKey, _, _, _, parseErr := ssh.ParseAuthorizedKey([]byte(req.PublicKey))
	if parseErr != nil {
		writeError(w, http.StatusBadRequest, "INVALID_KEY", "invalid SSH public key format")
		return
	}

	// Only allow ed25519 (recommended) and RSA 4096+ (legacy).
	keyType := parsedKey.Type()
	if keyType != "ssh-ed25519" && keyType != "ssh-rsa" {
		writeError(w, http.StatusBadRequest, "UNSUPPORTED_KEY_TYPE",
			"only ed25519 (recommended) and RSA 4096+ keys are accepted")
		return
	}
	if keyType == "ssh-rsa" {
		if cryptoPub, ok := parsedKey.(ssh.CryptoPublicKey); ok {
			if rsaKey, ok := cryptoPub.CryptoPublicKey().(*rsa.PublicKey); ok {
				if rsaKey.N.BitLen() < 4096 {
					writeError(w, http.StatusBadRequest, "WEAK_KEY",
						fmt.Sprintf("RSA keys must be at least 4096 bits (yours is %d bits)", rsaKey.N.BitLen()))
					return
				}
			}
		}
	}

	// Verify the submitted public key matches the user's registered key.
	userID, resolveErr := h.resolveUserID(ctx, claims.PreferredUsername)
	if resolveErr == nil {
		registeredKey, _ := h.KC.GetUserAttribute(ctx, userID, "ssh_public_key")
		if registeredKey != "" {
			// Normalize both keys for comparison (strip comments and whitespace).
			submittedParsed, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(req.PublicKey))
			registeredParsed, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(registeredKey))
			if submittedParsed != nil && registeredParsed != nil {
				if string(submittedParsed.Marshal()) != string(registeredParsed.Marshal()) {
					writeError(w, http.StatusForbidden, "KEY_MISMATCH",
						"submitted public key does not match your registered SSH key")
					return
				}
			}
		}
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
