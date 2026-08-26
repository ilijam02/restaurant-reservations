import { LogoutButton } from "@/components/logout-button";

export default function CustomerHomePage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center justify-center gap-6">
      <h1 className="text-3xl font-bold">KUPAC</h1>
      <LogoutButton />
    </main>
  );
}
