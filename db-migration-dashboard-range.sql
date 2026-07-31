-- ============================================================================
-- 마이그레이션: 대시보드 기간을 '시작일~종료일'로 지정 + 사람별 집계를 '횟수' 기준으로
--
-- 왜 필요한가
--   기존 get_admin_dashboard(p_days int) 는 p_days 를 1~31 로 잘랐다.
--   (least(greatest(coalesce(p_days,7),1),31)) — 그래서 90일·1년 조회가 불가능했고
--   90 을 보내면 조용히 31일이 됐다. 임의 기준일자 조회도 표현할 수 없었다.
--
--   또 사람별 dates/serve_dates 가 distinct date 라, 하루에 두 번 섬겨도 1일로
--   집계됐다. 이 앱은 하루 N회 섬김을 지원하므로(db-migration-multi-serving.sql)
--   실제 참여도가 과소 집계됐다.
--
-- 무엇이 바뀌나
--   1) _dashboard_cells 에 attend_ct(출석 횟수) · serve_ct(섬김 횟수) 추가.
--      attend_total 을 '누적 출석 일수' → '누적 출석 횟수' 로 변경.
--      dates/serve_dates 는 날짜별 매트릭스가 쓰므로 그대로 둔다.
--   2) get_admin_dashboard(p_from text, p_to text) 오버로드 추가.
--      get_cell_dashboard(p_cell text, p_from text, p_to text) 오버로드 추가.
--
-- 하위호환
--   기존 (int) 시그니처는 지우지 않는다. 내부 헬퍼 시그니처가 그대로라 구버전
--   클라이언트도 계속 동작하고, 새 필드만 덤으로 받는다.
--   → 이 파일을 실행하기 전에도 앱은 깨지지 않는다(클라이언트가 폴백한다).
--
-- 재실행 안전(idempotent). Supabase SQL Editor 에서 통째로 실행.
-- ============================================================================
begin;

-- ── 1) 내부 헬퍼 교체: 횟수 집계 추가 ────────────────────────────────
--   시그니처(text,text,text)는 유지 → 기존 (int) 진입점이 그대로 이걸 쓴다.
drop function if exists public._dashboard_cells(text,text,text);
create or replace function public._dashboard_cells(p_cell text, v_from_t text, v_today_t text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c) order by c.name), '[]'::jsonb)
  from (
    select
      cl.id        as cell_id,
      cl.name      as name,
      cl.home_cafe as home_cafe,
      jsonb_array_length(cl.members) as member_count,

      -- (1) 기간 내 섬김: 날짜별 오픈/마감 수 (실제 섬김이 있는 날만)
      (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'date', d.dt, 'servings', d.cnt, 'closed', d.closed) order by d.dt), '[]'::jsonb)
        from (
          select s.date as dt,
                 count(*) filter (where s.state in ('open','closed')) as cnt,
                 count(*) filter (where s.state = 'closed')           as closed
          from public.sessions s
          where s.room_id = cl.room_id
            and s.date >= v_from_t and s.date <= v_today_t
          group by s.date
          having count(*) filter (where s.state in ('open','closed')) > 0
        ) d
      ) as days,

      -- 요약: 사용한 날 수 / 총 섬김 수(하루 N회를 각각 셈)
      (select count(distinct s.date) from public.sessions s
        where s.room_id = cl.room_id and s.date >= v_from_t and s.date <= v_today_t
          and s.state in ('open','closed')) as used_days,
      (select count(*) from public.sessions s
        where s.room_id = cl.room_id and s.date >= v_from_t and s.date <= v_today_t
          and s.state in ('open','closed')) as servings_total,

      -- (2) 구성원별 집계
      (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'member_id',    m.id,
                 'name',         m.name,
                 'dates',        att.dates,        -- 출석한 날짜(오름차순) — 날짜별 매트릭스용
                 'serve_dates',  srv.dates,        -- 섬긴 날짜(오름차순)   — 날짜별 매트릭스용
                 'attend_ct',    att.ct,           -- 출석 '횟수'(섬김 단위. 하루 2회 참여 = 2)
                 'serve_ct',     srv.ct,           -- 섬김 '횟수'(하루 2번 호스트 = 2)
                 'attend_total', att.total,        -- 전체 기간 누적 출석 횟수
                 'menus',        mnu.menus         -- 메뉴별 주문 횟수 [{name,count}] (많은 순)
               ) order by srv.ct desc, att.ct desc, m.name), '[]'::jsonb)
        from (
          -- 멤버(숨은 id/이름). 레거시(문자열=id가 곧 이름)도 정규화.
          select coalesce(e->>'id',   e #>> '{}') as id,
                 coalesce(e->>'name', e #>> '{}') as name
          from jsonb_array_elements(cl.members) e
        ) m
        left join lateral (
          -- orders PK = (room_id, date, seq, member_id) → count(*) 이 곧 '참여한 섬김 횟수'
          select coalesce(jsonb_agg(distinct x.d order by x.d), '[]'::jsonb) as dates,
                 count(*)                                                    as ct,
                 (select count(*) from public.orders o2
                    where o2.room_id = cl.room_id and o2.member_id = m.id)   as total
          from (select o.date d from public.orders o
                 where o.room_id = cl.room_id and o.member_id = m.id
                   and o.date >= v_from_t and o.date <= v_today_t) x
        ) att on true
        left join lateral (
          -- sessions PK = (room_id, date, seq) → 같은 날 2번 호스트하면 2로 센다
          select coalesce(jsonb_agg(distinct y.d order by y.d), '[]'::jsonb) as dates,
                 count(*)                                                    as ct
          from (select s.date d from public.sessions s
                 where s.room_id = cl.room_id and s.host_id = m.id
                   and s.state in ('open','closed')
                   and s.date >= v_from_t and s.date <= v_today_t) y
        ) srv on true
        left join lateral (
          select coalesce(jsonb_agg(jsonb_build_object('name', z.nm, 'count', z.ct)
                            order by z.ct desc, z.nm), '[]'::jsonb) as menus
          from (select coalesce(nullif(o.menu_name,''), o.menu_id, '기타') as nm, count(*) as ct
                from public.orders o
                where o.room_id = cl.room_id and o.member_id = m.id and o.type = 'drink'
                  and o.date >= v_from_t and o.date <= v_today_t
                group by 1) z
        ) mnu on true
      ) as members
    from public.cells cl
    where p_cell is null or cl.id = p_cell
  ) c;
$$;
revoke all on function public._dashboard_cells(text,text,text) from public, anon, authenticated;

-- ── 2) 기간 정규화 헬퍼 ──────────────────────────────────────────────
--   미래 금지 · 뒤집힌 입력 교정 · 최대 366일. 잘못된 문자열은 기본값으로 떨어진다.
create or replace function public._dash_range(p_from text, p_to text)
returns table(f text, t text)
language plpgsql immutable as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_to    date;
  v_from  date;
  v_tmp   date;
begin
  begin v_to := nullif(p_to,'')::date;   exception when others then v_to := null;   end;
  begin v_from := nullif(p_from,'')::date; exception when others then v_from := null; end;
  v_to   := least(coalesce(v_to, v_today), v_today);      -- 미래 종료일 금지
  v_from := coalesce(v_from, v_to - 29);                  -- 기본 최근 30일(오늘 포함)
  if v_from > v_to then v_tmp := v_from; v_from := v_to; v_to := v_tmp; end if;
  v_from := greatest(v_from, v_to - 365);                 -- 최대 366일
  f := to_char(v_from,'YYYY-MM-DD');
  t := to_char(v_to,'YYYY-MM-DD');
  return next;
end $$;
revoke all on function public._dash_range(text,text) from public, anon, authenticated;

-- ── 3) 진입점: 관리자 전체 대시보드 (기간 지정) ──────────────────────
drop function if exists public.get_admin_dashboard(text,text);
create or replace function public.get_admin_dashboard(p_from text, p_to text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  if auth.role() is distinct from 'authenticated' then
    raise exception 'admin only';
  end if;
  select * into r from public._dash_range(p_from, p_to);
  return jsonb_build_object(
    'today', to_char((now() at time zone 'Asia/Seoul')::date,'YYYY-MM-DD'),
    'from', r.f, 'to', r.t,
    'cells', public._dashboard_cells(null, r.f, r.t)
  );
end $$;
revoke all on function public.get_admin_dashboard(text,text) from public, anon;
grant execute on function public.get_admin_dashboard(text,text) to authenticated;

-- ── 4) 진입점: 셀 단위 대시보드 (기간 지정) ──────────────────────────
drop function if exists public.get_cell_dashboard(text,text,text);
create or replace function public.get_cell_dashboard(p_cell text, p_from text, p_to text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; arr jsonb;
begin
  if p_cell is null or length(p_cell) = 0 then return null; end if;
  select * into r from public._dash_range(p_from, p_to);
  arr := public._dashboard_cells(p_cell, r.f, r.t);
  if arr is null or jsonb_array_length(arr) = 0 then return null; end if;
  return jsonb_build_object(
    'today', to_char((now() at time zone 'Asia/Seoul')::date,'YYYY-MM-DD'),
    'from', r.f, 'to', r.t,
    'cell', arr->0
  );
end $$;
revoke all on function public.get_cell_dashboard(text,text,text) from public;
grant execute on function public.get_cell_dashboard(text,text,text) to anon, authenticated;

commit;
