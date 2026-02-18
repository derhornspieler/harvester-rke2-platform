import { useState } from "react";
import { Link } from "react-router";
import {
  Download,
  KeyRound,
  RotateCcw,
  Shield,
  Terminal,
  User,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { QueryError } from "@/components/error-boundary";
import { useAuth } from "@/hooks/use-auth";
import { useProfile, useMfaStatus, useResetSelfMfa } from "@/hooks/use-api";

export function ProfilePage() {
  const { user: tokenUser } = useAuth();
  const profile = useProfile();
  const mfa = useMfaStatus();
  const resetMfa = useResetSelfMfa();
  const [showMfaReset, setShowMfaReset] = useState(false);

  return (
    <div className="space-y-6 max-w-3xl">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">My Profile</h1>
        <p className="text-muted-foreground">
          View your account information and settings
        </p>
      </div>

      {/* Profile info */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-4">
            <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary text-primary-foreground text-xl font-bold">
              {(tokenUser?.given_name?.[0] ?? "")
                .concat(tokenUser?.family_name?.[0] ?? "")
                .toUpperCase() ||
                tokenUser?.preferred_username?.charAt(0).toUpperCase() ||
                "?"}
            </div>
            <div>
              <CardTitle>
                {tokenUser?.given_name} {tokenUser?.family_name}
              </CardTitle>
              <CardDescription>{tokenUser?.email}</CardDescription>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          {profile.isLoading ? (
            <div className="space-y-3">
              {Array.from({ length: 4 }).map((_, i) => (
                <Skeleton key={i} className="h-6 w-64" />
              ))}
            </div>
          ) : profile.error ? (
            <QueryError
              error={profile.error}
              onRetry={() => profile.refetch()}
              message="Failed to load profile"
            />
          ) : (
            <div className="grid grid-cols-2 gap-y-4 gap-x-8">
              <div>
                <p className="text-xs text-muted-foreground">Username</p>
                <p className="text-sm font-medium flex items-center gap-2">
                  <User className="h-3 w-3 text-muted-foreground" />
                  {profile.data?.username ?? tokenUser?.preferred_username}
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">Email</p>
                <p className="text-sm font-medium">
                  {profile.data?.email ?? tokenUser?.email}
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">First Name</p>
                <p className="text-sm font-medium">
                  {profile.data?.firstName ?? tokenUser?.given_name ?? "-"}
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">Last Name</p>
                <p className="text-sm font-medium">
                  {profile.data?.lastName ?? tokenUser?.family_name ?? "-"}
                </p>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {/* MFA Status */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Shield className="h-5 w-5" />
            Multi-Factor Authentication
          </CardTitle>
        </CardHeader>
        <CardContent>
          {mfa.isLoading ? (
            <Skeleton className="h-6 w-32" />
          ) : mfa.error ? (
            <QueryError
              error={mfa.error}
              onRetry={() => mfa.refetch()}
              message="Failed to load MFA status"
            />
          ) : (
            <div className="space-y-3">
              <div className="flex items-center gap-3">
                {mfa.data?.enrolled ? (
                  <>
                    <Badge variant="success">Enrolled</Badge>
                    <span className="text-sm text-muted-foreground">
                      Your account is protected by multi-factor authentication
                      {(mfa.data.methods?.length ?? 0) > 0 &&
                        ` (${mfa.data.methods!.join(", ")})`}
                    </span>
                  </>
                ) : (
                  <>
                    <Badge variant="warning">Not Enrolled</Badge>
                    <span className="text-sm text-muted-foreground">
                      You can enroll MFA via your Keycloak account settings
                    </span>
                  </>
                )}
              </div>
              {mfa.data?.enrolled && (
                <Button
                  variant="destructive"
                  size="sm"
                  onClick={() => setShowMfaReset(true)}
                  disabled={resetMfa.isPending}
                >
                  <RotateCcw className="mr-2 h-4 w-4" />
                  {resetMfa.isPending ? "Resetting..." : "Reset MFA"}
                </Button>
              )}
              {resetMfa.isSuccess && (
                <p className="text-sm text-green-600">
                  MFA has been reset. You can re-enroll on your next login.
                </p>
              )}
              {resetMfa.isError && (
                <p className="text-sm text-destructive">
                  Failed to reset MFA. Please try again or contact an
                  administrator.
                </p>
              )}
            </div>
          )}
        </CardContent>
      </Card>

      {/* MFA Reset Confirmation Dialog */}
      <AlertDialog open={showMfaReset} onOpenChange={setShowMfaReset}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Reset Multi-Factor Authentication?</AlertDialogTitle>
            <AlertDialogDescription>
              This will remove all MFA methods from your account. You will need
              to re-enroll MFA on your next login. This action cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => resetMfa.mutate()}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              Reset MFA
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Groups */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <KeyRound className="h-5 w-5" />
            Group Memberships
          </CardTitle>
        </CardHeader>
        <CardContent>
          {profile.isLoading ? (
            <Skeleton className="h-6 w-48" />
          ) : (profile.data?.groups ?? tokenUser?.groups ?? []).length ===
            0 ? (
            <p className="text-sm text-muted-foreground">
              You are not a member of any groups
            </p>
          ) : (
            <div className="flex flex-wrap gap-2">
              {(profile.data?.groups ?? tokenUser?.groups ?? []).map(
                (group) => (
                  <Badge key={group} variant="secondary">
                    {group}
                  </Badge>
                ),
              )}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Roles */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Shield className="h-5 w-5" />
            Assigned Roles
          </CardTitle>
        </CardHeader>
        <CardContent>
          {profile.isLoading ? (
            <Skeleton className="h-6 w-48" />
          ) : (profile.data?.roles ?? tokenUser?.realm_access?.roles ?? [])
              .length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No roles assigned
            </p>
          ) : (
            <div className="flex flex-wrap gap-2">
              {(
                profile.data?.roles ??
                tokenUser?.realm_access?.roles ??
                []
              ).map((role) => (
                <Badge key={role} variant="default">
                  {role}
                </Badge>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <Separator />

      {/* Quick links */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Quick Links</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-3">
          <Button asChild variant="outline">
            <Link to="/ssh">
              <Terminal className="mr-2 h-4 w-4" />
              Request SSH Certificate
            </Link>
          </Button>
          <Button asChild variant="outline">
            <Link to="/kubeconfig">
              <Download className="mr-2 h-4 w-4" />
              Download Kubeconfig
            </Link>
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
