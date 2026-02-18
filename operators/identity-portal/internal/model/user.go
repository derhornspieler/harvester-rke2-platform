package model

// User represents a Keycloak user with essential fields.
type User struct {
	ID              string            `json:"id"`
	Username        string            `json:"username"`
	Email           string            `json:"email"`
	FirstName       string            `json:"firstName"`
	LastName        string            `json:"lastName"`
	Enabled         bool              `json:"enabled"`
	EmailVerified   bool              `json:"emailVerified"`
	CreatedAt       int64             `json:"createdTimestamp"`
	Groups          []Group           `json:"groups,omitempty"`
	RealmRoles      []Role            `json:"roles,omitempty"`
	Attributes      map[string]string `json:"attributes,omitempty"`
	MFAEnabled      bool              `json:"mfaEnabled"`
	RequiredActions []string          `json:"requiredActions,omitempty"`
}

// CreateUserRequest is the payload for creating a new user.
type CreateUserRequest struct {
	Username  string `json:"username"`
	Email     string `json:"email"`
	FirstName string `json:"firstName"`
	LastName  string `json:"lastName"`
	Enabled   bool   `json:"enabled"`
	Password  string `json:"password,omitempty"` //nolint:gosec // DTO field, not a hardcoded credential
}

// UpdateUserRequest is the payload for updating an existing user.
type UpdateUserRequest struct {
	Email     *string `json:"email,omitempty"`
	FirstName *string `json:"firstName,omitempty"`
	LastName  *string `json:"lastName,omitempty"`
	Enabled   *bool   `json:"enabled,omitempty"`
}

// UserProfile represents the self-service profile view.
type UserProfile struct {
	ID            string   `json:"id"`
	Username      string   `json:"username"`
	Email         string   `json:"email"`
	FirstName     string   `json:"firstName"`
	LastName      string   `json:"lastName"`
	EmailVerified bool     `json:"emailVerified"`
	Groups        []string `json:"groups"`
	RealmRoles    []string `json:"roles"`
	MFAEnabled    bool     `json:"mfaEnabled"`
}

// MFAStatus represents the MFA enrollment status for a user.
type MFAStatus struct {
	Enrolled     bool     `json:"enrolled"`
	Type         string   `json:"type,omitempty"`
	Methods      []string `json:"methods,omitempty"`
	ConfiguredAt string   `json:"configuredAt,omitempty"`
}

// ResetPasswordRequest is the payload for an admin password reset.
type ResetPasswordRequest struct {
	Password  string `json:"password"` //nolint:gosec // DTO field, not a hardcoded credential
	Temporary bool   `json:"temporary"`
}

// DashboardStats holds aggregate stats for the admin dashboard.
type DashboardStats struct {
	TotalUsers     int     `json:"totalUsers"`
	ActiveUsers    int     `json:"activeUsers"`
	MFAEnrolled    int     `json:"mfaEnrolled"`
	MFAPercentage  float64 `json:"mfaPercentage"`
	ActiveSessions int     `json:"activeSessions"`
	SSHCertsToday  int     `json:"sshCertsToday"`
}

// UsersResponse wraps a paginated list of users.
type UsersResponse struct {
	Users []User `json:"users"`
	Total int    `json:"total"`
}
