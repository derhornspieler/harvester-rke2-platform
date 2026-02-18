import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiDelete, apiGet, apiPost, apiPut, apiDownload } from "@/lib/api";
import type {
  DashboardStats,
  Group,
  GroupCreateRequest,
  LoginEvent,
  AdminEvent,
  MfaStatus,
  Profile,
  ResetPasswordRequest,
  Role,
  Session,
  SSHCertificateRequest,
  SSHCertificateResponse,
  SSHRole,
  User,
  UserCreateRequest,
  UserUpdateRequest,
  UsersResponse,
  VaultPolicy,
} from "@/lib/types";

// ── Self-service hooks ──────────────────────────────────────────────

export function useProfile() {
  return useQuery({
    queryKey: ["self", "profile"],
    queryFn: () => apiGet<Profile>("/self/profile"),
  });
}

export function useMfaStatus() {
  return useQuery({
    queryKey: ["self", "mfa"],
    queryFn: () => apiGet<MfaStatus>("/self/mfa/status"),
  });
}

export function useRequestSSHCertificate() {
  return useMutation({
    mutationFn: (data: SSHCertificateRequest) =>
      apiPost<SSHCertificateResponse>("/self/ssh/certificate", data),
  });
}

export function useSSHCA() {
  return useQuery({
    queryKey: ["self", "ssh", "ca"],
    queryFn: () => apiGet<string>("/self/ssh/ca"),
    enabled: false,
  });
}

export function useDownloadKubeconfig() {
  return useMutation({
    mutationFn: () => apiDownload("/self/kubeconfig", "kubeconfig.yaml"),
  });
}

export function useDownloadCACert() {
  return useMutation({
    mutationFn: () => apiDownload("/self/ca", "ca.pem"),
  });
}

// ── Admin: Dashboard stats ──────────────────────────────────────────

export function useDashboardStats() {
  return useQuery({
    queryKey: ["admin", "stats"],
    queryFn: () => apiGet<DashboardStats>("/admin/stats"),
    refetchInterval: 30000,
  });
}

// ── Admin: Users ────────────────────────────────────────────────────

export function useUsers(params: {
  search?: string;
  first?: number;
  max?: number;
}) {
  return useQuery({
    queryKey: ["admin", "users", params],
    queryFn: () =>
      apiGet<UsersResponse>("/admin/users", {
        search: params.search,
        first: params.first,
        max: params.max,
      }),
    placeholderData: (prev) => prev,
  });
}

export function useUser(id: string) {
  return useQuery({
    queryKey: ["admin", "users", id],
    queryFn: () => apiGet<User>(`/admin/users/${id}`),
    enabled: !!id,
  });
}

export function useCreateUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: UserCreateRequest) =>
      apiPost<User>("/admin/users", data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "users"] });
      qc.invalidateQueries({ queryKey: ["admin", "stats"] });
    },
  });
}

export function useUpdateUser(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: UserUpdateRequest) =>
      apiPut<User>(`/admin/users/${id}`, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "users", id] });
      qc.invalidateQueries({ queryKey: ["admin", "users"] });
    },
  });
}

export function useDeleteUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => apiDelete(`/admin/users/${id}`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "users"] });
      qc.invalidateQueries({ queryKey: ["admin", "stats"] });
    },
  });
}

export function useResetPassword(userId: string) {
  return useMutation({
    mutationFn: (data: ResetPasswordRequest) =>
      apiPost(`/admin/users/${userId}/reset-password`, data),
  });
}

// ── Admin: User Groups ──────────────────────────────────────────────

export function useUserGroups(userId: string) {
  return useQuery({
    queryKey: ["admin", "users", userId, "groups"],
    queryFn: () => apiGet<Group[]>(`/admin/users/${userId}/groups`),
    enabled: !!userId,
  });
}

export function useAddUserToGroup(userId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (groupId: string) =>
      apiPut(`/admin/users/${userId}/groups/${groupId}`),
    onSuccess: () => {
      qc.invalidateQueries({
        queryKey: ["admin", "users", userId, "groups"],
      });
      qc.invalidateQueries({ queryKey: ["admin", "users", userId] });
      qc.invalidateQueries({ queryKey: ["admin", "groups"] });
    },
  });
}

export function useRemoveUserFromGroup(userId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (groupId: string) =>
      apiDelete(`/admin/users/${userId}/groups/${groupId}`),
    onSuccess: () => {
      qc.invalidateQueries({
        queryKey: ["admin", "users", userId, "groups"],
      });
      qc.invalidateQueries({ queryKey: ["admin", "users", userId] });
      qc.invalidateQueries({ queryKey: ["admin", "groups"] });
    },
  });
}

// ── Admin: User MFA ─────────────────────────────────────────────────

export function useUserMfa(userId: string) {
  return useQuery({
    queryKey: ["admin", "users", userId, "mfa"],
    queryFn: () => apiGet<MfaStatus>(`/admin/users/${userId}/mfa`),
    enabled: !!userId,
  });
}

export function useResetUserMfa(userId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => apiDelete(`/admin/users/${userId}/mfa`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "users", userId, "mfa"] });
      qc.invalidateQueries({ queryKey: ["admin", "users", userId] });
    },
  });
}

// ── Admin: User Sessions ────────────────────────────────────────────

export function useUserSessions(userId: string) {
  return useQuery({
    queryKey: ["admin", "users", userId, "sessions"],
    queryFn: () => apiGet<Session[]>(`/admin/users/${userId}/sessions`),
    enabled: !!userId,
  });
}

export function useLogoutUserSessions(userId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => apiDelete(`/admin/users/${userId}/sessions`),
    onSuccess: () => {
      qc.invalidateQueries({
        queryKey: ["admin", "users", userId, "sessions"],
      });
    },
  });
}

// ── Admin: User Roles ───────────────────────────────────────────────

export function useAssignRoles(userId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (roles: string[]) =>
      apiPost(`/admin/users/${userId}/roles`, { roles }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "users", userId] });
    },
  });
}

export function useUnassignRoles(userId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (roles: string[]) =>
      apiDelete(`/admin/users/${userId}/roles`, { roles }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "users", userId] });
    },
  });
}

// ── Admin: Groups ───────────────────────────────────────────────────

export function useGroups() {
  return useQuery({
    queryKey: ["admin", "groups"],
    queryFn: () => apiGet<Group[]>("/admin/groups"),
  });
}

export function useGroup(id: string) {
  return useQuery({
    queryKey: ["admin", "groups", id],
    queryFn: () => apiGet<Group>(`/admin/groups/${id}`),
    enabled: !!id,
  });
}

export function useCreateGroup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: GroupCreateRequest) =>
      apiPost<Group>("/admin/groups", data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "groups"] });
    },
  });
}

export function useUpdateGroup(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: GroupCreateRequest) =>
      apiPut<Group>(`/admin/groups/${id}`, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "groups"] });
    },
  });
}

export function useDeleteGroup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => apiDelete(`/admin/groups/${id}`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "groups"] });
    },
  });
}

// ── Admin: Roles ────────────────────────────────────────────────────

export function useRoles() {
  return useQuery({
    queryKey: ["admin", "roles"],
    queryFn: () => apiGet<Role[]>("/admin/roles"),
  });
}

// ── Admin: Events ───────────────────────────────────────────────────

export function useLoginEvents(params: {
  type?: string;
  dateFrom?: string;
  dateTo?: string;
  user?: string;
}) {
  return useQuery({
    queryKey: ["admin", "events", params],
    queryFn: () =>
      apiGet<LoginEvent[]>("/admin/events", {
        type: params.type,
        dateFrom: params.dateFrom,
        dateTo: params.dateTo,
        user: params.user,
      }),
    placeholderData: (prev) => prev,
  });
}

export function useAdminEvents() {
  return useQuery({
    queryKey: ["admin", "admin-events"],
    queryFn: () => apiGet<AdminEvent[]>("/admin/admin-events"),
  });
}

// ── Admin: Vault Policies ───────────────────────────────────────────

export function useVaultPolicies() {
  return useQuery({
    queryKey: ["admin", "vault", "policies"],
    queryFn: () => apiGet<VaultPolicy[]>("/admin/vault/policies"),
  });
}

export function useVaultPolicy(name: string) {
  return useQuery({
    queryKey: ["admin", "vault", "policies", name],
    queryFn: () => apiGet<VaultPolicy>(`/admin/vault/policies/${name}`),
    enabled: !!name,
  });
}

export function useCreateVaultPolicy() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: VaultPolicy) =>
      apiPut(`/admin/vault/policies/${data.name}`, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "vault", "policies"] });
    },
  });
}

export function useDeleteVaultPolicy() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (name: string) =>
      apiDelete(`/admin/vault/policies/${name}`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "vault", "policies"] });
    },
  });
}

// ── Admin: SSH Roles ────────────────────────────────────────────────

export function useSSHRoles() {
  return useQuery({
    queryKey: ["admin", "vault", "ssh", "roles"],
    queryFn: () => apiGet<SSHRole[]>("/admin/vault/ssh/roles"),
  });
}

export function useSSHRole(name: string) {
  return useQuery({
    queryKey: ["admin", "vault", "ssh", "roles", name],
    queryFn: () => apiGet<SSHRole>(`/admin/vault/ssh/roles/${name}`),
    enabled: !!name,
  });
}

export function useCreateSSHRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: SSHRole) =>
      apiPut(`/admin/vault/ssh/roles/${data.name}`, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "vault", "ssh", "roles"] });
    },
  });
}

export function useDeleteSSHRole() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (name: string) =>
      apiDelete(`/admin/vault/ssh/roles/${name}`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin", "vault", "ssh", "roles"] });
    },
  });
}

export function useVaultSSHCA() {
  return useQuery({
    queryKey: ["admin", "vault", "ssh", "ca"],
    queryFn: () => apiGet<string>("/admin/vault/ssh/ca"),
  });
}
