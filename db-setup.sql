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

alter table public.cells enable row level security;
alter table public.sessions enable row level security;
alter table public.orders enable row level security;
alter table public.cafe_menus enable row level security;

do $$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('cells','sessions','orders','cafe_menus')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

grant usage on schema public to anon, authenticated;

revoke all on table public.sessions, public.orders, public.cells, public.cafe_menus from anon, authenticated;
grant select, insert, update, delete on table public.cells to authenticated;
grant select, insert, update, delete on table public.cafe_menus to authenticated;
grant select on table public.cafe_menus to anon, authenticated;

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
  select exists(
    select 1
    from public.cells c
    where c.room_id = p_room
      and c.members ? p_member
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

create or replace function public.set_members(p_id text, p_members jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_members) <> 'array'
     or jsonb_array_length(p_members) < 1
     or jsonb_array_length(p_members) > 60 then
    raise exception 'bad members';
  end if;

  if exists (
    select 1
    from jsonb_array_elements_text(p_members) e(name)
    where length(name) < 1 or length(name) > 40
  ) then
    raise exception 'bad member name';
  end if;

  update public.cells
  set members = p_members
  where id = p_id;

  if not found then
    raise exception 'no cell';
  end if;
end $$;
revoke all on function public.set_members(text,jsonb) from public;
grant execute on function public.set_members(text,jsonb) to anon, authenticated;

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
grant execute on function public.add_cafe_menu(text,text,text) to anon, authenticated;


-- ---- 데모 셀: 가이드/랜딩의 ?cell=demo 체험용 (가짜 데이터) ----
insert into public.cells (id, room_id, name, members, home_cafe)
values ('demo','demo','ㅇ-ㅇ셀',
        '["김요셉","이다니엘","박사무엘","최에스더","정하은","한사랑"]'::jsonb,'gil')
on conflict (id) do update
  set name = excluded.name, members = excluded.members, home_cafe = excluded.home_cafe;

commit;
