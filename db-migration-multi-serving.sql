-- ============================================================
-- 마이그레이션: 하루 N번의 섬김 (다중 서빙) — seq 차원 추가
-- Supabase Dashboard > SQL Editor 에 '전체' 붙여넣고 Run.
-- 재실행 안전(idempotent). 기존 데이터 보존(전부 seq=1 = 1번째 섬김).
-- ⚠️ 이 SQL을 먼저 실행한 뒤 새 클라이언트를 배포하세요.
--    (옛 RPC는 하위호환으로 유지 → 실행 후~배포 전에도 라이브 앱이 계속 동작)
-- ============================================================
begin;

-- ── 1) 스키마: seq 컬럼 + PK 교체 + 순차 보장 인덱스 ──────────────
alter table public.sessions add column if not exists seq int not null default 1;
alter table public.orders   add column if not exists seq int not null default 1;

alter table public.sessions drop constraint if exists sessions_pkey;
alter table public.sessions add  constraint sessions_pkey primary key (room_id, date, seq);
alter table public.orders   drop constraint if exists orders_pkey;
alter table public.orders   add  constraint orders_pkey  primary key (room_id, date, seq, member_id);

-- (room, date)당 'open' 섬김은 최대 1개 — 순차(한 번에 하나) 보장을 DB가 강제
create unique index if not exists sessions_one_open on public.sessions(room_id, date) where state = 'open';

-- ── 2) 내부 헬퍼: 활성 섬김 seq (열린 것 우선, 없으면 최신) ────────
create or replace function public._active_seq(p_room text, p_date text)
returns int
language sql stable security definer set search_path = public as $$
  select seq from public.sessions
  where room_id = p_room and date = p_date
  order by (state = 'open') desc, seq desc
  limit 1
$$;
revoke all on function public._active_seq(text,text) from public, anon, authenticated;

-- ── 3) 옛 함수 시그니처 제거 (아리티 변경분) ─────────────────────
drop function if exists public.set_order(text,text,text,text,text,text,text,jsonb,text);
drop function if exists public.remove_order(text,text,text);

-- ── 4) 신규: get_day — 그날 모든 섬김 + 각 주문 ──────────────────
create or replace function public.get_day(p_room text, p_date text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare arr jsonb;
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) then
    raise exception 'no room';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.seq), '[]'::jsonb) into arr
  from (
    select s.seq, s.state, s.host_id, s.cafe_id, s.close_at,
      (select coalesce(jsonb_agg(to_jsonb(o)), '[]'::jsonb)
         from public.orders o
        where o.room_id = s.room_id and o.date = s.date and o.seq = s.seq) as orders
    from public.sessions s
    where s.room_id = p_room and s.date = p_date
  ) x;
  return jsonb_build_object('servings', arr);
end $$;
revoke all on function public.get_day(text,text) from public;
grant execute on function public.get_day(text,text) to anon, authenticated;

-- ── 5) 신규: start_serving — 새 섬김 시작 (seq=max+1, open) ───────
--    이미 열린 섬김이 있으면 부분유니크 위반 → 0 반환(순차 보장)
create or replace function public.start_serving(p_room text, p_date text, p_me text, p_cafe text)
returns int
language plpgsql security definer set search_path = public as $$
declare nseq int;
begin
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_me)
     or not public.is_valid_app_date(p_date)
     or length(coalesce(p_cafe,'')) > 40 then
    raise exception 'bad request';
  end if;
  select coalesce(max(seq),0)+1 into nseq from public.sessions where room_id = p_room and date = p_date;
  insert into public.sessions(room_id, date, seq, state, host_id, cafe_id, updated_at)
    values (p_room, p_date, nseq, 'open', p_me, p_cafe, now());
  return nseq;
exception when unique_violation then
  return 0;  -- 이미 열린 섬김 있음 or seq 경쟁 → 실패
end $$;
revoke all on function public.start_serving(text,text,text,text) from public;
grant execute on function public.start_serving(text,text,text,text) to anon, authenticated;

-- ── 6) 신규: set_serving_state — 특정 섬김 open↔closed ───────────
--    reopen(open) 시 다른 open 있으면 부분유니크 위반(예외) → 클라이언트가 처리
create or replace function public.set_serving_state(p_room text, p_date text, p_seq int, p_state text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room)
     or not public.is_valid_app_date(p_date)
     or p_state not in ('open','closed') then
    raise exception 'bad request';
  end if;
  update public.sessions
     set state = p_state,
         close_at = case when p_state = 'closed' then (extract(epoch from now())*1000)::bigint else null end,
         updated_at = now()
   where room_id = p_room and date = p_date and seq = p_seq;
end $$;
revoke all on function public.set_serving_state(text,text,int,text) from public;
grant execute on function public.set_serving_state(text,text,int,text) to anon, authenticated;

-- ── 7) 신규: unclaim_serving — 섬김 취소 ────────────────────────
--    주문 없으면 섬김 삭제(빈 섬김 정리), 있으면 host만 비워 인계 가능(주문 보존)
create or replace function public.unclaim_serving(p_room text, p_date text, p_seq int)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) then
    raise exception 'bad request';
  end if;
  if not exists (select 1 from public.orders where room_id = p_room and date = p_date and seq = p_seq) then
    delete from public.sessions where room_id = p_room and date = p_date and seq = p_seq;
  else
    update public.sessions set host_id = null, updated_at = now()
     where room_id = p_room and date = p_date and seq = p_seq;
  end if;
end $$;
revoke all on function public.unclaim_serving(text,text,int) from public;
grant execute on function public.unclaim_serving(text,text,int) to anon, authenticated;

-- ── 8) set_order / remove_order: p_seq 추가 (없으면 활성 섬김) ────
create or replace function public.set_order(
  p_room text, p_date text, p_member_id text, p_type text,
  p_menu_id text, p_menu_name text, p_temp text, p_extras jsonb, p_note text,
  p_seq int default null
) returns void
language plpgsql security definer set search_path = public as $$
declare tseq int;
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
     or jsonb_typeof(coalesce(p_extras,'[]'::jsonb)) <> 'array' then
    raise exception 'bad request';
  end if;
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
returns void
language plpgsql security definer set search_path = public as $$
declare tseq int;
begin
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_member_id)
     or not public.is_valid_app_date(p_date) then
    raise exception 'bad request';
  end if;
  tseq := coalesce(p_seq, public._active_seq(p_room, p_date));
  delete from public.orders where room_id = p_room and date = p_date and seq = tseq and member_id = p_member_id;
end $$;
revoke all on function public.remove_order(text,text,text,int) from public;
grant execute on function public.remove_order(text,text,text,int) to anon, authenticated;

-- ── 9) 하위호환: 옛 클라이언트가 부르는 RPC를 '활성 섬김' 대상으로 유지 ──
--    (마이그레이션~새 클라 배포 사이 라이브 앱 무중단)

-- get_room_day: 활성 섬김 1개 + 그 주문 (옛 {session,orders} 형태)
create or replace function public.get_room_day(p_room text, p_date text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sess jsonb; ords jsonb; aseq int;
begin
  if not public.room_exists(p_room) or not public.is_valid_app_date(p_date) then
    raise exception 'no room';
  end if;
  aseq := public._active_seq(p_room, p_date);
  select to_jsonb(s) into sess from public.sessions s
    where s.room_id = p_room and s.date = p_date and s.seq = aseq;
  select coalesce(jsonb_agg(to_jsonb(o)), '[]'::jsonb) into ords from public.orders o
    where o.room_id = p_room and o.date = p_date and o.seq = aseq;
  return jsonb_build_object('session', sess, 'orders', ords);
end $$;
revoke all on function public.get_room_day(text,text) from public;
grant execute on function public.get_room_day(text,text) to anon, authenticated;

-- claim_host: 열린 섬김(host null)이면 인계, 없으면 새 섬김 시작
create or replace function public.claim_host(p_room text, p_date text, p_me text, p_cafe text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare oseq int; n int;
begin
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_me)
     or not public.is_valid_app_date(p_date)
     or length(coalesce(p_cafe,'')) > 40 then
    raise exception 'bad request';
  end if;
  select seq into oseq from public.sessions
    where room_id = p_room and date = p_date and state = 'open'
    order by seq desc limit 1;
  if oseq is not null then
    update public.sessions set host_id = p_me, cafe_id = coalesce(cafe_id, p_cafe), updated_at = now()
      where room_id = p_room and date = p_date and seq = oseq and host_id is null;
    get diagnostics n = row_count;
    return n > 0;             -- 인계 성공 / 이미 호스트 있으면 false
  end if;
  return public.start_serving(p_room, p_date, p_me, p_cafe) > 0;
end $$;
revoke all on function public.claim_host(text,text,text,text) from public;
grant execute on function public.claim_host(text,text,text,text) to anon, authenticated;

-- set_room_state(3-arg): 옛 마감/재개/취소를 활성 섬김에 적용
create or replace function public.set_room_state(p_room text, p_date text, p_state text)
returns void
language plpgsql security definer set search_path = public as $$
declare tseq int;
begin
  if not public.room_exists(p_room)
     or not public.is_valid_app_date(p_date)
     or p_state not in ('idle','open','closed') then
    raise exception 'bad request';
  end if;
  if p_state = 'idle' then
    select seq into tseq from public.sessions
      where room_id = p_room and date = p_date and state = 'open' order by seq desc limit 1;
    if tseq is not null then
      update public.sessions set host_id = null, updated_at = now()
        where room_id = p_room and date = p_date and seq = tseq;
    end if;
  else
    tseq := public._active_seq(p_room, p_date);
    if tseq is not null then
      update public.sessions
         set state = p_state,
             close_at = case when p_state = 'closed' then (extract(epoch from now())*1000)::bigint else null end,
             updated_at = now()
        where room_id = p_room and date = p_date and seq = tseq;
    end if;
  end if;
end $$;
revoke all on function public.set_room_state(text,text,text) from public;
grant execute on function public.set_room_state(text,text,text) to anon, authenticated;

commit;

-- 참고: get_room_history 는 변경 없음(date<today drink 주문 행 집계 → 섬김별로 자연히 카운트).
-- 참고: sessions/orders 는 anon 직접권한 0 + 정의자 RPC 전용이라 RLS 정책 변경 불필요.
