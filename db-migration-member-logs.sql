-- ============================================================
-- 마이그레이션: 셀원 수정 감사 로그 (member_logs)
-- Supabase Dashboard > SQL Editor 에 '전체' 붙여넣고 Run.
-- 재실행 안전(idempotent). 기존 데이터 보존.
-- (db-setup.sql 전체에도 반영돼 있어, 전체 재실행으로 대체 가능)
-- ============================================================
begin;

-- 1) 감사 로그 테이블: 누가(actor) 무엇을(changes) 언제 바꿨는지
create table if not exists public.member_logs (
  id bigint generated always as identity primary key,
  cell_id text not null,
  actor text,                       -- 편집자 자기신고 이름(일반) 또는 '관리자'(IT). null=익명
  changes jsonb not null,           -- [{op:'add',name} | {op:'remove',name} | {op:'rename',from,to}]
  created_at timestamptz not null default now()
);
create index if not exists member_logs_cell_idx on public.member_logs (cell_id, created_at desc);
alter table public.member_logs enable row level security;

-- 열람은 관리자(authenticated)만. anon 직접 접근 0. insert 는 set_members(정의자)가 수행.
revoke all on table public.member_logs from anon, authenticated;
grant select on table public.member_logs to authenticated;
drop policy if exists member_logs_admin_select on public.member_logs;
create policy member_logs_admin_select on public.member_logs
  for select to authenticated using (true);

-- 2) 멤버 명단 diff: 숨은 id 기준 추가/이름변경/삭제 (레거시 문자열·객체 모두 정규화)
create or replace function public.member_diff(old_m jsonb, new_m jsonb)
returns jsonb language sql immutable set search_path = public as $$
  with
  o as (select coalesce(e->>'id', e #>> '{}') as id, coalesce(e->>'name', e #>> '{}') as nm
        from jsonb_array_elements(coalesce(old_m,'[]'::jsonb)) e),
  n as (select coalesce(e->>'id', e #>> '{}') as id, coalesce(e->>'name', e #>> '{}') as nm
        from jsonb_array_elements(coalesce(new_m,'[]'::jsonb)) e),
  d as (
    select jsonb_build_object('op','add','name', n.nm) j     from n left join o on o.id=n.id where o.id is null
    union all
    select jsonb_build_object('op','remove','name', o.nm)    from o left join n on n.id=o.id where n.id is null
    union all
    select jsonb_build_object('op','rename','from', o.nm, 'to', n.nm) from o join n on n.id=o.id where o.nm is distinct from n.nm
  )
  select coalesce(jsonb_agg(j), '[]'::jsonb) from d
$$;
revoke all on function public.member_diff(jsonb,jsonb) from public;

-- 3) set_members: p_actor 추가 + 변경분 자동 로그 (옛 2-인자 제거 후 재생성)
drop function if exists public.set_members(text,jsonb);
drop function if exists public.set_members(text,jsonb,text);
create or replace function public.set_members(p_id text, p_members jsonb, p_actor text default null)
returns void language plpgsql security definer set search_path = public as $$
declare norm jsonb; old_m jsonb; ch jsonb;
begin
  if jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) < 1 or jsonb_array_length(p_members) > 60 then
    raise exception 'bad members';
  end if;
  if exists (select 1 from jsonb_array_elements(p_members) e where not (
      (jsonb_typeof(e)='string' and length(e #>> '{}') between 1 and 40)
      or (jsonb_typeof(e)='object' and coalesce(e->>'id','')<>'' and length(e->>'id')<=64
          and length(coalesce(e->>'name','')) between 1 and 40)
    )) then
    raise exception 'bad member';
  end if;
  select coalesce(jsonb_agg(case when jsonb_typeof(e)='string'
      then jsonb_build_object('id', e #>> '{}', 'name', e #>> '{}')
      else jsonb_build_object('id', e->>'id', 'name', e->>'name') end), '[]'::jsonb) into norm
    from jsonb_array_elements(p_members) e;
  select members into old_m from public.cells where id = p_id;
  if not found then raise exception 'no cell'; end if;
  update public.cells set members = norm where id = p_id;
  ch := public.member_diff(coalesce(old_m,'[]'::jsonb), norm);
  if jsonb_array_length(ch) > 0 then
    insert into public.member_logs(cell_id, actor, changes)
    values (p_id, nullif(left(coalesce(p_actor,''),40),''), ch);
  end if;
end $$;
revoke all on function public.set_members(text,jsonb,text) from public;
grant execute on function public.set_members(text,jsonb,text) to anon, authenticated;

commit;
