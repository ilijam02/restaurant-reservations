// A view or a favorite changes the ranking, but the ranked customer list can be
// shown again without being re-rendered on the server (the browser's Back
// button reuses the page it left, a restored back/forward-cache page is the old
// document). So whoever records a signal leaves a flag in this tab's session
// storage, and the list refreshes itself the next time it is shown if the flag
// is there. Storage can be unavailable (private modes, blocked site data); then
// the list simply stays as it was until the next visit.
const KEY = "rr:recommendation-signals-changed";

export function markSignalsChanged(): void {
  try {
    window.sessionStorage.setItem(KEY, "1");
  } catch {
    // ignore: see above
  }
}

// True once per mark: reading it clears it.
export function consumeSignalsChanged(): boolean {
  try {
    if (window.sessionStorage.getItem(KEY) !== "1") return false;
    window.sessionStorage.removeItem(KEY);
    return true;
  } catch {
    return false;
  }
}
