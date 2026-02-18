import { useNavigate } from "react-router";
import {
  Download,
  KeyRound,
  LogIn,
  Shield,
  Terminal,
  Users,
} from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/use-auth";

const features = [
  {
    icon: Users,
    title: "User & Group Management",
    description:
      "Create, update, and manage users, groups, and role assignments through a central admin console.",
  },
  {
    icon: Terminal,
    title: "SSH Certificate Authority",
    description:
      "Request short-lived SSH certificates signed by Vault. No more static authorized_keys files.",
  },
  {
    icon: Download,
    title: "Kubeconfig Generation",
    description:
      "Download a pre-configured OIDC kubeconfig for kubectl access to the cluster.",
  },
  {
    icon: Shield,
    title: "MFA Enforcement",
    description:
      "TOTP-based multi-factor authentication for all users, with enrollment tracking and admin reset.",
  },
  {
    icon: KeyRound,
    title: "Vault Policy Management",
    description:
      "View and manage HashiCorp Vault ACL policies and SSH signing roles from the browser.",
  },
];

export function LandingPage() {
  const { isAuthenticated, isLoading, login } = useAuth();
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-background">
      {/* Header */}
      <header className="border-b">
        <div className="container mx-auto flex items-center justify-between px-6 py-4">
          <div className="flex items-center gap-3">
            <Shield className="h-8 w-8 text-primary" />
            <span className="text-xl font-bold tracking-tight">
              Identity Portal
            </span>
          </div>
          {isAuthenticated ? (
            <Button onClick={() => navigate("/dashboard")}>
              Go to Dashboard
            </Button>
          ) : (
            <Button onClick={login} disabled={isLoading}>
              <LogIn className="mr-2 h-4 w-4" />
              {isLoading ? "Loading..." : "Sign in with Keycloak"}
            </Button>
          )}
        </div>
      </header>

      {/* Hero */}
      <section className="container mx-auto px-6 py-16 text-center">
        <h1 className="text-4xl font-bold tracking-tight sm:text-5xl">
          Identity & Access Management
        </h1>
        <p className="mx-auto mt-4 max-w-2xl text-lg text-muted-foreground">
          Centralized portal for user management, SSH certificate signing, and
          Kubernetes access provisioning. Powered by Keycloak and HashiCorp
          Vault.
        </p>
        <div className="mt-8" />
      </section>

      {/* Features grid */}
      <section className="container mx-auto px-6 pb-16">
        <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((feature) => (
            <Card key={feature.title}>
              <CardContent className="pt-6">
                <feature.icon className="mb-3 h-8 w-8 text-primary" />
                <h3 className="font-semibold">{feature.title}</h3>
                <p className="mt-1 text-sm text-muted-foreground">
                  {feature.description}
                </p>
              </CardContent>
            </Card>
          ))}
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t">
        <div className="container mx-auto px-6 py-6 text-center text-sm text-muted-foreground">
          RKE2 Platform &mdash; Identity Portal
        </div>
      </footer>
    </div>
  );
}
