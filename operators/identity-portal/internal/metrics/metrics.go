package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// HTTPRequestsTotal counts all HTTP requests by method, path, and status.
	HTTPRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_http_requests_total",
		Help: "Total number of HTTP requests",
	}, []string{"method", "path", "status"})

	// HTTPRequestDuration observes request latency by method and path.
	HTTPRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "identity_portal_http_request_duration_seconds",
		Help:    "HTTP request duration in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})

	// SSHCertsIssuedTotal counts successfully issued SSH certificates.
	SSHCertsIssuedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_ssh_certs_issued_total",
		Help: "Total number of SSH certificates issued",
	}, []string{"role", "principal"})

	// SSHCertErrorsTotal counts SSH certificate signing failures.
	SSHCertErrorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_ssh_cert_errors_total",
		Help: "Total number of SSH certificate errors",
	}, []string{"role", "error_type"})

	// KubeconfigsGeneratedTotal counts kubeconfig downloads.
	KubeconfigsGeneratedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "identity_portal_kubeconfigs_generated_total",
		Help: "Total number of kubeconfigs generated",
	})

	// KeycloakRequestsTotal counts Keycloak API requests.
	KeycloakRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_keycloak_requests_total",
		Help: "Total number of Keycloak API requests",
	}, []string{"operation", "status"})

	// KeycloakErrorsTotal counts Keycloak API errors.
	KeycloakErrorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_keycloak_errors_total",
		Help: "Total number of Keycloak API errors",
	}, []string{"operation"})

	// VaultRequestsTotal counts Vault API requests.
	VaultRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_vault_requests_total",
		Help: "Total number of Vault API requests",
	}, []string{"operation", "status"})

	// VaultErrorsTotal counts Vault API errors.
	VaultErrorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "identity_portal_vault_errors_total",
		Help: "Total number of Vault API errors",
	}, []string{"operation"})

	// ActiveUsersTotal is a gauge of currently enabled users in Keycloak.
	ActiveUsersTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "identity_portal_active_users_total",
		Help: "Number of active (enabled) users in Keycloak",
	})

	// MFAEnrolledUsersTotal is a gauge of users with MFA configured.
	MFAEnrolledUsersTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "identity_portal_mfa_enrolled_users_total",
		Help: "Number of users with MFA enrolled",
	})

	// ActiveSessionsTotal is a gauge of active Keycloak sessions.
	ActiveSessionsTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "identity_portal_active_sessions_total",
		Help: "Number of active sessions in Keycloak",
	})
)
