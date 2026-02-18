import { Link, useLocation } from "react-router";
import {
  BarChart3,
  Download,
  FolderKey,
  KeyRound,
  LayoutDashboard,
  Shield,
  Terminal,
  User,
  Users,
  UsersRound,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useAuth } from "@/hooks/use-auth";
import { Separator } from "@/components/ui/separator";

interface NavItem {
  label: string;
  href: string;
  icon: React.ComponentType<{ className?: string }>;
  adminOnly?: boolean;
}

const navItems: NavItem[] = [
  {
    label: "Dashboard",
    href: "/dashboard",
    icon: LayoutDashboard,
  },
  {
    label: "Users",
    href: "/users",
    icon: Users,
    adminOnly: true,
  },
  {
    label: "Groups",
    href: "/groups",
    icon: UsersRound,
    adminOnly: true,
  },
  {
    label: "Roles",
    href: "/roles",
    icon: Shield,
    adminOnly: true,
  },
  {
    label: "Vault Policies",
    href: "/vault/policies",
    icon: FolderKey,
    adminOnly: true,
  },
  {
    label: "SSH Access",
    href: "/ssh",
    icon: Terminal,
  },
  {
    label: "Kubeconfig",
    href: "/kubeconfig",
    icon: Download,
  },
  {
    label: "Reports",
    href: "/reports",
    icon: BarChart3,
    adminOnly: true,
  },
];

const selfServiceItems: NavItem[] = [
  {
    label: "Profile",
    href: "/profile",
    icon: User,
  },
];

export function Sidebar() {
  const location = useLocation();
  const { isAdmin } = useAuth();

  const isActive = (href: string) => {
    if (href === "/dashboard") return location.pathname === "/dashboard";
    return location.pathname.startsWith(href);
  };

  const filteredNavItems = navItems.filter(
    (item) => !item.adminOnly || isAdmin,
  );

  return (
    <aside className="hidden lg:flex lg:flex-col lg:w-64 lg:border-r bg-sidebar">
      <div className="flex h-14 items-center border-b px-6">
        <Link to="/dashboard" className="flex items-center gap-2">
          <KeyRound className="h-6 w-6 text-sidebar-primary" />
          <span className="font-semibold text-sidebar-foreground">
            Identity Portal
          </span>
        </Link>
      </div>

      <nav className="flex-1 overflow-y-auto py-4">
        <div className="px-3 space-y-1">
          {filteredNavItems.map((item) => (
            <Link
              key={item.href}
              to={item.href}
              className={cn(
                "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                isActive(item.href)
                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                  : "text-sidebar-foreground/70 hover:bg-sidebar-accent/50 hover:text-sidebar-accent-foreground",
              )}
            >
              <item.icon className="h-4 w-4" />
              {item.label}
            </Link>
          ))}
        </div>

        <div className="px-3 my-4">
          <Separator />
        </div>

        <div className="px-3 space-y-1">
          <p className="px-3 text-xs font-semibold text-sidebar-foreground/50 uppercase tracking-wider mb-2">
            Account
          </p>
          {selfServiceItems.map((item) => (
            <Link
              key={item.href}
              to={item.href}
              className={cn(
                "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                isActive(item.href)
                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                  : "text-sidebar-foreground/70 hover:bg-sidebar-accent/50 hover:text-sidebar-accent-foreground",
              )}
            >
              <item.icon className="h-4 w-4" />
              {item.label}
            </Link>
          ))}
        </div>
      </nav>
    </aside>
  );
}
