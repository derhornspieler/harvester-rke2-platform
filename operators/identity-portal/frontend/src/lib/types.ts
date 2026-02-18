// API Config
export interface AppConfig {
  keycloakUrl: string;
  realm: string;
  clientId: string;
}

// User
export interface User {
  id: string;
  username: string;
  email: string;
  firstName: string;
  lastName: string;
  enabled: boolean;
  emailVerified: boolean;
  createdTimestamp: number;
  groups?: Group[];
  roles?: Role[];
  mfaEnabled?: boolean;
  requiredActions?: string[];
  attributes?: Record<string, string>;
}

export interface UserCreateRequest {
  username: string;
  email: string;
  firstName: string;
  lastName: string;
  enabled: boolean;
}

export interface UserUpdateRequest {
  email?: string;
  firstName?: string;
  lastName?: string;
  enabled?: boolean;
}

export interface UsersResponse {
  users: User[];
  total: number;
}

export interface ResetPasswordRequest {
  password: string;
  temporary: boolean;
}

// Group
export interface Group {
  id: string;
  name: string;
  path: string;
  memberCount?: number;
  members?: User[];
  subGroups?: Group[];
}

export interface GroupCreateRequest {
  name: string;
}

// Role
export interface Role {
  id: string;
  name: string;
  description: string;
  composite: boolean;
  clientRole: boolean;
  containerId: string;
}

// MFA
export interface MfaStatus {
  enrolled: boolean;
  type?: string;
  methods?: string[];
  configuredAt?: string;
}

// Session
export interface Session {
  id: string;
  username: string;
  userId: string;
  ipAddress: string;
  start: number;
  lastAccess: number;
  clients: Record<string, string>;
}

// Events
export interface LoginEvent {
  time: number;
  type: string;
  clientId: string;
  userId: string;
  username: string;
  ipAddress: string;
  error?: string;
  details?: Record<string, string>;
}

export interface AdminEvent {
  time: number;
  operationType: string;
  resourceType: string;
  resourcePath: string;
  representation?: string;
  authDetails: {
    realmId: string;
    clientId: string;
    userId: string;
    ipAddress: string;
  };
}

// Stats
export interface DashboardStats {
  totalUsers: number;
  activeUsers: number;
  mfaEnrolled: number;
  mfaPercentage: number;
  activeSessions: number;
  sshCertsToday: number;
}

// Vault
export interface VaultPolicy {
  name: string;
  policy: string;
}

// SSH
export interface SSHRole {
  name: string;
  allowedUsers: string;
  allowedExtensions: string;
  defaultExtensions: Record<string, string>;
  keyTypeAllowed: string;
  ttl: string;
  maxTtl: string;
  defaultUser: string;
  algorithmSigner?: string;
}

export interface SSHPublicKeyResponse {
  publicKey: string;
  fingerprint: string;
  registeredAt?: string;
}

export interface SSHCertificateRequest {
  publicKey: string;
}

export interface SSHCertificateResponse {
  signedCertificate: string;
  principals: string[];
  ttl: string;
}

// Profile
export interface Profile {
  id: string;
  username: string;
  email: string;
  firstName: string;
  lastName: string;
  groups: string[];
  roles: string[];
  mfaEnabled?: boolean;
}

// Auth token claims
export interface TokenClaims {
  sub: string;
  preferred_username: string;
  email: string;
  given_name: string;
  family_name: string;
  realm_access?: {
    roles: string[];
  };
  groups?: string[];
  exp: number;
  iat: number;
}

// API error
export interface ApiError {
  error: string;
  message: string;
  status: number;
}
