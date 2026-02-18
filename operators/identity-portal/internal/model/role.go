package model

// Role represents a Keycloak realm role.
type Role struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Composite   bool   `json:"composite"`
	ClientRole  bool   `json:"clientRole"`
	ContainerID string `json:"containerId,omitempty"`
}

// CreateRoleRequest is the payload for creating a realm role.
type CreateRoleRequest struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// UpdateRoleRequest is the payload for updating a realm role.
type UpdateRoleRequest struct {
	Description *string `json:"description,omitempty"`
}

// RoleAssignmentRequest is the payload for assigning/unassigning roles.
type RoleAssignmentRequest struct {
	RoleNames []string `json:"roles"`
}
