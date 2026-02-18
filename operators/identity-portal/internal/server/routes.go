package server

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/handler"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
)

// NewRouter builds the complete HTTP handler with all routes and middleware.
func NewRouter(cfg *config.Config, h *handler.Handler, logger *zap.Logger) http.Handler {
	mux := http.NewServeMux()

	// --- Unauthenticated routes ---
	mux.HandleFunc("GET /healthz", h.Healthz)
	mux.HandleFunc("GET /readyz", h.Readyz)
	mux.Handle("GET /metrics", promhttp.Handler())

	// --- Public config (no auth needed, used by frontend) ---
	mux.HandleFunc("GET /api/v1/config", h.GetPublicConfig)

	// --- Self-service routes (require valid OIDC token) ---
	selfMux := http.NewServeMux()
	selfMux.HandleFunc("GET /api/v1/self/profile", h.GetSelfProfile)
	selfMux.HandleFunc("GET /api/v1/self/mfa/status", h.GetSelfMFAStatus)
	selfMux.HandleFunc("POST /api/v1/self/ssh/certificate", h.RequestSSHCertificate)
	selfMux.HandleFunc("GET /api/v1/self/ssh/ca", h.GetSSHCA)
	selfMux.HandleFunc("GET /api/v1/self/kubeconfig", h.GetKubeconfig)
	selfMux.HandleFunc("GET /api/v1/self/ca", h.GetRootCA)

	authMiddleware := middleware.OIDCAuth(logger, cfg.OIDCIssuerURL, cfg.OIDCClientID)
	mux.Handle("/api/v1/self/", authMiddleware(selfMux))

	// --- Admin routes (require valid OIDC token + admin group membership) ---
	adminMux := http.NewServeMux()

	// Users
	adminMux.HandleFunc("GET /api/v1/admin/users", h.ListUsers)
	adminMux.HandleFunc("POST /api/v1/admin/users", h.CreateUser)
	adminMux.HandleFunc("GET /api/v1/admin/users/{id}", h.GetUser)
	adminMux.HandleFunc("PUT /api/v1/admin/users/{id}", h.UpdateUser)
	adminMux.HandleFunc("DELETE /api/v1/admin/users/{id}", h.DeleteUser)
	adminMux.HandleFunc("POST /api/v1/admin/users/{id}/reset-password", h.ResetUserPassword)
	adminMux.HandleFunc("POST /api/v1/admin/users/{id}/roles", h.AssignUserRoles)
	adminMux.HandleFunc("DELETE /api/v1/admin/users/{id}/roles", h.UnassignUserRoles)

	// MFA
	adminMux.HandleFunc("GET /api/v1/admin/users/{id}/mfa", h.GetUserMFAStatus)
	adminMux.HandleFunc("DELETE /api/v1/admin/users/{id}/mfa", h.ResetUserMFA)

	// Sessions
	adminMux.HandleFunc("GET /api/v1/admin/users/{id}/sessions", h.GetUserSessions)
	adminMux.HandleFunc("POST /api/v1/admin/users/{id}/logout", h.LogoutUser)

	// Groups
	adminMux.HandleFunc("GET /api/v1/admin/groups", h.ListGroups)
	adminMux.HandleFunc("POST /api/v1/admin/groups", h.CreateGroup)
	adminMux.HandleFunc("GET /api/v1/admin/groups/{id}", h.GetGroup)
	adminMux.HandleFunc("PUT /api/v1/admin/groups/{id}", h.UpdateGroup)
	adminMux.HandleFunc("DELETE /api/v1/admin/groups/{id}", h.DeleteGroup)
	adminMux.HandleFunc("POST /api/v1/admin/groups/{id}/members", h.AddGroupMember)
	adminMux.HandleFunc("DELETE /api/v1/admin/groups/{id}/members/{userId}", h.RemoveGroupMember)

	// Roles
	adminMux.HandleFunc("GET /api/v1/admin/roles", h.ListRoles)
	adminMux.HandleFunc("POST /api/v1/admin/roles", h.CreateRole)
	adminMux.HandleFunc("GET /api/v1/admin/roles/{name}", h.GetRole)
	adminMux.HandleFunc("PUT /api/v1/admin/roles/{name}", h.UpdateRole)
	adminMux.HandleFunc("DELETE /api/v1/admin/roles/{name}", h.DeleteRole)

	// Vault Policies
	adminMux.HandleFunc("GET /api/v1/admin/vault/policies", h.ListVaultPolicies)
	adminMux.HandleFunc("POST /api/v1/admin/vault/policies", h.CreateVaultPolicy)
	adminMux.HandleFunc("GET /api/v1/admin/vault/policies/{name}", h.GetVaultPolicy)
	adminMux.HandleFunc("PUT /api/v1/admin/vault/policies/{name}", h.UpdateVaultPolicy)
	adminMux.HandleFunc("DELETE /api/v1/admin/vault/policies/{name}", h.DeleteVaultPolicy)

	// Vault SSH Roles
	adminMux.HandleFunc("GET /api/v1/admin/vault/ssh/roles", h.ListSSHRoles)
	adminMux.HandleFunc("GET /api/v1/admin/vault/ssh/roles/{name}", h.GetSSHRole)
	adminMux.HandleFunc("POST /api/v1/admin/vault/ssh/roles/{name}", h.CreateSSHRole)
	adminMux.HandleFunc("PUT /api/v1/admin/vault/ssh/roles/{name}", h.UpdateSSHRole)
	adminMux.HandleFunc("DELETE /api/v1/admin/vault/ssh/roles/{name}", h.DeleteSSHRole)

	// Reporting / Dashboard
	adminMux.HandleFunc("GET /api/v1/admin/dashboard", h.GetDashboardStats)
	adminMux.HandleFunc("GET /api/v1/admin/events", h.GetEvents)

	// Chain: OIDC auth -> require admin groups
	adminHandler := authMiddleware(
		middleware.RequireGroups(logger, cfg.AdminGroups...)(adminMux),
	)
	mux.Handle("/api/v1/admin/", adminHandler)

	// --- Apply global middleware (outermost first) ---
	var root http.Handler = mux
	root = cors(cfg.CORSOrigin)(root)
	root = middleware.Logging(logger)(root)
	root = middleware.Recovery(logger)(root)
	root = middleware.RequestID(root)

	return root
}

// cors adds CORS headers for the frontend.
func cors(origin string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Request-ID")
			w.Header().Set("Access-Control-Expose-Headers", "X-Request-ID")
			w.Header().Set("Access-Control-Max-Age", "3600")

			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
