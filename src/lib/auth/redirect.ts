export type Role = "customer" | "employee" | "owner";

export const ROLE_HOME_PATH: Record<Role, string> = {
  customer: "/customer",
  employee: "/employee",
  owner: "/owner",
};

const AUTH_ONLY_PATHS = ["/login", "/signup"];

// The role a path belongs to: the role's home page or anything nested under
// it. Matches on whole segments, so "/customers" or "/owner-x" belong to no
// role.
function roleOwningPath(pathname: string): Role | null {
  for (const role of Object.keys(ROLE_HOME_PATH) as Role[]) {
    const homePath = ROLE_HOME_PATH[role];
    if (pathname === homePath || pathname.startsWith(`${homePath}/`)) return role;
  }
  return null;
}

// `NextRequest.nextUrl.pathname` is still percent-encoded ("/%6Fwner/x"), but
// Next's router can decode it before matching a page (production builds do), so
// deciding on the raw string would let an encoded role prefix look like an
// unrelated path. Null when the encoding is malformed.
function decodePathname(pathname: string): string | null {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return null;
  }
}

/**
 * Pure redirect decision for the auth flow, shared by proxy.ts and the root
 * page. Returns the path to redirect to, or null to let the request through
 * unchanged.
 *
 * Every path under a role's home (`/owner`, `/owner/restaurants/...`) is
 * that role's alone: anonymous visitors go to /login, and a user of another
 * role goes to their own home page. A path with malformed percent-encoding
 * can't be classified, so it fails closed the same way (to /login when
 * anonymous, else the user's home).
 */
export function decideRedirect(rawPathname: string, role: Role | null): string | null {
  const homePath = role ? ROLE_HOME_PATH[role] : null;

  const pathname = decodePathname(rawPathname);
  if (pathname === null) return homePath ?? "/login";

  if (pathname === "/") {
    return homePath ?? "/login";
  }

  if (AUTH_ONLY_PATHS.includes(pathname)) {
    return homePath;
  }

  const owningRole = roleOwningPath(pathname);
  if (owningRole) {
    if (!homePath) return "/login";
    if (owningRole !== role) return homePath;
  }

  return null;
}
