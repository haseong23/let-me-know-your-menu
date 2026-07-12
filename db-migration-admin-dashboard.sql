-- ============================================================
-- 마이그레이션: 관리자 대시보드 집계 RPC
-- Supabase Dashboard > SQL Editor 에 '전체' 붙여넣고 Run.
-- 재실행 안전(idempotent). 스키마 변경 없음(집계 함수만 추가).
--
-- 목적: 관리자(로그인/authenticated)만 볼 수 있는 셀 현황 대시보드.
--   1) 셀별 최근 N일(기본 7일, KST) 사용 빈도 — 섬김 오픈/마감 기준
--   2) 셀별 구성원 출석횟수 — 이 앱에서 의사표현(주문/안마심)한 날 수
--
-- 보안: sessions/orders 는 anon 직접권한 0(정의자 RPC 전용).
--   이 함수도 authenticated(관리자)에게만 execute 부여 + auth.role() 재확인.
-- ============================================================
begin;

drop function if exists public.get_admin_dashboard(int);

create or replace function public.get_admin_dashboard(p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_days    int  := least(greatest(coalesce(p_days,7),1),31);   -- 1~31일로 제한
  v_today   date := (now() at time zone 'Asia/Seoul')::date;
  v_from    date := v_today - (v_days - 1);
  v_from_t  text := to_char(v_from,  'YYYY-MM-DD');
  v_today_t text := to_char(v_today, 'YYYY-MM-DD');
  cells_json jsonb;
begin
  -- 관리자만: authenticated 세션이 아니면 거부(grant + 재확인 이중 방어)
  if auth.role() is distinct from 'authenticated' then
    raise exception 'admin only';
  end if;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.name), '[]'::jsonb) into cells_json
  from (
    select
      cl.id        as cell_id,
      cl.name      as name,
      cl.home_cafe as home_cafe,
      jsonb_array_length(cl.members) as member_count,

      -- (1) 최근 N일 섬김: 날짜별 오픈/마감 수 (실제 섬김이 있는 날만; 없는 날은 클라이언트에서 0 채움)
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

      -- 요약: 최근 N일 사용한 날 수 / 총 섬김 수
      (select count(distinct s.date) from public.sessions s
        where s.room_id = cl.room_id and s.date >= v_from_t and s.date <= v_today_t
          and s.state in ('open','closed')) as used_days,
      (select count(*) from public.sessions s
        where s.room_id = cl.room_id and s.date >= v_from_t and s.date <= v_today_t
          and s.state in ('open','closed')) as servings_total,

      -- (2) 구성원별: 최근 N일 출석 날짜(dates) + 섬김(호스트) 날짜(serve_dates) + 누적 출석(attend_total).
      --   출석=그 날 주문/안마심(=의사표현), 섬김=그 날 그 사람이 host_id 인 섬김.
      (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'member_id',    m.id,
                 'name',         m.name,
                 'dates',        att.dates,        -- 최근 N일 출석한 날짜(오름차순)
                 'serve_dates',  srv.dates,        -- 최근 N일 섬긴 날짜(오름차순)
                 'attend_total', att.total,        -- 전체 기간 누적 출석일 수
                 'menus',        mnu.menus         -- 최근 N일 메뉴별 주문 횟수 [{name,count}] (많은 순)
               ) order by jsonb_array_length(att.dates) desc,
                          jsonb_array_length(srv.dates) desc, m.name), '[]'::jsonb)
        from (
          -- 멤버(숨은 id/이름). 레거시(문자열=id가 곧 이름)도 정규화.
          select coalesce(e->>'id',   e #>> '{}') as id,
                 coalesce(e->>'name', e #>> '{}') as name
          from jsonb_array_elements(cl.members) e
        ) m
        left join lateral (
          select coalesce(jsonb_agg(x.d order by x.d), '[]'::jsonb) as dates,
                 (select count(distinct o.date) from public.orders o
                    where o.room_id = cl.room_id and o.member_id = m.id) as total
          from (select distinct o.date d from public.orders o
                 where o.room_id = cl.room_id and o.member_id = m.id
                   and o.date >= v_from_t and o.date <= v_today_t) x
        ) att on true
        left join lateral (
          select coalesce(jsonb_agg(y.d order by y.d), '[]'::jsonb) as dates
          from (select distinct s.date d from public.sessions s
                 where s.room_id = cl.room_id and s.host_id = m.id
                   and s.state in ('open','closed')
                   and s.date >= v_from_t and s.date <= v_today_t) y
        ) srv on true
        left join lateral (
          -- 이 사람이 최근 N일 무엇을 몇 번 주문했는지(음료만). menu_name 우선, 없으면 menu_id.
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
  ) c;

  return jsonb_build_object(
    'today', v_today_t,
    'from',  v_from_t,
    'days',  v_days,
    'cells', cells_json
  );
end $$;

revoke all on function public.get_admin_dashboard(int) from public, anon;
grant execute on function public.get_admin_dashboard(int) to authenticated;

commit;
