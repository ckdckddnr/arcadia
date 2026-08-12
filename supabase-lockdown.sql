-- ============================================================================
--  Arcadia — final lockdown
--
--  ⚠️  DO NOT RUN THIS YET.
--
--  This removes the client's ability to write profiles or scores at all. The
--  moment it runs, any page still writing those tables directly will silently
--  stop awarding anything.
--
--  Run it only when ALL of these are true:
--    1. supabase-rls.sql has been applied
--    2. supabase-server-rewards.sql has been applied
--    3. The client migration to the RPC functions is deployed and pushed
--    4. You have played one run of each game type and seen rewards land
--
--  If something breaks after running this, section 3 below puts the old
--  policies back so the live site keeps working while you investigate.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. profiles: read your own row, write nothing.
--    Every mutation now goes through the SECURITY DEFINER functions.
-- ----------------------------------------------------------------------------
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
-- profiles_select_own stays, and is the only client access that remains


-- ----------------------------------------------------------------------------
-- 2. scores: still world-readable for leaderboards, but rows are written by
--    game_finish_run, so the client no longer needs insert.
-- ----------------------------------------------------------------------------
drop policy if exists scores_insert_own on public.scores;


-- ----------------------------------------------------------------------------
--    Verify — expect profiles_select_own and scores_select_public only.
-- ----------------------------------------------------------------------------
select tablename, policyname, cmd, roles
  from pg_policies
 where schemaname = 'public' and tablename in ('profiles','scores','coin_purchases')
 order by tablename, policyname;


-- ============================================================================
-- 3. ROLLBACK — paste and run this if the site starts failing to award.
-- ============================================================================
-- create policy profiles_insert_own on public.profiles
--   for insert to authenticated with check (auth.uid() = user_id);
-- create policy profiles_update_own on public.profiles
--   for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- create policy scores_insert_own on public.scores
--   for insert to authenticated with check (auth.uid() = user_id);
