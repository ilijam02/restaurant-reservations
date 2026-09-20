-- Restaurant recommendations: the scoring (ISSUES.md: "Restaurant
-- recommendations - algorithm design"). Pure collaborative filtering - user-user
-- KNN over each customer's weighted, time-decayed affinity for restaurants -
-- with a popularity fallback for customers with no history and a smooth blend
-- in between. Computed on request in SQL; nothing is precomputed or stored
-- (fine at demo scale; a nightly precompute is the next step if the number of
-- events ever makes this slow).
--
-- The pieces, all in this file:
--   recommendation_settings   which parameter profile is active
--   recommendation_params()   the two parameter profiles ('realistic', 'demo')
--   recommendation_decay()    the time-decay factor
--   restaurant_affinities()   (user, restaurant) -> weighted, decayed affinity
--   recommendation_scores()   the algorithm for one user (internal)
--   recommend_restaurants()   what the app calls: the caller's own ranking
--
-- Everything but recommend_restaurants() is internal: executable by no app
-- role. The scoring reads every customer's behavior, so it is security definer
-- and the only thing it hands to a caller is restaurant ids and scores for the
-- caller's own ranking - never another customer's identity or bookings. The
-- "similar_users" column is a count, nothing more.

-- Which profile recommend_restaurants() uses when the caller doesn't name one.
-- One row (the `id boolean primary key check (id)` trick, as in
-- geocode_rate_limit); not reachable from the Data API - switch it in SQL:
--   update public.recommendation_settings set profile = 'realistic';
-- It defaults to 'demo' because the algorithm is being demonstrated before it
-- has real traffic; flip it once there is any.
create table public.recommendation_settings (
  id boolean primary key default true check (id),
  profile text not null default 'demo' check (profile in ('realistic', 'demo'))
);

insert into public.recommendation_settings (id) values (true);

alter table public.recommendation_settings enable row level security;
revoke all on table public.recommendation_settings from public, anon, authenticated;

-- The two parameter sets. Same algorithm, different constants: 'demo' is
-- deliberately more volatile so a view or a booking visibly reorders the list.
--   sim_half_life_days    decay used when finding similar customers (taste is
--                         stable, so slow) and for favorites and the blend's
--                         confidence
--   score_half_life_days  decay used for what those neighbors did, and for
--                         popularity (what is booked *now* should dominate)
--   k                     how many similar customers are consulted
--   blend_c               confidence = total / (total + blend_c): how much
--                         history it takes to trust the neighbors over
--                         popularity (small = trust quickly)
--   repeat_penalty        the largest share of a score a restaurant loses for
--                         having been visited recently (repeat visits stay
--                         recommendable, just a little lower)
--   repeat_scale          the affinity at which half of that penalty applies
--                         (~ one completed booking)
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

-- 0.5 ^ (age / half_life): 1 for something happening now (or booked for the
-- future), 0.5 after one half-life, 0.25 after two, and so on.
create function public.recommendation_decay(p_event_at timestamptz, p_as_of timestamptz, p_half_life_days numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select power(
    0.5::numeric,
    greatest(0::numeric, extract(epoch from (p_as_of - p_event_at))::numeric / 86400.0) / p_half_life_days
  );
$$;

-- One row per (customer, live restaurant) they have any signal for: the sum of
-- their events' weights, each decayed by its age. The weights are the same in
-- both profiles:
--   reservation completed 5, other active reservation 4 (no_show and cancelled
--   0), +1 when it has a confirmed order; favorite 3; page view 0.5 each,
--   capped at 2 in total per restaurant - so no number of page views can
--   outweigh a single booking.
-- A reservation's age runs from starts_at (a future booking has age 0), a
-- favorite's from created_at, a view's from last_viewed_at. Events older than
-- the horizon are ignored, and archived restaurants never appear (RLS doesn't
-- hide them, so it is filtered here, like every other restaurant query).
-- Reservations with no customer (an anonymized, deleted account) are skipped.
create function public.restaurant_affinities(
  p_half_life_days numeric,
  p_favorite_half_life_days numeric,
  p_as_of timestamptz
)
returns table (user_id uuid, restaurant_id uuid, affinity numeric)
language sql
stable
security definer
set search_path = ''
as $$
  with w as (
    select 5::numeric as completed, 4::numeric as active, 1::numeric as with_order,
           3::numeric as favorite, 0.5::numeric as view_each, 2::numeric as view_cap,
           interval '730 days' as horizon
  ),
  events as (
    select r.customer_id as user_id, r.restaurant_id,
           (b.base + case
                       when b.base > 0 and exists (
                         select 1 from public.orders o
                         where o.reservation_id = r.id and o.status = 'confirmed'
                       ) then w.with_order
                       else 0
                     end)
             * public.recommendation_decay(r.starts_at, p_as_of, p_half_life_days) as weight
    from public.reservations r
    cross join w
    cross join lateral (
      select case
               when r.status = 'completed' then w.completed
               when public.is_active_reservation_status(r.status) then w.active
               else 0::numeric
             end as base
    ) b
    where r.customer_id is not null
      and r.starts_at > p_as_of - w.horizon

    union all

    select f.user_id, f.restaurant_id,
           w.favorite * public.recommendation_decay(f.created_at, p_as_of, p_favorite_half_life_days)
    from public.favorites f
    cross join w
    where f.created_at > p_as_of - w.horizon

    union all

    select v.user_id, v.restaurant_id,
           least(v.view_count * w.view_each, w.view_cap)
             * public.recommendation_decay(v.last_viewed_at, p_as_of, p_half_life_days)
    from public.restaurant_views v
    cross join w
    where v.last_viewed_at > p_as_of - w.horizon
  )
  select e.user_id, e.restaurant_id, sum(e.weight) as affinity
  from events e
  join public.restaurants rest on rest.id = e.restaurant_id and rest.archived_at is null
  where e.weight > 0
  group by e.user_id, e.restaurant_id;
$$;

-- The algorithm, for one customer, at one point in time (p_as_of exists so a
-- test or a demo can be deterministic; the app always passes now()). Returns
-- every live restaurant, best first.
--
--   1. Affinity vectors are built twice: with the slow half-life (used to find
--      similar customers and to size the confidence) and with the fast one (used
--      for what neighbors did and for popularity).
--   2. Similarity = cosine between the customer's slow vector and every other
--      customer's (only customers who share at least one restaurant); the k most
--      similar are the neighbors.
--   3. knn_score(r) = sum over neighbors of similarity * neighbor's fast
--      affinity for r, scaled to 0..1 by the best restaurant. popularity_score(r)
--      = sum over all customers of their fast affinity, scaled to 0..1 the same way.
--   4. personalization = total / (total + blend_c), where total is the
--      customer's own slow affinity - 0 for a customer with no history (pure
--      popularity) and for one nobody is similar to, rising smoothly toward 1
--      as they accumulate history. Score = personalization * knn_score +
--      (1 - personalization) * popularity_score. Popularity also fills the tail,
--      so a restaurant no neighbor touched is still ranked.
--   5. A restaurant the customer has been to recently loses up to
--      repeat_penalty of its score (own fast affinity / (that + repeat_scale)).
-- Ties are broken by the restaurant's name, so with no data at all the order is
-- the plain alphabetical list the app showed before there was any ranking.
--
-- booked_before is true when the caller has a completed or active reservation
-- there; similar_users is how many of the neighbors have a signal for the
-- restaurant (an aggregate - never who).
create function public.recommendation_scores(
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
    select a.user_id, a.restaurant_id, a.affinity
    from prm
    cross join lateral public.restaurant_affinities(prm.sim_half_life_days, prm.sim_half_life_days, p_as_of) a
  ),
  fast as (
    select a.user_id, a.restaurant_id, a.affinity
    from prm
    cross join lateral public.restaurant_affinities(prm.score_half_life_days, prm.sim_half_life_days, p_as_of) a
  ),
  me as (select restaurant_id, affinity from slow where user_id = p_user_id),
  me_stats as (
    select coalesce(sqrt(sum(affinity * affinity)), 0) as norm, coalesce(sum(affinity), 0) as total
    from me
  ),
  norms as (select user_id, sqrt(sum(affinity * affinity)) as norm from slow group by user_id),
  sims as (
    select s.user_id, sum(s.affinity * m.affinity) / (n.norm * ms.norm) as sim
    from slow s
    join me m on m.restaurant_id = s.restaurant_id
    join norms n on n.user_id = s.user_id
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
  own as (select restaurant_id, affinity from fast where user_id = p_user_id),
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

-- What the customer pages call: the caller's own ranking, in the active
-- profile unless one is named ('realistic' / 'demo' - handy for comparing them
-- live). Customer-role accounts only, and only ever for the caller
-- (auth.uid()), never a user id from the request.
create function public.recommend_restaurants(p_profile text default null)
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
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'customer') then
    raise exception 'Samo nalozi tipa kupac mogu dobijati preporuke.';
  end if;

  return query
    select * from public.recommendation_scores(
      auth.uid(),
      coalesce(p_profile, (select s.profile from public.recommendation_settings s)),
      now()
    );
end;
$$;

revoke all on function public.recommendation_params(text) from public, anon, authenticated, service_role;
revoke all on function public.recommendation_decay(timestamptz, timestamptz, numeric) from public, anon, authenticated, service_role;
revoke all on function public.restaurant_affinities(numeric, numeric, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.recommendation_scores(uuid, text, timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.recommend_restaurants(text) from public, anon;
grant execute on function public.recommend_restaurants(text) to authenticated;
