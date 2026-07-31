-- ============================================================
-- 마이그레이션: 직전에 섬긴 사람 조회 (get_last_host)
-- Supabase Dashboard > SQL Editor 에 '전체' 붙여넣고 Run.
-- 재실행 안전(idempotent). 스키마 변경 없음 — 함수 1개만 추가.
-- ⚠️ 배포 순서 제약 없음. 클라이언트는 이 RPC 가 없으면(PGRST202)
--    조용히 '오늘의 SERVINGS' 폴백을 쓰므로, 앞뒤 어느 쪽을 먼저 해도 된다.
-- ============================================================
begin;

-- 옛 정의 먼저 제거: create or replace 는 반환타입/파라미터명 변경을 허용하지 않아
-- 시그니처가 다른 옛 정의가 있으면 트랜잭션 전체가 롤백된다. 안전하게 drop 후 재생성.
drop function if exists public.get_last_host(text,text,int);

-- 직전에 섬긴 사람 1명(host_id). '지금 보고 있는 섬김'을 뺀 (date, seq) 역순 첫 행.
--
-- 왜 날짜를 넘어 보는가: 클라이언트의 SERVINGS 는 '오늘'만 담는다. 모임이 하루 한 번인
-- 셀에서는 오늘 데이터만으로 직전 섬김을 알 수 없어, 이 조회만 서버에 맡긴다.
--
-- 접근 모델은 get_room_history 와 동일하다 — room_exists 검사만 하고, room_id 를
-- 이미 아는 사람에게 text 한 개를 돌려준다. 방 목록을 훑거나 명단을 열거할 통로가 없다.
--
-- is_valid_app_date(p_date) 는 일부러 쓰지 않는다. 그 함수는 '앱이 쓰기를 허용하는
-- 날짜 창'([오늘-2, 오늘+1], Asia/Seoul)을 지키는 장치이고, 여기서 p_date 는 저장할
-- 키가 아니라 비교 상한일 뿐이다. 읽기 전용 상한에 시계 의존 검증을 걸면 자정을 넘긴
-- 탭이나 시계가 틀어진 기기에서 null 대신 예외가 날 뿐 얻는 게 없다. get_room_history
-- 가 p_today 에 같은 검증을 걸지 않는 것과 같은 이유다.
--
-- 정렬은 sessions_pkey(room_id, date, seq) 를 역방향으로 타므로 별도 인덱스가 필요없다.
create or replace function public.get_last_host(p_room text, p_date text, p_seq int)
returns text
language plpgsql stable security definer set search_path = public as $$
declare hid text;
begin
  if not public.room_exists(p_room) then
    raise exception 'no room';
  end if;

  select s.host_id into hid
  from public.sessions s
  where s.room_id = p_room
    and s.host_id is not null                 -- 인계 대기(unclaim 된) 섬김 제외
    and s.state in ('open','closed')          -- idle(옛 단일-섬김 시절의 미확정) 제외
    -- (date, seq) 사전순으로 '현재 섬김보다 앞'인 행만. 미래 날짜(오늘+1)도 함께 빠진다.
    -- p_seq 가 null = 볼 섬김이 없는 상태 → 그 날짜는 통째로 대상에 넣는다(int 상한 sentinel).
    and ( s.date < p_date
       or (s.date = p_date and s.seq < coalesce(p_seq, 2147483647)) )
  order by s.date desc, s.seq desc
  limit 1;

  return hid;                                 -- 이력이 없으면 null (예외 아님)
end $$;
revoke all on function public.get_last_host(text,text,int) from public;
grant execute on function public.get_last_host(text,text,int) to anon, authenticated;

commit;

-- 참고: sessions 는 anon 직접권한 0 + 정의자 RPC 전용이라 RLS 정책 변경이 필요없다.
-- 참고: 반환이 text 한 개뿐이라, 이 RPC 로는 이력 전체나 다른 방의 상태를 볼 수 없다.
