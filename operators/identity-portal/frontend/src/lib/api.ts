import type { ApiError } from "./types";

const BASE_URL = "/api/v1";

let getAccessToken: (() => string | null) | null = null;
let onUnauthorized: (() => void) | null = null;

export function setAuthHandlers(
  tokenGetter: () => string | null,
  unauthorizedHandler: () => void,
) {
  getAccessToken = tokenGetter;
  onUnauthorized = unauthorizedHandler;
}

class ApiRequestError extends Error {
  status: number;
  code: string;

  constructor(message: string, status: number, code: string = "API_ERROR") {
    super(message);
    this.name = "ApiRequestError";
    this.status = status;
    this.code = code;
  }
}

async function handleResponse<T>(response: Response): Promise<T> {
  if (response.status === 204) {
    return undefined as T;
  }

  if (response.status === 401) {
    onUnauthorized?.();
    throw new ApiRequestError("Unauthorized", 401, "UNAUTHORIZED");
  }

  if (!response.ok) {
    let errorBody: ApiError | null = null;
    try {
      errorBody = await response.json();
    } catch {
      // response body is not JSON
    }
    throw new ApiRequestError(
      errorBody?.message ?? `Request failed with status ${response.status}`,
      response.status,
      errorBody?.error ?? "API_ERROR",
    );
  }

  const contentType = response.headers.get("content-type");
  if (contentType?.includes("application/json")) {
    return response.json();
  }
  if (
    contentType?.includes("text/plain") ||
    contentType?.includes("application/x-pem-file")
  ) {
    return (await response.text()) as T;
  }
  if (contentType?.includes("application/octet-stream")) {
    return (await response.blob()) as T;
  }
  return response.json();
}

function buildHeaders(extraHeaders?: Record<string, string>): HeadersInit {
  const headers: Record<string, string> = {
    ...extraHeaders,
  };

  const token = getAccessToken?.();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  return headers;
}

export async function apiGet<T>(
  path: string,
  params?: Record<string, string | number | undefined>,
): Promise<T> {
  const url = new URL(`${BASE_URL}${path}`, window.location.origin);
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }
  }

  const response = await fetch(url.toString(), {
    method: "GET",
    headers: buildHeaders(),
    credentials: "include",
  });

  return handleResponse<T>(response);
}

export async function apiPost<T>(
  path: string,
  body?: unknown,
): Promise<T> {
  const response = await fetch(`${BASE_URL}${path}`, {
    method: "POST",
    headers: buildHeaders({ "Content-Type": "application/json" }),
    credentials: "include",
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  return handleResponse<T>(response);
}

export async function apiPut<T>(
  path: string,
  body?: unknown,
): Promise<T> {
  const response = await fetch(`${BASE_URL}${path}`, {
    method: "PUT",
    headers: buildHeaders({ "Content-Type": "application/json" }),
    credentials: "include",
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  return handleResponse<T>(response);
}

export async function apiDelete<T = void>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(`${BASE_URL}${path}`, {
    method: "DELETE",
    headers: buildHeaders(
      body !== undefined ? { "Content-Type": "application/json" } : undefined,
    ),
    credentials: "include",
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  return handleResponse<T>(response);
}

export async function apiDownload(path: string, filename: string): Promise<void> {
  const response = await fetch(`${BASE_URL}${path}`, {
    method: "GET",
    headers: buildHeaders(),
    credentials: "include",
  });

  if (!response.ok) {
    throw new ApiRequestError(
      `Download failed with status ${response.status}`,
      response.status,
    );
  }

  const blob = await response.blob();
  const url = window.URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  window.URL.revokeObjectURL(url);
  document.body.removeChild(a);
}

export { ApiRequestError };
