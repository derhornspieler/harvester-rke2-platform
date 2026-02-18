package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

type claimsKey struct{}

// Claims holds the verified OIDC token claims extracted by the auth middleware.
type Claims struct {
	Subject           string   `json:"sub"`
	PreferredUsername string   `json:"preferred_username"`
	Email             string   `json:"email"`
	EmailVerified     bool     `json:"email_verified"`
	Groups            []string `json:"groups"`
	Name              string   `json:"name"`
}

// GetClaims extracts the authenticated claims from the request context.
func GetClaims(ctx context.Context) *Claims {
	if c, ok := ctx.Value(claimsKey{}).(*Claims); ok {
		return c
	}
	return nil
}

// OIDCAuth verifies the Bearer token against the OIDC issuer and extracts claims.
func OIDCAuth(logger *zap.Logger, issuerURL, clientID string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		// Initialize the OIDC provider lazily on first request to avoid blocking startup
		// if the issuer is temporarily unreachable.
		var (
			provider *oidc.Provider
			verifier *oidc.IDTokenVerifier
			initErr  error
		)

		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Lazy init the provider.
			if provider == nil {
				provider, initErr = oidc.NewProvider(r.Context(), issuerURL)
				if initErr != nil {
					logger.Error("failed to initialize OIDC provider",
						zap.Error(initErr),
						zap.String("issuer", issuerURL),
					)
					model.WriteError(w, http.StatusServiceUnavailable, "OIDC_UNAVAILABLE", "OIDC provider unavailable")
					// Reset so we retry next time.
					provider = nil
					return
				}
				verifier = provider.Verifier(&oidc.Config{ClientID: clientID})
			}

			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				model.WriteError(w, http.StatusUnauthorized, "MISSING_TOKEN", "authorization header required")
				return
			}

			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
				model.WriteError(w, http.StatusUnauthorized, "INVALID_TOKEN", "authorization header must be Bearer {token}")
				return
			}
			rawToken := parts[1]

			idToken, err := verifier.Verify(r.Context(), rawToken)
			if err != nil {
				logger.Debug("token verification failed",
					zap.Error(err),
					zap.String("request_id", GetRequestID(r.Context())),
				)
				model.WriteError(w, http.StatusUnauthorized, "INVALID_TOKEN", "token verification failed")
				return
			}

			var claims Claims
			if err := idToken.Claims(&claims); err != nil {
				logger.Error("failed to parse token claims",
					zap.Error(err),
					zap.String("request_id", GetRequestID(r.Context())),
				)
				model.WriteError(w, http.StatusUnauthorized, "INVALID_CLAIMS", "failed to parse token claims")
				return
			}

			logger.Debug("authenticated request",
				zap.String("sub", claims.Subject),
				zap.String("preferred_username", claims.PreferredUsername),
				zap.Strings("groups", claims.Groups),
				zap.String("request_id", GetRequestID(r.Context())),
			)

			ctx := context.WithValue(r.Context(), claimsKey{}, &claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
