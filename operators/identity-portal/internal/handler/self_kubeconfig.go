package handler

import (
	"encoding/base64"
	"fmt"
	"net/http"

	"go.uber.org/zap"

	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/metrics"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/middleware"
	"github.com/derhornspieler/rke2-cluster/operators/identity-portal/internal/vault"
)

// GetKubeconfig handles GET /api/v1/self/kubeconfig
// Generates an OIDC-based kubeconfig using kubelogin as the exec credential plugin.
func (h *Handler) GetKubeconfig(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	claims := middleware.GetClaims(ctx)
	if claims == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHENTICATED", "authentication required")
		return
	}

	// Read the root CA cert.
	caCert, err := vault.ReadRootCACert(h.Config)
	if err != nil {
		h.Logger.Error("failed to read root CA cert", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "CA_ERROR", "failed to read cluster CA certificate")
		return
	}

	caBase64 := base64.StdEncoding.EncodeToString(caCert)

	kubeconfig := generateKubeconfig(
		h.Config.ClusterName,
		h.Config.KubeAPIServer,
		caBase64,
		h.Config.OIDCIssuerURL,
		h.Config.OIDCClientID,
		claims.PreferredUsername,
	)

	w.Header().Set("Content-Type", "application/x-yaml")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%s-kubeconfig.yaml", h.Config.ClusterName))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(kubeconfig)) //nolint:gosec // Not HTML output; YAML file download with Content-Disposition: attachment

	metrics.KubeconfigsGeneratedTotal.Inc()

	h.Logger.Info("kubeconfig generated",
		zap.String("username", claims.PreferredUsername),
		zap.String("cluster", h.Config.ClusterName),
		zap.String("request_id", middleware.GetRequestID(ctx)),
	)
}

// GetRootCA handles GET /api/v1/self/ca
// Returns the root CA PEM for clients that need to trust the cluster.
func (h *Handler) GetRootCA(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	caCert, err := vault.ReadRootCACert(h.Config)
	if err != nil {
		h.Logger.Error("failed to read root CA cert", zap.Error(err),
			zap.String("request_id", middleware.GetRequestID(ctx)))
		writeError(w, http.StatusInternalServerError, "CA_ERROR", "failed to read root CA certificate")
		return
	}

	w.Header().Set("Content-Type", "application/x-pem-file")
	w.Header().Set("Content-Disposition", "attachment; filename=root-ca.pem")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(caCert)
}

// generateKubeconfig creates a kubeconfig YAML string that uses kubelogin
// for OIDC-based authentication.
func generateKubeconfig(clusterName, apiServer, caBase64, issuerURL, clientID, username string) string {
	return fmt.Sprintf(`apiVersion: v1
kind: Config
preferences: {}
clusters:
- cluster:
    server: %s
    certificate-authority-data: %s
  name: %s
contexts:
- context:
    cluster: %s
    user: %s
  name: %s
current-context: %s
users:
- name: %s
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      args:
      - oidc-login
      - get-token
      - "--oidc-issuer-url=%s"
      - "--oidc-client-id=%s"
      - "--oidc-extra-scope=openid"
      - "--oidc-extra-scope=profile"
      - "--oidc-extra-scope=email"
      - "--oidc-extra-scope=groups"
      interactiveMode: IfAvailable
      provideClusterInfo: false
`,
		apiServer, caBase64, clusterName,
		clusterName, username, clusterName,
		clusterName,
		username,
		issuerURL, clientID,
	)
}
