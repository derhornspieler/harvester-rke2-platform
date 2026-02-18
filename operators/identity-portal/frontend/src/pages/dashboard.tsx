import { Link } from "react-router";
import {
  Activity,
  Download,
  KeyRound,
  Plus,
  Shield,
  Terminal,
  Users,
  UsersRound,
} from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
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
import { QueryError } from "@/components/error-boundary";
import { useAuth } from "@/hooks/use-auth";
import { useDashboardStats, useLoginEvents } from "@/hooks/use-api";
import { formatRelativeTime } from "@/lib/utils";

function StatCard({
  title,
  value,
  icon: Icon,
  description,
  loading,
}: {
  title: string;
  value: string | number;
  icon: React.ComponentType<{ className?: string }>;
  description?: string;
  loading?: boolean;
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium">{title}</CardTitle>
        <Icon className="h-4 w-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        {loading ? (
          <Skeleton className="h-7 w-20" />
        ) : (
          <div className="text-2xl font-bold">{value}</div>
        )}
        {description && (
          <p className="text-xs text-muted-foreground mt-1">{description}</p>
        )}
      </CardContent>
    </Card>
  );
}

export function DashboardPage() {
  const { isAdmin } = useAuth();
  const stats = useDashboardStats();
  const events = useLoginEvents({});

  const recentEvents = (events.data ?? []).slice(0, 10);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Dashboard</h1>
        <p className="text-muted-foreground">
          Overview of your identity management platform
        </p>
      </div>

      {/* Stats cards */}
      {isAdmin && (
        <>
          {stats.error ? (
            <QueryError
              error={stats.error}
              onRetry={() => stats.refetch()}
              message="Failed to load statistics"
            />
          ) : (
            <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
              <StatCard
                title="Total Users"
                value={stats.data?.totalUsers ?? 0}
                icon={Users}
                loading={stats.isLoading}
              />
              <StatCard
                title="Active Sessions"
                value={stats.data?.activeSessions ?? 0}
                icon={Activity}
                loading={stats.isLoading}
              />
              <StatCard
                title="MFA Enrollment"
                value={`${stats.data?.mfaPercentage ?? 0}%`}
                icon={Shield}
                description={`${stats.data?.mfaEnrolled ?? 0} of ${stats.data?.totalUsers ?? 0} users`}
                loading={stats.isLoading}
              />
              <StatCard
                title="SSH Certs (24h)"
                value={stats.data?.sshCertsToday ?? 0}
                icon={Terminal}
                loading={stats.isLoading}
              />
              <StatCard
                title="Active Users"
                value={stats.data?.activeUsers ?? 0}
                icon={UsersRound}
                loading={stats.isLoading}
              />
              <StatCard
                title="Kubeconfigs"
                value="-"
                icon={Download}
                description="Download count"
                loading={stats.isLoading}
              />
            </div>
          )}
        </>
      )}

      {/* Quick actions */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Quick Actions</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-3">
          {isAdmin && (
            <Button asChild>
              <Link to="/users/create">
                <Plus className="mr-2 h-4 w-4" />
                Create User
              </Link>
            </Button>
          )}
          <Button asChild variant="outline">
            <Link to="/ssh">
              <Terminal className="mr-2 h-4 w-4" />
              Request SSH Certificate
            </Link>
          </Button>
          <Button asChild variant="outline">
            <Link to="/kubeconfig">
              <Download className="mr-2 h-4 w-4" />
              Download Kubeconfig
            </Link>
          </Button>
          <Button asChild variant="outline">
            <Link to="/profile">
              <KeyRound className="mr-2 h-4 w-4" />
              My Profile
            </Link>
          </Button>
        </CardContent>
      </Card>

      {/* Recent login activity (admin only) */}
      {isAdmin && (
        <Card>
          <CardHeader className="flex flex-row items-center justify-between">
            <CardTitle className="text-base">Recent Login Activity</CardTitle>
            <Button asChild variant="ghost" size="sm">
              <Link to="/reports">View All</Link>
            </Button>
          </CardHeader>
          <CardContent>
            {events.isLoading ? (
              <div className="space-y-3">
                {Array.from({ length: 5 }).map((_, i) => (
                  <Skeleton key={i} className="h-10 w-full" />
                ))}
              </div>
            ) : events.error ? (
              <QueryError
                error={events.error}
                onRetry={() => events.refetch()}
                message="Failed to load events"
              />
            ) : recentEvents.length === 0 ? (
              <p className="text-sm text-muted-foreground text-center py-8">
                No recent login events
              </p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Time</TableHead>
                    <TableHead>User</TableHead>
                    <TableHead>Type</TableHead>
                    <TableHead>IP Address</TableHead>
                    <TableHead>Status</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {recentEvents.map((event, i) => (
                    <TableRow key={`${event.time}-${i}`}>
                      <TableCell className="text-xs text-muted-foreground">
                        {formatRelativeTime(
                          new Date(event.time).toISOString(),
                        )}
                      </TableCell>
                      <TableCell className="font-medium text-sm">
                        {event.username || "-"}
                      </TableCell>
                      <TableCell className="text-sm">
                        {event.type.replace(/_/g, " ")}
                      </TableCell>
                      <TableCell className="text-sm font-mono">
                        {event.ipAddress}
                      </TableCell>
                      <TableCell>
                        {event.error ? (
                          <Badge variant="destructive">Failed</Badge>
                        ) : (
                          <Badge variant="success">Success</Badge>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
