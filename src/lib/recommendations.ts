// One row of recommend_restaurants() (see 20260925100000_simplify_recommendations.sql):
// the caller's own ranking. It deliberately carries no scores - the
// neighbors' activity scaled to 0..1 would let a customer read another
// customer's behavior off it. `personalization` (0..1) is the same on every row
// of one customer's list: the share of the order that is tailored to them, the
// rest being popularity.
export type Recommendation = {
  rank: number;
  restaurant_id: string;
  personalization: number;
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
