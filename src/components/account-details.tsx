import { DeleteAccountSection } from "@/components/delete-account-section";
import { EditAccountSection } from "@/components/edit-account-section";
import { fetchAccountDeletionPlan } from "@/lib/account-deletion";
import { createClient } from "@/lib/supabase/server";

// The body of every role's "Moj nalog" page: the form for editing the account's
// details, and the deletion section. Shared because nothing on it depends on
// the role except the wording the deletion section derives from the plan; each
// role's page still renders its own AppHeader (a header is never applied
// automatically).
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
      {profile && user.email ? (
        <EditAccountSection
          initial={{
            firstName: profile.first_name,
            lastName: profile.last_name,
            email: user.email,
            phone: profile.phone,
          }}
        />
      ) : (
        <p role="alert" className="text-red-600 dark:text-red-400">
          Podaci o nalogu trenutno nisu dostupni. Osvežite stranicu ili pokušajte ponovo kasnije.
        </p>
      )}

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
