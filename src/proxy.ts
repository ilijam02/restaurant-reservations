import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { decideRedirect } from "@/lib/auth/redirect";
import { getProfileRole } from "@/lib/auth/role";

export async function proxy(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const role = user ? await getProfileRole(supabase, user.id) : null;

  const redirectTo = decideRedirect(request.nextUrl.pathname, role);
  if (redirectTo) {
    const url = request.nextUrl.clone();
    url.pathname = redirectTo;
    return NextResponse.redirect(url);
  }

  return supabaseResponse;
}

// No file-extension exclusion here (e.g. for .png): a role page whose last
// segment is dynamic - /employee/restaurants/[id] - also matches
// /employee/restaurants/x.png, which such an exclusion would let skip this
// proxy (and its role gate) entirely. There's no public/ folder for the
// exclusion to protect anyway.
export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
