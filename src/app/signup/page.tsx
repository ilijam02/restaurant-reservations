"use client";

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { Role } from "@/lib/auth/redirect";

export default function SignupPage() {
  const router = useRouter();
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [email, setEmail] = useState("");
  const [phone, setPhone] = useState("");
  const [password, setPassword] = useState("");
  const [role, setRole] = useState<Role>("customer");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setLoading(true);

    const supabase = createClient();
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          first_name: firstName,
          last_name: lastName,
          phone,
          role,
        },
      },
    });

    setLoading(false);
    if (error) {
      setError("Registracija nije uspela. Proverite podatke i pokušajte ponovo.");
      return;
    }

    router.replace("/");
    router.refresh();
  }

  return (
    <main className="flex min-h-screen flex-1 items-center justify-center p-6">
      <form onSubmit={handleSubmit} className="w-full max-w-sm space-y-4">
        <h1 className="text-2xl font-semibold">Registracija</h1>

        <div className="space-y-1">
          <label htmlFor="firstName" className="block text-sm font-medium">
            Ime
          </label>
          <input
            id="firstName"
            required
            value={firstName}
            onChange={(event) => setFirstName(event.target.value)}
            className="w-full rounded border border-black/20 px-3 py-2"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="lastName" className="block text-sm font-medium">
            Prezime
          </label>
          <input
            id="lastName"
            required
            value={lastName}
            onChange={(event) => setLastName(event.target.value)}
            className="w-full rounded border border-black/20 px-3 py-2"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="email" className="block text-sm font-medium">
            Email
          </label>
          <input
            id="email"
            type="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            className="w-full rounded border border-black/20 px-3 py-2"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="phone" className="block text-sm font-medium">
            Broj telefona
          </label>
          <input
            id="phone"
            type="tel"
            required
            value={phone}
            onChange={(event) => setPhone(event.target.value)}
            className="w-full rounded border border-black/20 px-3 py-2"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="password" className="block text-sm font-medium">
            Lozinka
          </label>
          <input
            id="password"
            type="password"
            required
            minLength={6}
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            className="w-full rounded border border-black/20 px-3 py-2"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="role" className="block text-sm font-medium">
            Tip naloga
          </label>
          <select
            id="role"
            value={role}
            onChange={(event) => setRole(event.target.value as Role)}
            className="w-full rounded border border-black/20 px-3 py-2"
          >
            <option value="customer">Kupac</option>
            <option value="employee">Zaposleni</option>
            <option value="owner">Vlasnik</option>
          </select>
        </div>

        {error && <p className="text-sm text-red-600">{error}</p>}

        <button
          type="submit"
          disabled={loading}
          className="w-full rounded bg-black px-3 py-2 text-white disabled:opacity-50"
        >
          {loading ? "Registracija..." : "Registruj se"}
        </button>

        <p className="text-sm">
          Već imate nalog?{" "}
          <Link href="/login" className="underline">
            Prijavite se
          </Link>
        </p>
      </form>
    </main>
  );
}
