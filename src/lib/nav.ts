import { ROLE_HOME_PATH, type Role } from "@/lib/auth/redirect";

export type MenuItem = { label: string; href: string };

// The dropdown menu in AppHeader is derived from the current URL's role
// segment rather than passed in by each page, so it's the same on every page
// of a role by construction - a page can't forget it or drift from the
// others. "Početna" (the role's home page) is always first; the rest are
// that role's top-level destinations. The current page's own link stays in
// the list (AppHeader refreshes instead of navigating when it's clicked).
const ROLE_MENU_ITEMS: Record<Role, MenuItem[]> = {
  customer: [{ label: "Moje rezervacije", href: "/customer/reservations" }],
  employee: [{ label: "Prijavi se za posao", href: "/employee/apply" }],
  owner: [{ label: "Sve rezervacije", href: "/owner/reservations" }],
};

function roleFromPathname(pathname: string): Role | null {
  const segment = pathname.split("/")[1];
  return segment === "customer" || segment === "employee" || segment === "owner" ? segment : null;
}

export function menuItemsForPath(pathname: string): MenuItem[] {
  const role = roleFromPathname(pathname);
  if (!role) return [];
  return [{ label: "Početna", href: ROLE_HOME_PATH[role] }, ...ROLE_MENU_ITEMS[role]];
}

// Trailing slashes and query strings don't make it a different page.
export function isCurrentPage(pathname: string, href: string): boolean {
  const normalize = (path: string) => (path.length > 1 ? path.replace(/\/+$/, "") : path);
  return normalize(pathname) === normalize(href);
}
