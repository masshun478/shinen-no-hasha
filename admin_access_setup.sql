-- Run this once in Supabase Dashboard -> SQL Editor after registering the admin account.
-- The admin role is granted only to this exact, email-confirmed account.
create or replace function public.is_game_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    where u.id = (select auth.uid())
      and lower(u.email) = 'yukina20210818@gmail.com'
      and u.email_confirmed_at is not null
  );
$$;

revoke all on function public.is_game_admin() from public;
grant execute on function public.is_game_admin() to authenticated;
