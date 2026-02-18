import { BrowserRouter, Routes, Route } from "react-router";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AuthProvider } from "@/lib/auth";
import { Toaster } from "@/components/ui/toast";
import { ErrorBoundary } from "@/components/error-boundary";
import { ProtectedRoute } from "@/components/protected-route";
import { AdminRoute } from "@/components/admin-route";
import { AppLayout } from "@/components/layout/app-layout";
import { DashboardPage } from "@/pages/dashboard";
import { LoginCallbackPage } from "@/pages/login-callback";
import { UsersListPage } from "@/pages/users/users-list";
import { UserCreatePage } from "@/pages/users/user-create";
import { UserDetailPage } from "@/pages/users/user-detail";
import { GroupsListPage } from "@/pages/groups/groups-list";
import { GroupDetailPage } from "@/pages/groups/group-detail";
import { RolesListPage } from "@/pages/roles/roles-list";
import { VaultPoliciesPage } from "@/pages/vault/vault-policies";
import { SSHAccessPage } from "@/pages/ssh/ssh-access";
import { KubeconfigPage } from "@/pages/kubeconfig/kubeconfig";
import { ReportsPage } from "@/pages/reports/reports";
import { ProfilePage } from "@/pages/profile/profile";
import { NotFoundPage } from "@/pages/not-found";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

export default function App() {
  return (
    <ErrorBoundary>
      <QueryClientProvider client={queryClient}>
        <AuthProvider>
          <BrowserRouter>
            <Routes>
              {/* Public callback route */}
              <Route path="/login/callback" element={<LoginCallbackPage />} />

              {/* Protected routes */}
              <Route
                element={
                  <ProtectedRoute>
                    <AppLayout />
                  </ProtectedRoute>
                }
              >
                <Route index element={<DashboardPage />} />

                {/* Admin routes */}
                <Route
                  path="users"
                  element={
                    <AdminRoute>
                      <UsersListPage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="users/create"
                  element={
                    <AdminRoute>
                      <UserCreatePage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="users/:id"
                  element={
                    <AdminRoute>
                      <UserDetailPage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="groups"
                  element={
                    <AdminRoute>
                      <GroupsListPage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="groups/:id"
                  element={
                    <AdminRoute>
                      <GroupDetailPage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="roles"
                  element={
                    <AdminRoute>
                      <RolesListPage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="vault/policies"
                  element={
                    <AdminRoute>
                      <VaultPoliciesPage />
                    </AdminRoute>
                  }
                />
                <Route
                  path="reports"
                  element={
                    <AdminRoute>
                      <ReportsPage />
                    </AdminRoute>
                  }
                />

                {/* All-user routes */}
                <Route path="ssh" element={<SSHAccessPage />} />
                <Route path="kubeconfig" element={<KubeconfigPage />} />
                <Route path="profile" element={<ProfilePage />} />

                {/* 404 */}
                <Route path="*" element={<NotFoundPage />} />
              </Route>
            </Routes>
          </BrowserRouter>
          <Toaster />
        </AuthProvider>
      </QueryClientProvider>
    </ErrorBoundary>
  );
}
