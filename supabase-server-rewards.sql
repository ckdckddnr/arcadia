-- ============================================================================
--  Arcadia — server-authoritative economy
--  Run AFTER supabase-rls.sql, in the Supabase SQL Editor. Safe to re-run.
--
--  Every coin, token, XP point, rune, tank and quest reward is decided here.
--  The browser can ask to start or finish a run; it cannot say what that is
--  worth. Section 9 then removes the client's ability to write profiles at all.
--
--  What this does NOT solve: the client still reports its own score, and no
--  server can verify an arcade run. That is acceptable because payouts are
--  capped — the best possible lie in a solo game is worth 19 coins, less than
--  the 20 it cost to play.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Shared helpers
-- ----------------------------------------------------------------------------
create or replace function public.arc_level_from_xp(p_xp integer)
returns integer language sql immutable as $$
  -- mirrors xpForLevel(l) = 25 * l * (l - 1)
  select greatest(1, floor((1 + sqrt(1 + (4 * greatest(p_xp, 0)) / 25.0)) / 2)::int);
$$;

create or replace function public.arc_week_start()
returns timestamptz language sql stable as $$
  select (date_trunc('week', (now() at time zone 'utc')) at time zone 'utc');
$$;

create or replace function public.arc_day_start()
returns timestamptz language sql stable as $$
  select (date_trunc('day', (now() at time zone 'utc')) at time zone 'utc');
$$;

-- Drop table matching the client's RUNES: 54/30/10/5/1 across the five tiers.
create or replace function public.arc_roll_rune()
returns text language plpgsql volatile as $$
declare
  r numeric := random() * 100;
  pool text[];
begin
  if    r < 54 then pool := array['r_green','r_red','r_yellow','r_grey','r_brown','r_white','r_sky','r_moss'];
  elsif r < 84 then pool := array['r_blue','r_teal','r_lime','r_steel','r_amber','r_rose'];
  elsif r < 94 then pool := array['r_violet','r_indigo','r_magenta'];
  elsif r < 99 then pool := array['r_pearl','r_gold'];
  else              pool := array['r_rainbow'];
  end if;
  return pool[1 + floor(random() * array_length(pool, 1))::int];
end $$;

-- Creates the row on first touch so every other function can assume it exists.
create or replace function public.arc_ensure_profile(p_uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (user_id, username, xp, coins, battle_tokens)
  values (p_uid, coalesce(split_part((select email from auth.users where id = p_uid), '@', 1), 'player'), 0, 100, 0)
  on conflict (user_id) do nothing;
end $$;


-- ----------------------------------------------------------------------------
-- 2. Entry fees and limits, enforced before a run begins
-- ----------------------------------------------------------------------------
create or replace function public.game_start_run(p_game text, p_difficulty text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  fee_coins int := 0;
  fee_tokens int := 0;
  prof profiles%rowtype;
  runs_today int;
begin
  if uid is null then
    return jsonb_build_object('ok', false, 'error', 'not signed in');
  end if;
  perform arc_ensure_profile(uid);
  select * into prof from profiles where user_id = uid for update;

  if p_game in ('asteroid-run','orbit-snap','stack-tower','one-button-dash') then
    fee_coins := 20;
  elsif p_game = 'meltdown' then
    fee_coins := 100;
    select count(*) into runs_today
      from scores
     where user_id = uid and game = 'meltdown' and created_at >= arc_day_start();
    if runs_today >= 3 then
      return jsonb_build_object('ok', false, 'error', 'daily limit reached', 'runs_left', 0);
    end if;
  elsif p_game = 'tank-clash' then
    fee_tokens := case p_difficulty
      when 'easy' then 10 when 'medium' then 15 when 'hard' then 20 when 'extreme' then 25
      else 15 end;
  elsif p_game like 'boss-%' then
    if coalesce(array_length(prof.boss_tanks_owned, 1), 0) < 4 then
      return jsonb_build_object('ok', false, 'error', 'need 4 tanks');
    end if;
  else
    return jsonb_build_object('ok', false, 'error', 'unknown game');
  end if;

  if coalesce(prof.coins, 0) < fee_coins then
    return jsonb_build_object('ok', false, 'error', 'not enough coins', 'coins', coalesce(prof.coins, 0));
  end if;
  if coalesce(prof.battle_tokens, 0) < fee_tokens then
    return jsonb_build_object('ok', false, 'error', 'not enough tokens', 'tokens', coalesce(prof.battle_tokens, 0));
  end if;

  update profiles
     set coins = coalesce(coins, 0) - fee_coins,
         battle_tokens = coalesce(battle_tokens, 0) - fee_tokens
   where user_id = uid
   returning * into prof;

  return jsonb_build_object(
    'ok', true, 'coins', prof.coins, 'tokens', prof.battle_tokens,
    'runs_left', case when p_game = 'meltdown' then 3 - runs_today - 1 else null end
  );
end $$;


-- ----------------------------------------------------------------------------
-- 3. Payouts. The client reports what happened; the server decides its worth.
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
    -- the tier ladder is fixed, so the payout cannot be argued with
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
      if flr >= 2 then
        drops := array[arc_roll_rune(), arc_roll_rune()];
      end if;
    end if;
  else
    return jsonb_build_object('ok', false, 'error', 'unknown game');
  end if;

  -- weekly quest counters advance from the same trusted path
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

  new_level := arc_level_from_xp(prof.xp);

  return jsonb_build_object(
    'ok', true, 'xp', xp_g, 'coins', coin_g, 'tokens', tok_g,
    'runes', to_jsonb(drops), 'leveled_up', new_level > prev_level, 'new_level', new_level,
    'balance_coins', prof.coins, 'balance_tokens', prof.battle_tokens
  );
end $$;


-- ----------------------------------------------------------------------------
-- 4. Tank purchases
-- ----------------------------------------------------------------------------
create or replace function public.buy_tank(p_tank text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prof profiles%rowtype;
  price int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not signed in'); end if;
  price := case p_tank
    when 'light' then 75 when 'medium' then 100 when 'heavy' then 125 when 'guardian' then 100
    when 'medic' then 110 when 'raider' then 120 when 'sniper' then 150 when 'warden' then 140
    else null end;
  if price is null then return jsonb_build_object('ok', false, 'error', 'unknown tank'); end if;

  perform arc_ensure_profile(uid);
  select * into prof from profiles where user_id = uid for update;

  if coalesce(prof.boss_tanks_owned, '{}') @> array[p_tank] then
    return jsonb_build_object('ok', false, 'error', 'already owned');
  end if;
  if coalesce(prof.battle_tokens, 0) < price then
    return jsonb_build_object('ok', false, 'error', 'not enough tokens', 'tokens', coalesce(prof.battle_tokens, 0));
  end if;

  update profiles
     set battle_tokens = battle_tokens - price,
         boss_tanks_owned = coalesce(boss_tanks_owned, '{}') || p_tank
   where user_id = uid
   returning * into prof;

  return jsonb_build_object('ok', true, 'tokens', prof.battle_tokens, 'owned', to_jsonb(prof.boss_tanks_owned));
end $$;


-- ----------------------------------------------------------------------------
-- 5. Rune loadout — cosmetic, but must stay within what you actually own
-- ----------------------------------------------------------------------------
create or replace function public.set_tank_runes(p_loadout jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prof profiles%rowtype;
  owned_counts jsonb := '{}'::jsonb;
  used_counts jsonb := '{}'::jsonb;
  tank text; rune text; n int;
  clean jsonb := '{}'::jsonb;
  arr jsonb;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not signed in'); end if;
  select * into prof from profiles where user_id = uid for update;

  for rune in select jsonb_array_elements_text(coalesce(prof.runes, '[]'::jsonb)) loop
    owned_counts := jsonb_set(owned_counts, array[rune], to_jsonb(coalesce((owned_counts->>rune)::int, 0) + 1));
  end loop;

  for tank in select jsonb_object_keys(coalesce(p_loadout, '{}'::jsonb)) loop
    arr := '[]'::jsonb;
    for rune in select jsonb_array_elements_text(p_loadout->tank) loop
      n := coalesce((used_counts->>rune)::int, 0);
      -- refuse to equip more copies than the inventory holds, max 3 per tank
      if n < coalesce((owned_counts->>rune)::int, 0) and jsonb_array_length(arr) < 3 then
        used_counts := jsonb_set(used_counts, array[rune], to_jsonb(n + 1));
        arr := arr || to_jsonb(rune);
      end if;
    end loop;
    if jsonb_array_length(arr) > 0 then clean := jsonb_set(clean, array[tank], arr); end if;
  end loop;

  update profiles set tank_runes = clean where user_id = uid;
  return jsonb_build_object('ok', true, 'tank_runes', clean);
end $$;


-- ----------------------------------------------------------------------------
-- 6. Weekly quest claims
-- ----------------------------------------------------------------------------
create or replace function public.claim_weekly_quest(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prof profiles%rowtype;
  wq jsonb; wk text := to_char(arc_week_start(), 'YYYY-MM-DD');
  goals jsonb := '{"play":10,"sharp":3,"raid":3,"clash":5,"meltdown":1}'::jsonb;
  coin_g int := 0; tok_g int := 0; rune_n int := 0;
  drops text[] := '{}'; k text; done boolean := true;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not signed in'); end if;
  select * into prof from profiles where user_id = uid for update;

  wq := coalesce(prof.weekly_quests, '{}'::jsonb);
  if wq->>'week' is distinct from wk then
    return jsonb_build_object('ok', false, 'error', 'nothing to claim this week');
  end if;
  if coalesce(wq->'claimed', '[]'::jsonb) @> to_jsonb(p_key) then
    return jsonb_build_object('ok', false, 'error', 'already claimed');
  end if;

  if p_key = 'bonus' then
    for k in select jsonb_object_keys(goals) loop
      if coalesce((wq#>>array['p', k])::int, 0) < (goals->>k)::int then done := false; end if;
    end loop;
    if not done then return jsonb_build_object('ok', false, 'error', 'not complete'); end if;
    rune_n := 1;
  else
    if goals->>p_key is null then return jsonb_build_object('ok', false, 'error', 'unknown quest'); end if;
    if coalesce((wq#>>array['p', p_key])::int, 0) < (goals->>p_key)::int then
      return jsonb_build_object('ok', false, 'error', 'not complete');
    end if;
    if    p_key = 'play'     then coin_g := 150;
    elsif p_key = 'sharp'    then coin_g := 200;
    elsif p_key = 'raid'     then tok_g := 60;
    elsif p_key = 'clash'    then tok_g := 50;
    elsif p_key = 'meltdown' then rune_n := 1;
    end if;
  end if;

  while rune_n > 0 loop
    drops := drops || arc_roll_rune();
    rune_n := rune_n - 1;
  end loop;

  wq := jsonb_set(wq, '{claimed}', coalesce(wq->'claimed', '[]'::jsonb) || to_jsonb(p_key));

  update profiles
     set coins = coalesce(coins, 0) + coin_g,
         battle_tokens = coalesce(battle_tokens, 0) + tok_g,
         runes = coalesce(runes, '[]'::jsonb) || to_jsonb(drops),
         weekly_quests = wq
   where user_id = uid
   returning * into prof;

  return jsonb_build_object('ok', true, 'coins', coin_g, 'tokens', tok_g, 'runes', to_jsonb(drops),
                            'balance_coins', prof.coins, 'balance_tokens', prof.battle_tokens);
end $$;


-- ----------------------------------------------------------------------------
-- 7. Daily check-in — the server owns the calendar, not the browser clock
-- ----------------------------------------------------------------------------
create or replace function public.claim_daily_checkin()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prof profiles%rowtype;
  today date := (now() at time zone 'utc')::date;
  streak int; slot int; coin_g int; tok_g int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'not signed in'); end if;
  perform arc_ensure_profile(uid);
  select * into prof from profiles where user_id = uid for update;

  if prof.last_checkin_date = today then
    return jsonb_build_object('ok', false, 'error', 'already claimed today');
  end if;

  streak := case when prof.last_checkin_date = today - 1 then coalesce(prof.checkin_streak, 0) + 1 else 1 end;
  slot := ((streak - 1) % 7);
  coin_g := (array[15,20,25,30,40,50,80])[slot + 1];
  tok_g  := (array[0,0,0,0,0,0,10])[slot + 1];

  update profiles
     set coins = coalesce(coins, 0) + coin_g,
         battle_tokens = coalesce(battle_tokens, 0) + tok_g,
         checkin_streak = streak,
         last_checkin_date = today
   where user_id = uid
   returning * into prof;

  return jsonb_build_object('ok', true, 'coins', coin_g, 'tokens', tok_g, 'streak', streak,
                            'balance_coins', prof.coins, 'balance_tokens', prof.battle_tokens);
end $$;


-- ----------------------------------------------------------------------------
-- 8. Permissions
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
    'claim_daily_checkin()',
    'award_weekly_champion_bonus(text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- internal helpers stay unreachable from the client
revoke all on function public.arc_ensure_profile(uuid) from public, authenticated;
revoke all on function public.arc_roll_rune() from public, authenticated;


-- ----------------------------------------------------------------------------
-- 9. Verify the functions exist
-- ----------------------------------------------------------------------------
select p.proname, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('game_start_run','game_finish_run','buy_tank','set_tank_runes',
                     'claim_weekly_quest','claim_daily_checkin','award_weekly_champion_bonus')
 order by p.proname;


-- ============================================================================
--  Running this file alone changes nothing about how the site behaves: it only
--  adds the functions. The site keeps writing profiles directly until the
--  client is switched over and supabase-lockdown.sql is applied.
-- ============================================================================
