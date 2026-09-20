-- Fixes from the review of the recommendation feature (20260920100000-120000).
--
-- 1. What the app can read (privacy). recommend_restaurants() used to return
--    score, knn_score and popularity_score. knn_score is the neighbors' own
--    (recency-weighted) activity scaled to 0..1, so a probe account could read
--    another customer's profile off it when that customer was one of its few
--    neighbors - which contradicted the "no column exposes another customer's
--    behavior" claim the earlier migration and docs made. It now returns only
--    what the UI shows, and no longer takes a profile argument (a caller could
--    pick 'demo' vs 'realistic' to get a second, differently-decayed
--    measurement). What is left, deliberately (the "minimal" fix): similar_users
--    is still an exact count, `popular` says whether anyone at all has a signal
--    at the restaurant, and the order itself depends on other customers'
--    behavior. So a customer's *relationship to a restaurant* can still be
--    inferred in small groups by someone who crafts their own signals; the
--    scores, and therefore the neighbors' profiles, can not. Not fixed at all:
--    one-view accounts still look maximally similar to whoever shares that view,
--    so throwaway accounts can steer other customers' lists (signup is open).
--    The next step for either is a minimum group size for similar_users/popular
--    and shrinking similarity by how much evidence a neighbor has.
--
-- 2. The repeat-visit penalty is based on *bookings* only. It was based on the
--    customer's own affinity from every signal, so favoriting a restaurant (or
--    viewing it twice) lowered its rank by ~10% - not "having been there".
--    restaurant_affinities() gains a booking_affinity column (the reservation
--    part of the sum) for it.
--
-- 3. Restaurant names are compared after normalization, not just lower/btrim:
--    the unique index accepted "Pica  Napoli" (two spaces), tabs, non-breaking
--    and zero-width characters, and "Пица Наполи" (Serbian Cyrillic) next to
--    "Pica Napoli" - indistinguishable in the list, which is what the rule is
--    for. normalize_restaurant_name() removes zero-width/format characters,
--    applies Unicode NFKC (which turns every kind of exotic space into a plain
--    one), lower-cases, transliterates Serbian Cyrillic to Latin, collapses
--    whitespace and trims. NOT covered: homoglyphs that are not the Cyrillic
--    letter's phonetic twin (a Cyrillic "Р" that looks like Latin "P" maps to
--    "r"), and "dj" vs "đ" style respelling.

-- === 1. recommend_restaurants(): narrower result, no profile argument ===
drop function public.recommend_restaurants(text);

create function public.recommend_restaurants()
returns table (
  rank integer,
  restaurant_id uuid,
  personalization numeric,
  similar_users integer,
  booked_before boolean,
  popular boolean
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
    select s.rank, s.restaurant_id, s.personalization, s.similar_users, s.booked_before, (s.popularity_score > 0)
    from public.recommendation_scores(
      auth.uid(),
      (select st.profile from public.recommendation_settings st),
      now()
    ) s;
end;
$$;

revoke all on function public.recommend_restaurants() from public, anon;
grant execute on function public.recommend_restaurants() to authenticated;

-- === 2. Booking-only repeat penalty ===
-- The return type changes (a new column), so the function is dropped and
-- recreated; recommendation_scores() below is a SQL-language function, which
-- Postgres does not track as a dependent.
drop function public.restaurant_affinities(numeric, numeric, timestamptz);

create function public.restaurant_affinities(
  p_half_life_days numeric,
  p_favorite_half_life_days numeric,
  p_as_of timestamptz
)
returns table (user_id uuid, restaurant_id uuid, affinity numeric, booking_affinity numeric)
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
    select r.customer_id as user_id, r.restaurant_id, 'booking'::text as kind,
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

    select f.user_id, f.restaurant_id, 'favorite'::text,
           w.favorite * public.recommendation_decay(f.created_at, p_as_of, p_favorite_half_life_days)
    from public.favorites f
    cross join w
    where f.created_at > p_as_of - w.horizon

    union all

    select v.user_id, v.restaurant_id, 'view'::text,
           least(v.view_count * w.view_each, w.view_cap)
             * public.recommendation_decay(v.last_viewed_at, p_as_of, p_half_life_days)
    from public.restaurant_views v
    cross join w
    where v.last_viewed_at > p_as_of - w.horizon
  )
  select e.user_id, e.restaurant_id,
         sum(e.weight) as affinity,
         coalesce(sum(e.weight) filter (where e.kind = 'booking'), 0) as booking_affinity
  from events e
  join public.restaurants rest on rest.id = e.restaurant_id and rest.archived_at is null
  where e.weight > 0
  group by e.user_id, e.restaurant_id;
$$;

revoke all on function public.restaurant_affinities(numeric, numeric, timestamptz) from public, anon, authenticated, service_role;

-- Same algorithm as before (see 20260920120000_recommendation_scoring.sql for
-- the full description) except step 5: the repeat-visit penalty now reads the
-- customer's own *booking* affinity, not their affinity from every signal.
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
    select a.user_id, a.restaurant_id, a.affinity
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

-- === 3. Restaurant names: compare after normalization ===
create function public.normalize_restaurant_name(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(
    regexp_replace(
      translate(
        replace(replace(replace(
          lower(normalize(
            -- zero-width and other invisible format characters (ZWSP, ZWNJ,
            -- ZWJ, word joiner, BOM, soft hyphen) are removed outright
            regexp_replace(p_name, '[​-‍⁠﻿­]', '', 'g'),
            NFKC
          )),
          'љ', 'lj'), 'њ', 'nj'), 'џ', 'dž'),
        'абвгдђежзијклмнопрстћуфхцчш',
        'abvgdđežzijklmnoprstćufhcčš'
      ),
      '\s+', ' ', 'g'
    )
  );
$$;

drop index public.restaurants_live_name_unique_idx;

create unique index restaurants_live_name_unique_idx
  on public.restaurants (public.normalize_restaurant_name(name))
  where archived_at is null;
