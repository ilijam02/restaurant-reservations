"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { consumeSignalsChanged } from "@/lib/recommendation-signals";

// Re-renders the ranked list on the server if a view or a favorite was
// recorded since it was last shown - on mount (which also covers the browser's
// Back button reusing the cached page) and when the page is restored from the
// back/forward cache, where nothing remounts. See recommendation-signals.ts.
export function RefreshWhenSignalsChange() {
  const router = useRouter();

  useEffect(() => {
    const refreshIfChanged = () => {
      if (consumeSignalsChanged()) router.refresh();
    };
    refreshIfChanged();

    const onPageShow = (event: PageTransitionEvent) => {
      if (event.persisted) refreshIfChanged();
    };
    window.addEventListener("pageshow", onPageShow);
    return () => window.removeEventListener("pageshow", onPageShow);
  }, [router]);

  return null;
}
