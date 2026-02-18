package model

// VaultPolicy represents a Vault ACL policy.
type VaultPolicy struct {
	Name   string `json:"name"`
	Policy string `json:"policy"`
}

// CreateVaultPolicyRequest is the payload for creating/updating a Vault policy.
type CreateVaultPolicyRequest struct {
	Name   string `json:"name"`
	Policy string `json:"policy"`
}
