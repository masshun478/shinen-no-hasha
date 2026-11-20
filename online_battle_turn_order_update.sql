-- Apply this migration in Supabase SQL Editor after the original online_battle_setup.sql.
-- Online turn order: every living member acts once in join order, then the enemy attacks once.

alter table public.online_battles
  add column if not exists phase text not null default 'ally',
  add column if not exists action_index integer not null default 0;

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
  v_actor uuid;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_battle from public.online_battles where id=p_battle_id for update;
  if not found then raise exception '募集が見つかりません'; end if;
  if not exists(
    select 1 from public.online_battle_members
     where battle_id=p_battle_id and user_id=auth.uid() and left_at is null
  ) then raise exception 'この募集への参加者ではありません'; end if;

  select count(*) into v_count
    from public.online_battle_members
   where battle_id=p_battle_id and left_at is null;

  if v_battle.status='recruiting' and (v_count>=5 or v_battle.created_at<=now()-interval '30 seconds') then
    update public.online_battles
       set status='active',started_at=coalesce(started_at,now()),phase='ally',action_index=0,updated_at=now()
     where id=p_battle_id returning * into v_battle;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',user_id,'player_name',player_name,'character',character,'hp',hp,'max_hp',max_hp
  ) order by joined_at),'[]'::jsonb)
    into v_members
    from public.online_battle_members
   where battle_id=p_battle_id and left_at is null;

  if v_battle.phase='enemy' then
    select user_id into v_actor
      from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0
     order by joined_at limit 1;
  else
    select user_id into v_actor
      from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0
     order by joined_at offset v_battle.action_index limit 1;
  end if;

  return jsonb_build_object(
    'battle',to_jsonb(v_battle)||jsonb_build_object('acting_user_id',v_actor),
    'members',v_members,'count',v_count,
    'remaining',greatest(0,30-floor(extract(epoch from (now()-v_battle.created_at)))::integer)
  );
end $$;

create or replace function public.online_battle_action(
  p_battle_id uuid,
  p_damage numeric,
  p_taken numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_battle public.online_battles%rowtype;
  v_member public.online_battle_members%rowtype;
  v_target public.online_battle_members%rowtype;
  v_expected uuid;
  v_alive integer;
  v_damage numeric := 0;
  v_members jsonb;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_battle from public.online_battles where id=p_battle_id for update;
  if not found or v_battle.status <> 'active' then raise exception '戦闘は進行中ではありません'; end if;

  select * into v_member from public.online_battle_members
   where battle_id=p_battle_id and user_id=auth.uid() and left_at is null for update;
  if not found then raise exception '参加者ではありません'; end if;

  select count(*) into v_alive
    from public.online_battle_members
   where battle_id=p_battle_id and left_at is null and hp>0;

  if v_alive=0 then
    update public.online_battles set status='lost',updated_at=now()
     where id=p_battle_id returning * into v_battle;
  elsif v_battle.phase='ally' then
    select user_id into v_expected
      from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0
     order by joined_at offset v_battle.action_index limit 1;
    if v_expected is null or v_expected<>auth.uid() then
      raise exception 'まだあなたの行動順ではありません';
    end if;

    update public.online_battles
       set enemy_hp=greatest(0,enemy_hp-greatest(0,coalesce(p_damage,0))),updated_at=now()
     where id=p_battle_id returning * into v_battle;

    if v_battle.enemy_hp<=0 then
      update public.online_battles set status='won',updated_at=now()
       where id=p_battle_id returning * into v_battle;
    elsif v_battle.action_index+1>=v_alive then
      update public.online_battles set phase='enemy',action_index=0,updated_at=now()
       where id=p_battle_id returning * into v_battle;
    else
      update public.online_battles set action_index=action_index+1,updated_at=now()
       where id=p_battle_id returning * into v_battle;
    end if;
  else
    select user_id into v_expected
      from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0
     order by joined_at limit 1;
    if v_expected is null or v_expected<>auth.uid() then
      raise exception '敵の攻撃処理を待っています';
    end if;

    select * into v_target
      from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0
     order by random() limit 1 for update;

    if found then
      v_damage:=greatest(1,floor(coalesce((v_battle.enemy->>'atk')::numeric,1)
        -coalesce((v_target.character->>'def')::numeric,0)*0.55));
      update public.online_battle_members
         set hp=greatest(0,hp-v_damage)
       where battle_id=p_battle_id and user_id=v_target.user_id;
    end if;

    select count(*) into v_alive
      from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0;

    if v_alive=0 then
      update public.online_battles set status='lost',phase='ally',action_index=0,turn=turn+1,updated_at=now()
       where id=p_battle_id returning * into v_battle;
    else
      update public.online_battles set phase='ally',action_index=0,turn=turn+1,updated_at=now()
       where id=p_battle_id returning * into v_battle;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',user_id,'player_name',player_name,'character',character,'hp',hp,'max_hp',max_hp
  ) order by joined_at),'[]'::jsonb)
    into v_members
    from public.online_battle_members
   where battle_id=p_battle_id and left_at is null;

  if v_battle.phase='enemy' then
    select user_id into v_expected from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0 order by joined_at limit 1;
  elsif v_battle.status='active' then
    select user_id into v_expected from public.online_battle_members
     where battle_id=p_battle_id and left_at is null and hp>0
     order by joined_at offset v_battle.action_index limit 1;
  else
    v_expected:=null;
  end if;

  return jsonb_build_object(
    'battle',to_jsonb(v_battle)||jsonb_build_object('acting_user_id',v_expected),
    'members',v_members,'my_hp',coalesce((select hp from public.online_battle_members
      where battle_id=p_battle_id and user_id=auth.uid()),0),
    'target_user_id',case when v_target.user_id is null then null else v_target.user_id end,
    'target_name',case when v_target.user_id is null then null else v_target.player_name end,
    'damage',v_damage
  );
end $$;

grant execute on function public.poll_online_battle(uuid) to authenticated;
grant execute on function public.online_battle_action(uuid,numeric,numeric) to authenticated;
