import { Shield } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { QueryError } from "@/components/error-boundary";
import { useRoles } from "@/hooks/use-api";

export function RolesListPage() {
  const roles = useRoles();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Roles</h1>
        <p className="text-muted-foreground">
          View realm roles configured in Keycloak
        </p>
      </div>

      {roles.error ? (
        <QueryError error={roles.error} onRetry={() => roles.refetch()} />
      ) : roles.isLoading ? (
        <div className="space-y-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <Skeleton key={i} className="h-12 w-full" />
          ))}
        </div>
      ) : (roles.data ?? []).length === 0 ? (
        <Card>
          <CardContent className="py-12 text-center">
            <Shield className="h-12 w-12 text-muted-foreground mx-auto mb-4" />
            <p className="text-muted-foreground">No roles found</p>
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Realm Roles</CardTitle>
            <CardDescription>
              {(roles.data ?? []).length} role
              {(roles.data ?? []).length !== 1 ? "s" : ""} configured
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Description</TableHead>
                  <TableHead>Type</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(roles.data ?? []).map((role) => (
                  <TableRow key={role.id}>
                    <TableCell className="font-medium">
                      <div className="flex items-center gap-2">
                        <Shield className="h-4 w-4 text-primary" />
                        {role.name}
                      </div>
                    </TableCell>
                    <TableCell className="text-muted-foreground text-sm">
                      {role.description || "-"}
                    </TableCell>
                    <TableCell>
                      {role.composite ? (
                        <Badge variant="secondary">Composite</Badge>
                      ) : role.clientRole ? (
                        <Badge variant="outline">Client</Badge>
                      ) : (
                        <Badge>Realm</Badge>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
