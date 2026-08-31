import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { OwnerStaffManager } from "@/components/owner-staff-manager";

export default async function OwnerRestaurantStaffPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: restaurant } = await supabase
    .from("restaurants")
    .select("id, name")
    .eq("id", id)
    .eq("owner_id", user!.id)
    .single();

  if (!restaurant) {
    notFound();
  }

  const { data: staffRows } = await supabase
    .from("restaurant_staff")
    .select("id, employee_id, status")
    .eq("restaurant_id", id)
    .order("created_at");

  const employeeIds = (staffRows ?? []).map((row) => row.employee_id);
  const { data: profiles } = employeeIds.length
    ? await supabase.from("profiles").select("id, first_name, last_name").in("id", employeeIds)
    : { data: [] };

  const nameById = new Map((profiles ?? []).map((profile) => [profile.id, `${profile.first_name} ${profile.last_name}`]));

  const applications = (staffRows ?? [])
    .filter((row) => row.status === "pending")
    .map((row) => ({ id: row.id, name: nameById.get(row.employee_id) ?? "Nepoznat korisnik" }));

  const staff = (staffRows ?? [])
    .filter((row) => row.status === "accepted")
    .map((row) => ({ id: row.id, name: nameById.get(row.employee_id) ?? "Nepoznat korisnik" }));

  return (
    <main className="flex min-h-screen flex-1 flex-col items-center gap-6 p-6 pt-16">
      <h1 className="text-3xl font-bold">{restaurant.name}</h1>
      <OwnerStaffManager applications={applications} staff={staff} />
    </main>
  );
}
