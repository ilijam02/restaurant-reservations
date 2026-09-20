"use client";

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { describeAuthError } from "@/lib/auth/auth-errors";
import type { Role } from "@/lib/auth/redirect";
import {
  validateEmail,
  validateName,
  validateNewPassword,
  validatePasswordConfirmation,
  validatePhone,
} from "@/lib/validation";

type SignupField = "firstName" | "lastName" | "email" | "phone" | "password" | "confirmPassword";
type SignupErrors = Partial<Record<SignupField, string>>;

const inputClassName =
  "w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent aria-invalid:border-red-600 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500 dark:aria-invalid:border-red-400";

function FieldError({ field, message }: { field: SignupField; message: string | undefined }) {
  if (!message) return null;
  return (
    <p id={`${field}-error`} role="alert" className="text-sm text-red-600 dark:text-red-400">
      {message}
    </p>
  );
}

export default function SignupPage() {
  const router = useRouter();
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [email, setEmail] = useState("");
  const [phone, setPhone] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [role, setRole] = useState<Role>("customer");
  const [fieldErrors, setFieldErrors] = useState<SignupErrors>({});
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  // An error is about what was typed before; clear it once the field is edited.
  function clearError(field: SignupField) {
    setFieldErrors((current) => ({ ...current, [field]: undefined }));
  }

  // The props every field shares: the invalid state and the id of its message.
  function fieldProps(field: SignupField) {
    return {
      "aria-invalid": fieldErrors[field] ? (true as const) : undefined,
      "aria-describedby": fieldErrors[field] ? `${field}-error` : undefined,
    };
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);

    const first = validateName(firstName, "Ime");
    const last = validateName(lastName, "Prezime");
    const emailResult = validateEmail(email);
    const phoneResult = validatePhone(phone);
    const passwordResult = validateNewPassword(password);
    // Only worth comparing once the password itself is acceptable; otherwise
    // the user is told about two problems for one mistake.
    const confirmError = passwordResult.ok ? validatePasswordConfirmation(password, confirmPassword) : null;

    const errors: SignupErrors = {};
    if (!first.ok) errors.firstName = first.error;
    if (!last.ok) errors.lastName = last.error;
    if (!emailResult.ok) errors.email = emailResult.error;
    if (!phoneResult.ok) errors.phone = phoneResult.error;
    if (!passwordResult.ok) errors.password = passwordResult.error;
    if (confirmError) errors.confirmPassword = confirmError;
    setFieldErrors(errors);
    if (!first.ok || !last.ok || !emailResult.ok || !phoneResult.ok || !passwordResult.ok || confirmError) return;

    setLoading(true);

    const supabase = createClient();
    const { error } = await supabase.auth.signUp({
      email: emailResult.value,
      password,
      options: {
        data: {
          first_name: first.value,
          last_name: last.value,
          phone: phoneResult.value,
          role,
        },
      },
    });

    setLoading(false);
    if (error) {
      // A specific reason when Auth gave one (email already registered, address
      // refused, weak password, rate limit); the generic line otherwise.
      const info = describeAuthError(error);
      if (info?.field) setFieldErrors({ [info.field]: info.message });
      else setError(info?.message ?? "Registracija nije uspela. Proverite podatke i pokušajte ponovo.");
      return;
    }

    router.replace("/");
    router.refresh();
  }

  return (
    <main className="flex min-h-screen flex-1 items-center justify-center p-6">
      <form
        onSubmit={handleSubmit}
        noValidate
        className="w-full max-w-sm space-y-4 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
      >
        <h1 className="text-2xl font-semibold">Registracija</h1>

        <div className="space-y-1">
          <label htmlFor="firstName" className="block text-sm font-medium">
            Ime
          </label>
          <input
            id="firstName"
            autoComplete="given-name"
            value={firstName}
            onChange={(event) => {
              setFirstName(event.target.value);
              clearError("firstName");
            }}
            className={inputClassName}
            {...fieldProps("firstName")}
          />
          <FieldError field="firstName" message={fieldErrors.firstName} />
        </div>

        <div className="space-y-1">
          <label htmlFor="lastName" className="block text-sm font-medium">
            Prezime
          </label>
          <input
            id="lastName"
            autoComplete="family-name"
            value={lastName}
            onChange={(event) => {
              setLastName(event.target.value);
              clearError("lastName");
            }}
            className={inputClassName}
            {...fieldProps("lastName")}
          />
          <FieldError field="lastName" message={fieldErrors.lastName} />
        </div>

        <div className="space-y-1">
          <label htmlFor="email" className="block text-sm font-medium">
            Email
          </label>
          <input
            id="email"
            type="email"
            autoComplete="email"
            value={email}
            onChange={(event) => {
              setEmail(event.target.value);
              clearError("email");
            }}
            className={inputClassName}
            {...fieldProps("email")}
          />
          <FieldError field="email" message={fieldErrors.email} />
        </div>

        <div className="space-y-1">
          <label htmlFor="phone" className="block text-sm font-medium">
            Broj telefona
          </label>
          <input
            id="phone"
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            placeholder="060 123 4567"
            value={phone}
            onChange={(event) => {
              setPhone(event.target.value);
              clearError("phone");
            }}
            className={inputClassName}
            {...fieldProps("phone")}
          />
          <FieldError field="phone" message={fieldErrors.phone} />
        </div>

        <div className="space-y-1">
          <label htmlFor="password" className="block text-sm font-medium">
            Lozinka
          </label>
          <input
            id="password"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(event) => {
              setPassword(event.target.value);
              clearError("password");
              // A "don't match" message is about the pair, so it's stale now.
              clearError("confirmPassword");
            }}
            className={inputClassName}
            {...fieldProps("password")}
          />
          <FieldError field="password" message={fieldErrors.password} />
        </div>

        <div className="space-y-1">
          <label htmlFor="confirmPassword" className="block text-sm font-medium">
            Ponovite lozinku
          </label>
          <input
            id="confirmPassword"
            type="password"
            autoComplete="new-password"
            value={confirmPassword}
            onChange={(event) => {
              setConfirmPassword(event.target.value);
              clearError("confirmPassword");
            }}
            className={inputClassName}
            {...fieldProps("confirmPassword")}
          />
          <FieldError field="confirmPassword" message={fieldErrors.confirmPassword} />
        </div>

        <div className="space-y-1">
          <label htmlFor="role" className="block text-sm font-medium">
            Tip naloga
          </label>
          <select
            id="role"
            value={role}
            onChange={(event) => setRole(event.target.value as Role)}
            className={inputClassName}
          >
            <option value="customer">Kupac</option>
            <option value="employee">Zaposleni</option>
            <option value="owner">Vlasnik</option>
          </select>
        </div>

        {error && (
          <p role="alert" className="text-sm text-red-600 dark:text-red-400">
            {error}
          </p>
        )}

        <button
          type="submit"
          disabled={loading}
          className="w-full rounded-md bg-accent px-3 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
        >
          {loading ? "Registracija..." : "Registruj se"}
        </button>

        <p className="text-sm">
          Već imate nalog?{" "}
          <Link href="/login" className="font-medium text-orange-700 underline dark:text-accent">
            Prijavite se
          </Link>
        </p>
      </form>
    </main>
  );
}
