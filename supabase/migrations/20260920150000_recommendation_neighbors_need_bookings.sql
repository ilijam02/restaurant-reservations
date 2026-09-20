-- Replaces the evidence weighting of 20260920140000 with a simpler rule:
--
--   Only customers with at least one COMPLETED booking can count as "similar to
--   you". Customers whose history is page views, favorites and bookings that
--   were never carried out cannot.
--
-- Why. Views and favorites cost nothing and signup is open, so throwaway
-- accounts can fake them at will. An upcoming or ongoing booking is nearly as
-- free (create_reservation() is open to any customer account, and it can be
-- cancelled afterwards), and cancelled/no-show ones count for nothing. A
-- COMPLETED booking is the one signal that is costly to fake: the restaurant's
-- staff have to have seated the party. The evidence weighting of 20260920140000
-- (similarity * e/(e + lambda), e = bookings + 0.25 * views/favorites) only
-- stopped the cheapest fakes, and review found two ways around it:
--   * e summed views/favorites over ALL of a neighbor's restaurants, so an
--     account favoriting ~4 restaurants (the victim's two, the target and a
--     decoy) had trust 0.5 and cosine 0.71 - weight 0.354 against a real
--     neighbor's 0.385 - and three such accounts pushed their target from
--     nowhere to the top of the list;
--   * knn_score is divided by its maximum and personalization only checks that
--     a neighbor exists, so trust (a constant factor) cancelled out: a customer
--     with no real neighbor got a single fake as their only neighbor at full
--     weight.
-- Requiring a completed booking removes all of those at once - an account
-- without one is never a neighbor, so it has no weight to inflate and cannot become the sole
-- neighbor - and it is one rule instead of a formula with two tuning numbers,
-- so evidence_lambda and signal_trust are gone again.
--
-- What is still open (documented in ISSUES.md): an attacker who gets bookings
-- genuinely completed (that takes a restaurant and a staff account); and popularity, which sums everyone's activity, free accounts
-- included. Both need account-level defenses (email verification, rate limits),
-- not a scoring rule. Customers with only favorites/views are still recommended
-- things normally - they just can't be the "someone like you" for anyone else.

-- The two columns added in 20260920140000 go away, so the function is recreated.
drop function public.recommendation_params(text);

create function public.recommendation_params(p_profile text)
returns table (
  sim_half_life_days numeric,
  score_half_life_days numeric,
  k integer,
  blend_c numeric,
  repeat_penalty numeric,
  repeat_scale numeric
)
language plpgsql
stable
set search_path = ''
as $$
begin
  return query
    select v.sim_half_life_days, v.score_half_life_days, v.k, v.blend_c, v.repeat_penalty, v.repeat_scale
    from (values
      ('realistic'::text, 180::numeric, 30::numeric, 30::integer, 10::numeric, 0.3::numeric, 5::numeric),
      ('demo'::text,       30::numeric,  7::numeric,  4::integer,  2::numeric, 0.3::numeric, 5::numeric)
    ) as v(profile, sim_half_life_days, score_half_life_days, k, blend_c, repeat_penalty, repeat_scale)
    where v.profile = p_profile;

  if not found then
    raise exception 'Nepoznat profil preporuka.';
  end if;
end;
$$;

revoke all on function public.recommendation_params(text) from public, anon, authenticated, service_role;

-- The algorithm, for one customer at one instant (p_as_of exists so a test or a
-- demo is deterministic). Returns every live restaurant, best first.
--   1. Affinities: what each customer did with each restaurant (bookings far
--      above favorites, far above page views), fading with age. Built twice: with
--      the slow half-life (for finding similar customers and sizing the blend)
--      and the fast one (for what neighbors did and for popularity).
--   2. Neighbors: the k customers most similar to the caller by cosine
--      similarity - counting only customers with a completed booking.
--   3. knn_score(r) = what those neighbors did at r recently, weighted by how
--      similar they are, scaled to 0..1; popularity_score(r) = what everyone did
--      at r recently, scaled to 0..1.
--   4. personalization = own total / (own total + blend_c): 0 for a caller with
--      no history or no neighbors, rising toward 1 with history. Score =
--      personalization * knn + (1 - personalization) * popularity.
--   5. A restaurant the caller booked recently loses up to repeat_penalty.
-- Ties are broken by restaurant name.
create or replace function public.recommendation_scores(
  p_user_id uuid,
  p_profile text,
  p_as_of timestamptz default now()
)
returns table (
  rank integer,
  restaurant_id uuid,
  score numeric,
  knn_score numeric,
  popularity_score numeric,
  personalization numeric,
  similar_users integer,
  booked_before boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  with
  prm as (select * from public.recommendation_params(p_profile)),
  slow as (
    select a.user_id, a.restaurant_id, a.affinity, a.booking_affinity
    from prm
    cross join lateral public.restaurant_affinities(prm.sim_half_life_days, prm.sim_half_life_days, p_as_of) a
  ),
  fast as (
    select a.user_id, a.restaurant_id, a.affinity, a.booking_affinity
    from prm
    cross join lateral public.restaurant_affinities(prm.score_half_life_days, prm.sim_half_life_days, p_as_of) a
  ),
  me as (select restaurant_id, affinity from slow where user_id = p_user_id),
  me_stats as (
    select coalesce(sqrt(sum(affinity * affinity)), 0) as norm, coalesce(sum(affinity), 0) as total
    from me
  ),
  norms as (select user_id, sqrt(sum(affinity * affinity)) as norm from slow group by user_id),
  -- customers with a COMPLETED booking: the only ones who may count as similar
  -- (an upcoming or ongoing booking is free to create and cancel; a completed
  -- one needs the restaurant's staff to have seated the party)
  bookers as (
    select distinct res.customer_id as user_id
    from public.reservations res
    where res.customer_id is not null
      and res.status = 'completed'
      and res.starts_at > p_as_of - interval '730 days'
  ),
  sims as (
    select s.user_id, sum(s.affinity * m.affinity) / (n.norm * ms.norm) as sim
    from slow s
    join me m on m.restaurant_id = s.restaurant_id
    join norms n on n.user_id = s.user_id
    join bookers b on b.user_id = s.user_id
    cross join me_stats ms
    where s.user_id <> p_user_id
    group by s.user_id, n.norm, ms.norm
  ),
  nbrs as (
    select user_id, sim from sims order by sim desc, user_id limit (select k from prm)
  ),
  knn as (
    select f.restaurant_id, sum(nb.sim * f.affinity) as raw, count(*)::integer as users
    from nbrs nb
    join fast f on f.user_id = nb.user_id
    group by f.restaurant_id
  ),
  pop as (select restaurant_id, sum(affinity) as raw from fast group by restaurant_id),
  own as (
    select restaurant_id, booking_affinity as affinity
    from fast
    where user_id = p_user_id and booking_affinity > 0
  ),
  visited as (
    select distinct res.restaurant_id
    from public.reservations res
    where res.customer_id = p_user_id
      and (res.status = 'completed' or public.is_active_reservation_status(res.status))
  ),
  ctx as (
    select
      case when (select count(*) from nbrs) > 0 then ms.total / (ms.total + prm.blend_c) else 0 end as pers,
      coalesce((select max(raw) from knn), 0) as knn_max,
      coalesce((select max(raw) from pop), 0) as pop_max,
      prm.repeat_penalty,
      prm.repeat_scale
    from prm
    cross join me_stats ms
  ),
  scored as (
    select
      r.id as restaurant_id,
      r.name,
      coalesce(knn.raw / nullif(ctx.knn_max, 0), 0) as knn_score,
      coalesce(pop.raw / nullif(ctx.pop_max, 0), 0) as popularity_score,
      ctx.pers as personalization,
      coalesce(knn.users, 0) as similar_users,
      (visited.restaurant_id is not null) as booked_before,
      (
        ctx.pers * coalesce(knn.raw / nullif(ctx.knn_max, 0), 0)
        + (1 - ctx.pers) * coalesce(pop.raw / nullif(ctx.pop_max, 0), 0)
      ) * (1 - ctx.repeat_penalty * coalesce(own.affinity / (own.affinity + ctx.repeat_scale), 0)) as score
    from public.restaurants r
    cross join ctx
    left join knn on knn.restaurant_id = r.id
    left join pop on pop.restaurant_id = r.id
    left join own on own.restaurant_id = r.id
    left join visited on visited.restaurant_id = r.id
    where r.archived_at is null
  )
  select
    (row_number() over (order by s.score desc, s.name))::integer,
    s.restaurant_id, s.score, s.knn_score, s.popularity_score,
    s.personalization, s.similar_users::integer, s.booked_before
  from scored s
  order by 1;
$$;
