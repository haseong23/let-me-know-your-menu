-- ============================================================
-- 마이그레이션: 관리자 운영 도구 (섬김 정리 · 셀 URL 변경)
-- Supabase Dashboard > SQL Editor 에 '전체' 붙여넣고 Run.
-- 재실행 안전(idempotent). 스키마 변경 없음(정의자 RPC만 추가).
--
--   1) admin_list_servings(p_room)          : 셀의 섬김 목록(날짜/순번/상태/주문수)
--   2) admin_delete_serving(p_room,p_date,p_seq): 특정 섬김 + 그 주문 삭제(실수 데이터 정리)
--   3) admin_rename_cell(p_old,p_new)       : 셀 URL(id/room_id) 변경 + 데이터 전부 이관
--
-- 보안: 모두 authenticated(관리자)에게만 execute. 함수 안에서 auth.role() 재확인.
-- ============================================================
begin;

-- ── 1) 섬김 목록 (관리자) ───────────────────────────────────────
drop function if exists public.admin_list_servings(text);
create or replace function public.admin_list_servings(p_room text)
returns table(dt text, seq int, state text, host_id text, n_orders bigint, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.role() is distinct from 'authenticated' then raise exception 'admin only'; end if;
  return query
    select s.date, s.seq, s.state, s.host_id,
      (select count(*) from public.orders o
        where o.room_id = s.room_id and o.date = s.date and o.seq = s.seq),
      s.updated_at
    from public.sessions s
    where s.room_id = p_room
    order by s.date desc, s.seq desc;
end $$;
revoke all on function public.admin_list_servings(text) from public, anon;
grant execute on function public.admin_list_servings(text) to authenticated;

-- ── 2) 특정 섬김 삭제 (관리자) — 그 섬김의 주문까지 함께 제거 ─────
drop function if exists public.admin_delete_serving(text,text,int);
create or replace function public.admin_delete_serving(p_room text, p_date text, p_seq int)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() is distinct from 'authenticated' then raise exception 'admin only'; end if;
  delete from public.orders   where room_id = p_room and date = p_date and seq = p_seq;
  delete from public.sessions where room_id = p_room and date = p_date and seq = p_seq;
end $$;
revoke all on function public.admin_delete_serving(text,text,int) from public, anon;
grant execute on function public.admin_delete_serving(text,text,int) to authenticated;

-- ── 3) 셀 URL 변경 + 데이터 이관 (관리자) ───────────────────────
--   id == room_id 전제(신규 셀 정책). 새 id 형식 검증 + 미사용 확인 후
--   sessions/orders/member_logs 의 참조를 새 id로 전부 갱신. 함수=단일 트랜잭션(원자적).
drop function if exists public.admin_rename_cell(text,text);
create or replace function public.admin_rename_cell(p_old text, p_new text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() is distinct from 'authenticated' then raise exception 'admin only'; end if;
  if p_new is null or p_new !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then
    raise exception 'invalid new id';
  end if;
  if p_new = p_old then return; end if;
  if not exists (select 1 from public.cells where id = p_old) then
    raise exception 'cell not found';
  end if;
  if exists (select 1 from public.cells where id = p_new or room_id = p_new) then
    raise exception 'id already in use';
  end if;
  -- 자식 데이터 먼저 이관(참조는 room_id/cell_id 텍스트 — FK 없음)
  update public.sessions    set room_id = p_new where room_id = p_old;
  update public.orders      set room_id = p_new where room_id = p_old;
  update public.member_logs set cell_id = p_new where cell_id = p_old;
  -- 셀 자체(id=room_id 동시 변경)
  update public.cells set id = p_new, room_id = p_new where id = p_old;
end $$;
revoke all on function public.admin_rename_cell(text,text) from public, anon;
grant execute on function public.admin_rename_cell(text,text) to authenticated;

commit;
