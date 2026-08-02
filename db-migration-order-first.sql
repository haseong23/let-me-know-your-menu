-- ============================================================================
-- 주문 먼저 받기 (order-first) — open_serving RPC
--
-- 왜 필요한가
--   지금은 섬김이 시작되기 전에는 주문할 방법이 없다. 링크를 연 사람이 처음 보는 화면에서
--   누를 수 있는 것이 [오늘은 제가 살게요] 하나뿐이라, "뭐 마실래?"에 답하러 온 사람에게
--   앱이 먼저 묻는 것이 "누가 살래?"가 된다. 잘못 누르면 되돌리기 어려운 약속이 된다.
--
--   호스트 없는 열린 섬김(host_id IS NULL)은 이 스키마가 '이미' 지원하는 상태다 —
--   unclaim_serving 이 주문이 있을 때 만드는 상태가 정확히 그것이고, claim_host 가
--   그걸 이어받는다. 없던 것은 그 상태를 '처음부터' 만드는 길뿐이다.
--   start_serving 은 room_has_member(p_me) 를 요구해서 p_me := null 로는 못 부른다
--   (그 검사는 아무나 방을 열지 못하게 하는 장치라 없애면 안 된다).
--
-- 그래서 open_serving 은
--   · p_me 로 '요청한 사람이 이 방 구성원인지'는 그대로 검사하고
--   · host_id 에는 null 을 넣는다.
--   즉 권한 검사는 유지한 채 '아직 사는 사람은 정해지지 않았다'만 표현한다.
--
-- 적용
--   Supabase → SQL Editor 에 붙여넣고 실행. 되돌리려면 맨 아래 DROP 두 줄.
--   적용하지 않아도 앱은 그대로 동작한다 — 클라이언트가 PGRST202(함수 없음)를 만나면
--   예전처럼 [오늘은 제가 살게요] 한 갈래만 보여준다.
-- ============================================================================

create or replace function public.open_serving(p_room text, p_date text, p_me text, p_cafe text)
returns int
language plpgsql security definer set search_path = public as $$
declare nseq int;
begin
  -- start_serving 과 같은 검사다. 다른 것은 host_id 에 무엇을 넣느냐뿐이다.
  if not public.room_exists(p_room)
     or not public.room_has_member(p_room, p_me)
     or not public.is_valid_app_date(p_date)
     or length(coalesce(p_cafe,'')) > 40 then
    raise exception 'bad request';
  end if;

  -- 이미 열린 섬김이 있으면 그것을 쓴다. 새로 만들지 않는다 —
  -- '하루에 열린 섬김은 하나'라는 불변식(부분 유니크 인덱스)을 여기서도 지킨다.
  select seq into nseq from public.sessions
    where room_id = p_room and date = p_date and state = 'open' limit 1;
  if nseq is not null then
    -- 카페가 아직 안 정해졌으면 채워 준다(호스트가 나중에 이어받아도 그대로 쓴다)
    update public.sessions set cafe_id = coalesce(cafe_id, p_cafe), updated_at = now()
      where room_id = p_room and date = p_date and seq = nseq;
    return nseq;
  end if;

  select coalesce(max(seq),0)+1 into nseq from public.sessions
    where room_id = p_room and date = p_date;
  insert into public.sessions(room_id, date, seq, state, host_id, cafe_id, updated_at)
    values (p_room, p_date, nseq, 'open', null, p_cafe, now());   -- ← host_id 를 비운 채로 연다
  return nseq;
exception when unique_violation then
  -- 그 찰나에 남이 먼저 열었다 → 그 섬김을 돌려준다(경쟁에서 져도 주문은 갈 곳이 있다)
  select seq into nseq from public.sessions
    where room_id = p_room and date = p_date and state = 'open' limit 1;
  return coalesce(nseq, 0);
end $$;

revoke all on function public.open_serving(text,text,text,text) from public;
grant execute on function public.open_serving(text,text,text,text) to anon, authenticated;

-- 되돌리기
-- drop function if exists public.open_serving(text,text,text,text);
