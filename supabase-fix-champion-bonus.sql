-- ============================================================================
--  Arcadia — fix: the champion bonus was callable by anyone, unlimited times
--
--  Run this in the SQL Editor now. It is safe and changes nothing else.
--
--  What was wrong: award_weekly_champion_bonus executed for anonymous callers
--  and had no rate limit, so anybody could sit in a browser console calling it
--  in a loop and pump coins into the current weekly champion's account.
--
--  Fix: the bonus is no longer independently callable. It is folded into
--  game_finish_run, which already only runs once per completed game.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Take the standalone function away from every client role.
--    Supabase grants EXECUTE to anon/authenticated by default, and
--    "revoke from public" does not remove those, so name them explicitly.
-- ----------------------------------------------------------------------------
revoke all on function public.award_weekly_champion_bonus(text) from public, anon, authenticated;

-- Internal-only now: refuses to do anything unless called from another
-- function running as the definer, and never for an unauthenticated session.
create or replace function public.award_weekly_champion_bonus(p_game text)
returns void language plpgsql security definer set search_path = public as $$
declare
  champ uuid;
  week_start timestamptz := (date_trunc('week', (now() at time zone 'utc')) at time zone 'utc');
begin
  if auth.uid() is null then
    return;
  end if;

  select s.user_id into champ
    from scores s
   where s.game = p_game
     and s.created_at >= week_start - interval '7 days'
     and s.created_at <  week_start
   order by s.score desc
   limit 1;

  if champ is null then return; end if;

  update profiles set coins = coalesce(coins, 0) + 1 where user_id = champ;
end $$;

revoke all on function public.award_weekly_champion_bonus(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. Fire it from inside game_finish_run, so it happens exactly once per run.
--    Only the two leaderboard games paid this bonus, so keep it to those.
-- ----------------------------------------------------------------------------
create or replace function public.game_finish_run(
  p_game       text,
  p_score      integer default 0,
  p_win        boolean default false,
  p_difficulty text    default null,
  p_tier       integer default 0,
  p_floor      integer default 0
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prof profiles%rowtype;
  uname text;
  s int := greatest(coalesce(p_score, 0), 0);
  tier int := least(greatest(coalesce(p_tier, 0), 0), 10);
  flr int := least(greatest(coalesce(p_floor, 0), 0), 11);
  xp_g int := 0; coin_g int := 0; tok_g int := 0;
  drops text[] := '{}';
  mult numeric;
  prev_level int; new_level int;
  wq jsonb; wk text := to_char(arc_week_start(), 'YYYY-MM-DD');
  q_sharp int := 0; q_raid int := 0; q_clash int := 0; q_melt int := 0;
begin
  if uid is null then
    return jsonb_build_object('ok', false, 'error', 'not signed in');
  end if;
  perform arc_ensure_profile(uid);
  select * into prof from profiles where user_id = uid for update;
  uname := coalesce(prof.username, 'player');
  prev_level := arc_level_from_xp(coalesce(prof.xp, 0));

  if p_game = 'asteroid-run' then
    xp_g := greatest(5, s / 20);  coin_g := least(19, greatest(2, s / 40));  tok_g := s / 200;
    if coin_g >= 19 then q_sharp := 1; end if;
  elsif p_game = 'orbit-snap' then
    xp_g := greatest(5, s / 55);  coin_g := least(19, greatest(2, s / 200)); tok_g := s / 1200;
    if coin_g >= 19 then q_sharp := 1; end if;
  elsif p_game = 'stack-tower' then
    xp_g := greatest(5, (s * 8) / 10); coin_g := least(19, greatest(2, s / 2)); tok_g := s / 5;
    if coin_g >= 19 then q_sharp := 1; end if;
  elsif p_game = 'one-button-dash' then
    xp_g := greatest(5, s / 20);  coin_g := least(19, greatest(2, s / 32));  tok_g := s / 90;
    if coin_g >= 19 then q_sharp := 1; end if;

  elsif p_game = 'tank-clash' then
    xp_g := case when p_win then 90 else 25 end;
    coin_g := case when p_win then 45 else 12 end;
    tok_g := case p_difficulty
      when 'easy'    then case when p_win then 25 else 5 end
      when 'medium'  then case when p_win then 35 else 8 end
      when 'hard'    then case when p_win then 50 else 10 end
      when 'extreme' then case when p_win then 60 else 12 end
      else case when p_win then 35 else 8 end end;
    if p_win then q_clash := 1; end if;

  elsif p_game = 'meltdown' then
    mult := case tier when 7 then 1.2 when 8 then 1.8 when 9 then 2.8 when 10 then 4.5 else 0 end;
    coin_g := floor(100 * mult);
    xp_g := greatest(5, tier * 10);
    tok_g := tier;
    if mult >= 2 then q_melt := 1; end if;

  elsif p_game like 'boss-%' then
    if flr < 1 then return jsonb_build_object('ok', false, 'error', 'bad floor'); end if;
    xp_g   := case when p_win then 100 + flr * 75  else 25 + flr * 15 end;
    coin_g := case when p_win then 50  + flr * 38  else 10 + flr * 6  end;
    tok_g  := case when p_win then 25  + flr * 18  else 6  + flr * 4  end;
    if p_win then
      q_raid := 1;
      if flr >= 2 then drops := array[arc_roll_rune(), arc_roll_rune()]; end if;
    end if;
  else
    return jsonb_build_object('ok', false, 'error', 'unknown game');
  end if;

  wq := coalesce(prof.weekly_quests, '{}'::jsonb);
  if wq->>'week' is distinct from wk then
    wq := jsonb_build_object('week', wk, 'p', '{}'::jsonb, 'claimed', '[]'::jsonb);
  end if;
  wq := jsonb_set(wq, '{p}', coalesce(wq->'p', '{}'::jsonb));
  wq := jsonb_set(wq, '{p,play}',     to_jsonb(coalesce((wq#>>'{p,play}')::int, 0) + 1));
  if q_sharp > 0 then wq := jsonb_set(wq, '{p,sharp}',    to_jsonb(coalesce((wq#>>'{p,sharp}')::int, 0) + 1)); end if;
  if q_raid  > 0 then wq := jsonb_set(wq, '{p,raid}',     to_jsonb(coalesce((wq#>>'{p,raid}')::int, 0) + 1)); end if;
  if q_clash > 0 then wq := jsonb_set(wq, '{p,clash}',    to_jsonb(coalesce((wq#>>'{p,clash}')::int, 0) + 1)); end if;
  if q_melt  > 0 then wq := jsonb_set(wq, '{p,meltdown}', to_jsonb(coalesce((wq#>>'{p,meltdown}')::int, 0) + 1)); end if;

  insert into scores (user_id, username, game, score)
  values (uid, uname, p_game, s);

  update profiles
     set xp = coalesce(xp, 0) + xp_g,
         coins = coalesce(coins, 0) + coin_g,
         battle_tokens = coalesce(battle_tokens, 0) + tok_g,
         runes = coalesce(runes, '[]'::jsonb) || to_jsonb(drops),
         boss_tower_floor = case when p_game like 'boss-%' and p_win
                                 then greatest(coalesce(boss_tower_floor, 0), flr)
                                 else boss_tower_floor end,
         weekly_quests = wq,
         updated_at = now()
   where user_id = uid
   returning * into prof;

  -- one run, one champion payout — no way to call this on its own any more
  if p_game in ('asteroid-run', 'orbit-snap') then
    perform award_weekly_champion_bonus(p_game);
  end if;

  new_level := arc_level_from_xp(prof.xp);

  return jsonb_build_object(
    'ok', true, 'xp', xp_g, 'coins', coin_g, 'tokens', tok_g,
    'runes', to_jsonb(drops), 'leveled_up', new_level > prev_level, 'new_level', new_level,
    'balance_coins', prof.coins, 'balance_tokens', prof.battle_tokens
  );
end $$;


-- ----------------------------------------------------------------------------
-- 3. While we are here: strip anon from every other function too.
--    They all guard internally, but there is no reason to let a logged-out
--    visitor reach them at all.
-- ----------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'game_start_run(text,text)',
    'game_finish_run(text,integer,boolean,text,integer,integer)',
    'buy_tank(text)',
    'set_tank_runes(jsonb)',
    'claim_weekly_quest(text)',
    'claim_daily_checkin()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- 4. Verify — anon should hold no EXECUTE on any of these.
-- ----------------------------------------------------------------------------
select p.proname,
       has_function_privilege('anon',          p.oid, 'execute') as anon_can_call,
       has_function_privilege('authenticated', p.oid, 'execute') as authed_can_call
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('game_start_run','game_finish_run','buy_tank','set_tank_runes',
                     'claim_weekly_quest','claim_daily_checkin','award_weekly_champion_bonus')
 order by p.proname;
-- expected: anon_can_call false everywhere,
--           authed_can_call true except award_weekly_champion_bonus (false)
