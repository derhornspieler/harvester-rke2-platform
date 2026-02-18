package model

// KubeconfigParams holds the parameters for generating a kubeconfig.
type KubeconfigParams struct {
	ClusterName   string
	APIServer     string
	CACertData    string
	OIDCIssuerURL string
	OIDCClientID  string
	Username      string
}

// PublicConfig is the response for the /api/v1/config endpoint,
// providing the frontend with the information it needs to perform OIDC login.
// JSON field names use camelCase to match the frontend AppConfig interface.
type PublicConfig struct {
	KeycloakURL string `json:"keycloakUrl"`
	Realm       string `json:"realm"`
	ClientID    string `json:"clientId"`
	IssuerURL   string `json:"issuerUrl"`
}
