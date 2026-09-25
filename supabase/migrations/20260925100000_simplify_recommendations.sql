-- Simplifies the recommendation algorithm (and what the app reads from it) so
-- it can be explained in a few sentences. Three things go:
--
--   1. The repeat-visit penalty. A restaurant the customer booked recently no
--      longer loses up to 30% of its score, so the `own` CTE, repeat_penalty and
--      repeat_scale are gone - and with them the booking_affinity column of
--      restaurant_affinities(), which nothing else used.
--   2. The second half-life. There were two ("slow" for finding similar
--      customers, "fast" for what they did and for popularity), which meant every
--      affinity was computed twice. There is one now, half_life_days, used for
--      everything: bookings, favorites and page views all fade with it, similarity
--      and scores are built from the same affinities, and restaurant_affinities()
--      takes one half-life instead of two.
--   3. The per-card hints. recommend_restaurants() returns only rank,
--      restaurant_id and personalization (the same for every row of one
--      customer's list); similar_users, booked_before and popular are gone, and
--      with them the `visited` CTE and the neighbor counting.
--
-- What stays: the weights (completed booking 5, other active booking 4, +1 with
-- a confirmed order, favorite 3, page views 0.5 each capped at 2 per pair), the
-- rule that only customers with a completed booking can count as "similar to
-- you", the blend personalization = total / (total + blend_c), popularity as the
-- fallback, ties broken by restaurant name.
--
-- Parameters, per profile:
--                       half_life_days   k    blend_c
--   demo (ships)              14           4      2
--   realistic                 60          30     10
-- 'demo' stays visibly volatile because k and blend_c are small: one page view
-- moves a customer with no history to 20% personalized (0.5 / (0.5 + 2)), a
-- favorite on top to about 64%, a booking to about 80%, and the demo data spans
-- 1 to 25 days, which a 14-day half-life turns into clearly different weights
-- (yesterday's booking counts ~0.95, one from 25 days ago ~0.29).
--
-- Every function whose result type changes is dropped and recreated, and they
-- are created in dependency order (params, affinities, scores, wrapper) because
-- SQL-language functions are checked at creation time.

drop function public.recommend_restaurants();
drop function public.recommendation_scores(uuid, text, timestamptz);
drop function public.restaurant_affinities(numeric, numeric, timestamptz);
drop function public.recommendation_params(text);

-- === Parameters ===
create function public.recommendation_params(p_profile text)
returns table (
  half_life_days numeric,
  k integer,
  blend_c numeric
)
language plpgsql
stable
set search_path = ''
as $$
begin
  return query
    select v.half_life_days, v.k, v.blend_c
    from (values
      ('realistic'::text, 60::numeric, 30::integer, 10::numeric),
      ('demo'::text,      14::numeric,  4::integer,  2::numeric)
    ) as v(profile, half_life_days, k, blend_c)
    where v.profile = p_profile;

  if not found then
    raise exception 'Nepoznat profil preporuka.';
  end if;
end;
$$;

revoke all on function public.recommendation_params(text) from public, anon, authenticated, service_role;

-- === What each customer did at each restaurant ===
-- One row per (customer, live restaurant): the sum of their events' weights,
-- each faded by its age with the single half-life:
--   completed booking 5, other active booking 4 (+1 with a confirmed order;
--   no_show and cancelled 0), favorite 3, page view 0.5 each capped at 2 per
--   restaurant. A booking's age runs from starts_at (a future booking has age
--   0), a favorite's from created_at, a view's from last_viewed_at. Events older
--   than 730 days, bookings with no customer (deleted account) and archived
--   restaurants are ignored.
create function public.restaurant_affinities(
  p_half_life_days numeric,
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
           w.favorite * public.recommendation_decay(f.created_at, p_as_of, p_half_life_days)
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

revoke all on function public.restaurant_affinities(numeric, timestamptz) from public, anon, authenticated, service_role;

-- === The algorithm, for one customer at one instant ===
-- (p_as_of exists so a test or a demo is deterministic.) Returns every live
-- restaurant, best first.
--   1. Affinities: what every customer did at every restaurant (above).
--   2. Neighbors: the k customers most similar to the caller by cosine
--      similarity of their affinity vectors - counting only customers with a
--      completed booking (views, favorites and upcoming bookings are free to
--      fake; a completed booking needs the restaurant's staff to have seated the
--      party).
--   3. knn_score(r): what those neighbors did at r, each weighted by how similar
--      they are, scaled to 0..1 by the best restaurant.
--      popularity_score(r): what everyone did at r, scaled to 0..1 the same way.
--   4. personalization = own total / (own total + blend_c): 0 for a customer
--      with no history or no neighbors, rising toward 1 with history.
--      score = personalization * knn_score + (1 - personalization) * popularity_score.
-- Ties are broken by the restaurant's name, so with no data at all the order is
-- the plain alphabetical list.
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
  personalization numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  with
  prm as (select * from public.recommendation_params(p_profile)),
  aff as (
    select a.user_id, a.restaurant_id, a.affinity
    from prm
    cross join lateral public.restaurant_affinities(prm.half_life_days, p_as_of) a
  ),
  me as (select restaurant_id, affinity from aff where user_id = p_user_id),
  me_stats as (
    select coalesce(sqrt(sum(affinity * affinity)), 0) as norm, coalesce(sum(affinity), 0) as total
    from me
  ),
  norms as (select user_id, sqrt(sum(affinity * affinity)) as norm from aff group by user_id),
  -- customers with a COMPLETED booking: the only ones who may count as similar
  bookers as (
    select distinct res.customer_id as user_id
    from public.reservations res
    where res.customer_id is not null
      and res.status = 'completed'
      and res.starts_at > p_as_of - interval '730 days'
  ),
  sims as (
    select a.user_id, sum(a.affinity * m.affinity) / (n.norm * ms.norm) as sim
    from aff a
    join me m on m.restaurant_id = a.restaurant_id
    join norms n on n.user_id = a.user_id
    join bookers b on b.user_id = a.user_id
    cross join me_stats ms
    where a.user_id <> p_user_id
    group by a.user_id, n.norm, ms.norm
  ),
  nbrs as (
    select user_id, sim from sims order by sim desc, user_id limit (select k from prm)
  ),
  knn as (
    select a.restaurant_id, sum(nb.sim * a.affinity) as raw
    from nbrs nb
    join aff a on a.user_id = nb.user_id
    group by a.restaurant_id
  ),
  pop as (select restaurant_id, sum(affinity) as raw from aff group by restaurant_id),
  ctx as (
    select
      case when exists (select 1 from nbrs) then ms.total / (ms.total + prm.blend_c) else 0 end as pers,
      coalesce((select max(raw) from knn), 0) as knn_max,
      coalesce((select max(raw) from pop), 0) as pop_max
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
      ctx.pers * coalesce(knn.raw / nullif(ctx.knn_max, 0), 0)
        + (1 - ctx.pers) * coalesce(pop.raw / nullif(ctx.pop_max, 0), 0) as score
    from public.restaurants r
    cross join ctx
    left join knn on knn.restaurant_id = r.id
    left join pop on pop.restaurant_id = r.id
    where r.archived_at is null
  )
  select
    (row_number() over (order by s.score desc, s.name))::integer,
    s.restaurant_id, s.score, s.knn_score, s.popularity_score, s.personalization
  from scored s
  order by 1;
$$;

revoke all on function public.recommendation_scores(uuid, text, timestamptz) from public, anon, authenticated, service_role;

-- === What the app calls ===
-- The caller's own ranking. Customer-role accounts only, always for auth.uid()
-- (never a user id from the request), in the profile of recommendation_settings.
-- personalization is the same on every row: the share of the order that is
-- tailored to the customer, the rest being popularity.
create function public.recommend_restaurants()
returns table (
  rank integer,
  restaurant_id uuid,
  personalization numeric
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
    select s.rank, s.restaurant_id, s.personalization
    from public.recommendation_scores(
      auth.uid(),
      (select st.profile from public.recommendation_settings st),
      now()
    ) s;
end;
$$;

revoke all on function public.recommend_restaurants() from public, anon;
grant execute on function public.recommend_restaurants() to authenticated;
