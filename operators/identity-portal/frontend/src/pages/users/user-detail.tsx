import { useState } from "react";
import { Link, useParams, useNavigate } from "react-router";
import {
  ArrowLeft,
  Loader2,
  LogOut,
  Shield,
  ShieldOff,
  Trash2,
  UserMinus,
  UserPlus,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { toast } from "@/components/ui/toast";
import { QueryError } from "@/components/error-boundary";
import {
  useUser,
  useUpdateUser,
  useDeleteUser,
  useUserGroups,
  useAddUserToGroup,
  useRemoveUserFromGroup,
  useUserMfa,
  useResetUserMfa,
  useUserSessions,
  useLogoutUserSessions,
  useResetPassword,
  useGroups,
  useRoles,
  useAssignRoles,
  useUnassignRoles,
} from "@/hooks/use-api";
import { formatDate } from "@/lib/utils";

export function UserDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const userId = id ?? "";

  const user = useUser(userId);
  const userGroups = useUserGroups(userId);
  const userMfa = useUserMfa(userId);
  const userSessions = useUserSessions(userId);
  const allGroups = useGroups();
  const allRoles = useRoles();

  const updateUser = useUpdateUser(userId);
  const deleteUser = useDeleteUser();
  const addToGroup = useAddUserToGroup(userId);
  const removeFromGroup = useRemoveUserFromGroup(userId);
  const resetMfa = useResetUserMfa(userId);
  const logoutSessions = useLogoutUserSessions(userId);
  const resetPassword = useResetPassword(userId);
  const assignRoles = useAssignRoles(userId);
  const unassignRoles = useUnassignRoles(userId);

  // Edit state
  const [editing, setEditing] = useState(false);
  const [editEmail, setEditEmail] = useState("");
  const [editFirstName, setEditFirstName] = useState("");
  const [editLastName, setEditLastName] = useState("");
  const [editEnabled, setEditEnabled] = useState(true);

  // Password reset state
  const [newPassword, setNewPassword] = useState("");
  const [tempPassword, setTempPassword] = useState(true);
  const [passwordDialogOpen, setPasswordDialogOpen] = useState(false);

  // Delete state
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);

  // Group add state
  const [selectedGroupId, setSelectedGroupId] = useState("");

  // Role assign state
  const [selectedRoleToAssign, setSelectedRoleToAssign] = useState("");

  const startEditing = () => {
    if (user.data) {
      setEditEmail(user.data.email);
      setEditFirstName(user.data.firstName);
      setEditLastName(user.data.lastName);
      setEditEnabled(user.data.enabled);
      setEditing(true);
    }
  };

  const handleSave = async () => {
    try {
      await updateUser.mutateAsync({
        email: editEmail,
        firstName: editFirstName,
        lastName: editLastName,
        enabled: editEnabled,
      });
      toast({ title: "User updated", variant: "success" });
      setEditing(false);
    } catch (err) {
      toast({
        title: "Failed to update user",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleDelete = async () => {
    try {
      await deleteUser.mutateAsync(userId);
      toast({ title: "User deleted", variant: "success" });
      navigate("/users");
    } catch (err) {
      toast({
        title: "Failed to delete user",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleResetPassword = async () => {
    if (!newPassword) return;
    try {
      await resetPassword.mutateAsync({
        password: newPassword,
        temporary: tempPassword,
      });
      toast({ title: "Password reset", variant: "success" });
      setPasswordDialogOpen(false);
      setNewPassword("");
    } catch (err) {
      toast({
        title: "Failed to reset password",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleAddGroup = async () => {
    if (!selectedGroupId) return;
    try {
      await addToGroup.mutateAsync(selectedGroupId);
      toast({ title: "User added to group", variant: "success" });
      setSelectedGroupId("");
    } catch (err) {
      toast({
        title: "Failed to add to group",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleRemoveGroup = async (groupId: string) => {
    try {
      await removeFromGroup.mutateAsync(groupId);
      toast({ title: "Removed from group", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to remove from group",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleAssignRole = async () => {
    if (!selectedRoleToAssign) return;
    try {
      await assignRoles.mutateAsync([selectedRoleToAssign]);
      toast({ title: "Role assigned", variant: "success" });
      setSelectedRoleToAssign("");
    } catch (err) {
      toast({
        title: "Failed to assign role",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleUnassignRole = async (roleName: string) => {
    try {
      await unassignRoles.mutateAsync([roleName]);
      toast({ title: "Role removed", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to remove role",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleResetMfa = async () => {
    try {
      await resetMfa.mutateAsync();
      toast({ title: "MFA reset", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to reset MFA",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleLogoutSessions = async () => {
    try {
      await logoutSessions.mutateAsync();
      toast({ title: "All sessions terminated", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to logout sessions",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  if (user.isLoading) {
    return (
      <div className="space-y-6 max-w-4xl">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (user.error) {
    return (
      <QueryError
        error={user.error}
        onRetry={() => user.refetch()}
        message="Failed to load user"
      />
    );
  }

  if (!user.data) {
    return (
      <div className="text-center py-12">
        <p className="text-muted-foreground">User not found</p>
      </div>
    );
  }

  const u = user.data;
  const currentGroupIds = new Set(
    (userGroups.data ?? []).map((g) => g.id),
  );
  const availableGroups = (allGroups.data ?? []).filter(
    (g) => !currentGroupIds.has(g.id),
  );
  const currentRoleNames = new Set(
    (u.roles ?? []).map((r) => r.name),
  );
  const availableRoles = (allRoles.data ?? []).filter(
    (r) => !currentRoleNames.has(r.name),
  );

  return (
    <div className="space-y-6 max-w-4xl">
      <div className="flex items-center gap-4">
        <Button asChild variant="ghost" size="icon">
          <Link to="/users">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div className="flex-1">
          <h1 className="text-2xl font-bold tracking-tight">{u.username}</h1>
          <p className="text-muted-foreground">{u.email}</p>
        </div>
        <div className="flex gap-2">
          {!editing ? (
            <Button variant="outline" onClick={startEditing}>
              Edit
            </Button>
          ) : (
            <>
              <Button onClick={handleSave} disabled={updateUser.isPending}>
                {updateUser.isPending && (
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                )}
                Save
              </Button>
              <Button variant="outline" onClick={() => setEditing(false)}>
                Cancel
              </Button>
            </>
          )}
          <Dialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
            <DialogTrigger asChild>
              <Button variant="destructive" size="icon">
                <Trash2 className="h-4 w-4" />
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Delete User</DialogTitle>
                <DialogDescription>
                  Are you sure you want to delete user &quot;{u.username}
                  &quot;? This action cannot be undone.
                </DialogDescription>
              </DialogHeader>
              <DialogFooter>
                <Button
                  variant="outline"
                  onClick={() => setDeleteDialogOpen(false)}
                >
                  Cancel
                </Button>
                <Button
                  variant="destructive"
                  onClick={handleDelete}
                  disabled={deleteUser.isPending}
                >
                  {deleteUser.isPending && (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  )}
                  Delete User
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </div>
      </div>

      {/* User Info */}
      <Card>
        <CardHeader>
          <CardTitle>User Information</CardTitle>
          <CardDescription>
            Created{" "}
            {u.createdTimestamp
              ? formatDate(new Date(u.createdTimestamp).toISOString())
              : "Unknown"}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {editing ? (
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label>Email</Label>
                <Input
                  value={editEmail}
                  onChange={(e) => setEditEmail(e.target.value)}
                />
              </div>
              <div />
              <div className="space-y-2">
                <Label>First Name</Label>
                <Input
                  value={editFirstName}
                  onChange={(e) => setEditFirstName(e.target.value)}
                />
              </div>
              <div className="space-y-2">
                <Label>Last Name</Label>
                <Input
                  value={editLastName}
                  onChange={(e) => setEditLastName(e.target.value)}
                />
              </div>
              <div className="flex items-center gap-2 col-span-2">
                <input
                  type="checkbox"
                  id="editEnabled"
                  checked={editEnabled}
                  onChange={(e) => setEditEnabled(e.target.checked)}
                  className="h-4 w-4 rounded border-input"
                />
                <Label htmlFor="editEnabled">Account enabled</Label>
              </div>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-y-3 gap-x-8">
              <div>
                <p className="text-xs text-muted-foreground">Username</p>
                <p className="text-sm font-medium">{u.username}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">Email</p>
                <p className="text-sm font-medium">{u.email}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">First Name</p>
                <p className="text-sm font-medium">{u.firstName || "-"}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">Last Name</p>
                <p className="text-sm font-medium">{u.lastName || "-"}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">Status</p>
                {u.enabled ? (
                  <Badge variant="success">Active</Badge>
                ) : (
                  <Badge variant="destructive">Disabled</Badge>
                )}
              </div>
              <div>
                <p className="text-xs text-muted-foreground">
                  Email Verified
                </p>
                <Badge variant={u.emailVerified ? "success" : "outline"}>
                  {u.emailVerified ? "Yes" : "No"}
                </Badge>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Groups */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Groups</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex gap-2">
            <Select value={selectedGroupId} onValueChange={setSelectedGroupId}>
              <SelectTrigger className="w-[200px]">
                <SelectValue placeholder="Select group..." />
              </SelectTrigger>
              <SelectContent>
                {availableGroups.map((g) => (
                  <SelectItem key={g.id} value={g.id}>
                    {g.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Button
              size="sm"
              onClick={handleAddGroup}
              disabled={!selectedGroupId || addToGroup.isPending}
            >
              <UserPlus className="mr-1 h-3 w-3" />
              Add
            </Button>
          </div>
          <div className="flex flex-wrap gap-2">
            {userGroups.isLoading ? (
              <Skeleton className="h-6 w-24" />
            ) : (userGroups.data ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">No groups</p>
            ) : (
              (userGroups.data ?? []).map((g) => (
                <Badge key={g.id} variant="secondary" className="gap-1">
                  {g.name}
                  <button
                    onClick={() => handleRemoveGroup(g.id)}
                    className="ml-1 hover:text-destructive"
                  >
                    <UserMinus className="h-3 w-3" />
                  </button>
                </Badge>
              ))
            )}
          </div>
        </CardContent>
      </Card>

      {/* Roles */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Roles</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex gap-2">
            <Select
              value={selectedRoleToAssign}
              onValueChange={setSelectedRoleToAssign}
            >
              <SelectTrigger className="w-[200px]">
                <SelectValue placeholder="Select role..." />
              </SelectTrigger>
              <SelectContent>
                {availableRoles.map((r) => (
                  <SelectItem key={r.id} value={r.name}>
                    {r.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Button
              size="sm"
              onClick={handleAssignRole}
              disabled={!selectedRoleToAssign || assignRoles.isPending}
            >
              <Shield className="mr-1 h-3 w-3" />
              Assign
            </Button>
          </div>
          <div className="flex flex-wrap gap-2">
            {(u.roles ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">No roles</p>
            ) : (
              (u.roles ?? []).map((r) => (
                <Badge key={r.id} variant="default" className="gap-1">
                  {r.name}
                  <button
                    onClick={() => handleUnassignRole(r.name)}
                    className="ml-1 hover:text-destructive"
                  >
                    <ShieldOff className="h-3 w-3" />
                  </button>
                </Badge>
              ))
            )}
          </div>
        </CardContent>
      </Card>

      {/* MFA */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-base">Multi-Factor Authentication</CardTitle>
          {userMfa.data?.enrolled && (
            <Button
              variant="destructive"
              size="sm"
              onClick={handleResetMfa}
              disabled={resetMfa.isPending}
            >
              {resetMfa.isPending && (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              )}
              Reset MFA
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {userMfa.isLoading ? (
            <Skeleton className="h-6 w-24" />
          ) : (
            <div className="flex items-center gap-2">
              <Badge
                variant={userMfa.data?.enrolled ? "success" : "outline"}
              >
                {userMfa.data?.enrolled ? "Enrolled" : "Not Enrolled"}
              </Badge>
              {userMfa.data?.type && (
                <span className="text-sm text-muted-foreground">
                  ({userMfa.data.type})
                </span>
              )}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Sessions */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-base">Active Sessions</CardTitle>
          {(userSessions.data ?? []).length > 0 && (
            <Button
              variant="outline"
              size="sm"
              onClick={handleLogoutSessions}
              disabled={logoutSessions.isPending}
            >
              <LogOut className="mr-1 h-3 w-3" />
              Logout All
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {userSessions.isLoading ? (
            <Skeleton className="h-16 w-full" />
          ) : (userSessions.data ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">No active sessions</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>IP Address</TableHead>
                  <TableHead>Started</TableHead>
                  <TableHead>Last Access</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(userSessions.data ?? []).map((session) => (
                  <TableRow key={session.id}>
                    <TableCell className="font-mono text-sm">
                      {session.ipAddress}
                    </TableCell>
                    <TableCell className="text-sm">
                      {formatDate(
                        new Date(session.start).toISOString(),
                      )}
                    </TableCell>
                    <TableCell className="text-sm">
                      {formatDate(
                        new Date(session.lastAccess).toISOString(),
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* Password Reset */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Password</CardTitle>
        </CardHeader>
        <CardContent>
          <Dialog
            open={passwordDialogOpen}
            onOpenChange={setPasswordDialogOpen}
          >
            <DialogTrigger asChild>
              <Button variant="outline">Reset Password</Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Reset Password</DialogTitle>
                <DialogDescription>
                  Set a new password for user &quot;{u.username}&quot;
                </DialogDescription>
              </DialogHeader>
              <div className="space-y-4 py-4">
                <div className="space-y-2">
                  <Label htmlFor="newPassword">New Password</Label>
                  <Input
                    id="newPassword"
                    type="password"
                    value={newPassword}
                    onChange={(e) => setNewPassword(e.target.value)}
                    placeholder="Enter new password"
                  />
                </div>
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="tempPassword"
                    checked={tempPassword}
                    onChange={(e) => setTempPassword(e.target.checked)}
                    className="h-4 w-4 rounded border-input"
                  />
                  <Label htmlFor="tempPassword">
                    Require password change on next login
                  </Label>
                </div>
              </div>
              <DialogFooter>
                <Button
                  variant="outline"
                  onClick={() => setPasswordDialogOpen(false)}
                >
                  Cancel
                </Button>
                <Button
                  onClick={handleResetPassword}
                  disabled={!newPassword || resetPassword.isPending}
                >
                  {resetPassword.isPending && (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  )}
                  Reset Password
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </CardContent>
      </Card>

      <Separator />
    </div>
  );
}
