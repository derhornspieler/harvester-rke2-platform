package model

// SSHCertRequest is the payload for requesting an SSH certificate.
type SSHCertRequest struct {
	PublicKey string `json:"publicKey"`
}

// SSHPublicKeyRequest is the payload for registering an SSH public key.
type SSHPublicKeyRequest struct {
	PublicKey string `json:"publicKey"`
}

// SSHPublicKeyResponse is the response for a registered SSH public key.
type SSHPublicKeyResponse struct {
	PublicKey     string `json:"publicKey"`
	Fingerprint  string `json:"fingerprint"`
	RegisteredAt string `json:"registeredAt,omitempty"`
}

// SSHCertResponse is the response containing the signed SSH certificate.
type SSHCertResponse struct {
	SignedCertificate string   `json:"signedCertificate"`
	Principals        []string `json:"principals"`
	ValidAfter        int64    `json:"validAfter"`
	ValidBefore       int64    `json:"validBefore"`
	TTL               string   `json:"ttl"`
}

// SSHCAResponse is the response containing the SSH CA public key.
type SSHCAResponse struct {
	PublicKey string `json:"publicKey"`
}

// SSHRoleConfig represents a Vault SSH signing role configuration.
type SSHRoleConfig struct {
	Name              string            `json:"name"`
	DefaultUser       string            `json:"defaultUser,omitempty"`
	AllowedUsers      string            `json:"allowedUsers,omitempty"`
	AllowedExtensions string            `json:"allowedExtensions,omitempty"`
	DefaultExtensions map[string]string `json:"defaultExtensions,omitempty"`
	TTL               string            `json:"ttl,omitempty"`
	MaxTTL            string            `json:"maxTtl,omitempty"`
	KeyType           string            `json:"keyTypeAllowed,omitempty"`
	AlgorithmSigner   string            `json:"algorithmSigner,omitempty"`
}

// CreateSSHRoleRequest is the payload for creating/updating an SSH signing role.
type CreateSSHRoleRequest struct {
	DefaultUser       string            `json:"defaultUser,omitempty"`
	AllowedUsers      string            `json:"allowedUsers,omitempty"`
	AllowedExtensions string            `json:"allowedExtensions,omitempty"`
	DefaultExtensions map[string]string `json:"defaultExtensions,omitempty"`
	TTL               string            `json:"ttl,omitempty"`
	MaxTTL            string            `json:"maxTtl,omitempty"`
}
