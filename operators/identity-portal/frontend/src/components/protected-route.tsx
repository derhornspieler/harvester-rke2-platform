import { type ReactNode } from "react";
import { Navigate } from "react-router";
import { useAuth } from "@/hooks/use-auth";
import { Loading } from "@/components/loading";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";

interface ProtectedRouteProps {
  children: ReactNode;
}

export function ProtectedRoute({ children }: ProtectedRouteProps) {
  const { isAuthenticated, isLoading, login, error } = useAuth();

  if (isLoading) {
    return <Loading fullPage message="Authenticating..." />;
  }

  if (error) {
    return (
      <div className="flex h-screen w-full items-center justify-center">
        <div className="text-center space-y-4 max-w-md">
          <AlertTriangle className="h-12 w-12 text-destructive mx-auto" />
          <h2 className="text-lg font-semibold">Authentication Error</h2>
          <p className="text-sm text-muted-foreground">{error}</p>
          <div className="flex gap-3 justify-center">
            <Button variant="outline" asChild>
              <a href="/">Return Home</a>
            </Button>
            <Button onClick={login}>Try Again</Button>
          </div>
        </div>
      </div>
    );
  }

  if (!isAuthenticated) {
    return <Navigate to="/" replace />;
  }

  return <>{children}</>;
}
