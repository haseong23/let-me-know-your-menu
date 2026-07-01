-- ============================================================
-- 오늘은 제가 섬기겠습니다 — DB 전체 설정 스크립트 (한 번에 실행)
-- Supabase Dashboard > SQL Editor 에 '전체' 붙여넣고 Run 하세요.
-- 기존 데이터는 보존됩니다(create table if not exists). 재실행 안전(idempotent).
-- 실행 후 Auth 설정: Authentication > Providers > Email ON,
--   'Allow new users to sign up' OFF, Users 에서 관리자 계정 1개 생성.
-- ============================================================

begin;

create table if not exists public.cells (
  id text primary key,
  room_id text not null unique,
  name text not null,
  members jsonb not null default '[]'::jsonb,
  home_cafe text not null default 'gil',
  created_at timestamptz not null default now()
);

create table if not exists public.sessions (
  room_id text not null,
  date text not null,
  state text not null default 'idle',
  host_id text,
  close_at bigint,
  cafe_id text,
  updated_at timestamptz not null default now(),
  primary key (room_id, date)
);

create table if not exists public.orders (
  room_id text not null,
  date text not null,
  member_id text not null,
  type text not null,
  menu_id text,
  menu_name text,
  temp text,
  extras jsonb not null default '[]'::jsonb,
  note text,
  updated_at timestamptz not null default now(),
  primary key (room_id, date, member_id)
);

create table if not exists public.cafe_menus (
  cafe_id text not null,
  menu_id text not null,
  name text not null,
  emoji text default '🥤',
  temps jsonb default '["ICE","HOT"]'::jsonb,
  extras jsonb default '[]'::jsonb,
  cat text,
  popular boolean default false,
  sort int default 0,
  created_at timestamptz not null default now(),
  primary key (cafe_id, menu_id)
);

-- 구성원 편집 감사 로그: 누가(자기신고 이름/'관리자') 무엇을(추가/이름변경/삭제) 바꿨는지.
-- set_members RPC 안에서 old/new diff 를 계산해 자동 기록(정의자 권한으로 RLS 우회 insert).
create table if not exists public.member_logs (
  id bigint generated always as identity primary key,
  cell_id text not null,
  actor text,                       -- 편집자 자기신고 이름(일반) 또는 '관리자'(IT). null=익명
  changes jsonb not null,           -- [{op:'add',name} | {op:'remove',name} | {op:'rename',from,to}]
  created_at timestamptz not null default now()
);
create index if not exists member_logs_cell_idx on public.member_logs (cell_id, created_at desc);

alter table public.cells enable row level security;
alter table public.sessions enable row level security;
alter table public.orders enable row level security;
alter table public.cafe_menus enable row level security;
alter table public.member_logs enable row level security;

do $$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('cells','sessions','orders','cafe_menus','member_logs')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

grant usage on schema public to anon, authenticated;

revoke all on table public.sessions, public.orders, public.cells, public.cafe_menus, public.member_logs from anon, authenticated;
grant select, insert, update, delete on table public.cells to authenticated;
grant select, insert, update, delete on table public.cafe_menus to authenticated;
grant select on table public.cafe_menus to anon, authenticated;
grant select on table public.member_logs to authenticated;  -- 로그 열람=관리자(authenticated)만. insert는 set_members(정의자)가 수행.

create policy cells_admin_select on public.cells
  for select to authenticated using (true);
create policy cells_admin_insert on public.cells
  for insert to authenticated with check (
    id = room_id
    and id ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'
    and length(name) between 1 and 40
    and length(coalesce(home_cafe,'')) <= 40
    and jsonb_typeof(members) = 'array'
    and jsonb_array_length(members) <= 60
  );
create policy cells_admin_update on public.cells
  for update to authenticated using (true) with check (
    length(name) between 1 and 40
    and length(coalesce(home_cafe,'')) <= 40
    and jsonb_typeof(members) = 'array'
    and jsonb_array_length(members) <= 60
  );
create policy cells_admin_delete on public.cells
  for delete to authenticated using (true);

create policy cafe_menus_public_select on public.cafe_menus
  for select to anon, authenticated using (true);
create policy cafe_menus_admin_insert on public.cafe_menus
  for insert to authenticated with check (length(name) between 1 and 40);
create policy cafe_menus_admin_update on public.cafe_menus
  for update to authenticated using (true) with check (length(name) between 1 and 40);
create policy cafe_menus_admin_delete on public.cafe_menus
  for delete to authenticated using (true);

-- 수정 내역: 관리자(authenticated)만 열람. anon 직접 접근 없음.
create policy member_logs_admin_select on public.member_logs
  for select to authenticated using (true);

-- 기존(구버전) 함수 먼저 제거: create or replace 는 반환타입/파라미터명 변경을 허용하지 않아
-- get_cell 등 옛 정의가 있으면 트랜잭션 전체가 롤백됨. 안전하게 drop 후 재생성.
drop function if exists public.is_valid_app_date(text);
drop function if exists public.room_exists(text);
drop function if exists public.room_has_member(text,text);
drop function if exists public.get_cell(text);
drop function if exists public.set_members(text,jsonb);
drop function if exists public.set_members(text,jsonb,text);
drop function if exists public.member_diff(jsonb,jsonb);
drop function if exists public.get_room_day(text,text);
drop function if exists public.get_room_history(text,text);
drop function if exists public.claim_host(text,text,text,text);
drop function if exists public.set_room_state(text,text,text);
drop function if exists public.set_order(text,text,text,text,text,text,text,jsonb,text);
drop function if exists public.remove_order(text,text,text);
drop function if exists public.add_cafe_menu(text,text,text);

create or replace function public.is_valid_app_date(p_date text)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_date ~ '^\d{4}-\d{2}-\d{2}$'
    and p_date between to_char((now() at time zone 'Asia/Seoul')::date - 2, 'YYYY-MM-DD')
                   and to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY-MM-DD')
$$;
revoke all on function public.is_valid_app_date(text) from public;

create or replace function public.room_exists(p_room text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.cells c where c.room_id = p_room)
$$;
revoke all on function public.room_exists(text) from public;

create or replace function public.room_has_member(p_room text, p_member text)
returns boolean
language sql stable security definer set search_path = public as $$
  -- p_member 는 멤버의 숨은 id. 레거시(문자열 멤버 = id가 곧 이름)도 함께 매칭.
  select exists(
    select 1
    from public.cells c, jsonb_array_elements(c.members) e
    where c.room_id = p_room
      and ( (jsonb_typeof(e) = 'object' and e->>'id' = p_member)
         or (jsonb_typeof(e) = 'string' and e #>> '{}' = p_member) )
  )
$$;
revoke all on function public.room_has_member(text,text) from public;

create or replace function public.get_cell(p_id text)
returns table(id text, room_id text, name text, members jsonb, home_cafe text)
language sql stable security definer set search_path = public as $$
  select c.id, c.room_id, c.name, c.members, c.home_cafe
  from public.cells c
  where c.id = p_id
$$;
revoke all on function public.get_cell(text) from public;
grant execute on function public.get_cell(text) to anon, authenticated;

-- 멤버 명단 diff: 숨은 id 기준으로 추가/이름변경/삭제 계산(레거시 문자열·객체 모두 정규화).
create or replace function public.member_diff(old_m jsonb, new_m jsonb)
returns jsonb
language sql immutable set search_path = public as $$
  with
  o as (select coalesce(e->>'id', e #>> '{}') as id,
               coalesce(e->>'name', e #>> '{}') as nm
        from jsonb_array_elements(coalesce(old_m, '[]'::jsonb)) e),
  n as (select coalesce(e->>'id', e #>> '{}') as id,
               coalesce(e->>'name', e #>> '{}') as nm
        from jsonb_array_elements(coalesce(new_m, '[]'::jsonb)) e),
  d as (
    select jsonb_build_object('op','add','name', n.nm) j
      from n left join o on o.id = n.id where o.id is null
    union all
    select jsonb_build_object('op','remove','name', o.nm)
      from o left join n on n.id = o.id where n.id is null
    union all
    select jsonb_build_object('op','rename','from', o.nm, 'to', n.nm)
      from o join n on n.id = o.id where o.nm is distinct from n.nm
  )
  select coalesce(jsonb_agg(j), '[]'::jsonb) from d
$$;
-- 내부 헬퍼(set_members가 정의자 권한으로 호출). 외부 노출 불필요 → anon/authenticated 모두 회수.
-- (Supabase 기본권한이 함수 생성 시 anon에 EXECUTE를 부여하므로 from public 만으론 부족)
revoke all on function public.member_diff(jsonb,jsonb) from public, anon, authenticated;

create or replace function public.set_members(p_id text, p_members jsonb, p_actor text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare norm jsonb; old_m jsonb; ch jsonb;
begin
  if jsonb_typeof(p_members) <> 'array'
     or jsonb_array_length(p_members) < 1
     or jsonb_array_length(p_members) > 60 then
    raise exception 'bad members';
  end if;

  -- 각 요소: 문자열(레거시) 또는 {id,name} 객체 허용
  if exists (
    select 1 from jsonb_array_elements(p_members) e
    where not (
      (jsonb_typeof(e) = 'string' and length(e #>> '{}') between 1 and 40)
      or (jsonb_typeof(e) = 'object'
          and coalesce(e->>'id','') <> '' and length(e->>'id') <= 64
          and length(coalesce(e->>'name','')) between 1 and 40)
    )
  ) then
    raise exception 'bad member';
  end if;

  -- 객체로 정규화 저장(문자열 → {id:name, name:name}). 이름은 표시용, id는 불변.
  select coalesce(jsonb_agg(
    case when jsonb_typeof(e) = 'string'
         then jsonb_build_object('id', e #>> '{}', 'name', e #>> '{}')
         else jsonb_build_object('id', e->>'id', 'name', e->>'name') end
  ), '[]'::jsonb) into norm
  from jsonb_array_elements(p_members) e;

  select members into old_m from public.cells where id = p_id;
  if not found then raise exception 'no cell'; end if;

  update public.cells set members = norm where id = p_id;

  -- 변경분이 있을 때만 감사 로그 기록(순서/무변경 재저장은 기록 안 함)
  ch := public.member_diff(coalesce(old_m, '[]'::jsonb), norm);
  if jsonb_array_length(ch) > 0 then
    insert into public.member_logs(cell_id, actor, changes)
    values (p_id, nullif(left(coalesce(p_actor,''), 40), ''), ch);
  end if;
end $$;
revoke all on function public.set_members(text,jsonb,text) from public;
grant execute on function public.set_members(text,jsonb,text) to anon, authenticated;

create or replace function public.get_room_day(p_room text, p_date text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  sess jsonb;
  ords jsonb;
begin
  if not public.room_exists(p_room)
     or not public.is_valid_app_date(p_date) then
    raise exception 'no room';
  end if;

  select to_jsonb(s) into sess
  from public.sessions s
  where s.room_id = p_room and s.date = p_date;

  select coalesce(jsonb_agg(to_jsonb(o)), '[]'::jsonb) into ords
  from public.orders o
  where o.room_id = p_room and o.date = p_date;

  return jsonb_build_object('session', sess, 'orders', ords);
end $$;
revoke all on function public.get_room_day(text,text) from public;
grant execute on function public.get_room_day(text,text) to anon, authenticated;

create or replace function public.get_room_history(p_room text, p_today text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  rows jsonb;
begin
  if not public.room_exists(p_room) then
    raise exception 'no room';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', o.member_id,
    'menu_id', o.menu_id,
    'menu_name', o.menu_name
  )), '[]'::jsonb) into rows
  from public.orders o
  where o.room_id = p_room
    and o.type = 'drink'
    and o.date < p_today;

  return rows;
end $$;
revoke all on function public.get_room_history(text,text) from public;
grant execute on function public.get_room_history(text,text) to anon, authenticated;

create or replace function public.claim_host(p_room text, p_date text, p_me text, p_cafe text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_me)
     or not public.is_valid_app_date(p_date)
     or length(coalesce(p_cafe,'')) > 40 then
    raise exception 'bad request';
  end if;

  insert into public.sessions(room_id, date, state)
  values (p_room, p_date, 'idle')
  on conflict (room_id, date) do nothing;

  update public.sessions
  set state = 'open',
      host_id = p_me,
      close_at = null,
      cafe_id = p_cafe,
      updated_at = now()
  where room_id = p_room
    and date = p_date
    and state = 'idle';

  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.claim_host(text,text,text,text) from public;
grant execute on function public.claim_host(text,text,text,text) to anon, authenticated;

create or replace function public.set_room_state(p_room text, p_date text, p_state text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room)
     or not public.is_valid_app_date(p_date)
     or p_state not in ('idle','open','closed') then
    raise exception 'bad request';
  end if;

  update public.sessions
  set state = p_state,
      host_id = case when p_state = 'idle' then null else host_id end,
      updated_at = now()
  where room_id = p_room and date = p_date;
end $$;
revoke all on function public.set_room_state(text,text,text) from public;
grant execute on function public.set_room_state(text,text,text) to anon, authenticated;

create or replace function public.set_order(
  p_room text,
  p_date text,
  p_member_id text,
  p_type text,
  p_menu_id text,
  p_menu_name text,
  p_temp text,
  p_extras jsonb,
  p_note text
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_member_id)
     or not public.is_valid_app_date(p_date)
     or p_type not in ('drink','skip')
     or length(coalesce(p_member_id,'')) > 40
     or length(coalesce(p_menu_id,'')) > 60
     or length(coalesce(p_menu_name,'')) > 60
     or length(coalesce(p_temp,'')) > 20
     or length(coalesce(p_note,'')) > 200
     or jsonb_typeof(coalesce(p_extras, '[]'::jsonb)) <> 'array' then
    raise exception 'bad request';
  end if;

  insert into public.orders(room_id, date, member_id, type, menu_id, menu_name, temp, extras, note, updated_at)
  values (p_room, p_date, p_member_id, p_type, p_menu_id, p_menu_name, p_temp, coalesce(p_extras, '[]'::jsonb), coalesce(p_note,''), now())
  on conflict (room_id, date, member_id) do update
  set type = excluded.type,
      menu_id = excluded.menu_id,
      menu_name = excluded.menu_name,
      temp = excluded.temp,
      extras = excluded.extras,
      note = excluded.note,
      updated_at = now();
end $$;
revoke all on function public.set_order(text,text,text,text,text,text,text,jsonb,text) from public;
grant execute on function public.set_order(text,text,text,text,text,text,text,jsonb,text) to anon, authenticated;

create or replace function public.remove_order(p_room text, p_date text, p_member_id text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_member_id)
     or not public.is_valid_app_date(p_date) then
    raise exception 'bad request';
  end if;

  delete from public.orders
  where room_id = p_room
    and date = p_date
    and member_id = p_member_id;
end $$;
revoke all on function public.remove_order(text,text,text) from public;
grant execute on function public.remove_order(text,text,text) to anon, authenticated;

create or replace function public.add_cafe_menu(p_cafe_id text, p_menu_id text, p_name text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_cafe_id,'')) < 1
     or length(coalesce(p_cafe_id,'')) > 40
     or length(coalesce(p_menu_id,'')) < 1
     or length(coalesce(p_menu_id,'')) > 80
     or length(coalesce(p_name,'')) < 1
     or length(coalesce(p_name,'')) > 40 then
    raise exception 'bad menu';
  end if;

  if (select count(*) from public.cafe_menus where cafe_id = p_cafe_id) >= 300 then
    raise exception 'too many menus';
  end if;

  insert into public.cafe_menus(cafe_id, menu_id, name, cat)
  values (p_cafe_id, p_menu_id, p_name, 'extra')
  on conflict do nothing;
end $$;
revoke all on function public.add_cafe_menu(text,text,text) from public;
grant execute on function public.add_cafe_menu(text,text,text) to authenticated;  -- anon 제외: 공유 카페 메뉴 오염 방지(관리자만 추가)


-- ---- 데모 셀: 가이드/랜딩의 ?cell=demo 체험용 (가짜 데이터) ----
insert into public.cells (id, room_id, name, members, home_cafe)
values ('demo','demo','ㅇ-ㅇ셀',
        '["김요셉","이다니엘","박사무엘","최에스더","정하은","한사랑"]'::jsonb,'gil')
on conflict (id) do update
  set name = excluded.name, members = excluded.members, home_cafe = excluded.home_cafe;

-- ============================================================
-- 다중 섬김(하루 N번) 오버레이 — seq 차원 (db-migration-multi-serving.sql 과 동일)
-- 위에서 만든 단일-섬김 정의를 seq 지원 버전으로 교체. 재실행 안전.
-- ============================================================
alter table public.sessions add column if not exists seq int not null default 1;
alter table public.orders   add column if not exists seq int not null default 1;
alter table public.sessions drop constraint if exists sessions_pkey;
alter table public.sessions add  constraint sessions_pkey primary key (room_id, date, seq);
alter table public.orders   drop constraint if exists orders_pkey;
alter table public.orders   add  constraint orders_pkey  primary key (room_id, date, seq, member_id);
create unique index if not exists sessions_one_open on public.sessions(room_id, date) where state = 'open';

create or replace function public._active_seq(p_room text, p_date text)
returns int language sql stable security definer set search_path = public as $$
  select seq from public.sessions where room_id = p_room and date = p_date
  order by (state = 'open') desc, seq desc limit 1
$$;
revoke all on function public._active_seq(text,text) from public, anon, authenticated;

drop function if exists public.set_order(text,text,text,text,text,text,text,jsonb,text);
drop function if exists public.remove_order(text,text,text);

create or replace function public.get_day(p_room text, p_date text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare arr jsonb;
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) then raise exception 'no room'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.seq), '[]'::jsonb) into arr
  from (
    select s.seq, s.state, s.host_id, s.cafe_id, s.close_at,
      (select coalesce(jsonb_agg(to_jsonb(o)), '[]'::jsonb) from public.orders o
        where o.room_id = s.room_id and o.date = s.date and o.seq = s.seq) as orders
    from public.sessions s where s.room_id = p_room and s.date = p_date
  ) x;
  return jsonb_build_object('servings', arr);
end $$;
revoke all on function public.get_day(text,text) from public;
grant execute on function public.get_day(text,text) to anon, authenticated;

create or replace function public.start_serving(p_room text, p_date text, p_me text, p_cafe text)
returns int language plpgsql security definer set search_path = public as $$
declare nseq int;
begin
  if not public.room_exists(p_room) or not public.room_has_member(p_room, p_me)
     or not public.is_valid_app_date(p_date) or length(coalesce(p_cafe,'')) > 40 then raise exception 'bad request'; end if;
  select coalesce(max(seq),0)+1 into nseq from public.sessions where room_id = p_room and date = p_date;
  insert into public.sessions(room_id, date, seq, state, host_id, cafe_id, updated_at)
    values (p_room, p_date, nseq, 'open', p_me, p_cafe, now());
  return nseq;
exception when unique_violation then return 0;
end $$;
revoke all on function public.start_serving(text,text,text,text) from public;
grant execute on function public.start_serving(text,text,text,text) to anon, authenticated;

create or replace function public.set_serving_state(p_room text, p_date text, p_seq int, p_state text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) or p_state not in ('open','closed') then raise exception 'bad request'; end if;
  update public.sessions set state = p_state,
      close_at = case when p_state = 'closed' then (extract(epoch from now())*1000)::bigint else null end, updated_at = now()
   where room_id = p_room and date = p_date and seq = p_seq;
end $$;
revoke all on function public.set_serving_state(text,text,int,text) from public;
grant execute on function public.set_serving_state(text,text,int,text) to anon, authenticated;

create or replace function public.unclaim_serving(p_room text, p_date text, p_seq int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) then raise exception 'bad request'; end if;
  if not exists (select 1 from public.orders where room_id = p_room and date = p_date and seq = p_seq) then
    delete from public.sessions where room_id = p_room and date = p_date and seq = p_seq;
  else
    update public.sessions set host_id = null, updated_at = now() where room_id = p_room and date = p_date and seq = p_seq;
  end if;
end $$;
revoke all on function public.unclaim_serving(text,text,int) from public;
grant execute on function public.unclaim_serving(text,text,int) to anon, authenticated;

create or replace function public.set_order(
  p_room text, p_date text, p_member_id text, p_type text,
  p_menu_id text, p_menu_name text, p_temp text, p_extras jsonb, p_note text, p_seq int default null
) returns void language plpgsql security definer set search_path = public as $$
declare tseq int;
begin
  if not public.room_exists(p_room) or not public.room_has_member(p_room, p_member_id) or not public.is_valid_app_date(p_date)
     or p_type not in ('drink','skip') or length(coalesce(p_member_id,'')) > 40 or length(coalesce(p_menu_id,'')) > 60
     or length(coalesce(p_menu_name,'')) > 60 or length(coalesce(p_temp,'')) > 20 or length(coalesce(p_note,'')) > 200
     or jsonb_typeof(coalesce(p_extras,'[]'::jsonb)) <> 'array' then raise exception 'bad request'; end if;
  tseq := coalesce(p_seq, public._active_seq(p_room, p_date));
  if tseq is null then raise exception 'no serving'; end if;
  insert into public.orders(room_id, date, seq, member_id, type, menu_id, menu_name, temp, extras, note, updated_at)
    values (p_room, p_date, tseq, p_member_id, p_type, p_menu_id, p_menu_name, p_temp, coalesce(p_extras,'[]'::jsonb), coalesce(p_note,''), now())
  on conflict (room_id, date, seq, member_id) do update
    set type = excluded.type, menu_id = excluded.menu_id, menu_name = excluded.menu_name,
        temp = excluded.temp, extras = excluded.extras, note = excluded.note, updated_at = now();
end $$;
revoke all on function public.set_order(text,text,text,text,text,text,text,jsonb,text,int) from public;
grant execute on function public.set_order(text,text,text,text,text,text,text,jsonb,text,int) to anon, authenticated;

create or replace function public.remove_order(p_room text, p_date text, p_member_id text, p_seq int default null)
returns void language plpgsql security definer set search_path = public as $$
declare tseq int;
begin
  if not public.room_exists(p_room) or not public.room_has_member(p_room, p_member_id) or not public.is_valid_app_date(p_date) then raise exception 'bad request'; end if;
  tseq := coalesce(p_seq, public._active_seq(p_room, p_date));
  delete from public.orders where room_id = p_room and date = p_date and seq = tseq and member_id = p_member_id;
end $$;
revoke all on function public.remove_order(text,text,text,int) from public;
grant execute on function public.remove_order(text,text,text,int) to anon, authenticated;

-- 하위호환(옛 클라이언트) — 활성 섬김 대상
create or replace function public.get_room_day(p_room text, p_date text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sess jsonb; ords jsonb; aseq int;
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) then raise exception 'no room'; end if;
  aseq := public._active_seq(p_room, p_date);
  select to_jsonb(s) into sess from public.sessions s where s.room_id = p_room and s.date = p_date and s.seq = aseq;
  select coalesce(jsonb_agg(to_jsonb(o)), '[]'::jsonb) into ords from public.orders o where o.room_id = p_room and o.date = p_date and o.seq = aseq;
  return jsonb_build_object('session', sess, 'orders', ords);
end $$;
revoke all on function public.get_room_day(text,text) from public;
grant execute on function public.get_room_day(text,text) to anon, authenticated;

create or replace function public.claim_host(p_room text, p_date text, p_me text, p_cafe text)
returns boolean language plpgsql security definer set search_path = public as $$
declare oseq int; n int;
begin
  if not public.room_exists(p_room) or not public.room_has_member(p_room, p_me)
     or not public.is_valid_app_date(p_date) or length(coalesce(p_cafe,'')) > 40 then raise exception 'bad request'; end if;
  select seq into oseq from public.sessions where room_id = p_room and date = p_date and state = 'open' order by seq desc limit 1;
  if oseq is not null then
    update public.sessions set host_id = p_me, cafe_id = coalesce(cafe_id, p_cafe), updated_at = now()
      where room_id = p_room and date = p_date and seq = oseq and host_id is null;
    get diagnostics n = row_count; return n > 0;
  end if;
  return public.start_serving(p_room, p_date, p_me, p_cafe) > 0;
end $$;
revoke all on function public.claim_host(text,text,text,text) from public;
grant execute on function public.claim_host(text,text,text,text) to anon, authenticated;

create or replace function public.set_room_state(p_room text, p_date text, p_state text)
returns void language plpgsql security definer set search_path = public as $$
declare tseq int;
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) or p_state not in ('idle','open','closed') then raise exception 'bad request'; end if;
  if p_state = 'idle' then
    select seq into tseq from public.sessions where room_id = p_room and date = p_date and state = 'open' order by seq desc limit 1;
    if tseq is not null then update public.sessions set host_id = null, updated_at = now() where room_id = p_room and date = p_date and seq = tseq; end if;
  else
    tseq := public._active_seq(p_room, p_date);
    if tseq is not null then
      update public.sessions set state = p_state,
          close_at = case when p_state = 'closed' then (extract(epoch from now())*1000)::bigint else null end, updated_at = now()
        where room_id = p_room and date = p_date and seq = tseq;
    end if;
  end if;
end $$;
revoke all on function public.set_room_state(text,text,text) from public;
grant execute on function public.set_room_state(text,text,text) to anon, authenticated;

commit;
