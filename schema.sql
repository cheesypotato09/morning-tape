-- Morning Tape: Supabase schema
-- Run this whole file once in the Supabase SQL Editor.
-- To change which email domain can play, edit is_allowed() below.

-- ---------- tables ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null default 'Player',
  created_at timestamptz not null default now()
);

create table if not exists public.admins (
  user_id uuid primary key references auth.users on delete cascade
);

-- Public part of each puzzle (no answers)
create table if not exists public.puzzles (
  puzzle_date date primary key,
  title text,
  blurb text,
  rounds jsonb not null,
  published_at timestamptz not null default now()
);

-- Answers and explanations, never readable by players directly
create table if not exists public.puzzle_solutions (
  puzzle_date date primary key references public.puzzles on delete cascade,
  solutions jsonb not null
);

-- One row per player per round. started_at is set by the server,
-- so the speed bonus can't be faked from the browser.
create table if not exists public.attempts (
  user_id uuid not null references auth.users on delete cascade,
  puzzle_date date not null references public.puzzles on delete cascade,
  round_idx int not null,
  started_at timestamptz not null default now(),
  answered_at timestamptz,
  answer numeric,
  points int,
  primary key (user_id, puzzle_date, round_idx)
);

alter table public.profiles enable row level security;
alter table public.admins enable row level security;
alter table public.puzzles enable row level security;
alter table public.puzzle_solutions enable row level security;
alter table public.attempts enable row level security;

-- ---------- helpers ----------
create or replace function public.is_allowed() returns boolean
language sql stable as $$
  select coalesce(lower(auth.jwt() ->> 'email') like '%@iu.edu', false)
$$;

create or replace function public.am_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

-- ---------- policies ----------
drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles
  for select to authenticated using (public.is_allowed());

drop policy if exists "edit own profile" on public.profiles;
create policy "edit own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "puzzles readable" on public.puzzles;
create policy "puzzles readable" on public.puzzles
  for select to authenticated using (public.is_allowed());

drop policy if exists "own attempts readable" on public.attempts;
create policy "own attempts readable" on public.attempts
  for select to authenticated using (user_id = auth.uid());
-- No insert/update policies on attempts: all writes go through the functions below.
-- No policies at all on puzzle_solutions or admins: clients can't read them.

-- ---------- new user -> profile ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- game functions ----------
-- Latest puzzle dated today or earlier (Indiana time)
create or replace function public.get_current_puzzle()
returns table (puzzle_date date, title text, blurb text, rounds jsonb)
language sql stable as $$
  select p.puzzle_date, p.title, p.blurb, p.rounds
  from public.puzzles p
  where p.puzzle_date <= (now() at time zone 'America/Indiana/Indianapolis')::date
  order by p.puzzle_date desc
  limit 1
$$;

create or replace function public.start_round(p_date date, p_idx int) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null or not is_allowed() then raise exception 'not_allowed'; end if;
  select jsonb_array_length(rounds) into n from puzzles where puzzle_date = p_date;
  if n is null or p_idx < 0 or p_idx >= n then raise exception 'bad_round'; end if;
  if p_idx > 0 and not exists (
    select 1 from attempts where user_id = auth.uid() and puzzle_date = p_date
      and round_idx = p_idx - 1 and answered_at is not null
  ) then raise exception 'previous_round_open'; end if;
  insert into attempts (user_id, puzzle_date, round_idx)
  values (auth.uid(), p_date, p_idx)
  on conflict do nothing;
end $$;

create or replace function public.submit_answer(p_date date, p_idx int, p_answer numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a attempts%rowtype; r jsonb; s jsonb;
  ms numeric; base numeric := 0; bonus numeric := 0; pts int; off numeric; w numeric;
begin
  if auth.uid() is null or not is_allowed() then raise exception 'not_allowed'; end if;
  select * into a from attempts
    where user_id = auth.uid() and puzzle_date = p_date and round_idx = p_idx for update;
  if not found then raise exception 'round_not_started'; end if;
  select rounds -> p_idx into r from puzzles where puzzle_date = p_date;
  select solutions -> p_idx into s from puzzle_solutions where puzzle_date = p_date;

  if a.answered_at is not null then
    return jsonb_build_object('points', a.points, 'your_answer', a.answer,
      'correct', s -> 'answer', 'explain', s ->> 'explain', 'already', true);
  end if;

  ms := extract(epoch from (now() - a.started_at)) * 1000;
  if r ->> 'type' = 'choice' then
    base := case when p_answer = (s ->> 'answer')::numeric then 850 else 0 end;
  elsif r ->> 'type' = 'number' then
    base := 850 * exp(-abs(p_answer - (s ->> 'answer')::numeric) / coalesce((s ->> 'scale')::numeric, 3));
    if base < 40 then base := 0; end if;
  elsif r ->> 'type' = 'year' then
    off := abs(p_answer - (s ->> 'answer')::numeric);
    w := coalesce((s ->> 'window')::numeric, 8);
    base := 850 * power(greatest(0, 1 - off / w), 1.5);
  end if;

  if base > 0 then
    bonus := (case when ms <= 10000 then 150 when ms >= 45000 then 0
                   else 150 * (1 - (ms / 1000 - 10) / 35) end) * base / 850;
  end if;
  pts := round(least(1000, base + bonus));

  update attempts set answered_at = now(), answer = p_answer, points = pts
    where user_id = auth.uid() and puzzle_date = p_date and round_idx = p_idx;

  return jsonb_build_object('points', pts, 'your_answer', p_answer,
    'correct', s -> 'answer', 'explain', s ->> 'explain', 'already', false);
end $$;

-- ---------- leaderboards (finished runs only) ----------
create or replace function public.leaderboard_daily(p_date date)
returns table (user_id uuid, display_name text, total bigint)
language sql stable security definer set search_path = public as $$
  select a.user_id, pr.display_name, sum(a.points)::bigint
  from attempts a
  join profiles pr on pr.id = a.user_id
  join puzzles pz on pz.puzzle_date = a.puzzle_date
  where a.puzzle_date = p_date and a.answered_at is not null and is_allowed()
  group by a.user_id, pr.display_name, pz.rounds
  having count(*) = jsonb_array_length(pz.rounds)
  order by 3 desc
$$;

create or replace function public.leaderboard_alltime()
returns table (user_id uuid, display_name text, days bigint, total bigint, average numeric)
language sql stable security definer set search_path = public as $$
  with runs as (
    select a.user_id, a.puzzle_date, sum(a.points) as total
    from attempts a
    join puzzles pz on pz.puzzle_date = a.puzzle_date
    where a.answered_at is not null
    group by a.user_id, a.puzzle_date, pz.rounds
    having count(*) = jsonb_array_length(pz.rounds)
  )
  select r.user_id, pr.display_name, count(*)::bigint, sum(r.total)::bigint, round(avg(r.total))
  from runs r join profiles pr on pr.id = r.user_id
  where is_allowed()
  group by r.user_id, pr.display_name
  order by 4 desc
$$;

-- ---------- admin ----------
-- Takes the full puzzle JSON (with answers), stores the public part and
-- the solutions separately. Re-publishing the same date overwrites it.
create or replace function public.publish_puzzle(p jsonb) returns date
language plpgsql security definer set search_path = public as $$
declare d date; pub jsonb; sol jsonb;
begin
  if not am_admin() then raise exception 'not_admin'; end if;
  d := (p ->> 'date')::date;
  select
    jsonb_agg(e - 'answer' - 'explain' - 'scale' - 'window' order by i),
    jsonb_agg(jsonb_build_object('answer', e -> 'answer', 'explain', e -> 'explain',
                                 'scale', e -> 'scale', 'window', e -> 'window') order by i)
  into pub, sol
  from jsonb_array_elements(p -> 'rounds') with ordinality as t(e, i);

  insert into puzzles (puzzle_date, title, blurb, rounds, published_at)
  values (d, p ->> 'title', p ->> 'blurb', pub, now())
  on conflict (puzzle_date) do update
    set title = excluded.title, blurb = excluded.blurb, rounds = excluded.rounds, published_at = now();

  insert into puzzle_solutions (puzzle_date, solutions) values (d, sol)
  on conflict (puzzle_date) do update set solutions = excluded.solutions;
  return d;
end $$;

create or replace function public.list_puzzles()
returns table (puzzle_date date, title text, players bigint)
language sql stable security definer set search_path = public as $$
  select p.puzzle_date, p.title,
    (select count(distinct a.user_id) from attempts a where a.puzzle_date = p.puzzle_date)
  from puzzles p where am_admin()
  order by p.puzzle_date desc limit 30
$$;

-- Lock function access to signed-in users
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.handle_new_user() to supabase_auth_admin;
