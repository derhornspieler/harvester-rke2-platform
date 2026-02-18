import {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { AppConfig, TokenClaims } from "./types";
import { apiGet, setAuthHandlers } from "./api";

interface AuthState {
  isAuthenticated: boolean;
  isLoading: boolean;
  accessToken: string | null;
  refreshToken: string | null;
  user: TokenClaims | null;
  isAdmin: boolean;
  login: () => void;
  logout: () => void;
  error: string | null;
}

export const AuthContext = createContext<AuthState>({
  isAuthenticated: false,
  isLoading: true,
  accessToken: null,
  refreshToken: null,
  user: null,
  isAdmin: false,
  login: () => {},
  logout: () => {},
  error: null,
});

function decodeJwt(token: string): TokenClaims {
  const base64Url = token.split(".")[1];
  if (!base64Url) throw new Error("Invalid token format");
  const base64 = base64Url.replace(/-/g, "+").replace(/_/g, "/");
  const jsonPayload = decodeURIComponent(
    atob(base64)
      .split("")
      .map((c) => "%" + ("00" + c.charCodeAt(0).toString(16)).slice(-2))
      .join(""),
  );
  return JSON.parse(jsonPayload);
}

function isTokenExpired(claims: TokenClaims): boolean {
  return Date.now() >= claims.exp * 1000;
}

function isTokenExpiringSoon(claims: TokenClaims, marginSeconds = 60): boolean {
  return Date.now() >= (claims.exp - marginSeconds) * 1000;
}

function generateCodeVerifier(): string {
  const array = new Uint8Array(32);
  crypto.getRandomValues(array);
  return btoa(String.fromCharCode(...array))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function generateCodeChallenge(verifier: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(verifier);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function generateState(): string {
  const array = new Uint8Array(16);
  crypto.getRandomValues(array);
  return Array.from(array, (b) => b.toString(16).padStart(2, "0")).join("");
}

const ADMIN_ROLES = ["admin", "realm-admin", "identity-portal-admin"];

export function AuthProvider({ children }: { children: ReactNode }) {
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const [refreshToken, setRefreshToken] = useState<string | null>(null);
  const [user, setUser] = useState<TokenClaims | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [config, setConfig] = useState<AppConfig | null>(null);
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const initRef = useRef(false);

  const isAdmin = useMemo(() => {
    if (!user) return false;
    const roles = user.realm_access?.roles ?? [];
    const groups = user.groups ?? [];
    return (
      roles.some((r) => ADMIN_ROLES.includes(r)) ||
      groups.some((g) => g.includes("admin"))
    );
  }, [user]);

  const clearAuth = useCallback(() => {
    setAccessToken(null);
    setRefreshToken(null);
    setUser(null);
    if (refreshTimerRef.current) {
      clearTimeout(refreshTimerRef.current);
      refreshTimerRef.current = null;
    }
  }, []);

  const setTokens = useCallback(
    (access: string, refresh: string | null) => {
      const claims = decodeJwt(access);
      if (isTokenExpired(claims)) {
        clearAuth();
        return;
      }
      setAccessToken(access);
      setRefreshToken(refresh);
      setUser(claims);

      // Schedule token refresh
      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current);
      }
      const expiresInMs = claims.exp * 1000 - Date.now() - 60000;
      if (expiresInMs > 0 && refresh && config) {
        refreshTimerRef.current = setTimeout(() => {
          performTokenRefresh(refresh, config);
        }, expiresInMs);
      }
    },
    [clearAuth, config],
  );

  const performTokenRefresh = useCallback(
    async (rt: string, cfg: AppConfig) => {
      try {
        const tokenUrl = `${cfg.keycloakUrl}/realms/${cfg.realm}/protocol/openid-connect/token`;
        const response = await fetch(tokenUrl, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            grant_type: "refresh_token",
            client_id: cfg.clientId,
            refresh_token: rt,
          }),
        });

        if (!response.ok) {
          clearAuth();
          return;
        }

        const data = await response.json();
        setTokens(data.access_token, data.refresh_token ?? null);
      } catch {
        clearAuth();
      }
    },
    [clearAuth, setTokens],
  );

  const login = useCallback(async () => {
    let cfg = config;
    if (!cfg) {
      try {
        cfg = await apiGet<AppConfig>("/config");
        setConfig(cfg);
      } catch {
        setError("Failed to load authentication configuration");
        return;
      }
    }

    const codeVerifier = generateCodeVerifier();
    const codeChallenge = await generateCodeChallenge(codeVerifier);
    const state = generateState();

    sessionStorage.setItem("pkce_verifier", codeVerifier);
    sessionStorage.setItem("oauth_state", state);

    const redirectUri = `${window.location.origin}/login/callback`;
    const authUrl = new URL(
      `${cfg.keycloakUrl}/realms/${cfg.realm}/protocol/openid-connect/auth`,
    );
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("client_id", cfg.clientId);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("scope", "openid profile email");
    authUrl.searchParams.set("state", state);
    authUrl.searchParams.set("code_challenge", codeChallenge);
    authUrl.searchParams.set("code_challenge_method", "S256");

    window.location.href = authUrl.toString();
  }, [config]);

  const logout = useCallback(async () => {
    const cfg = config;
    clearAuth();
    if (cfg) {
      const logoutUrl = new URL(
        `${cfg.keycloakUrl}/realms/${cfg.realm}/protocol/openid-connect/logout`,
      );
      logoutUrl.searchParams.set(
        "post_logout_redirect_uri",
        window.location.origin,
      );
      logoutUrl.searchParams.set("client_id", cfg.clientId);
      window.location.href = logoutUrl.toString();
    }
  }, [config, clearAuth]);

  const handleCallback = useCallback(
    async (cfg: AppConfig) => {
      const params = new URLSearchParams(window.location.search);
      const code = params.get("code");
      const state = params.get("state");
      const savedState = sessionStorage.getItem("oauth_state");
      const codeVerifier = sessionStorage.getItem("pkce_verifier");

      sessionStorage.removeItem("oauth_state");
      sessionStorage.removeItem("pkce_verifier");

      if (!code || !state || state !== savedState || !codeVerifier) {
        setError("Invalid authentication callback");
        setIsLoading(false);
        return;
      }

      try {
        const tokenUrl = `${cfg.keycloakUrl}/realms/${cfg.realm}/protocol/openid-connect/token`;
        const redirectUri = `${window.location.origin}/login/callback`;

        const response = await fetch(tokenUrl, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            grant_type: "authorization_code",
            client_id: cfg.clientId,
            code,
            redirect_uri: redirectUri,
            code_verifier: codeVerifier,
          }),
        });

        if (!response.ok) {
          const errorData = await response.json().catch(() => ({}));
          throw new Error(
            (errorData as Record<string, string>).error_description ??
              "Token exchange failed",
          );
        }

        const data = await response.json();
        setTokens(data.access_token, data.refresh_token ?? null);

        // Clean up the URL
        window.history.replaceState({}, "", "/");
      } catch (err) {
        setError(
          err instanceof Error ? err.message : "Authentication failed",
        );
      } finally {
        setIsLoading(false);
      }
    },
    [setTokens],
  );

  // Initialize: fetch config and check for callback
  useEffect(() => {
    if (initRef.current) return;
    initRef.current = true;

    const init = async () => {
      try {
        const cfg = await apiGet<AppConfig>("/config");
        setConfig(cfg);

        // Check if this is a callback with authorization code
        const params = new URLSearchParams(window.location.search);
        if (params.has("code") && params.has("state")) {
          await handleCallback(cfg);
        } else {
          setIsLoading(false);
        }
      } catch {
        setError("Failed to load application configuration");
        setIsLoading(false);
      }
    };

    init();
  }, [handleCallback]);

  // Set up API auth handlers
  useEffect(() => {
    setAuthHandlers(
      () => {
        if (!accessToken) return null;
        if (user && isTokenExpiringSoon(user, 10)) {
          // Token is about to expire, try refresh
          if (refreshToken && config) {
            performTokenRefresh(refreshToken, config);
          }
        }
        return accessToken;
      },
      () => {
        if (refreshToken && config) {
          performTokenRefresh(refreshToken, config);
        } else {
          clearAuth();
        }
      },
    );
  }, [accessToken, refreshToken, user, config, clearAuth, performTokenRefresh]);

  const value = useMemo(
    () => ({
      isAuthenticated: !!accessToken && !!user && !isTokenExpired(user),
      isLoading,
      accessToken,
      refreshToken,
      user,
      isAdmin,
      login,
      logout,
      error,
    }),
    [
      accessToken,
      refreshToken,
      user,
      isAdmin,
      isLoading,
      login,
      logout,
      error,
    ],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
