import { useEffect } from "react";
import { useNavigate } from "react-router";
import { useAuth } from "@/hooks/use-auth";
import { Loading } from "@/components/loading";

export function LoginCallbackPage() {
  const { isAuthenticated, isLoading, error } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      navigate("/", { replace: true });
    }
  }, [isLoading, isAuthenticated, navigate]);

  if (error) {
    return (
      <div className="flex h-screen w-full items-center justify-center">
        <div className="text-center space-y-4 max-w-md">
          <h2 className="text-lg font-semibold text-destructive">
            Login Failed
          </h2>
          <p className="text-sm text-muted-foreground">{error}</p>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            Return to Home
          </a>
        </div>
      </div>
    );
  }

  return <Loading fullPage message="Completing authentication..." />;
}
