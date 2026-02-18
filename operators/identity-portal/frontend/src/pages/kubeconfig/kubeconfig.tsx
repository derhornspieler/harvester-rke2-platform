import {
  CheckCircle,
  Download,
  Loader2,
  Terminal,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { toast } from "@/components/ui/toast";
import { useDownloadKubeconfig, useDownloadCACert } from "@/hooks/use-api";

export function KubeconfigPage() {
  const downloadKubeconfig = useDownloadKubeconfig();
  const downloadCA = useDownloadCACert();

  const handleDownloadKubeconfig = async () => {
    try {
      await downloadKubeconfig.mutateAsync();
      toast({ title: "Kubeconfig downloaded", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to download kubeconfig",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  const handleDownloadCA = async () => {
    try {
      await downloadCA.mutateAsync();
      toast({ title: "CA certificate downloaded", variant: "success" });
    } catch (err) {
      toast({
        title: "Failed to download CA certificate",
        description: err instanceof Error ? err.message : "Unknown error",
        variant: "destructive",
      });
    }
  };

  return (
    <div className="space-y-6 max-w-3xl">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Kubeconfig</h1>
        <p className="text-muted-foreground">
          Download your kubeconfig file for cluster access via kubectl
        </p>
      </div>

      {/* Download card */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Download className="h-5 w-5" />
            Download Files
          </CardTitle>
          <CardDescription>
            Get the files needed to access the Kubernetes cluster
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex flex-col sm:flex-row gap-3">
            <Button
              onClick={handleDownloadKubeconfig}
              disabled={downloadKubeconfig.isPending}
              className="flex-1"
            >
              {downloadKubeconfig.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <Download className="mr-2 h-4 w-4" />
              )}
              Download Kubeconfig
            </Button>
            <Button
              variant="outline"
              onClick={handleDownloadCA}
              disabled={downloadCA.isPending}
            >
              {downloadCA.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <Download className="mr-2 h-4 w-4" />
              )}
              Download CA Certificate
            </Button>
          </div>
          <p className="text-xs text-muted-foreground">
            The kubeconfig file is configured for OIDC authentication via
            Keycloak. You will need the kubelogin plugin installed.
          </p>
        </CardContent>
      </Card>

      {/* Setup instructions */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Terminal className="h-5 w-5" />
            Setup Instructions
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="space-y-4">
            <div className="flex gap-3">
              <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border bg-muted text-xs font-bold">
                1
              </div>
              <div className="space-y-2">
                <p className="text-sm font-medium">
                  Install the kubelogin (OIDC) plugin
                </p>
                <div className="rounded-md bg-muted p-3">
                  <code className="text-xs font-mono">
                    # Using krew (kubectl plugin manager)
                    <br />
                    kubectl krew install oidc-login
                    <br />
                    <br />
                    # Or download from GitHub releases
                    <br />
                    # https://github.com/int128/kubelogin/releases
                  </code>
                </div>
              </div>
            </div>

            <Separator />

            <div className="flex gap-3">
              <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border bg-muted text-xs font-bold">
                2
              </div>
              <div className="space-y-2">
                <p className="text-sm font-medium">
                  Save the kubeconfig file
                </p>
                <div className="rounded-md bg-muted p-3">
                  <code className="text-xs font-mono">
                    # Move the downloaded file to the kubectl config directory
                    <br />
                    mv ~/Downloads/kubeconfig.yaml ~/.kube/config
                    <br />
                    <br />
                    # Or merge with existing config
                    <br />
                    export KUBECONFIG=~/.kube/config:~/Downloads/kubeconfig.yaml
                    <br />
                    kubectl config view --merge --flatten &gt;
                    ~/.kube/config.merged
                    <br />
                    mv ~/.kube/config.merged ~/.kube/config
                  </code>
                </div>
              </div>
            </div>

            <Separator />

            <div className="flex gap-3">
              <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border bg-muted text-xs font-bold">
                3
              </div>
              <div className="space-y-2">
                <p className="text-sm font-medium">
                  Set the KUBECONFIG environment variable
                </p>
                <div className="rounded-md bg-muted p-3">
                  <code className="text-xs font-mono">
                    export KUBECONFIG=~/.kube/config
                  </code>
                </div>
                <p className="text-xs text-muted-foreground">
                  Add this to your shell profile (~/.bashrc, ~/.zshrc) for
                  persistence
                </p>
              </div>
            </div>

            <Separator />

            <div className="flex gap-3">
              <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border bg-muted text-xs font-bold">
                4
              </div>
              <div className="space-y-2">
                <p className="text-sm font-medium">
                  Verify cluster access
                </p>
                <div className="rounded-md bg-muted p-3">
                  <code className="text-xs font-mono">
                    # This will open your browser for OIDC login on first use
                    <br />
                    kubectl get nodes
                    <br />
                    <br />
                    # Check your identity
                    <br />
                    kubectl auth whoami
                  </code>
                </div>
              </div>
            </div>
          </div>

          <Separator />

          <div className="space-y-2">
            <div className="flex items-center gap-2">
              <CheckCircle className="h-4 w-4 text-success" />
              <p className="text-sm font-medium">How it works</p>
            </div>
            <p className="text-xs text-muted-foreground leading-relaxed">
              The kubeconfig is configured to use OIDC authentication via
              Keycloak. When you run a kubectl command, the kubelogin plugin
              opens your browser for authentication. After login, it obtains an
              OIDC token which is sent to the Kubernetes API server. The API
              server validates the token with Keycloak and maps your groups and
              roles to Kubernetes RBAC permissions.
            </p>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
