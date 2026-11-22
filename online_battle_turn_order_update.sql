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
  v_player_damage numeric := 0;
  v_max_player_damage numeric := 1;
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

    -- Limit client-reported damage to a server-calculated ceiling based on the
    -- participant stats stored when they joined. This is a guardrail until
    -- character progression and equipped skills are persisted server-side.
    v_max_player_damage:=greatest(1,floor((
      greatest(1,coalesce(nullif(v_member.character->>'str','')::numeric,1))*2
      + greatest(0,coalesce(nullif(v_member.character->>'spd','')::numeric,0))
    )*6));
    v_player_damage:=least(
      greatest(0,coalesce(p_damage,0)),
      v_max_player_damage,
      greatest(0,v_battle.enemy_hp)
    );

    update public.online_battles
       set enemy_hp=greatest(0,enemy_hp-v_player_damage),updated_at=now()
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
    'damage',v_damage,'player_damage',v_player_damage
  );
end $$;

grant execute on function public.poll_online_battle(uuid) to authenticated;
grant execute on function public.online_battle_action(uuid,numeric,numeric) to authenticated;


-- Prevent one account from joining multiple unfinished online battles.
-- Resolve pre-existing duplicate active memberships before creating the index.
with ranked_members as (
  select ctid,
         row_number() over (
           partition by user_id
           order by joined_at desc, battle_id desc
         ) as rn
    from public.online_battle_members
   where left_at is null
)
update public.online_battle_members m
   set left_at = now()
  from ranked_members r
 where m.ctid = r.ctid
   and r.rn > 1;

create unique index if not exists online_battle_one_active_room_per_user_idx
  on public.online_battle_members (user_id)
  where left_at is null;

-- Correct active-room protection without blocking completed battle history.

-- Correct active-room protection without blocking completed battle history.
-- A permanent partial index on left_at is incorrect because finished members
-- remain visible to poll_online_battle; enforce the rule under a per-user lock.
drop index if exists public.online_battle_one_active_room_per_user_idx;

create or replace function public.join_online_battle(
  p_difficulty text,
  p_player_name text,
  p_character jsonb,
  p_enemy jsonb
)
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
  perform pg_advisory_xact_lock(hashtext('online-user-' || v_uid::text));
  if exists (
    select 1
      from public.online_battle_members m
      join public.online_battles b on b.id=m.battle_id
     where m.user_id=v_uid
       and m.left_at is null
       and b.status in ('recruiting','active')
  ) then
    raise exception 'すでに進行中のオンライン戦闘に参加しています';
  end if;

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

grant execute on function public.join_online_battle(text,text,jsonb,jsonb) to authenticated;


-- Generate the online battle enemy on the database
drop function if exists public.join_online_battle(text,text,jsonb,jsonb);
create or replace function public.join_online_battle(
  p_difficulty text,p_player_name text,p_character jsonb
) returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare
  v_uid uuid:=auth.uid();
  v_battle public.online_battles%rowtype;
  v_count integer;
  v_catalog jsonb;
  v_pick jsonb;
  v_enemy jsonb;
begin
  if v_uid is null then raise exception 'ログインが必要です'; end if;
  if p_difficulty not in ('最弱','弱','普通','強','激強','最強') then
    raise exception '難易度が正しくありません';
  end if;
  -- Serialize joins per account and ignore completed historical memberships.
  perform pg_advisory_xact_lock(hashtext('online-user-'||v_uid::text));
  if exists(
    select 1
      from public.online_battle_members m
      join public.online_battles b on b.id=m.battle_id
     where m.user_id=v_uid and m.left_at is null
       and b.status in ('recruiting','active')
  ) then
    raise exception 'すでに進行中のオンライン戦闘に参加しています';
  end if;
  perform pg_advisory_xact_lock(hashtext('online-battle-'||p_difficulty));
  select b.* into v_battle from public.online_battles b
   where b.difficulty=p_difficulty and b.status='recruiting'
     and b.created_at>now()-interval '30 seconds'
     and (select count(*) from public.online_battle_members m where m.battle_id=b.id and m.left_at is null)<5
   order by b.created_at asc limit 1 for update;
  if not found then
    v_catalog:=case p_difficulty
      when '最弱' then '[["ぷちスライム","🟢",35,5,10,5],["野ネズミ","🐭",28,7,12,6],["ひよこ魔","🐣",40,4,10,4]]'::jsonb
      when '弱' then '[["ゴブリン","👺",100,13,35,20],["森の狼","🐺",85,17,38,22],["毒キノコ","🍄",120,10,40,25]]'::jsonb
      when '普通' then '[["オーク","👹",4200,150,900,600],["骸骨騎士","💀",3800,180,1000,650],["魔導ゴーレム","🗿",5600,140,1100,720]]'::jsonb
      when '強' then '[["深淵の獣","🐗",180000,4200,18000,12000],["地獄の騎士","🛡️",220000,3800,20000,13500],["雷鳴ワイバーン","🐲",165000,4800,21000,14000]]'::jsonb
      when '激強' then '[["右刃の守護竜","🐉",2200000,26000,90000,65000,"右手"],["双影の魔将","👿",2600000,24000,100000,70000,"左手"],["天駆ける獣王","🦁",2000000,29000,105000,74000,"足"]]'::jsonb
      else '[["ダークロード","🌑",12000000,180000,500000,400000,"身体"]]'::jsonb
    end;
    v_pick:=v_catalog->floor(random()*jsonb_array_length(v_catalog))::integer;
    if p_difficulty='激強' and random()<0.006 then
      v_enemy:=jsonb_build_object('name','深淵の狩人・ナイトメア','emoji','👹',
        'hp',greatest(65000,(v_catalog->0->>2)::numeric*12),'max',greatest(65000,(v_catalog->0->>2)::numeric*12),
        'atk',greatest(900,(v_catalog->0->>3)::numeric*4),'xp',65000,'gold',42000,
        'drop','深淵の秘宝','diff',p_difficulty,'rare',true);
    elsif p_difficulty='最強' and random()<0.012 then
      v_enemy:=jsonb_build_object('name','終焉の覇竜・アポカリプス','emoji','🐉',
        'hp',greatest(18000000,(v_catalog->0->>2)::numeric*1.5),'max',greatest(18000000,(v_catalog->0->>2)::numeric*1.5),
        'atk',greatest(220000,(v_catalog->0->>3)::numeric*1.22),'xp',900000,'gold',750000,
        'drop','神話級の秘宝','diff',p_difficulty,'rare',true);
    else
      v_enemy:=jsonb_build_object('name',v_pick->>0,'emoji',v_pick->>1,
        'hp',(v_pick->>2)::numeric,'max',(v_pick->>2)::numeric,'atk',(v_pick->>3)::numeric,
        'xp',(v_pick->>4)::numeric,'gold',(v_pick->>5)::numeric,
        'drop',case when jsonb_array_length(v_pick)>6 then v_pick->>6 else null end,
        'diff',p_difficulty,'rare',false);
    end if;
    insert into public.online_battles(difficulty,enemy,enemy_hp,enemy_max_hp)
    values(p_difficulty,v_enemy,(v_enemy->>'hp')::numeric,(v_enemy->>'max')::numeric)
    returning * into v_battle;
  end if;
  insert into public.online_battle_members(battle_id,user_id,player_name,character,hp,max_hp)
  values(v_battle.id,v_uid,left(coalesce(nullif(p_player_name,''),'冒険者'),24),
    coalesce(p_character,'{}'::jsonb),greatest(0,coalesce((p_character->>'hp')::numeric,1)),
    greatest(1,coalesce((p_character->>'maxHp')::numeric,1)))
  on conflict(battle_id,user_id) do update
    set left_at=null,player_name=excluded.player_name,character=excluded.character,hp=excluded.hp,max_hp=excluded.max_hp;
  select count(*) into v_count from public.online_battle_members where battle_id=v_battle.id and left_at is null;
  if v_count>=5 or v_battle.created_at<=now()-interval '30 seconds' then
    update public.online_battles set status='active',started_at=coalesce(started_at,now()),updated_at=now()
     where id=v_battle.id and status='recruiting' returning * into v_battle;
  end if;
  return jsonb_build_object('battle',to_jsonb(v_battle),'count',v_count);
end $$;
grant execute on function public.join_online_battle(text,text,jsonb) to authenticated;
