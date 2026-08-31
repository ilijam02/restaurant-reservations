import { createClient } from "@/lib/supabase/server";
import { EmployeeRestaurantBrowser } from "@/components/employee-restaurant-browser";

export async function EmployeeRestaurantList() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: restaurants } = await supabase
    .from("restaurants")
    .select("id, name")
    .order("name");

  const { data: applications } = await supabase
    .from("restaurant_staff")
    .select("restaurant_id, status")
    .eq("employee_id", user!.id);

  return <EmployeeRestaurantBrowser restaurants={restaurants ?? []} applications={applications ?? []} />;
}
