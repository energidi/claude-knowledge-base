-- PlayBuild - Initial Schema
-- Run this in the Supabase SQL editor

-- ─────────────────────────────────────────────
-- USERS (extends Supabase auth.users)
-- ─────────────────────────────────────────────
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  gender      text not null default 'neutral' check (gender in ('male', 'female', 'neutral')),
  avatar_url  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Auto-create profile on new user signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    new.raw_user_meta_data->>'avatar_url'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ─────────────────────────────────────────────
-- GAMES
-- ─────────────────────────────────────────────
create table public.games (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  name          text not null default 'משחק ללא שם',
  html_content  text,
  published_url text,
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index games_user_id_idx on public.games(user_id);

-- ─────────────────────────────────────────────
-- CONVERSATIONS (per game build/edit session)
-- ─────────────────────────────────────────────
create table public.conversations (
  id         uuid primary key default gen_random_uuid(),
  game_id    uuid not null references public.games(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  messages   jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index conversations_game_id_idx on public.conversations(game_id);

-- ─────────────────────────────────────────────
-- ROW LEVEL SECURITY
-- ─────────────────────────────────────────────
alter table public.profiles     enable row level security;
alter table public.games        enable row level security;
alter table public.conversations enable row level security;

-- Profiles: users can only read/update their own
create policy "profiles: own read"   on public.profiles for select using (auth.uid() = id);
create policy "profiles: own update" on public.profiles for update using (auth.uid() = id);

-- Games: users can only CRUD their own
create policy "games: own read"   on public.games for select using (auth.uid() = user_id);
create policy "games: own insert" on public.games for insert with check (auth.uid() = user_id);
create policy "games: own update" on public.games for update using (auth.uid() = user_id);
create policy "games: own delete" on public.games for delete using (auth.uid() = user_id);

-- Conversations: users can only CRUD their own
create policy "conversations: own read"   on public.conversations for select using (auth.uid() = user_id);
create policy "conversations: own insert" on public.conversations for insert with check (auth.uid() = user_id);
create policy "conversations: own update" on public.conversations for update using (auth.uid() = user_id);
create policy "conversations: own delete" on public.conversations for delete using (auth.uid() = user_id);

-- ─────────────────────────────────────────────
-- AUTO-UPDATE updated_at
-- ─────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger set_updated_at_profiles
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

create trigger set_updated_at_games
  before update on public.games
  for each row execute procedure public.set_updated_at();

create trigger set_updated_at_conversations
  before update on public.conversations
  for each row execute procedure public.set_updated_at();
