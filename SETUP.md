# 단체 커피 주문 설정 & 배포 가이드

이 저장소는 public 입니다. 실제 셀 명단, 주문 데이터, 운영용 Supabase 프로젝트 정보가 코드, 문서, 스크린샷, Git 히스토리에 남지 않도록 관리합니다.

루트 랜딩 페이지는 의도된 공개 화면입니다. 셀 입장은 `?cell=...` 링크를 받은 사람만 하며, `?cell=demo`는 개인정보가 없는 내장 `ㅇ-ㅇ셀`입니다.

## 보안 원칙

- 실제 셀원 이름은 코드에 넣지 않고 Supabase `cells` 테이블에만 저장합니다.
- `orders`, `sessions`, `cells`는 익명 사용자의 직접 `SELECT`를 허용하지 않습니다.
- 앱은 `get_cell`, `get_room_day`, `get_room_history` 같은 RPC를 통해 필요한 방 1개만 조회합니다.
- Supabase publishable/anon key는 비밀 키는 아니지만, RLS/RPC가 느슨하면 누구나 데이터를 읽는 열쇠가 됩니다.
- public repo의 `main`에는 운영용 Supabase URL/key를 커밋하지 않습니다. 공유 모드는 보안 SQL 적용 후 별도 배포 설정이나 앱의 고급 설정에서만 사용하세요.

## 1. Supabase 프로젝트 만들기

1. https://supabase.com 에서 새 프로젝트를 만듭니다.
2. 리전은 가까운 곳을 선택합니다.
3. **SQL Editor**에서 아래 SQL을 한 번에 실행합니다.
4. 관리자 화면을 쓸 경우 **Authentication > Providers > Email**을 켜고, **Allow new users to sign up**은 꺼둡니다.
5. **Authentication > Users > Add user**로 관리자 계정 1개를 직접 만듭니다.

## 2. 보안 SQL

> **한 번에 실행하려면 저장소 루트의 [`db-setup.sql`](db-setup.sql) 전체를 복사해 Supabase SQL Editor에 붙여넣고 Run** 하세요. (아래 SQL + 데모 셀 insert를 하나로 합친 스크립트, 재실행 안전)

아래 SQL은 기존 prototype 정책을 제거하고, private 테이블은 RPC로만 접근하게 만듭니다.

```sql
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

-- 기존(구버전) 함수 먼저 제거: create or replace 는 반환타입/파라미터명 변경을 불허하므로
-- 옛 get_cell 등이 있으면 트랜잭션이 롤백됨. drop 후 재생성으로 안전하게.
drop function if exists public.is_valid_app_date(text);
drop function if exists public.room_exists(text);
drop function if exists public.room_has_member(text,text);
drop function if exists public.get_cell(text);
drop function if exists public.set_members(text,jsonb);
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

create or replace function public.set_members(p_id text, p_members jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare norm jsonb;
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

  update public.cells set members = norm where id = p_id;
  if not found then raise exception 'no cell'; end if;
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
grant execute on function public.add_cafe_menu(text,text,text) to authenticated;  -- anon 제외: 공유 카페 메뉴 오염 방지(관리자만 추가)

commit;
```

## (선택) 데모 셀 — 가이드/랜딩의 라이브 데모(`?cell=demo`)가 작동하려면 DB에 삽입
운영(SHARED) 모드에선 `fetchCell`이 DB의 `get_cell`만 조회하므로(코드 폴백 없음), 데모 링크가 동작하려면 `cells`에 `demo` 행이 있어야 합니다. **가짜 데이터만** 사용합니다.
```sql
insert into public.cells (id, room_id, name, members, home_cafe)
values ('demo','demo','ㅇ-ㅇ셀',
        '["김요셉","이다니엘","박사무엘","최에스더","정하은","한사랑"]'::jsonb,'gil')
on conflict (id) do update
  set name = excluded.name, members = excluded.members, home_cafe = excluded.home_cafe;
```

## 3. 앱 연결

public `main` 브랜치에는 운영용 값을 커밋하지 않습니다. 보안 SQL을 적용한 뒤 테스트할 때는 앱 우상단 **고급 설정**에서 Project URL과 publishable key를 넣어 현재 기기에만 저장하세요.

별도 운영 배포에 값을 직접 넣는 경우에도 아래처럼 실제 셀원 명단이나 주문 데이터는 코드에 넣지 않습니다.

```js
const CONFIG = {
  SUPABASE_URL: "https://your-project.supabase.co",
  SUPABASE_ANON_KEY: "your-publishable-key",
  ROOM_ID: "default",
  ROOM_NAME: "오늘은 제가 섬기겠습니다",
};
```

연결되면 `cells`에 생성한 셀 링크(`?cell=...`)로 입장할 수 있습니다.

## 4. 관리자 화면

관리자 화면은 `?admin` 경로입니다.

- 공유 모드가 켜져 있어야 합니다.
- Supabase Email 인증으로 로그인해야 셀 생성, 삭제, 메뉴 관리를 할 수 있습니다.
- 관리자 이메일과 비밀번호는 코드나 문서에 적지 않습니다.

## 5. 기존 프로젝트 긴급 조치

이미 public repo나 GitHub Pages에 운영용 key가 올라간 적이 있다면 아래 순서로 처리합니다.

1. 위 보안 SQL을 실행해서 `orders`, `sessions`, `cells`의 직접 조회를 막습니다.
2. Supabase Dashboard에서 publishable key를 rotate 합니다.
3. Git 히스토리에 실명, 주문 데이터, 예전 key가 남아 있으면 히스토리를 정리하고 force push 합니다.
4. GitHub Pages 캐시가 갱신될 때까지 live HTML에 예전 값이 남아 있지 않은지 확인합니다.
