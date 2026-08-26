export type Role = "customer" | "employee" | "owner";

export const ROLE_HOME_PATH: Record<Role, string> = {
  customer: "/customer",
  employee: "/employee",
  owner: "/owner",
};

const AUTH_ONLY_PATHS = ["/login", "/signup"];

/**
 * Pure redirect decision for the auth flow, shared by middleware.ts and the
 * root page. Returns the path to redirect to, or null to let the request
 * through unchanged.
 */
export function decideRedirect(pathname: string, role: Role | null): string | null {
  const homePath = role ? ROLE_HOME_PATH[role] : null;

  if (pathname === "/") {
    return homePath ?? "/login";
  }

  if (AUTH_ONLY_PATHS.includes(pathname)) {
    return homePath;
  }

  const roleHomePaths = Object.values(ROLE_HOME_PATH);
  if (roleHomePaths.includes(pathname)) {
    if (!homePath) return "/login";
    if (pathname !== homePath) return homePath;
    return null;
  }

  return null;
}
