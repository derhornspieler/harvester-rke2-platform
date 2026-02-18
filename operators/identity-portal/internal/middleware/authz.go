package middleware

import (
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// RequireGroups returns middleware that checks the authenticated user belongs
// to at least one of the specified groups.
func RequireGroups(logger *zap.Logger, groups ...string) func(http.Handler) http.Handler {
	groupSet := make(map[string]struct{}, len(groups))
	for _, g := range groups {
		groupSet[g] = struct{}{}
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := GetClaims(r.Context())
			if claims == nil {
				model.WriteError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
				return
			}

			for _, userGroup := range claims.Groups {
				if _, ok := groupSet[userGroup]; ok {
					next.ServeHTTP(w, r)
					return
				}
			}

			logger.Warn("authorization denied",
				zap.String("username", claims.PreferredUsername),
				zap.Strings("user_groups", claims.Groups),
				zap.Any("required_groups", groups),
				zap.String("request_id", GetRequestID(r.Context())),
			)

			model.WriteError(w, http.StatusForbidden, "FORBIDDEN", "insufficient group membership")
		})
	}
}
