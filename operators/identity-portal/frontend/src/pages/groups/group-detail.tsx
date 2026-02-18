import { useState } from "react";
import { Link, useParams, useNavigate } from "react-router";
import { ArrowLeft, Loader2, Pencil, Trash2, UserMinus } from "lucide-react";
import { apiDelete } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { toast } from "@/components/ui/toast";
import { QueryError } from "@/components/error-boundary";
import {
  useGroup,
  useUpdateGroup,
  useDeleteGroup,
} from "@/hooks/use-api";

export function GroupDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const groupId = id ?? "";

  const group = useGroup(groupId);
  const updateGroup = useUpdateGroup(groupId);
  const deleteGroup = useDeleteGroup();

  const [editOpen, setEditOpen] = useState(false);
  const [editName, setEditName] = useState("");
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);

  const handleStartEdit = () => {
    if (group.data) {
      setEditName(group.data.name);
      setEditOpen(true);
    }
  };

  const handleUpdate = async () => {
    if (!editName.trim()) return;
    try {
      await updateGroup.mutateAsync({ name: editName.trim() });
      toast({ title: "Group updated", variant: "success" });
      setEditOpen(false);
    } catch (err) {
      toast({
        title: "Failed to update group",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleDelete = async () => {
    try {
      await deleteGroup.mutateAsync(groupId);
      toast({ title: "Group deleted", variant: "success" });
      navigate("/groups");
    } catch (err) {
      toast({
        title: "Failed to delete group",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleRemoveMember = async (userId: string) => {
    try {
      await apiDelete(`/admin/users/${userId}/groups/${groupId}`);
      toast({ title: "Member removed", variant: "success" });
      group.refetch();
    } catch (err) {
      toast({
        title: "Failed to remove member",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  if (group.isLoading) {
    return (
      <div className="space-y-6 max-w-3xl">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (group.error) {
    return (
      <QueryError
        error={group.error}
        onRetry={() => group.refetch()}
        message="Failed to load group"
      />
    );
  }

  if (!group.data) {
    return (
      <div className="text-center py-12">
        <p className="text-muted-foreground">Group not found</p>
      </div>
    );
  }

  const g = group.data;

  return (
    <div className="space-y-6 max-w-3xl">
      <div className="flex items-center gap-4">
        <Button asChild variant="ghost" size="icon">
          <Link to="/groups">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div className="flex-1">
          <h1 className="text-2xl font-bold tracking-tight">{g.name}</h1>
          <p className="text-muted-foreground font-mono text-sm">{g.path}</p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="icon" onClick={handleStartEdit}>
            <Pencil className="h-4 w-4" />
          </Button>
          <Dialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
            <DialogTrigger asChild>
              <Button variant="destructive" size="icon">
                <Trash2 className="h-4 w-4" />
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Delete Group</DialogTitle>
                <DialogDescription>
                  Are you sure you want to delete group &quot;{g.name}&quot;?
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
                  disabled={deleteGroup.isPending}
                >
                  {deleteGroup.isPending && (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  )}
                  Delete
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </div>
      </div>

      {/* Edit dialog */}
      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Rename Group</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="editGroupName">Group Name</Label>
              <Input
                id="editGroupName"
                value={editName}
                onChange={(e) => setEditName(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && handleUpdate()}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditOpen(false)}>
              Cancel
            </Button>
            <Button
              onClick={handleUpdate}
              disabled={!editName.trim() || updateGroup.isPending}
            >
              {updateGroup.isPending && (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              )}
              Save
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Members */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Members</CardTitle>
          <CardDescription>
            {g.members?.length ?? 0} member
            {(g.members?.length ?? 0) !== 1 ? "s" : ""} in this group
          </CardDescription>
        </CardHeader>
        <CardContent>
          {(g.members ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground text-center py-8">
              No members in this group. Add users from the{" "}
              <Link to="/users" className="text-primary hover:underline">
                Users
              </Link>{" "}
              page.
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Username</TableHead>
                  <TableHead>Email</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="w-[60px]" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {(g.members ?? []).map((member) => (
                  <TableRow key={member.id}>
                    <TableCell>
                      <Link
                        to={`/users/${member.id}`}
                        className="font-medium text-primary hover:underline"
                      >
                        {member.username}
                      </Link>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {member.email}
                    </TableCell>
                    <TableCell>
                      {member.enabled ? (
                        <Badge variant="success">Active</Badge>
                      ) : (
                        <Badge variant="destructive">Disabled</Badge>
                      )}
                    </TableCell>
                    <TableCell>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-8 w-8 text-muted-foreground hover:text-destructive"
                        onClick={() => handleRemoveMember(member.id)}
                      >
                        <UserMinus className="h-4 w-4" />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
