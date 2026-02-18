import { Link } from "react-router";
import { FileQuestion } from "lucide-react";
import { Button } from "@/components/ui/button";

export function NotFoundPage() {
  return (
    <div className="flex items-center justify-center py-20">
      <div className="text-center space-y-4">
        <FileQuestion className="h-16 w-16 text-muted-foreground mx-auto" />
        <h1 className="text-3xl font-bold">404</h1>
        <p className="text-muted-foreground">
          The page you are looking for does not exist.
        </p>
        <Button asChild>
          <Link to="/dashboard">Return to Dashboard</Link>
        </Button>
      </div>
    </div>
  );
}
