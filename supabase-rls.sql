-- ============================================================================
--  Arcadia — Row Level Security
--  Run this once in the Supabase dashboard: SQL Editor -> New query -> Run.
--  Safe to re-run; it drops and recreates its own policies each time.
--
--  Problem this fixes: profiles was readable with the public anon key, so
--  anyone could enumerate every player's coins, tokens, tanks and runes.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Weekly champion bonus, moved server-side.
--
--    The client used to hand +1 coin to last week's champion by writing to that
--    player's row directly. Once the policies below are live no client can do
--    that, so the award runs here instead, where it can be trusted.
--    Run this BEFORE section 2 so the feature never has a gap.
-- ----------------------------------------------------------------------------
create or replace function public.award_weekly_champion_bonus(p_game text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  champ uuid;
  -- date_trunc('week') is Monday-based, matching the app's weekly rollover
  week_start timestamptz := (date_trunc('week', (now() at time zone 'utc')) at time zone 'utc');
begin
  select s.user_id
    into champ
    from scores s
   where s.game = p_game
     and s.created_at >= week_start - interval '7 days'
     and s.created_at <  week_start
   order by s.score desc
   limit 1;

  if champ is null then
    return;
  end if;

  update profiles
     set coins = coalesce(coins, 0) + 1
   where user_id = champ;
end;
$$;

revoke all on function public.award_weekly_champion_bonus(text) from public;
grant execute on function public.award_weekly_champion_bonus(text) to authenticated;


-- ----------------------------------------------------------------------------
-- 2. profiles — private to its owner.
--
--    Nothing in the app needs to read another player's profile any more;
--    leaderboards get their names from the scores table instead.
-- ----------------------------------------------------------------------------
alter table public.profiles enable row level security;

do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'profiles'
  loop
    execute format('drop policy %I on public.profiles', p.policyname);
  end loop;
end $$;

create policy profiles_select_own on public.profiles
  for select to authenticated
  using (auth.uid() = user_id);

create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (auth.uid() = user_id);

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- no delete policy: rows cannot be removed from the client at all


-- ----------------------------------------------------------------------------
-- 3. scores — world readable, append only, always under your own name.
--
--    Leaderboards render for logged-out visitors, so select stays open to anon.
--    Inserts are pinned to the caller, and nothing may edit history.
-- ----------------------------------------------------------------------------
alter table public.scores enable row level security;

do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'scores'
  loop
    execute format('drop policy %I on public.scores', p.policyname);
  end loop;
end $$;

create policy scores_select_public on public.scores
  for select to anon, authenticated
  using (true);

create policy scores_insert_own on public.scores
  for insert to authenticated
  with check (auth.uid() = user_id);

-- no update or delete policy: a submitted score is immutable


-- ----------------------------------------------------------------------------
-- 4. coin_purchases — server only.
--
--    Written solely by the Stripe webhook using the service role key, which
--    bypasses RLS. Enabling RLS with no policies locks out every client.
-- ----------------------------------------------------------------------------
alter table public.coin_purchases enable row level security;

do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'coin_purchases'
  loop
    execute format('drop policy %I on public.coin_purchases', p.policyname);
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- 5. Verify.
-- ----------------------------------------------------------------------------
-- Every table should report rowsecurity = true
select tablename, rowsecurity
  from pg_tables
 where schemaname = 'public'
   and tablename in ('profiles', 'scores', 'coin_purchases')
 order by tablename;

-- Expected: profiles 3 policies, scores 2, coin_purchases 0
select tablename, policyname, cmd, roles
  from pg_policies
 where schemaname = 'public'
   and tablename in ('profiles', 'scores', 'coin_purchases')
 order by tablename, policyname;
