import { LogoutButton } from "@/components/logout-button";
import { EmployeeRestaurantList } from "@/components/employee-restaurant-list";

export default function EmployeeHomePage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">ZAPOSLENI</h1>
      <EmployeeRestaurantList />
      <LogoutButton />
    </main>
  );
}
