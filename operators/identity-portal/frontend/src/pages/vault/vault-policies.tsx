import { useState } from "react";
import { FileCode, Loader2, Plus, Save, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
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
import { Skeleton } from "@/components/ui/skeleton";
import { toast } from "@/components/ui/toast";
import { QueryError } from "@/components/error-boundary";
import {
  useVaultPolicies,
  useVaultPolicy,
  useCreateVaultPolicy,
  useDeleteVaultPolicy,
} from "@/hooks/use-api";

const DEFAULT_HCL = `# Example Vault policy
path "secret/data/{{identity.entity.aliases.auth_oidc_*.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/{{identity.entity.aliases.auth_oidc_*.name}}/*" {
  capabilities = ["list"]
}
`;

export function VaultPoliciesPage() {
  const policies = useVaultPolicies();
  const createPolicy = useCreateVaultPolicy();
  const deletePolicy = useDeleteVaultPolicy();

  const [selectedPolicy, setSelectedPolicy] = useState<string>("");
  const [editContent, setEditContent] = useState("");
  const [createOpen, setCreateOpen] = useState(false);
  const [newPolicyName, setNewPolicyName] = useState("");
  const [newPolicyContent, setNewPolicyContent] = useState(DEFAULT_HCL);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState("");

  const policyDetail = useVaultPolicy(selectedPolicy);

  const handleSelectPolicy = (name: string) => {
    setSelectedPolicy(name);
  };

  // When policy detail loads, set edit content
  const currentContent = policyDetail.data?.policy ?? "";
  if (currentContent && editContent !== currentContent && selectedPolicy) {
    setEditContent(currentContent);
  }

  const handleSave = async () => {
    if (!selectedPolicy) return;
    try {
      await createPolicy.mutateAsync({
        name: selectedPolicy,
        policy: editContent,
      });
      toast({ title: "Policy saved", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to save policy",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleCreate = async () => {
    if (!newPolicyName.trim()) return;
    try {
      await createPolicy.mutateAsync({
        name: newPolicyName.trim(),
        policy: newPolicyContent,
      });
      toast({ title: "Policy created", variant: "success" });
      setCreateOpen(false);
      setSelectedPolicy(newPolicyName.trim());
      setEditContent(newPolicyContent);
      setNewPolicyName("");
      setNewPolicyContent(DEFAULT_HCL);
    } catch (err) {
      toast({
        title: "Failed to create policy",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    try {
      await deletePolicy.mutateAsync(deleteTarget);
      toast({ title: "Policy deleted", variant: "success" });
      setDeleteDialogOpen(false);
      if (selectedPolicy === deleteTarget) {
        setSelectedPolicy("");
        setEditContent("");
      }
    } catch (err) {
      toast({
        title: "Failed to delete policy",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">
            Vault Policies
          </h1>
          <p className="text-muted-foreground">
            Manage HashiCorp Vault HCL policies
          </p>
        </div>
        <Dialog open={createOpen} onOpenChange={setCreateOpen}>
          <DialogTrigger asChild>
            <Button>
              <Plus className="mr-2 h-4 w-4" />
              New Policy
            </Button>
          </DialogTrigger>
          <DialogContent className="max-w-2xl">
            <DialogHeader>
              <DialogTitle>Create Policy</DialogTitle>
              <DialogDescription>
                Create a new Vault HCL policy
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="policyName">Policy Name</Label>
                <Input
                  id="policyName"
                  value={newPolicyName}
                  onChange={(e) => setNewPolicyName(e.target.value)}
                  placeholder="my-policy"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="policyContent">HCL Content</Label>
                <Textarea
                  id="policyContent"
                  value={newPolicyContent}
                  onChange={(e) => setNewPolicyContent(e.target.value)}
                  className="font-mono text-sm min-h-[300px]"
                />
              </div>
            </div>
            <DialogFooter>
              <Button
                variant="outline"
                onClick={() => setCreateOpen(false)}
              >
                Cancel
              </Button>
              <Button
                onClick={handleCreate}
                disabled={
                  !newPolicyName.trim() || createPolicy.isPending
                }
              >
                {createPolicy.isPending && (
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                )}
                Create
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Policy list */}
        <Card className="lg:col-span-1">
          <CardHeader>
            <CardTitle className="text-base">Policies</CardTitle>
          </CardHeader>
          <CardContent>
            {policies.error ? (
              <QueryError
                error={policies.error}
                onRetry={() => policies.refetch()}
              />
            ) : policies.isLoading ? (
              <div className="space-y-2">
                {Array.from({ length: 4 }).map((_, i) => (
                  <Skeleton key={i} className="h-10 w-full" />
                ))}
              </div>
            ) : (policies.data ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground text-center py-4">
                No policies found
              </p>
            ) : (
              <div className="space-y-1">
                {(policies.data ?? []).map((p) => (
                  <div
                    key={p.name}
                    className={`flex items-center justify-between rounded-md px-3 py-2 text-sm cursor-pointer transition-colors ${
                      selectedPolicy === p.name
                        ? "bg-accent text-accent-foreground"
                        : "hover:bg-muted"
                    }`}
                    onClick={() => handleSelectPolicy(p.name)}
                  >
                    <div className="flex items-center gap-2">
                      <FileCode className="h-4 w-4 text-muted-foreground" />
                      <span className="font-medium">{p.name}</span>
                    </div>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-6 w-6 text-muted-foreground hover:text-destructive"
                      onClick={(e) => {
                        e.stopPropagation();
                        setDeleteTarget(p.name);
                        setDeleteDialogOpen(true);
                      }}
                    >
                      <Trash2 className="h-3 w-3" />
                    </Button>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        {/* Editor */}
        <Card className="lg:col-span-2">
          <CardHeader className="flex flex-row items-center justify-between">
            <div>
              <CardTitle className="text-base">
                {selectedPolicy ? `Editing: ${selectedPolicy}` : "Policy Editor"}
              </CardTitle>
              <CardDescription>
                {selectedPolicy
                  ? "Edit the HCL content below and save"
                  : "Select a policy to edit"}
              </CardDescription>
            </div>
            {selectedPolicy && (
              <Button
                size="sm"
                onClick={handleSave}
                disabled={createPolicy.isPending}
              >
                {createPolicy.isPending ? (
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                ) : (
                  <Save className="mr-2 h-4 w-4" />
                )}
                Save
              </Button>
            )}
          </CardHeader>
          <CardContent>
            {selectedPolicy ? (
              policyDetail.isLoading ? (
                <Skeleton className="h-[400px] w-full" />
              ) : (
                <Textarea
                  value={editContent}
                  onChange={(e) => setEditContent(e.target.value)}
                  className="font-mono text-sm min-h-[400px] resize-y"
                  placeholder="# Write your HCL policy here..."
                />
              )
            ) : (
              <div className="flex items-center justify-center h-[400px] text-muted-foreground">
                <div className="text-center">
                  <FileCode className="h-12 w-12 mx-auto mb-3 opacity-50" />
                  <p>Select a policy from the list to edit it</p>
                </div>
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Delete confirmation */}
      <Dialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete Policy</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete policy &quot;{deleteTarget}
              &quot;? This cannot be undone.
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
              disabled={deletePolicy.isPending}
            >
              {deletePolicy.isPending && (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
