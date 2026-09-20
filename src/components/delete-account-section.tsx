"use client";

import { useId, useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { deletionBlockedMessage, type AccountDeletionPlan } from "@/lib/account-deletion";
import { deleteAccountAction } from "@/lib/auth/delete-account";
import { pluralSr } from "@/lib/plural";

const INPUT_CLASSES =
  "w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500";

const LINK_CLASSES =
  "text-sm font-medium text-orange-700 hover:underline focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent dark:text-accent";

// What deleting does depends on the role and on what the account has - the
// database decides (see delete_my_account()); this only describes it up front
// so nobody is surprised.
function Consequences({ plan }: { plan: AccountDeletionPlan }) {
  const toDelete = plan.restaurants_to_delete.length;
  const toArchive = plan.restaurants_to_archive;

  return (
    <div className="space-y-2">
      <p>Vaš nalog i lični podaci (ime, telefon, email) biće trajno obrisani.</p>

      {plan.history_reservations > 0 && (
        <p>
          Vaše prošle rezervacije ({plan.history_reservations}) i porudžbine ostaju u istoriji restorana, ali bez ikakve
          veze sa vama.
        </p>
      )}

      {plan.role === "owner" && toDelete > 0 && (
        <p>
          Restorani bez rezervacija ({toDelete}) biće trajno obrisani, zajedno sa menijem, rasporedom stolova, osobljem i
          slikama.
        </p>
      )}

      {plan.role === "owner" && toArchive > 0 && (
        <p>
          Restorani sa istorijom rezervacija ({toArchive}) nestaju sa svih lista i osoblje gubi pristup, a njihove prošle
          rezervacije ostaju sačuvane u istoriji gostiju.
        </p>
      )}

      {plan.role === "employee" && <p>Vaše prijave i članstva u restoranima biće obrisani.</p>}
    </div>
  );
}

function Blocked({ plan }: { plan: AccountDeletionPlan }) {
  const message = deletionBlockedMessage(plan);

  return (
    <div className="space-y-3">
      <p role="alert" className="text-red-600 dark:text-red-400">
        {message}
      </p>

      {plan.active_reservations > 0 && (
        <Link href="/customer/reservations" className={LINK_CLASSES}>
          Idi na moje rezervacije
        </Link>
      )}

      {plan.blocking_restaurants.length > 0 && (
        <ul className="space-y-1">
          {plan.blocking_restaurants.map((restaurant) => (
            <li key={restaurant.id} className="text-sm">
              <span className="font-medium">{restaurant.name}</span> — {restaurant.active_reservations}{" "}
              {pluralSr(restaurant.active_reservations, "aktivna rezervacija", "aktivne rezervacije", "aktivnih rezervacija")}
              {" · "}
              <Link href={`/owner/restaurants/${restaurant.id}/reservations`} className={LINK_CLASSES}>
                Idi na rezervacije
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function DeleteAccountSection({ email, plan }: { email: string; plan: AccountDeletionPlan }) {
  const router = useRouter();
  const emailId = useId();
  const passwordId = useId();
  const [typedEmail, setTypedEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const blocked = deletionBlockedMessage(plan) !== null;
  const emailMatches = typedEmail.trim().toLowerCase() === email.toLowerCase();
  const canSubmit = emailMatches && password.length > 0 && !loading;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canSubmit || blocked) return;
    setError(null);
    setLoading(true);

    const result = await deleteAccountAction(typedEmail, password);

    if (!result.ok) {
      setLoading(false);
      setError(result.error);
      // The usual reason is that the account changed under this (stale) page -
      // a new booking - so the section should catch up (and switch to the
      // blocked view if that's what happened).
      router.refresh();
      return;
    }

    router.push("/login?deleted=1");
    router.refresh();
  }

  return (
    <section className="w-full max-w-3xl space-y-4 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800">
      <h2 className="text-xl font-semibold text-red-600 dark:text-red-400">Brisanje naloga</h2>

      {blocked ? (
        <Blocked plan={plan} />
      ) : (
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2 text-stone-700 dark:text-stone-300">
            <Consequences plan={plan} />
            <p className="font-medium">Ovo se ne može poništiti.</p>
          </div>

          <div className="space-y-1">
            <label htmlFor={emailId} className="block text-sm font-medium">
              Za potvrdu ukucajte svoj email: <span className="font-semibold">{email}</span>
            </label>
            <input
              id={emailId}
              type="email"
              value={typedEmail}
              onChange={(event) => setTypedEmail(event.target.value)}
              autoComplete="off"
              disabled={loading}
              className={INPUT_CLASSES}
            />
          </div>

          <div className="space-y-1">
            <label htmlFor={passwordId} className="block text-sm font-medium">
              Lozinka
            </label>
            <input
              id={passwordId}
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              autoComplete="current-password"
              disabled={loading}
              className={INPUT_CLASSES}
            />
          </div>

          {error && (
            <p role="alert" className="text-red-600 dark:text-red-400">
              {error}
            </p>
          )}

          <button
            type="submit"
            disabled={!canSubmit}
            className="rounded-md bg-red-700 px-4 py-2 text-white hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-red-700 focus-visible:ring-offset-2 dark:bg-red-400 dark:text-stone-900 dark:focus-visible:ring-red-400 dark:focus-visible:ring-offset-stone-800"
          >
            {loading ? "Brisanje..." : "Obriši nalog"}
          </button>
        </form>
      )}
    </section>
  );
}
