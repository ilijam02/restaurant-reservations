-- Sybil resistance for the recommendations (review finding: "one-view accounts
-- push real neighbors out of the top-k").
--
-- The problem: neighbors are the k customers with the highest cosine similarity
-- to the caller, and cosine similarity ignores how much evidence a customer
-- has. An account whose whole history is one page view of a restaurant the
-- caller booked looks *more* similar than a real customer who booked there and
-- somewhere else too (its vector points exactly the same way). Signup is open
-- and page views and favorites cost nothing, so a handful of throwaway
-- accounts each viewing one restaurant fill the top-k and decide what everyone
-- who shares that restaurant is recommended (reproduced: four one-view
-- accounts moved Ana's first place from Osaka to Sakura, `similar_users`
-- going from 2 real neighbors to 4 fake ones).
--
-- The fix: a neighbor's similarity is multiplied by how much evidence stands
-- behind them,
--     trust = e / (e + evidence_lambda),
--     e     = their booking affinity + signal_trust * their view/favorite affinity
-- (slow-decayed, summed over all their restaurants). A booking is a real slot
-- at a real restaurant - it can be cancelled or missed, but those count for
-- nothing, and completed/active ones are visible to the restaurant - so it is
-- the evidence that is costly to fake; a view is free, so views and favorites
-- count for a quarter. A real customer with a couple of bookings has trust of
-- ~0.75 (demo); a one-view account ~0.04; a favorite-only account ~0.2. The
-- weight also carries into the neighbor's contribution to knn_score, so a
-- fake that still squeaks into the top-k counts for little. Real neighbors are
-- scaled by similar factors, and the score is normalised by its maximum, so an
-- honest ranking barely moves.
--
-- What this does NOT do, and cannot do by itself: stop an attacker who is
-- willing to make real bookings (they get full evidence), or poison
-- *popularity* - the cold-start ranking sums everyone's activity, including
-- free accounts', and an army of accounts favoriting one restaurant still
-- moves it. Both need account-level defenses (email verification, signup and
-- booking rate limits, anomaly detection) that no scoring formula replaces.
-- The residual count leak (`similar_users`) from the previous review fix is
-- also untouched.

-- Two new parameters, so the function is recreated (its return type changes).
drop function public.recommendation_params(text);

create function public.recommendation_params(p_profile text)
returns table (
  sim_half_life_days numeric,
  score_half_life_days numeric,
  k integer,
  blend_c numeric,
  repeat_penalty numeric,
  repeat_scale numeric,
  evidence_lambda numeric,
  signal_trust numeric
)
language plpgsql
stable
set search_path = ''
as $$
begin
  return query
    select v.sim_half_life_days, v.score_half_life_days, v.k, v.blend_c, v.repeat_penalty, v.repeat_scale,
           v.evidence_lambda, v.signal_trust
    from (values
      ('realistic'::text, 180::numeric, 30::numeric, 30::integer, 10::numeric, 0.3::numeric, 5::numeric, 5::numeric, 0.25::numeric),
      ('demo'::text,       30::numeric,  7::numeric,  4::integer,  2::numeric, 0.3::numeric, 5::numeric, 3::numeric, 0.25::numeric)
    ) as v(profile, sim_half_life_days, score_half_life_days, k, blend_c, repeat_penalty, repeat_scale, evidence_lambda, signal_trust)
    where v.profile = p_profile;

  if not found then
    raise exception 'Nepoznat profil preporuka.';
  end if;
end;
$$;

revoke all on function public.recommendation_params(text) from public, anon, authenticated, service_role;

-- Same algorithm as before (20260920120000 / 20260920130000) except step 2: a
-- neighbor's similarity is scaled by their evidence (see above).
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
  -- how much real evidence stands behind each customer: bookings in full,
  -- views and favorites (free to fake) at signal_trust
  evidence as (
    select s.user_id,
           sum(s.booking_affinity) + (select signal_trust from prm) * sum(s.affinity - s.booking_affinity) as e
    from slow s
    group by s.user_id
  ),
  sims as (
    select s.user_id,
           sum(s.affinity * m.affinity) / (n.norm * ms.norm) * (ev.e / (ev.e + prm.evidence_lambda)) as sim
    from slow s
    join me m on m.restaurant_id = s.restaurant_id
    join norms n on n.user_id = s.user_id
    join evidence ev on ev.user_id = s.user_id
    cross join me_stats ms
    cross join prm
    where s.user_id <> p_user_id
    group by s.user_id, n.norm, ms.norm, ev.e, prm.evidence_lambda
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
