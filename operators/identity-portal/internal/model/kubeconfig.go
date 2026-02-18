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
type PublicConfig struct {
	KeycloakURL string `json:"keycloak_url"`
	Realm       string `json:"realm"`
	ClientID    string `json:"client_id"`
	IssuerURL   string `json:"issuer_url"`
}
