import { pluralSr } from "@/lib/plural";

// One row of recommend_restaurants() (see 20260920130000_recommendation_review_fixes.sql):
// the caller's own ranking. It deliberately carries no scores - the
// neighbors' activity scaled to 0..1 would let a customer read another
// customer's behavior off it. `similar_users` is a count of the caller's
// neighbors with a signal at the restaurant, `popular` whether anyone at all
// has one; neither says who.
export type Recommendation = {
  rank: number;
  restaurant_id: string;
  personalization: number;
  similar_users: number;
  booked_before: boolean;
  popular: boolean;
};

// Restaurants in recommendation order. `restaurants` is expected in its
// fallback order (alphabetical, as queried); with no recommendations at all
// (the call failed, or returned nothing) it is returned as is, and a
// restaurant the ranking doesn't know yet (created a moment ago) goes last,
// keeping that fallback order.
export function rankRestaurants<T extends { id: string }>(restaurants: T[], recommendations: Recommendation[] | null): T[] {
  if (!recommendations || recommendations.length === 0) return restaurants;
  const rankById = new Map(recommendations.map((r) => [r.restaurant_id, r.rank]));
  return restaurants
    .map((restaurant, index) => ({ restaurant, index, rank: rankById.get(restaurant.id) ?? Number.POSITIVE_INFINITY }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((entry) => entry.restaurant);
}

// The one-line "why" under a restaurant card, or null when there is nothing
// worth saying. Only ever aggregate information about other customers.
export function describeRecommendation(recommendation: Recommendation | undefined): string | null {
  if (!recommendation) return null;
  if (recommendation.booked_before) return "Već ste rezervisali ovde";
  if (recommendation.similar_users > 0) {
    const n = recommendation.similar_users;
    return `Slično vama · ${n} ${pluralSr(n, "korisnik", "korisnika", "korisnika")}`;
  }
  if (recommendation.popular) return "Popularno";
  return null;
}

// A sentence above the list explaining how it is ordered: how much of the
// ranking is tailored to this customer, the rest being popularity. null when
// there is no ranking to explain.
export function describeOrdering(recommendations: Recommendation[] | null): string | null {
  if (!recommendations || recommendations.length === 0) return null;
  const percent = Math.round(recommendations[0].personalization * 100);
  if (percent === 0) {
    return "Redosled prema popularnosti. Kada rezervišete, dodate restoran u omiljene ili ga pregledate, prilagodićemo ga vama.";
  }
  return `Redosled: ${percent}% prilagođeno vama, ostatak prema popularnosti.`;
}
