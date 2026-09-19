"use client";

import { useId, useState, type ChangeEvent, type FormEvent, type HTMLInputTypeAttribute } from "react";
import { useRouter } from "next/navigation";
import { updateAccountAction } from "@/lib/auth/update-account";
import {
  accountChanges,
  validateAccountForm,
  type AccountFieldErrors,
  type AccountFieldName,
  type AccountFields,
  type AccountFormInput,
} from "@/lib/validation";

const INPUT_CLASSES =
  "w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-base text-stone-900 placeholder:text-stone-400 focus:outline-hidden focus:ring-2 focus:ring-accent aria-invalid:border-red-600 disabled:cursor-not-allowed disabled:opacity-50 dark:border-stone-600 dark:bg-stone-800 dark:text-stone-100 dark:placeholder:text-stone-500 dark:aria-invalid:border-red-400";

type Field = {
  name: AccountFieldName;
  label: string;
  type?: HTMLInputTypeAttribute;
  autoComplete: string;
  placeholder?: string;
  hint?: string;
};

function TextField({
  field,
  value,
  error,
  disabled,
  onChange,
}: {
  field: Field;
  value: string;
  error: string | undefined;
  disabled: boolean;
  onChange: (event: ChangeEvent<HTMLInputElement>) => void;
}) {
  const id = useId();
  const messageId = `${id}-message`;

  return (
    <div className="space-y-1">
      <label htmlFor={id} className="block text-sm font-medium">
        {field.label}
      </label>
      <input
        id={id}
        name={field.name}
        type={field.type ?? "text"}
        inputMode={field.type === "tel" ? "tel" : undefined}
        autoComplete={field.autoComplete}
        placeholder={field.placeholder}
        value={value}
        onChange={onChange}
        disabled={disabled}
        aria-invalid={error ? true : undefined}
        aria-describedby={error || field.hint ? messageId : undefined}
        className={INPUT_CLASSES}
      />
      {error ? (
        <p id={messageId} role="alert" className="text-sm text-red-600 dark:text-red-400">
          {error}
        </p>
      ) : field.hint ? (
        <p id={messageId} className="text-sm text-stone-600 dark:text-stone-400">
          {field.hint}
        </p>
      ) : null}
    </div>
  );
}

const FIELDS: Record<AccountFieldName, Field> = {
  firstName: { name: "firstName", label: "Ime", autoComplete: "given-name" },
  lastName: { name: "lastName", label: "Prezime", autoComplete: "family-name" },
  email: { name: "email", label: "Email", type: "email", autoComplete: "email" },
  phone: {
    name: "phone",
    label: "Broj telefona",
    type: "tel",
    autoComplete: "tel",
    placeholder: "060 123 4567 ili +381 60 123 4567",
  },
  newPassword: {
    name: "newPassword",
    label: "Nova lozinka",
    type: "password",
    autoComplete: "new-password",
    hint: "Ostavite prazno ako ne menjate lozinku.",
  },
  confirmNewPassword: {
    name: "confirmNewPassword",
    label: "Ponovite novu lozinku",
    type: "password",
    autoComplete: "new-password",
  },
  currentPassword: {
    name: "currentPassword",
    label: "Trenutna lozinka",
    type: "password",
    autoComplete: "current-password",
    hint: "Potrebna za promenu emaila, telefona ili lozinke.",
  },
};

export function EditAccountSection({ initial }: { initial: AccountFields }) {
  const router = useRouter();
  const [values, setValues] = useState<AccountFormInput>({
    ...initial,
    newPassword: "",
    confirmNewPassword: "",
    currentPassword: "",
  });
  const [errors, setErrors] = useState<AccountFieldErrors>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const changes = accountChanges(initial, values);
  const hasChanges = changes.name || changes.email || changes.phone || changes.password;

  function bind(name: AccountFieldName) {
    return {
      field: FIELDS[name],
      value: values[name],
      error: errors[name],
      disabled: loading,
      onChange: (event: ChangeEvent<HTMLInputElement>) => {
        const { value } = event.target;
        setValues((current) => ({ ...current, [name]: value }));
        // An error is about what was typed before; clear it once it's edited.
        setErrors((current) => ({ ...current, [name]: undefined }));
        setMessage(null);
      },
    };
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (loading || !hasChanges) return;
    setFormError(null);
    setMessage(null);

    const validated = validateAccountForm(initial, values);
    if (!validated.ok) {
      setErrors(validated.errors);
      return;
    }
    setErrors({});
    setLoading(true);

    const result = await updateAccountAction(values);
    setLoading(false);

    if (!result.ok) {
      setErrors(result.errors ?? {});
      setFormError(result.error ?? null);
      return;
    }

    // Show what was actually stored (trimmed, lower-cased, +381...), and drop
    // the password fields.
    setValues({ ...validated.values, newPassword: "", confirmNewPassword: "", currentPassword: "" });
    setMessage(result.message);
    router.refresh();
  }

  return (
    <form
      onSubmit={handleSubmit}
      noValidate
      className="w-full max-w-3xl space-y-4 rounded-lg border border-stone-200 bg-white p-8 shadow-sm dark:border-stone-700 dark:bg-stone-800"
    >
      <h2 className="text-xl font-semibold">Podaci o nalogu</h2>

      <div className="grid gap-4 sm:grid-cols-2">
        <TextField {...bind("firstName")} />
        <TextField {...bind("lastName")} />
      </div>
      <TextField {...bind("email")} />
      <TextField {...bind("phone")} />

      <fieldset className="space-y-4 border-t border-stone-200 pt-4 dark:border-stone-700">
        <legend className="pr-2 text-base font-semibold">Promena lozinke</legend>
        <div className="grid gap-4 sm:grid-cols-2">
          <TextField {...bind("newPassword")} />
          <TextField {...bind("confirmNewPassword")} />
        </div>
      </fieldset>

      {changes.needsCurrentPassword && (
        <div className="border-t border-stone-200 pt-4 dark:border-stone-700">
          <TextField {...bind("currentPassword")} />
        </div>
      )}

      {formError && (
        <p role="alert" className="text-red-600 dark:text-red-400">
          {formError}
        </p>
      )}
      {message && (
        <p role="status" className="text-stone-700 dark:text-stone-300">
          {message}
        </p>
      )}

      <button
        type="submit"
        disabled={!hasChanges || loading}
        className="rounded-md bg-accent px-4 py-2 text-accent-foreground hover:opacity-90 active:opacity-80 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 dark:focus-visible:ring-offset-stone-800"
      >
        {loading ? "Čuvanje..." : "Sačuvaj izmene"}
      </button>
    </form>
  );
}
