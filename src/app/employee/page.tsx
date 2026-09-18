import { AppHeader } from "@/components/app-header";
import { EmployeeStaffRestaurants } from "@/components/employee-staff-restaurants";
import { EMPLOYEE_MENU_ITEMS } from "@/lib/employee-nav";

export default function EmployeeHomePage() {
  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <AppHeader menuItems={EMPLOYEE_MENU_ITEMS} />
      <h1 className="text-3xl font-bold">ZAPOSLENI</h1>
      <EmployeeStaffRestaurants />
    </main>
  );
}
