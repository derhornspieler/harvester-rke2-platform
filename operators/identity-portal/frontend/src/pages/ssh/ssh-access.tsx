import { useState, useRef } from "react";
import {
  Check,
  Clipboard,
  Download,
  KeyRound,
  Loader2,
  Plus,
  Terminal,
  Trash2,
  Upload,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { toast } from "@/components/ui/toast";
import { QueryError } from "@/components/error-boundary";
import { useAuth } from "@/hooks/use-auth";
import {
  useSelfSSHPublicKey,
  useRegisterSSHPublicKey,
  useDeleteSSHPublicKey,
  useRequestSSHCertificate,
  useSSHRoles,
  useCreateSSHRole,
  useDeleteSSHRole,
} from "@/hooks/use-api";
import type { SSHCertificateResponse } from "@/lib/types";

export function SSHAccessPage() {
  const { isAdmin } = useAuth();
  const sshKey = useSelfSSHPublicKey();
  const registerKey = useRegisterSSHPublicKey();
  const removeKey = useDeleteSSHPublicKey();
  const requestCert = useRequestSSHCertificate();
  const sshRoles = useSSHRoles();
  const createRole = useCreateSSHRole();
  const deleteRole = useDeleteSSHRole();

  const [publicKey, setPublicKey] = useState("");
  const [registerKeyInput, setRegisterKeyInput] = useState("");
  const [certResult, setCertResult] = useState<SSHCertificateResponse | null>(
    null,
  );
  const [copied, setCopied] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const registerFileRef = useRef<HTMLInputElement>(null);

  // Create role state
  const [createRoleOpen, setCreateRoleOpen] = useState(false);
  const [roleName, setRoleName] = useState("");
  const [roleTtl, setRoleTtl] = useState("8h");
  const [roleMaxTtl, setRoleMaxTtl] = useState("24h");
  const [roleDefaultUser, setRoleDefaultUser] = useState("");
  const [roleAllowedUsers, setRoleAllowedUsers] = useState("*");

  // Delete state
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState("");

  const handleFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      const content = ev.target?.result;
      if (typeof content === "string") {
        setPublicKey(content.trim());
      }
    };
    reader.readAsText(file);
    // Reset file input
    e.target.value = "";
  };

  const handleRegisterFileUpload = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      const content = ev.target?.result;
      if (typeof content === "string") {
        setRegisterKeyInput(content.trim());
      }
    };
    reader.readAsText(file);
    e.target.value = "";
  };

  const handleRegisterKey = async () => {
    const key = registerKeyInput.trim();
    if (!key) return;

    if (!key.startsWith("ssh-ed25519") && !key.startsWith("ssh-rsa")) {
      toast({
        title: "Unsupported key type",
        description: "Only ed25519 (recommended) and RSA 4096 keys are accepted",
        variant: "destructive",
      });
      return;
    }

    try {
      await registerKey.mutateAsync(key);
      setRegisterKeyInput("");
      toast({ title: "SSH public key registered", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to register key",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleRemoveKey = async () => {
    try {
      await removeKey.mutateAsync();
      toast({ title: "SSH public key removed", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to remove key",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleRequestCert = async () => {
    if (!publicKey.trim()) {
      toast({
        title: "Public key required",
        description: "Please paste your SSH public key or upload a file",
        variant: "destructive",
      });
      return;
    }

    if (
      !publicKey.trim().startsWith("ssh-") &&
      !publicKey.trim().startsWith("ecdsa-")
    ) {
      toast({
        title: "Invalid public key",
        description:
          "The key should start with ssh-rsa, ssh-ed25519, ecdsa-sha2, etc.",
        variant: "destructive",
      });
      return;
    }

    try {
      const result = await requestCert.mutateAsync({
        publicKey: publicKey.trim(),
      });
      setCertResult(result);
      toast({ title: "Certificate signed successfully", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to sign certificate",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleCopyCert = async () => {
    if (!certResult?.signedCertificate) return;
    try {
      await navigator.clipboard.writeText(certResult.signedCertificate);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast({
        title: "Failed to copy",
        description: "Please select and copy the certificate manually",
        variant: "destructive",
      });
    }
  };

  const handleCreateRole = async () => {
    if (!roleName.trim()) return;
    try {
      await createRole.mutateAsync({
        name: roleName.trim(),
        ttl: roleTtl,
        maxTtl: roleMaxTtl,
        defaultUser: roleDefaultUser,
        allowedUsers: roleAllowedUsers,
        allowedExtensions: "permit-pty,permit-agent-forwarding",
        defaultExtensions: { "permit-pty": "" },
        keyTypeAllowed: "ca",
      });
      toast({ title: "SSH role created", variant: "success" });
      setCreateRoleOpen(false);
      setRoleName("");
    } catch (err) {
      toast({
        title: "Failed to create SSH role",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleDeleteRole = async () => {
    if (!deleteTarget) return;
    try {
      await deleteRole.mutateAsync(deleteTarget);
      toast({ title: "SSH role deleted", variant: "success" });
      setDeleteDialogOpen(false);
    } catch (err) {
      toast({
        title: "Failed to delete SSH role",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">SSH Access</h1>
        <p className="text-muted-foreground">
          Request SSH certificates and manage SSH signing roles
        </p>
      </div>

      {/* SSH Public Key Registration */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <KeyRound className="h-5 w-5" />
            Registered SSH Public Key
          </CardTitle>
          <CardDescription>
            Register your SSH public key to enable certificate signing. Only
            ed25519 (recommended) or RSA 4096 keys are accepted.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {sshKey.isLoading ? (
            <Skeleton className="h-16 w-full" />
          ) : sshKey.data?.publicKey ? (
            <div className="space-y-3">
              <div className="rounded-lg border p-3 bg-muted/30">
                <p className="text-xs text-muted-foreground mb-1">
                  Fingerprint
                </p>
                <p className="text-sm font-mono">{sshKey.data.fingerprint}</p>
                {sshKey.data.registeredAt && (
                  <p className="text-xs text-muted-foreground mt-2">
                    Registered:{" "}
                    {new Date(sshKey.data.registeredAt).toLocaleString()}
                  </p>
                )}
              </div>
              <div className="bg-background rounded border p-3 max-h-[80px] overflow-auto">
                <pre className="text-xs font-mono whitespace-pre-wrap break-all">
                  {sshKey.data.publicKey}
                </pre>
              </div>
              <Button
                variant="destructive"
                size="sm"
                onClick={handleRemoveKey}
                disabled={removeKey.isPending}
              >
                <Trash2 className="mr-2 h-3 w-3" />
                {removeKey.isPending ? "Removing..." : "Remove Key"}
              </Button>
            </div>
          ) : (
            <div className="space-y-3">
              <Textarea
                value={registerKeyInput}
                onChange={(e) => setRegisterKeyInput(e.target.value)}
                placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... user@host"
                className="font-mono text-xs min-h-[80px]"
              />
              <div className="flex items-center gap-2">
                <input
                  type="file"
                  ref={registerFileRef}
                  onChange={handleRegisterFileUpload}
                  className="hidden"
                  accept=".pub"
                />
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => registerFileRef.current?.click()}
                >
                  <Upload className="mr-2 h-3 w-3" />
                  Upload .pub file
                </Button>
                <Button
                  size="sm"
                  onClick={handleRegisterKey}
                  disabled={registerKey.isPending || !registerKeyInput.trim()}
                >
                  {registerKey.isPending && (
                    <Loader2 className="mr-2 h-3 w-3 animate-spin" />
                  )}
                  Register Key
                </Button>
              </div>
              <p className="text-xs text-muted-foreground">
                Only your registered key can be used for certificate signing.
                Use{" "}
                <code className="bg-muted px-1 rounded">
                  ssh-keygen -t ed25519
                </code>{" "}
                to generate a key pair.
              </p>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Certificate Request */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Terminal className="h-5 w-5" />
            Request SSH Certificate
          </CardTitle>
          <CardDescription>
            Submit your SSH public key to get a signed certificate for cluster
            access
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="publicKey">SSH Public Key</Label>
            <Textarea
              id="publicKey"
              value={publicKey}
              onChange={(e) => setPublicKey(e.target.value)}
              placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... user@host"
              className="font-mono text-xs min-h-[80px]"
            />
            <div className="flex items-center gap-2">
              <input
                type="file"
                ref={fileInputRef}
                onChange={handleFileUpload}
                className="hidden"
                accept=".pub"
              />
              <Button
                variant="outline"
                size="sm"
                onClick={() => fileInputRef.current?.click()}
              >
                <Upload className="mr-2 h-3 w-3" />
                Upload .pub file
              </Button>
              <span className="text-xs text-muted-foreground">
                Typically ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
              </span>
            </div>
          </div>

          <Button
            onClick={handleRequestCert}
            disabled={requestCert.isPending || !publicKey.trim()}
          >
            {requestCert.isPending && (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            )}
            Sign Certificate
          </Button>

          {/* Certificate result */}
          {certResult && (
            <div className="mt-4 space-y-4 rounded-lg border p-4 bg-muted/30">
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-semibold">
                  Signed Certificate
                </h3>
                <Button variant="outline" size="sm" onClick={handleCopyCert}>
                  {copied ? (
                    <>
                      <Check className="mr-1 h-3 w-3" />
                      Copied
                    </>
                  ) : (
                    <>
                      <Clipboard className="mr-1 h-3 w-3" />
                      Copy
                    </>
                  )}
                </Button>
              </div>

              <div className="bg-background rounded border p-3 max-h-[150px] overflow-auto">
                <pre className="text-xs font-mono whitespace-pre-wrap break-all">
                  {certResult.signedCertificate}
                </pre>
              </div>

              <div className="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <p className="text-xs text-muted-foreground">Principals</p>
                  <div className="flex flex-wrap gap-1 mt-1">
                    {certResult.principals.map((p) => (
                      <Badge key={p} variant="secondary">
                        {p}
                      </Badge>
                    ))}
                  </div>
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">TTL</p>
                  <p className="font-medium">{certResult.ttl}</p>
                </div>
              </div>

              <Separator />

              <div className="space-y-2">
                <p className="text-sm font-medium">Usage Instructions</p>
                <ol className="text-xs text-muted-foreground space-y-1 list-decimal list-inside">
                  <li>
                    Save the certificate to a file, e.g.,{" "}
                    <code className="bg-muted px-1 rounded">
                      ~/.ssh/id_ed25519-cert.pub
                    </code>
                  </li>
                  <li>
                    Ensure your private key is at{" "}
                    <code className="bg-muted px-1 rounded">
                      ~/.ssh/id_ed25519
                    </code>
                  </li>
                  <li>
                    Connect:{" "}
                    <code className="bg-muted px-1 rounded">
                      ssh -i ~/.ssh/id_ed25519 user@host
                    </code>
                  </li>
                  <li>SSH will automatically use the certificate if present</li>
                </ol>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {/* CLI Tool */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Terminal className="h-5 w-5" />
            CLI Tool
          </CardTitle>
          <CardDescription>
            <code className="bg-muted px-1 rounded">identity-ssh-sign</code>{" "}
            automates certificate signing — authenticate via browser, sign your
            key, and install the certificate in one command.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <a href="/api/v1/cli/identity-ssh-sign" download="identity-ssh-sign">
            <Button variant="outline" size="sm">
              <Download className="mr-2 h-3 w-3" />
              Download identity-ssh-sign
            </Button>
          </a>

          <div className="space-y-2">
            <p className="text-sm font-medium">Install</p>
            <div className="bg-background rounded border p-3">
              <pre className="text-xs font-mono whitespace-pre-wrap">{`curl -sL ${window.location.origin}/api/v1/cli/identity-ssh-sign -o identity-ssh-sign
chmod +x identity-ssh-sign
sudo mv identity-ssh-sign /usr/local/bin/`}</pre>
            </div>
          </div>

          <div className="space-y-2">
            <p className="text-sm font-medium">Usage</p>
            <div className="bg-background rounded border p-3">
              <pre className="text-xs font-mono">{`identity-ssh-sign -s ${window.location.origin}`}</pre>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Admin: SSH Roles */}
      {isAdmin && (
        <Card>
          <CardHeader className="flex flex-row items-center justify-between">
            <div>
              <CardTitle className="text-base">SSH Signing Roles</CardTitle>
              <CardDescription>
                Manage Vault SSH certificate signing roles
              </CardDescription>
            </div>
            <Dialog open={createRoleOpen} onOpenChange={setCreateRoleOpen}>
              <DialogTrigger asChild>
                <Button size="sm">
                  <Plus className="mr-2 h-3 w-3" />
                  New Role
                </Button>
              </DialogTrigger>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>Create SSH Role</DialogTitle>
                  <DialogDescription>
                    Define a new SSH certificate signing role
                  </DialogDescription>
                </DialogHeader>
                <div className="space-y-4 py-4">
                  <div className="space-y-2">
                    <Label>Role Name</Label>
                    <Input
                      value={roleName}
                      onChange={(e) => setRoleName(e.target.value)}
                      placeholder="default-role"
                    />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <div className="space-y-2">
                      <Label>TTL</Label>
                      <Input
                        value={roleTtl}
                        onChange={(e) => setRoleTtl(e.target.value)}
                        placeholder="8h"
                      />
                    </div>
                    <div className="space-y-2">
                      <Label>Max TTL</Label>
                      <Input
                        value={roleMaxTtl}
                        onChange={(e) => setRoleMaxTtl(e.target.value)}
                        placeholder="24h"
                      />
                    </div>
                  </div>
                  <div className="space-y-2">
                    <Label>Default User</Label>
                    <Input
                      value={roleDefaultUser}
                      onChange={(e) => setRoleDefaultUser(e.target.value)}
                      placeholder="ubuntu"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label>Allowed Users</Label>
                    <Input
                      value={roleAllowedUsers}
                      onChange={(e) => setRoleAllowedUsers(e.target.value)}
                      placeholder="*"
                    />
                  </div>
                </div>
                <DialogFooter>
                  <Button
                    variant="outline"
                    onClick={() => setCreateRoleOpen(false)}
                  >
                    Cancel
                  </Button>
                  <Button
                    onClick={handleCreateRole}
                    disabled={!roleName.trim() || createRole.isPending}
                  >
                    {createRole.isPending && (
                      <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    )}
                    Create
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
          </CardHeader>
          <CardContent>
            {sshRoles.error ? (
              <QueryError
                error={sshRoles.error}
                onRetry={() => sshRoles.refetch()}
              />
            ) : sshRoles.isLoading ? (
              <div className="space-y-2">
                {Array.from({ length: 3 }).map((_, i) => (
                  <Skeleton key={i} className="h-10 w-full" />
                ))}
              </div>
            ) : (sshRoles.data ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground text-center py-8">
                No SSH roles configured
              </p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Name</TableHead>
                    <TableHead>Default User</TableHead>
                    <TableHead>Allowed Users</TableHead>
                    <TableHead>TTL</TableHead>
                    <TableHead>Max TTL</TableHead>
                    <TableHead className="w-[60px]" />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(sshRoles.data ?? []).map((role) => (
                    <TableRow key={role.name}>
                      <TableCell className="font-medium">
                        {role.name}
                      </TableCell>
                      <TableCell className="text-sm">
                        {role.defaultUser || "-"}
                      </TableCell>
                      <TableCell className="text-sm font-mono">
                        {role.allowedUsers || "*"}
                      </TableCell>
                      <TableCell className="text-sm">{role.ttl}</TableCell>
                      <TableCell className="text-sm">
                        {role.maxTtl}
                      </TableCell>
                      <TableCell>
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8 text-muted-foreground hover:text-destructive"
                          onClick={() => {
                            setDeleteTarget(role.name);
                            setDeleteDialogOpen(true);
                          }}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      )}

      {/* Delete role confirmation */}
      <Dialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete SSH Role</DialogTitle>
            <DialogDescription>
              Are you sure you want to delete SSH role &quot;{deleteTarget}
              &quot;?
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
              onClick={handleDeleteRole}
              disabled={deleteRole.isPending}
            >
              {deleteRole.isPending && (
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
