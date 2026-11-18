create extension if not exists pgcrypto;

create table if not exists public.online_battles (
  id uuid primary key default gen_random_uuid(),
  difficulty text not null,
  status text not null default 'recruiting' check (status in ('recruiting','active','won','lost','finished')),
  enemy jsonb not null,
  enemy_hp numeric not null,
  enemy_max_hp numeric not null,
  turn integer not null default 1,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.online_battle_members (
  battle_id uuid not null references public.online_battles(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  player_name text not null,
  character jsonb not null default '{}'::jsonb,
  hp numeric not null default 1,
  max_hp numeric not null default 1,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (battle_id, user_id)
);

create index if not exists online_battles_recruiting_idx
  on public.online_battles (difficulty, created_at desc) where status = 'recruiting';

alter table public.online_battles enable row level security;
alter table public.online_battle_members enable row level security;
revoke all on public.online_battles from anon, authenticated;
revoke all on public.online_battle_members from anon, authenticated;

create or replace function public.join_online_battle(p_difficulty text, p_player_name text, p_character jsonb, p_enemy jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_battle public.online_battles%rowtype;
  v_count integer;
begin
  if v_uid is null then raise exception 'ログインが必要です'; end if;
  perform pg_advisory_xact_lock(hashtext('online-battle-' || p_difficulty));
  select b.* into v_battle
    from public.online_battles b
   where b.difficulty = p_difficulty
     and b.status = 'recruiting'
     and b.created_at > now() - interval '30 seconds'
     and (select count(*) from public.online_battle_members m where m.battle_id=b.id and m.left_at is null) < 5
   order by b.created_at asc
   limit 1 for update;
  if not found then
    insert into public.online_battles(difficulty, enemy, enemy_hp, enemy_max_hp)
    values (p_difficulty, p_enemy, (p_enemy->>'hp')::numeric, (p_enemy->>'max')::numeric)
    returning * into v_battle;
  end if;
  insert into public.online_battle_members(battle_id,user_id,player_name,character,hp,max_hp)
  values(v_battle.id,v_uid,left(coalesce(nullif(p_player_name,''),'冒険者'),24),coalesce(p_character,'{}'::jsonb),
         greatest(0,coalesce((p_character->>'hp')::numeric,1)),
         greatest(1,coalesce((p_character->>'maxHp')::numeric,1)))
  on conflict (battle_id,user_id) do update
    set left_at=null, player_name=excluded.player_name, character=excluded.character;
  select count(*) into v_count from public.online_battle_members where battle_id=v_battle.id and left_at is null;
  if v_count >= 5 or v_battle.created_at <= now() - interval '30 seconds' then
    update public.online_battles set status='active', started_at=coalesce(started_at,now()), updated_at=now()
     where id=v_battle.id and status='recruiting' returning * into v_battle;
  end if;
  return jsonb_build_object('battle',to_jsonb(v_battle),'count',v_count);
end $$;

create or replace function public.poll_online_battle(p_battle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_battle public.online_battles%rowtype;
  v_members jsonb;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_battle from public.online_battles where id=p_battle_id for update;
  if not found then raise exception '募集が見つかりません'; end if;
  if not exists(select 1 from public.online_battle_members where battle_id=p_battle_id and user_id=auth.uid() and left_at is null)
    then raise exception 'この募集への参加者ではありません'; end if;
  select count(*) into v_count from public.online_battle_members where battle_id=p_battle_id and left_at is null;
  if v_battle.status='recruiting' and (v_count>=5 or v_battle.created_at<=now()-interval '30 seconds') then
    update public.online_battles set status='active',started_at=coalesce(started_at,now()),updated_at=now()
      where id=p_battle_id returning * into v_battle;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'player_name',player_name,'character',character,'hp',hp,'max_hp',max_hp) order by joined_at),'[]'::jsonb)
    into v_members from public.online_battle_members where battle_id=p_battle_id and left_at is null;
  return jsonb_build_object('battle',to_jsonb(v_battle),'members',v_members,'count',v_count,
    'remaining',greatest(0,30-floor(extract(epoch from (now()-v_battle.created_at)))::integer));
end $$;

create or replace function public.online_battle_action(p_battle_id uuid, p_damage numeric, p_taken numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_battle public.online_battles%rowtype;
  v_member public.online_battle_members%rowtype;
  v_count_alive integer;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_battle from public.online_battles where id=p_battle_id for update;
  if not found or v_battle.status <> 'active' then raise exception '戦闘は進行中ではありません'; end if;
  select * into v_member from public.online_battle_members
   where battle_id=p_battle_id and user_id=auth.uid() and left_at is null for update;
  if not found then raise exception '参加者ではありません'; end if;
  update public.online_battles
     set enemy_hp=greatest(0,enemy_hp-greatest(0,coalesce(p_damage,0))),
         turn=turn+1, updated_at=now()
   where id=p_battle_id returning * into v_battle;
  update public.online_battle_members
     set hp=greatest(0,hp-greatest(0,coalesce(p_taken,0)))
   where battle_id=p_battle_id and user_id=auth.uid() returning * into v_member;
  if v_battle.enemy_hp<=0 then
    update public.online_battles set status='won',updated_at=now() where id=p_battle_id returning * into v_battle;
  else
    select count(*) into v_count_alive from public.online_battle_members where battle_id=p_battle_id and left_at is null and hp>0;
    if v_count_alive=0 then
      update public.online_battles set status='lost',updated_at=now() where id=p_battle_id returning * into v_battle;
    end if;
  end if;
  return jsonb_build_object('battle',to_jsonb(v_battle),'my_hp',v_member.hp);
end $$;

create or replace function public.leave_online_battle(p_battle_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  update public.online_battle_members set left_at=now()
   where battle_id=p_battle_id and user_id=auth.uid();
end $$;

grant execute on function public.join_online_battle(text,text,jsonb,jsonb) to authenticated;
grant execute on function public.poll_online_battle(uuid) to authenticated;
grant execute on function public.online_battle_action(uuid,numeric,numeric) to authenticated;
grant execute on function public.leave_online_battle(uuid) to authenticated;
