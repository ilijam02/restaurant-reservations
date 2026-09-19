import { AccountDetails } from "@/components/account-details";
import { AppHeader } from "@/components/app-header";

export default function OwnerAccountPage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/owner" />
      <h1 className="text-3xl font-bold">Moj nalog</h1>
      <AccountDetails />
    </main>
  );
}
