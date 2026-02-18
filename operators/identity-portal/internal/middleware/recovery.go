package middleware

import (
	"net/http"
	"runtime/debug"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
)

// Recovery catches panics, logs the stack trace, and returns a 500 response.
func Recovery(logger *zap.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if err := recover(); err != nil {
					stack := string(debug.Stack())
					logger.Error("panic recovered",
						zap.Any("error", err),
						zap.String("stack", stack),
						zap.String("method", r.Method),
						zap.String("path", r.URL.Path),
						zap.String("request_id", GetRequestID(r.Context())),
					)
					model.WriteError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "internal server error")
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
