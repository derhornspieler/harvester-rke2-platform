import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
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
import { useLoginEvents, useUsers } from "@/hooks/use-api";
import { formatDate } from "@/lib/utils";

export function ReportsPage() {
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [userFilter, setUserFilter] = useState("");

  const loginEvents = useLoginEvents({
    dateFrom: dateFrom || undefined,
    dateTo: dateTo || undefined,
    user: userFilter || undefined,
  });

  const failedEvents = useLoginEvents({
    type: "LOGIN_ERROR",
    dateFrom: dateFrom || undefined,
    dateTo: dateTo || undefined,
    user: userFilter || undefined,
  });

  const allUsers = useUsers({ max: 1000 });

  // Compute MFA stats from users
  const users = allUsers.data?.users ?? [];
  const usersWithMfa = users.filter((u) => u.mfaStatus?.enrolled);
  const usersWithoutMfa = users.filter((u) => !u.mfaStatus?.enrolled);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Reports</h1>
        <p className="text-muted-foreground">
          Login activity, failed logins, and MFA enrollment status
        </p>
      </div>

      {/* Filters */}
      <Card>
        <CardContent className="pt-6">
          <div className="flex flex-wrap gap-4">
            <div className="space-y-1">
              <Label htmlFor="dateFrom" className="text-xs">
                From
              </Label>
              <Input
                id="dateFrom"
                type="date"
                value={dateFrom}
                onChange={(e) => setDateFrom(e.target.value)}
                className="w-[160px]"
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="dateTo" className="text-xs">
                To
              </Label>
              <Input
                id="dateTo"
                type="date"
                value={dateTo}
                onChange={(e) => setDateTo(e.target.value)}
                className="w-[160px]"
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="userFilter" className="text-xs">
                User
              </Label>
              <Input
                id="userFilter"
                value={userFilter}
                onChange={(e) => setUserFilter(e.target.value)}
                placeholder="Filter by username"
                className="w-[200px]"
              />
            </div>
          </div>
        </CardContent>
      </Card>

      <Tabs defaultValue="logins">
        <TabsList>
          <TabsTrigger value="logins">Login Activity</TabsTrigger>
          <TabsTrigger value="failed">Failed Logins</TabsTrigger>
          <TabsTrigger value="mfa">MFA Status</TabsTrigger>
        </TabsList>

        {/* Login Activity */}
        <TabsContent value="logins">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Login Events</CardTitle>
            </CardHeader>
            <CardContent>
              {loginEvents.isLoading ? (
                <div className="space-y-2">
                  {Array.from({ length: 10 }).map((_, i) => (
                    <Skeleton key={i} className="h-10 w-full" />
                  ))}
                </div>
              ) : loginEvents.error ? (
                <QueryError
                  error={loginEvents.error}
                  onRetry={() => loginEvents.refetch()}
                />
              ) : (loginEvents.data ?? []).length === 0 ? (
                <p className="text-sm text-muted-foreground text-center py-8">
                  No login events found for the selected filters
                </p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Time</TableHead>
                      <TableHead>User</TableHead>
                      <TableHead>Type</TableHead>
                      <TableHead>IP Address</TableHead>
                      <TableHead>Client</TableHead>
                      <TableHead>Status</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(loginEvents.data ?? []).map((event, i) => (
                      <TableRow key={`${event.time}-${i}`}>
                        <TableCell className="text-xs">
                          {formatDate(
                            new Date(event.time).toISOString(),
                          )}
                        </TableCell>
                        <TableCell className="font-medium text-sm">
                          {event.username || "-"}
                        </TableCell>
                        <TableCell className="text-sm">
                          {event.type.replace(/_/g, " ")}
                        </TableCell>
                        <TableCell className="font-mono text-xs">
                          {event.ipAddress}
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground">
                          {event.clientId}
                        </TableCell>
                        <TableCell>
                          {event.error ? (
                            <Badge variant="destructive">
                              {event.error}
                            </Badge>
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
        </TabsContent>

        {/* Failed Logins */}
        <TabsContent value="failed">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Failed Login Attempts</CardTitle>
            </CardHeader>
            <CardContent>
              {failedEvents.isLoading ? (
                <div className="space-y-2">
                  {Array.from({ length: 8 }).map((_, i) => (
                    <Skeleton key={i} className="h-10 w-full" />
                  ))}
                </div>
              ) : failedEvents.error ? (
                <QueryError
                  error={failedEvents.error}
                  onRetry={() => failedEvents.refetch()}
                />
              ) : (failedEvents.data ?? []).length === 0 ? (
                <p className="text-sm text-muted-foreground text-center py-8">
                  No failed login attempts found
                </p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Time</TableHead>
                      <TableHead>User</TableHead>
                      <TableHead>IP Address</TableHead>
                      <TableHead>Client</TableHead>
                      <TableHead>Error</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(failedEvents.data ?? []).map((event, i) => (
                      <TableRow key={`${event.time}-${i}`}>
                        <TableCell className="text-xs">
                          {formatDate(
                            new Date(event.time).toISOString(),
                          )}
                        </TableCell>
                        <TableCell className="font-medium text-sm">
                          {event.username || "-"}
                        </TableCell>
                        <TableCell className="font-mono text-xs">
                          {event.ipAddress}
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground">
                          {event.clientId}
                        </TableCell>
                        <TableCell>
                          <Badge variant="destructive">
                            {event.error ?? "Unknown"}
                          </Badge>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* MFA Status */}
        <TabsContent value="mfa">
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <Card>
              <CardHeader>
                <CardTitle className="text-base">
                  MFA Enrolled ({usersWithMfa.length})
                </CardTitle>
              </CardHeader>
              <CardContent>
                {allUsers.isLoading ? (
                  <div className="space-y-2">
                    {Array.from({ length: 5 }).map((_, i) => (
                      <Skeleton key={i} className="h-8 w-full" />
                    ))}
                  </div>
                ) : allUsers.error ? (
                  <QueryError
                    error={allUsers.error}
                    onRetry={() => allUsers.refetch()}
                  />
                ) : usersWithMfa.length === 0 ? (
                  <p className="text-sm text-muted-foreground text-center py-4">
                    No users with MFA enrolled
                  </p>
                ) : (
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Username</TableHead>
                        <TableHead>Email</TableHead>
                        <TableHead>Type</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {usersWithMfa.map((user) => (
                        <TableRow key={user.id}>
                          <TableCell className="font-medium text-sm">
                            {user.username}
                          </TableCell>
                          <TableCell className="text-xs text-muted-foreground">
                            {user.email}
                          </TableCell>
                          <TableCell>
                            <Badge variant="success">
                              {user.mfaStatus?.type ?? "OTP"}
                            </Badge>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="text-base">
                  Not Enrolled ({usersWithoutMfa.length})
                </CardTitle>
              </CardHeader>
              <CardContent>
                {allUsers.isLoading ? (
                  <div className="space-y-2">
                    {Array.from({ length: 5 }).map((_, i) => (
                      <Skeleton key={i} className="h-8 w-full" />
                    ))}
                  </div>
                ) : allUsers.error ? (
                  <QueryError
                    error={allUsers.error}
                    onRetry={() => allUsers.refetch()}
                  />
                ) : usersWithoutMfa.length === 0 ? (
                  <p className="text-sm text-muted-foreground text-center py-4">
                    All users have MFA enrolled
                  </p>
                ) : (
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Username</TableHead>
                        <TableHead>Email</TableHead>
                        <TableHead>Status</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {usersWithoutMfa.map((user) => (
                        <TableRow key={user.id}>
                          <TableCell className="font-medium text-sm">
                            {user.username}
                          </TableCell>
                          <TableCell className="text-xs text-muted-foreground">
                            {user.email}
                          </TableCell>
                          <TableCell>
                            <Badge variant="outline">Not enrolled</Badge>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                )}
              </CardContent>
            </Card>
          </div>
        </TabsContent>
      </Tabs>
    </div>
  );
}
