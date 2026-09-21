"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";

export type PaymentReturn = {
  // success: booked and paid. processing: paid, the reservation is being made.
  // error: the payment went through but no reservation could be made (refunded).
  // info: the customer backed out of paying.
  kind: "success" | "processing" | "error" | "info";
  text: string;
};

const CLASSES: Record<PaymentReturn["kind"], string> = {
  success: "text-success",
  processing: "text-amber-700 dark:text-warning",
  error: "text-red-600 dark:text-red-400",
  info: "text-stone-600 dark:text-stone-400",
};

// The message shown in the reservation form when Stripe sends the customer back. The
// reservation is created by the payment webhook, which can land a few seconds
// after the redirect - while it hasn't, this re-fetches the page (every 2 s, for
// about 30 s) so the message turns into the confirmation on its own.
export function PaymentReturnBanner({ kind, text }: PaymentReturn) {
  const router = useRouter();
  const attempts = useRef(0);

  useEffect(() => {
    if (kind !== "processing") return;
    const timer = setInterval(() => {
      attempts.current += 1;
      if (attempts.current > 15) {
        clearInterval(timer);
        return;
      }
      router.refresh();
    }, 2000);
    return () => clearInterval(timer);
  }, [kind, router]);

  return (
    <p role={kind === "error" ? "alert" : "status"} className={`text-sm ${CLASSES[kind]}`}>
      {text}
    </p>
  );
}
