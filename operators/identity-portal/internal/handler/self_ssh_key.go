package handler

import (
	"context"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/http"
	"time"

	"go.uber.org/zap"
	"golang.org/x/crypto/ssh"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

const (
	attrSSHPublicKey     = "ssh_public_key"
	attrSSHKeyRegistered = "ssh_key_registered_at"
)

// GetSelfSSHPublicKey handles GET /api/v1/self/ssh/public-key
// Returns the user's registered SSH public key.
func (h *Handler) GetSelfSSHPublicKey(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	userID, err := h.resolveUserID(ctx, claims.PreferredUsername)
	if err != nil {
		h.Logger.Error("failed to resolve user for SSH key lookup", zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
		return
	}

	pubKey, err := h.KC.GetUserAttribute(ctx, userID, attrSSHPublicKey)
	if err != nil {
		h.Logger.Error("failed to get SSH public key attribute", zap.Error(err),
			zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to get SSH public key")
		return
	}

	if pubKey == "" {
		writeJSON(w, http.StatusOK, model.SSHPublicKeyResponse{})
		return
	}

	registeredAt, _ := h.KC.GetUserAttribute(ctx, userID, attrSSHKeyRegistered)
	fingerprint := sshFingerprint(pubKey)

	writeJSON(w, http.StatusOK, model.SSHPublicKeyResponse{
		PublicKey:    pubKey,
		Fingerprint:  fingerprint,
		RegisteredAt: registeredAt,
	})
}

// RegisterSelfSSHPublicKey handles PUT /api/v1/self/ssh/public-key
// Registers or updates the user's SSH public key.
func (h *Handler) RegisterSelfSSHPublicKey(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	var req model.SSHPublicKeyRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid request body")
		return
	}

	if req.PublicKey == "" {
		writeError(w, http.StatusBadRequest, "MISSING_FIELD", "publicKey is required")
		return
	}

	if len(req.PublicKey) > 16384 {
		writeError(w, http.StatusBadRequest, "INVALID_KEY", "public key exceeds maximum size")
		return
	}

	// Validate SSH public key format and type.
	pubKey, _, _, _, parseErr := ssh.ParseAuthorizedKey([]byte(req.PublicKey))
	if parseErr != nil {
		writeError(w, http.StatusBadRequest, "INVALID_KEY", "invalid SSH public key format")
		return
	}

	// Only allow ed25519 (recommended) and RSA 4096+ (legacy).
	keyType := pubKey.Type()
	switch keyType {
	case "ssh-ed25519":
		// Preferred — always allowed.
	case "ssh-rsa":
		// Legacy — only allow 4096-bit or larger.
		if cryptoPub, ok := pubKey.(ssh.CryptoPublicKey); ok {
			if rsaKey, ok := cryptoPub.CryptoPublicKey().(*rsa.PublicKey); ok {
				if rsaKey.N.BitLen() < 4096 {
					writeError(w, http.StatusBadRequest, "WEAK_KEY",
						fmt.Sprintf("RSA keys must be at least 4096 bits (yours is %d bits)", rsaKey.N.BitLen()))
					return
				}
			}
		}
	default:
		writeError(w, http.StatusBadRequest, "UNSUPPORTED_KEY_TYPE",
			"only ed25519 (recommended) and RSA 4096+ keys are accepted")
		return
	}

	userID, err := h.resolveUserID(ctx, claims.PreferredUsername)
	if err != nil {
		h.Logger.Error("failed to resolve user for SSH key registration", zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
		return
	}

	if err := h.KC.SetUserAttribute(ctx, userID, attrSSHPublicKey, req.PublicKey); err != nil {
		h.Logger.Error("failed to set SSH public key attribute", zap.Error(err),
			zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to register SSH public key")
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	_ = h.KC.SetUserAttribute(ctx, userID, attrSSHKeyRegistered, now)

	fingerprint := sshFingerprint(req.PublicKey)

	h.Logger.Info("SSH public key registered",
		zap.String("username", claims.PreferredUsername),
		zap.String("fingerprint", fingerprint),
		zap.String("request_id", middleware.GetRequestID(ctx)))

	writeJSON(w, http.StatusOK, model.SSHPublicKeyResponse{
		PublicKey:    req.PublicKey,
		Fingerprint:  fingerprint,
		RegisteredAt: now,
	})
}

// DeleteSelfSSHPublicKey handles DELETE /api/v1/self/ssh/public-key
// Removes the user's registered SSH public key.
func (h *Handler) DeleteSelfSSHPublicKey(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	userID, err := h.resolveUserID(ctx, claims.PreferredUsername)
	if err != nil {
		h.Logger.Error("failed to resolve user for SSH key deletion", zap.Error(err),
			zap.String("username", claims.PreferredUsername),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
		return
	}

	if err := h.KC.DeleteUserAttribute(ctx, userID, attrSSHPublicKey); err != nil {
		h.Logger.Error("failed to delete SSH public key attribute", zap.Error(err),
			zap.String("user_id", userID),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "KEYCLOAK_ERROR", "failed to delete SSH public key")
		return
	}
	_ = h.KC.DeleteUserAttribute(ctx, userID, attrSSHKeyRegistered)

	h.Logger.Info("SSH public key removed",
		zap.String("username", claims.PreferredUsername),
		zap.String("request_id", middleware.GetRequestID(ctx)))

	w.WriteHeader(http.StatusNoContent)
}

// resolveUserID finds the Keycloak user ID from a username.
func (h *Handler) resolveUserID(ctx context.Context, username string) (string, error) {
	users, err := h.KC.GetUsers(ctx, 0, 1, username)
	if err != nil || len(users) == 0 {
		return "", fmt.Errorf("user not found: %s", username)
	}

	for _, u := range users {
		if u.Username == username {
			return u.ID, nil
		}
	}
	return users[0].ID, nil
}

// sshFingerprint computes the SHA256 fingerprint of an SSH public key.
func sshFingerprint(pubKey string) string {
	parsed, _, _, _, err := ssh.ParseAuthorizedKey([]byte(pubKey))
	if err != nil {
		return ""
	}
	hash := sha256.Sum256(parsed.Marshal())
	return fmt.Sprintf("SHA256:%s", base64.RawStdEncoding.EncodeToString(hash[:]))
}
