import { DeleteAccountSection } from "@/components/delete-account-section";
import { fetchAccountDeletionPlan } from "@/lib/account-deletion";
import { createClient } from "@/lib/supabase/server";

// The body of every role's "Moj nalog" page: who the account is, and the
// deletion section. Shared because nothing on it depends on the role except
// the wording the section derives from the plan; each role's page still renders
// its own AppHeader (a header is never applied automatically).
export async function AccountDetails() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  // The id filter is needed: an owner's RLS also lets them read their staff's
  // and customers' profiles, so an unfiltered query returns several rows.
  const [{ data: profile }, plan] = await Promise.all([
    supabase.from("profiles").select("first_name, last_name, phone").eq("id", user.id).maybeSingle(),
    fetchAccountDeletionPlan(supabase),
  ]);

  return (
    <>
      <section className="w-full max-w-3xl space-y-3 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800">
        <h2 className="text-xl font-semibold">Podaci o nalogu</h2>
        <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2">
          <dt className="text-stone-600 dark:text-stone-400">Ime i prezime</dt>
          <dd>{profile ? `${profile.first_name} ${profile.last_name}` : "—"}</dd>
          <dt className="text-stone-600 dark:text-stone-400">Email</dt>
          <dd className="break-all">{user.email ?? "—"}</dd>
          <dt className="text-stone-600 dark:text-stone-400">Telefon</dt>
          <dd>{profile?.phone ?? "—"}</dd>
        </dl>
      </section>

      {user.email && plan ? (
        <DeleteAccountSection email={user.email} plan={plan} />
      ) : (
        <p role="alert" className="text-red-600 dark:text-red-400">
          Brisanje naloga trenutno nije dostupno. Osvežite stranicu ili pokušajte ponovo kasnije.
        </p>
      )}
    </>
  );
}
