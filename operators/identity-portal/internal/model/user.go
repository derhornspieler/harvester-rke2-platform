package model

// User represents a Keycloak user with essential fields.
type User struct {
	ID              string            `json:"id"`
	Username        string            `json:"username"`
	Email           string            `json:"email"`
	FirstName       string            `json:"first_name"`
	LastName        string            `json:"last_name"`
	Enabled         bool              `json:"enabled"`
	EmailVerified   bool              `json:"email_verified"`
	CreatedAt       int64             `json:"created_at"`
	Groups          []string          `json:"groups,omitempty"`
	RealmRoles      []string          `json:"realm_roles,omitempty"`
	Attributes      map[string]string `json:"attributes,omitempty"`
	MFAEnabled      bool              `json:"mfa_enabled"`
	RequiredActions []string          `json:"required_actions,omitempty"`
}

// CreateUserRequest is the payload for creating a new user.
type CreateUserRequest struct {
	Username  string `json:"username"`
	Email     string `json:"email"`
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	Enabled   bool   `json:"enabled"`
	Password  string `json:"password,omitempty"`
}

// UpdateUserRequest is the payload for updating an existing user.
type UpdateUserRequest struct {
	Email     *string `json:"email,omitempty"`
	FirstName *string `json:"first_name,omitempty"`
	LastName  *string `json:"last_name,omitempty"`
	Enabled   *bool   `json:"enabled,omitempty"`
}

// UserProfile represents the self-service profile view.
type UserProfile struct {
	ID            string   `json:"id"`
	Username      string   `json:"username"`
	Email         string   `json:"email"`
	FirstName     string   `json:"first_name"`
	LastName      string   `json:"last_name"`
	EmailVerified bool     `json:"email_verified"`
	Groups        []string `json:"groups"`
	RealmRoles    []string `json:"realm_roles"`
	MFAEnabled    bool     `json:"mfa_enabled"`
}

// MFAStatus represents the MFA enrollment status for a user.
type MFAStatus struct {
	Enabled      bool     `json:"enabled"`
	Methods      []string `json:"methods,omitempty"`
	ConfiguredAt string   `json:"configured_at,omitempty"`
}

// ResetPasswordRequest is the payload for an admin password reset.
type ResetPasswordRequest struct {
	Password  string `json:"password"`
	Temporary bool   `json:"temporary"`
}

// DashboardStats holds aggregate stats for the admin dashboard.
type DashboardStats struct {
	TotalUsers     int `json:"total_users"`
	EnabledUsers   int `json:"enabled_users"`
	DisabledUsers  int `json:"disabled_users"`
	MFAEnrolled    int `json:"mfa_enrolled"`
	ActiveSessions int `json:"active_sessions"`
	TotalGroups    int `json:"total_groups"`
}
