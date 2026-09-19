import { AppHeader } from "@/components/app-header";
import { EmployeeRestaurantList } from "@/components/employee-restaurant-list";

export default function EmployeeApplyPage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader backHref="/employee" />
      <h1 className="sr-only">Prijava u restoran</h1>
      <EmployeeRestaurantList />
    </main>
  );
}
