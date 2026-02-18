package handler

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/config"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/keycloak"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/model"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/vault"
)

// Handler holds shared dependencies injected into all route handlers.
type Handler struct {
	Config   *config.Config
	KC       *keycloak.Client
	Vault    *vault.Client
	Logger   *zap.Logger
}

// NewHandler creates a Handler with all dependencies.
func NewHandler(cfg *config.Config, kc *keycloak.Client, vc *vault.Client, logger *zap.Logger) *Handler {
	return &Handler{
		Config: cfg,
		KC:     kc,
		Vault:  vc,
		Logger: logger.Named("handler"),
	}
}

// decodeJSON reads and decodes a JSON request body into v.
func decodeJSON(r *http.Request, v any) error {
	defer func() { _ = r.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1 MB limit
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

// pathParam extracts a path parameter from the URL.
// For Go 1.22+ net/http.ServeMux, use r.PathValue(name).
func pathParam(r *http.Request, name string) string {
	return r.PathValue(name)
}

// queryInt reads an integer query parameter with a default.
func queryInt(r *http.Request, name string, defaultVal int) int {
	v := r.URL.Query().Get(name)
	if v == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return defaultVal
	}
	return n
}

// queryString reads a string query parameter with a default.
func queryString(r *http.Request, name string, defaultVal string) string {
	v := r.URL.Query().Get(name)
	if v == "" {
		return defaultVal
	}
	return v
}

// writeJSON writes a JSON response with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	model.WriteJSON(w, status, v)
}

// writeError writes a JSON error response.
func writeError(w http.ResponseWriter, status int, code, message string) {
	model.WriteError(w, status, code, message)
}
