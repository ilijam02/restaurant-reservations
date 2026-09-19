import { AppHeader } from "@/components/app-header";
import { RestaurantList } from "@/components/restaurant-list";

export default function CustomerHomePage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader />
      <h1 className="text-3xl font-bold">KUPAC</h1>
      <RestaurantList />
    </main>
  );
}
