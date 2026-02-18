package model

// Group represents a Keycloak group.
type Group struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Path      string   `json:"path"`
	SubGroups []Group  `json:"sub_groups,omitempty"`
	Members   []string `json:"members,omitempty"`
}

// CreateGroupRequest is the payload for creating a group.
type CreateGroupRequest struct {
	Name string `json:"name"`
}

// UpdateGroupRequest is the payload for updating a group.
type UpdateGroupRequest struct {
	Name *string `json:"name,omitempty"`
}

// GroupMembershipRequest is the payload for adding/removing a user to/from a group.
type GroupMembershipRequest struct {
	UserID string `json:"user_id"`
}
