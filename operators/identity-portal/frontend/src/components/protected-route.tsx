import { type ReactNode, useEffect } from "react";
import { useAuth } from "@/hooks/use-auth";
import { Loading } from "@/components/loading";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";

interface ProtectedRouteProps {
  children: ReactNode;
}

export function ProtectedRoute({ children }: ProtectedRouteProps) {
  const { isAuthenticated, isLoading, login, error } = useAuth();

  useEffect(() => {
    if (!isLoading && !isAuthenticated && !error) {
      login();
    }
  }, [isLoading, isAuthenticated, login, error]);

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
          <Button onClick={login}>Try Again</Button>
        </div>
      </div>
    );
  }

  if (!isAuthenticated) {
    return <Loading fullPage message="Redirecting to login..." />;
  }

  return <>{children}</>;
}
