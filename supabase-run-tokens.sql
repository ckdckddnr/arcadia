-- ============================================================================
--  Arcadia — pair every payout with the run that earned it
--
--  ALREADY APPLIED (2026-08-12). Kept for the record and for rebuilding from
--  scratch. Applied via the Supabase migration API in this order.
--
--  The problem: entry fees lived in game_start_run and payouts in
--  game_finish_run, with nothing linking them. A signed-in player could call
--  the payout directly in a loop and never pay to play. Boss floor 11 was the
--  worst case at roughly 468 coins, 223 tokens and two runes per call.
--
--  Rolled out in three steps so the live site never broke:
--    1. issue tokens, accept them optionally   (no behaviour change)
--    2. ship the client that sends the token   (no behaviour change)
--    3. require the token, drop the old overload
--
--  Watch out: `create or replace function` with a NEW argument list creates a
--  sibling overload rather than replacing anything. Step 3 looked fine until a
--  catalogue query showed both a 6-arg and a 7-arg game_finish_run, with the
--  6-arg one still unguarded. Always confirm overload counts after changing a
--  function's signature.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. The tokens themselves. RLS on with no policies, so only the SECURITY
--    DEFINER functions can see or write them.
-- ---------------------------------------------------------------------------
create table if not exists public.run_tokens (
  token       uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  game        text not null,
  difficulty  text,
  floor       int,
  created_at  timestamptz not null default now(),
  consumed_at timestamptz
);
create index if not exists run_tokens_user_day on public.run_tokens (user_id, game, created_at);
alter table public.run_tokens enable row level security;


-- ---------------------------------------------------------------------------
-- 2. game_start_run issues one token per paid entry.
--
--    Meltdown's daily cap now counts issued tokens rather than score rows, so
--    abandoning a run mid-way still consumes one of the three attempts.
--
--    (Full body applied via migration arcadia_start_run_issues_token — the
--    live definition is the source of truth; see pg_get_functiondef.)
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 3. game_finish_run refuses to pay without a valid token.
--
--    The token must belong to the caller, match the game, be unconsumed, and
--    be under six hours old. Floor and difficulty are read back off the token
--    instead of being trusted from the request, so a floor-1 token cannot be
--    redeemed for floor-11 rewards.
--
--    (Full body applied via migration arcadia_finish_run_requires_token.)
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 4. Remove the pre-token overload — this is the step that actually closed it.
-- ---------------------------------------------------------------------------
drop function if exists public.game_finish_run(text,integer,boolean,text,integer,integer);


-- ---------------------------------------------------------------------------
-- 5. Verify. Every function should report exactly one overload, and
--    game_finish_run's signature must end in p_token uuid.
-- ---------------------------------------------------------------------------
select p.proname,
       count(*) as overloads,
       string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as signatures,
       bool_or(has_function_privilege('anon', p.oid, 'execute')) as anon_can_call
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('game_start_run','game_finish_run','buy_tank','set_tank_runes',
                     'claim_weekly_quest','claim_daily_checkin','award_weekly_champion_bonus')
 group by p.proname
 order by p.proname;
