-- ============================================================================
--  Arcadia — fix: boss floors charge a Battle Token entry fee
--
--  Run this in the SQL Editor. Safe and re-runnable.
--
--  game_start_run checked tank ownership for boss floors but never took the
--  entry fee, so once the client migration lands the tower would have been
--  free to enter. Floors 8-11 also inherited floor 7's fee of 80 from the
--  template they were generated from; they now scale.
-- ============================================================================

create or replace function public.game_start_run(p_game text, p_difficulty text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  fee_coins int := 0;
  fee_tokens int := 0;
  prof profiles%rowtype;
  runs_today int;
  flr int;
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
    flr := coalesce(nullif(regexp_replace(p_game, '^boss-', ''), '')::int, 0);
    if flr < 1 or flr > 11 then
      return jsonb_build_object('ok', false, 'error', 'unknown floor');
    end if;
    if coalesce(array_length(prof.boss_tanks_owned, 1), 0) < 4 then
      return jsonb_build_object('ok', false, 'error', 'need 4 tanks');
    end if;
    -- floor 1 is the free trial run; the rest scale with difficulty
    fee_tokens := (array[0, 20, 25, 35, 50, 65, 80, 95, 110, 125, 140])[flr];

  else
    return jsonb_build_object('ok', false, 'error', 'unknown game');
  end if;

  if coalesce(prof.coins, 0) < fee_coins then
    return jsonb_build_object('ok', false, 'error', 'not enough coins', 'coins', coalesce(prof.coins, 0));
  end if;
  if coalesce(prof.battle_tokens, 0) < fee_tokens then
    return jsonb_build_object('ok', false, 'error', 'not enough tokens',
                              'tokens', coalesce(prof.battle_tokens, 0), 'need', fee_tokens);
  end if;

  update profiles
     set coins = coalesce(coins, 0) - fee_coins,
         battle_tokens = coalesce(battle_tokens, 0) - fee_tokens
   where user_id = uid
   returning * into prof;

  return jsonb_build_object(
    'ok', true, 'coins', prof.coins, 'tokens', prof.battle_tokens,
    'fee_coins', fee_coins, 'fee_tokens', fee_tokens,
    'runs_left', case when p_game = 'meltdown' then 3 - runs_today - 1 else null end
  );
end $$;

revoke all on function public.game_start_run(text,text) from public, anon;
grant execute on function public.game_start_run(text,text) to authenticated;

-- quick check: every floor's fee
select f as floor, (array[0,20,25,35,50,65,80,95,110,125,140])[f] as token_fee
  from generate_series(1, 11) f;
