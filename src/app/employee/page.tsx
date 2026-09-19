import { AppHeader } from "@/components/app-header";
import { EmployeeStaffRestaurants } from "@/components/employee-staff-restaurants";

export default function EmployeeHomePage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader />
      <h1 className="sr-only">Početna</h1>
      <EmployeeStaffRestaurants />
    </main>
  );
}
