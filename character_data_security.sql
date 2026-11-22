-- Ownership guardrails for RPG data tables (apply in Supabase SQL Editor).
-- Restrictive policies are ANDed with existing permissive policies, so legacy
-- broad policies cannot authorize access to another player's rows.

alter table public.characters enable row level security;
drop policy if exists characters_owner_guard on public.characters;
create policy characters_owner_guard on public.characters
  as restrictive for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- Keep a single character row per account.
create unique index if not exists characters_owner_id_unique
  on public.characters(owner_id);

alter table public.profiles enable row level security;
drop policy if exists profiles_owner_guard on public.profiles;
create policy profiles_owner_guard on public.profiles
  as restrictive for all to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Chat inserts must be authenticated and attributed to the current account.
alter table public.chat_messages enable row level security;
drop policy if exists chat_messages_owner_insert_guard on public.chat_messages;
create policy chat_messages_owner_insert_guard on public.chat_messages
  as restrictive for insert to authenticated
  with check (user_id = auth.uid());

-- Public chat read access is intentional; this restrictive policy allows reads
-- to authenticated players while retaining existing permissive read policies.
drop policy if exists chat_messages_authenticated_read_guard on public.chat_messages;
create policy chat_messages_authenticated_read_guard on public.chat_messages
  as restrictive for select to authenticated
  using (true);
