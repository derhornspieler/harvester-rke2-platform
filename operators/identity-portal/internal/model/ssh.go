package model

// SSHCertRequest is the payload for requesting an SSH certificate.
type SSHCertRequest struct {
	PublicKey string `json:"public_key"`
}

// SSHCertResponse is the response containing the signed SSH certificate.
type SSHCertResponse struct {
	SignedCertificate string   `json:"signed_certificate"`
	Principals        []string `json:"principals"`
	ValidAfter        int64    `json:"valid_after"`
	ValidBefore       int64    `json:"valid_before"`
	TTL               string   `json:"ttl"`
}

// SSHCAResponse is the response containing the SSH CA public key.
type SSHCAResponse struct {
	PublicKey string `json:"public_key"`
}

// SSHRoleConfig represents a Vault SSH signing role configuration.
type SSHRoleConfig struct {
	Name              string            `json:"name"`
	DefaultUser       string            `json:"default_user,omitempty"`
	AllowedUsers      string            `json:"allowed_users,omitempty"`
	AllowedExtensions string            `json:"allowed_extensions,omitempty"`
	DefaultExtensions map[string]string `json:"default_extensions,omitempty"`
	TTL               string            `json:"ttl,omitempty"`
	MaxTTL            string            `json:"max_ttl,omitempty"`
	KeyType           string            `json:"key_type,omitempty"`
	AlgorithmSigner   string            `json:"algorithm_signer,omitempty"`
}

// CreateSSHRoleRequest is the payload for creating/updating an SSH signing role.
type CreateSSHRoleRequest struct {
	DefaultUser       string            `json:"default_user,omitempty"`
	AllowedUsers      string            `json:"allowed_users,omitempty"`
	AllowedExtensions string            `json:"allowed_extensions,omitempty"`
	DefaultExtensions map[string]string `json:"default_extensions,omitempty"`
	TTL               string            `json:"ttl,omitempty"`
	MaxTTL            string            `json:"max_ttl,omitempty"`
}
