# Design — 게임으로 섬길 사람 정하기 개선 및 UI 버그 수정

## Overview

`index.html` 하나에 모든 것이 들어 있는 앱이다. 게임 기능은 약 1440~1700행의 함수 묶음과 310~355행의 CSS로 구성된다. 이 설계는 파일을 쪼개지 않고 그 묶음 안에서 상태 모델을 하나로 정리한 뒤, 각 요구사항을 그 모델 위에 얹는다.

핵심 변경은 세 가지다.

1. **흩어진 게임 상태를 `GS` 하나로 모은다.** 지금은 `gameOpen`, `gameOff`, `gameKind`, `gameTimers`, `gameTeardown`이 각자 살아 있고 `gameInit()`이 진입마다 초기화한다. 이 구조 때문에 명단 연동(R3)과 정책 유지(R6-8)를 붙일 자리가 없다.
2. **참가자를 저장하지 않고 파생시킨다.** "기본값 + 사용자가 명시적으로 뒤집은 것"으로 매번 계산한다. 주문이 실시간으로 바뀌어도 사용자의 선택이 살아남는다(R3-5).
3. **게임 오버레이가 자기 히스토리 항목을 직접 소유한다.** 지금은 `subActive` 불리언 하나를 탭·시트·게임이 공유해서 뒤로가기 한 칸이 사라진다(R11).

나머지는 이 세 가지 위에서 국소적으로 해결된다.

---

## 설계 결정

| 결정 | 값 | 근거 |
|---|---|---|
| 사다리타기 인원 상한 | **16명** | `GAP = 292/(n-1)`. n=16이면 19.5px로 2글자 라벨(9px)과 14px 도착 상자가 들어간다. n=18은 17.2px로 무너진다. |
| 돌림판 인원 상한 | **24명** | 조각 각도 `a = 360/n`. n=24면 15°로 회전 보정된 2글자 라벨이 들어간다. |
| 손가락 룰렛 인원 상한 | 없음 | 물리적으로 폰에 올라가는 손가락 수가 스스로 제한한다. 대신 명단이 클 때 안내만 띄운다. |
| 이름 대신 번호를 쓰는 기준 | **11명 이상** | `GAME_COLORS` 10색을 넘는 지점과 라벨이 좁아지는 지점이 같다. 한 기준으로 묶는다. |
| 11명 이상 색 생성 | HSL 골든앵글 `h = i*137.508 % 360`, `s 52%`, `l 34%` | 인접 인덱스의 색상차가 최대가 되어 돌림판 인접 조각 문제(R9-2)가 자동으로 풀린다. `l 34%`는 기존 팔레트 명도대와 같아 흰 구분선·`#e7ddcf` 배경 위에서 식별된다. |
| 확률 낮추기 가중치 | `1/3` | 요구사항 확정값. 상수 `GS_SOFT_W`로 한 곳에 둔다. |
| 새 RPC | `get_last_host(p_room text, p_date text, p_seq int) returns text` | `get_room_history`와 같은 접근 모델(`room_exists` 검사 + `security definer` + anon 실행 허용). |
| 마이그레이션 파일 | `db-migration-last-host.sql` | 기존 `db-migration-*.sql` 명명 규칙을 따른다. `db-setup.sql`은 건드리지 않는다. |
| 테스트 방식 | `tests/game-logic.test.mjs` (Node 내장 `node:test` + `node:vm`) | 리포지토리에 `package.json`도 테스트 러너도 없다. 순수 로직을 index.html에서 분리하지 않고, 마커 주석 사이 블록을 읽어 샌드박스에서 평가한다. 의존성 0, 빌드 0, 프로덕션 코드에 테스트 훅을 남기지 않는다. |

---

## 1. 게임 세션 상태 — `GS`

기존 전역을 하나로 모은다.

```js
// 게임 상태는 '보고 있는 섬김' 하나에 매인다. 섬김이 바뀌면 통째로 버린다.
let GS = null;
// {
//   seq:        number|null   이 상태가 속한 섬김
//   on:         Set<memberId> 사용자가 명시적으로 '참가'로 켠 사람
//   off:        Set<memberId> 사용자가 명시적으로 '제외'로 끈 사람
//   kind:       "ladder"|"wheel"|"finger"|null
//   policy:     "soft"|"skip"|"even"     직전 섬긴 사람 확률 정책
//   lastHostId: string|null|undefined    undefined = 아직 조회 안 됨
//   open:       boolean       오버레이가 떠 있는지 (기존 gameOpen)
//   pushed:     boolean       오버레이가 히스토리 1칸을 쥐고 있는지
//   opener:     Element|null  오버레이를 연 버튼 (포커스 복귀용)
//   timers:     number[]      기존 gameTimers
//   teardown:   fn|null       기존 gameTeardown
// }

function gameEnsure(opener){
  const seq = SESSION.seq ?? null;
  if(!GS || GS.seq !== seq){          // 섬김이 바뀌면 기본값으로 리셋 (R3-4)
    GS = { seq, on:new Set(), off:new Set(), kind:null,
           policy:"soft", lastHostId:undefined,
           open:false, pushed:false, opener:null, timers:[], teardown:null };
  }
  GS.opener = opener || null;
}
```

`gameInit()`은 삭제한다. 진입점 핸들러가 `gameInit()` 대신 `gameEnsure(this)`를 부르므로, 같은 섬김에서 게임을 닫고 다시 열면 명단과 정책이 그대로 살아 있다(R3-3, R6-8).

`SESSION.seq`가 `null`인 경우(호스트 없는 섬김에서 하단바로 진입)도 `seq:null`로 일관되게 다룬다.

---

## 2. 참가자 파생 규칙

명단을 저장하지 않고 매번 계산한다. 이렇게 하면 실시간 주문 변경과 사용자 선택이 충돌하지 않는다.

```js
// 기본 참가 = 음료를 주문한 사람 (R2-1)
function gameDefaultOn(m){ const o=ORDERS[m.id]; return !!(o && o.type==="drink"); }
function gameIsSkip(m){    const o=ORDERS[m.id]; return !!(o && o.type==="skip"); }

// 명단: 화면에 '참가자 N명'으로 보이는 집합
function gameRoster(){
  return MEMBERS.filter(m=>{
    if(gameIsSkip(m)) return false;        // 안 마심 = 되돌릴 수 없는 제외 (R2-5)
    if(GS.off.has(m.id)) return false;      // 사용자가 끔 (R3-5)
    if(GS.on.has(m.id))  return true;       // 사용자가 켬 (R3-5)
    return gameDefaultOn(m);                // 그 외는 기본값
  });
}

// 추첨 대상: 명단에 정책을 얹은 것
function gamePlayers(){
  const r = gameRoster();
  if(GS.policy==="skip" && GS.lastHostId) return r.filter(m=>m.id!==GS.lastHostId);
  return r;
}

function gameEligible(){ return gamePlayers().length >= 2; }
```

`gameRoster()`가 아니라 **`gamePlayers()`**가 참가자 수 표기와 게임 가능 판정의 단일 출처다(R6-6, R2-8, R3-6, R16-3). 진입점의 `canGame`도 `gameEligible()`을 그대로 쓴다.

토글 조작은 두 Set을 갱신한다.

```js
function gameToggle(id, on){
  if(on){ GS.on.add(id);  GS.off.delete(id); }
  else  { GS.off.add(id); GS.on.delete(id);  }
}
// 전원 참가 (R2-10): 안 마시는 사람 외 전원을 명시적 on 으로
function gameAllOn(){ GS.off.clear(); GS.on = new Set(MEMBERS.filter(m=>!gameIsSkip(m)).map(m=>m.id)); }
// 오늘 섬긴 분 빼기 (R2-9): 수동 동작으로만 남는다
function gameDropServed(){ gameServedIds().forEach(id=>gameToggle(id,false)); }
```

`gameServedIds()`는 그대로 두되, `gameEnsure`에서 더 이상 호출하지 않는다. 이것이 "오늘 섬긴 분 전원 자동 제외" 제거다(R2).

---

## 3. 확률 정책과 가중 추첨

```js
const GS_SOFT_W = 1/3;   // 확률 낮추기 강도 (R6-4)

// 난수를 인자로 받아 테스트에서 결정론적으로 만들 수 있게 한다 (R6-15)
function gameWeights(players){
  return players.map(m =>
    (GS.policy==="soft" && GS.lastHostId && m.id===GS.lastHostId) ? GS_SOFT_W : 1);
}
function pickWeighted(players, w, rnd){
  const total = w.reduce((a,b)=>a+b, 0);
  let r = (rnd||Math.random)() * total;
  for(let i=0;i<players.length;i++){ r -= w[i]; if(r < 0) return players[i]; }
  return players[players.length-1];        // 부동소수 잔차 방어
}
function gamePickWinner(players){ return pickWeighted(players, gameWeights(players)); }
```

정책별 동작:

| 정책 | 명단 | 가중치 | 손가락 룰렛 |
|---|---|---|---|
| `soft` (기본) | 그대로 | 직전 섬긴 사람만 `1/3` | 적용 불가 → `even`처럼 동작 + 안내 표시 (R6-10, R6-11) |
| `skip` | 직전 섬긴 사람 제외 | 전원 `1` | 명단에서 빠지므로 그대로 적용됨 |
| `even` | 그대로 | 전원 `1` | 그대로 |

`soft`는 가중치가 `1/3`이므로 확률이 0이 되지 않는다(R6-5). 직전 섬긴 사람이 없거나(`lastHostId` null) 사용자가 이미 끈 상태면 `gameWeights`가 전원 `1`을 돌려주므로 정책이 결과에 영향을 주지 않는다(R6-12, R6-13).

`startGame`은 `gamePlayers()`가 2명 미만이면 시작하지 않고 사유를 알린다(R6-14).

손가락 룰렛만 예외인 이유는 당첨 대상이 화면에 올라온 물리적 포인터이고, 그게 누구인지는 사후에 사람이 지목하기 때문이다. 가중치를 걸 지점이 없다.

---

## 4. 직전 섬긴 사람 조회

### 4.1 새 RPC — `db-migration-last-host.sql`

`sessions`의 PK는 `(room_id, date, seq)`이고 `host_id`, `state`를 갖는다. 현재 섬김을 빼고 `(date, seq)` 역순 첫 행의 호스트를 돌려준다.

```sql
begin;

drop function if exists public.get_last_host(text,text,int);

-- 직전에 섬긴 사람 1명. 날짜를 넘어 조회하되 '지금 진행 중인 섬김'은 뺀다.
-- 접근 모델은 get_room_history 와 동일: room_id 를 아는 사람만, 열거 불가, 정의자 권한.
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
    and s.host_id is not null                 -- 인계 대기 섬김 제외 (R5-3)
    and s.state in ('open','closed')          -- idle/취소 제외 (R5-3)
    and ( s.date < p_date
       or (s.date = p_date and s.seq < coalesce(p_seq, 2147483647)) )   -- 현재 섬김 제외 (R5-1)
  order by s.date desc, s.seq desc
  limit 1;

  return hid;
end $$;

revoke all on function public.get_last_host(text,text,int) from public;
grant execute on function public.get_last_host(text,text,int) to anon, authenticated;

commit;
```

`is_valid_app_date`는 쓰지 않는다. 그 함수는 ±2일로 범위를 좁히는데 여기서는 과거 전체를 봐야 하고, `p_date`는 비교 상한으로만 쓰인다. `get_room_history`도 `room_exists`만 검사한다.

반환값은 `host_id` 하나뿐이므로 이 RPC로 다른 방을 훑거나 명단을 열거할 수 없다(R5-4).

### 4.2 프론트엔드 조회

```js
// (room, date, seq) 조합당 한 번만 조회. 게임 시트를 여러 번 열어도 재조회하지 않는다.
let LAST_HOST = { key:null, id:null };

function lastHostFromToday(){          // 폴백: 오늘의 SERVINGS 안에서 (R5-6, R5-9)
  const cur = SESSION.seq ?? Infinity;
  const past = SERVINGS.filter(s=>s.hostId && s.seq < cur).sort((a,b)=>b.seq-a.seq);
  return past.length ? past[0].hostId : null;
}

async function fetchLastHost(){
  const key = ROOM+"|"+todayKey()+"|"+(SESSION.seq ?? 0);
  if(LAST_HOST.key===key) return LAST_HOST.id;
  let id = lastHostFromToday();
  if(SHARED){
    try{
      const { data, error } = await Sync.client.rpc("get_last_host",
        { p_room:ROOM, p_date:todayKey(), p_seq:SESSION.seq ?? null });
      // RPC 미배포(PGRST202)·오프라인·기타 오류는 조용히 폴백값을 쓴다 (R5-6, R5-8)
      if(!error && typeof data === "string" && data) id = data;
    }catch(e){}
  }
  if(id && !memberById(id)) id = null;   // 명단에서 사라진 사람은 없는 것으로 (R5-7)
  LAST_HOST = { key, id };
  return id;
}
```

`rpcSetMembers`가 구버전 DB에서 인자 수를 줄여 재시도하는 것과 같은 정신이다. 여기서는 재시도할 대체 시그니처가 없으므로 폴백값을 그대로 쓴다. 마이그레이션 적용 전에도 앱이 정상 동작하므로 배포 순서에 제약이 없다.

**지연 없이 표시하기(R5-10):** `openGameSheet()`는 조회를 기다리지 않고 즉시 그린다. 정책 블록은 자리만 비워두고, `fetchLastHost()`가 끝난 뒤 그 블록만 교체한다.

```js
function openGameSheet(){
  drawGameSheet();                                  // lastHostId 가 undefined 면 정책 블록 없이 그림
  if(GS.lastHostId === undefined){
    fetchLastHost().then(id=>{
      GS.lastHostId = id;
      if(sheetOpen) syncPolicyBlock();              // 시트 전체가 아니라 그 블록만 (R7-6)
    });
  }
}
```

시트가 이미 닫혔으면 아무것도 하지 않는다. `GS.lastHostId`는 `undefined`(미조회) / `null`(없음) / `string`(있음) 세 상태를 구분한다.

---

## 5. 색 배정 · 인원 상한 · 범례

```js
const GAME_COLORS = [ /* 기존 10색 유지 */ ];

// 10명 이하는 지금 보이는 색 그대로. 11명 이상은 골든앵글로 생성해
// 인접 인덱스끼리 색상차를 최대로 벌린다 (R9-1~R9-3)
function gcolor(i, n){
  if(n <= GAME_COLORS.length) return GAME_COLORS[i];
  return "hsl(" + ((i*137.508) % 360).toFixed(1) + " 52% 34%)";
}

const GAME_LABEL_MAX = 10;                             // 이보다 많으면 이름 대신 번호 + 범례
const GAME_MAX = { ladder:16, wheel:24, finger:Infinity, race:24 };
function gameFits(kind, n){ return n <= GAME_MAX[kind]; }
```

`gcolor`의 시그니처에 `n`이 추가된다. 호출부는 `playLadder`, `playWheel`, `playFinger` 세 곳이다. `playFinger`의 `gcolor(seq++)`는 손가락 순번이라 참가자 수와 무관하므로 `gcolor(seq++, Infinity)`가 아니라 별도 처리한다 — 손가락은 최대 10개를 넘기 어려우므로 `GAME_COLORS`를 그대로 순환시킨다.

**범례(R9-5, R10-1, R10-2):** 참가자가 11명 이상이면 사다리 상단 라벨과 돌림판 조각 라벨에 **번호만** 넣고, SVG 아래에 번호–색–이름 목록을 붙인다.

```
[1]■ 김요셉  [2]■ 이다니엘  [3]■ 박사무엘 …
```

이 하나로 세 가지가 동시에 해결된다. 이름 겹침이 사라지고, 색이 비슷해 보여도 번호로 구분되며, 잘린 이름을 범례에서 온전히 읽을 수 있다. 범례는 `.game-body` 안 SVG 다음에 놓여 함께 스크롤된다.

**상한 초과 처리(R10-4):** `openGameSheet`의 게임 선택 버튼을 `disabled`로 만들고 사유를 붙인다.

```
🪜 사다리타기   [16명까지 — 지금 20명이라 화면에 안 들어가요]
🎡 돌림판       [24명까지]
☝️ 손가락 룰렛  ← 남는 선택지
```

전부 막히는 경우는 없다. 손가락 룰렛은 상한이 없다.

---

## 6. 화면별 설계

### 6.1 게임 고르기 시트 — `openGameSheet` / `drawGameSheet`

블록 순서:

1. 제목 + "확정 전에는 아무것도 바뀌지 않아요" 안내 (현재 유지)
2. **참가자 카드** — `참가자 N명` (`gamePlayers().length`), 이름 나열, `바꾸기` 버튼, 그리고 기준 안내 한 줄: "메뉴를 고른 분이 기본으로 들어가 있어요" (R2-6)
3. **정책 카드** — `GS.lastHostId`가 있을 때만. `직전에 섬긴 분: 김요셉님` + 3택 칩 (R6-1, R6-2)
4. **게임 고르기** — 3개 버튼, 상한 초과 시 `disabled` + 사유
5. 닫기

`gamePlayers()`가 2명 미만이면 4번 대신 사유 배너를 띄우고 `바꾸기`로 유도한다(R2-7).

정책 칩은 `.chips`/`.chip.sel` 기존 패턴을 쓴다. 클릭 시 `GS.policy`를 바꾸고 정책 카드와 참가자 카드만 부분 갱신한다(`skip`은 참가자 수를 바꾸므로). 시트를 다시 그리지 않으므로 스크롤이 유지된다(R7-6).

### 6.2 참가자 고르기 시트 — `openRosterSheet`

**현재 구조의 문제:** `draw()`가 토글마다 `openSheet()`를 재호출한다. `openSheet`는 `innerHTML` 교체 + `scrollTop=0` + `pushSub()`를 하므로 스크롤·포커스가 날아간다.

**바뀔 구조:** `openSheet()`는 **한 번만** 부른다.

```js
function openRosterSheet(){
  openSheet(rosterSheetHtml());        // 최초 1회
  const list = document.getElementById("gRosterList");

  // 이벤트 위임 — 행을 다시 그려도 재배선이 필요 없다
  list.addEventListener("click", e=>{
    const sw = e.target.closest(".gsw"); if(!sw) return;
    const id = sw.dataset.id;
    gameToggle(id, sw.getAttribute("aria-checked") !== "true");
    syncRosterRow(id);                 // 그 행만
    syncRosterCount();                 // 상단 카운트만
    sw.focus();                        // 포커스 유지 (R7-2)
  });

  bind("gAll",    ()=>{ gameAllOn();      syncRosterAll(); });
  bind("gServed", ()=>{ gameDropServed(); syncRosterAll(); });
  bind("gDone",   backToGameSheet);
}
```

`syncRosterRow(id)`는 해당 행의 스위치 `aria-checked`, 클래스, 부제 텍스트, 아바타 상태만 고친다. `syncRosterAll()`은 모든 행에 같은 일을 하되 컨테이너를 재생성하지 않으므로 `scrollTop`이 유지된다(R7-1, R7-4).

`gDone`은 `openGameSheet()`를 직접 부르지 않고 `backToGameSheet()`를 쓴다 — 게임 고르기 시트로 돌아갈 때 `openSheet`가 또 불려 히스토리가 늘어나는 것을 막는다(R11-7). `openSheet`의 `pushSub()`는 `subActive`가 이미 true면 no-op이므로 실제로 항목이 늘지는 않지만, 의도를 코드에 남긴다.

**행 구성:**

| 상태 | 스위치 | 부제 |
|---|---|---|
| 음료 주문함 | 켜짐 | `주문 완료` |
| 주문 전 | 꺼짐 | `아직 주문 전 — 넣으려면 켜주세요` (R2-4) |
| 안 마심 | 없음 (`안마심` 배지) | `오늘은 안 마셔요 — 후보에서 빠짐` (R2-5) |
| 오늘 섬김 | 기본값 따름 | `오늘 이미 섬기셨어요` |
| 직전 섬김 | 기본값 따름 | `직전에 섬기신 분` |

### 6.3 토글 스위치 — `.gsw`

```css
/* 휴대폰 설정 앱의 스위치. 시각 높이는 32px 이지만 위아래 padding 으로
   탭 영역을 44px 로 넓힌다(음수 margin 으로 레이아웃 높이는 그대로).
   height 는 44px 이어야 한다 — 이 파일은 전역으로 `* { box-sizing:border-box }` 를
   쓰므로 height:32px + padding:6px 0 은 콘텐츠 박스를 20px 로 만들어 32px 트랙이
   넘친다. 44-12=32 로 콘텐츠 박스가 트랙과 정확히 같아지고, 음수 margin 이
   흐름상 높이를 다시 32px 로 되돌린다. */
.gsw { position:relative; flex:none; width:52px; height:44px; padding:6px 0; margin:-6px 0 -6px auto;
       background:none; border:0; cursor:pointer; -webkit-tap-highlight-color:transparent; }
.gsw-track { display:block; width:52px; height:32px; border-radius:16px;
             background:var(--gray); transition:background .18s ease; }
.gsw-knob  { position:absolute; left:3px; top:9px; width:26px; height:26px; border-radius:50%;
             background:#fff; box-shadow:0 1px 3px rgba(40,28,16,.35);
             transition:transform .18s ease; }
.gsw[aria-checked="true"] .gsw-track { background:var(--green); }
.gsw[aria-checked="true"] .gsw-knob  { transform:translateX(20px); }
.gsw:focus-visible .gsw-track { outline:2px solid var(--brand); outline-offset:2px; }
@media (prefers-reduced-motion: reduce){
  .gsw-track, .gsw-knob { transition:none; }
}
```

마크업은 `<button class="gsw" role="switch" aria-checked aria-labelledby="...">`이다. `<button>`이므로 Space/Enter가 기본 동작으로 들어오고 포커스도 공짜로 얻는다(R1-6). `aria-labelledby`는 같은 행의 이름 노드를 가리켜 "김요셉, 스위치, 켜짐"으로 읽힌다(R1-5).

켜짐/꺼짐은 트랙 색(`--green` ↔ `--gray`)과 손잡이 위치 두 가지로 구분된다(R1-3). 아바타 배경을 `--sub`로 바꾸던 기존 처방은 **삭제한다** — 스위치가 상태를 말하므로 아바타는 늘 `--brand`로 두고, 제외된 행은 이름·부제를 흐리게 한다.

**흐리게 하는 방법이 대비를 결정한다(R1-9).** 팔레트 색을 그대로 `opacity:.55`로 깔면 흰 카드(#fff) 위에서 이름(`--ink`)이 3.65:1, 부제(`--sub`)가 2.33:1 로 AA 4.5:1 을 못 넘긴다. `--sub`는 흰 카드 대비가 원래 5.92:1 이라 어떤 opacity 값으로도(최대 .88) 기준을 못 지킨다 — 즉 `--sub` 대비 문제는 이 방식에서도 발생한다. 그래서 색까지 함께 바꾼다: `color:#000; opacity:.55`는 합성 결과가 `#737373` 이고 흰 카드 대비 4.76:1 로 기준을 넘는다.

```css
.person.gs-off .pname, .person.gs-off .pmenu { color:#000; opacity:.55; }
```

### 6.4 사다리타기 — `playLadder`

```js
function playLadder(players, winner){ ... }
```

바뀌는 부분만:

- **☕를 처음부터 그린다.** `goal = paths[wi].end`는 이미 계산된다. 도착 상자 생성 시 `i===goal`이면 `☕` + 강조 배경(`#fbe9e3`/`#c2552f`), 아니면 `·` + 중립 배경(`#f6f1ea`)으로 **정적 마크업에 박는다** (R4-1, R4-2, R4-8).
- **`openBox`와 계단식 공개를 삭제한다.** 선 그리기가 끝나면 바로 `showGameResult(winner)`를 부른다 (R4-5).

```js
gtimer(()=>showGameResult(winner), DUR + 120);
```

- **기호 크기를 상자에 맞춘다.** `font-size = Math.min(14, BOX_W*0.62)` (R4-7, R10-3).
- **라벨을 번호로 바꾼다.** `n > GAME_LABEL_MAX`면 상단 라벨에 `i+1`을 넣고 범례를 붙인다. 10명 이하는 현재의 `shortName`/`NCH`/`NFS` 로직을 그대로 쓴다.
- 선이 그려지는 애니메이션(`stroke-dashoffset` + 강제 리플로우)은 **그대로 둔다**. 이미 옳고 TC63이 지키고 있다(R4-3).
- 사다리 재생성 루프(`t<60`, `total>=n`, 제자리 방지)도 그대로 둔다(R4-6).

☕가 미리 보여도 긴장이 유지되는 이유는 선이 2.4초 동안 위에서 아래로 그려지기 때문이다. "누가 저 칸에 닿을까"가 사다리타기의 원래 재미다.

### 6.5 돌림판 — `playWheel`

- **애니메이션 시작을 사다리와 같은 방식으로 맞춘다.** 현재는 `requestAnimationFrame` 한 번 뒤에 `transform`을 바꾼다. 같은 파일의 사다리에는 "rAF 한 번으로는 부족하다"는 주석과 강제 리플로우가 있다. 두 곳의 처방을 통일한다 (R14-1).

```js
rot.style.transition = "none";
rot.style.transform  = "rotate(0deg)";
void $gv().offsetHeight;                      // 시작값 커밋
if(slow) rot.style.transition = "transform 4.2s cubic-bezier(.16,.72,.14,1)";
rot.style.transform = "rotate(" + spin.toFixed(2) + "deg)";
```

리플로우 한 번은 비용이 무의미하고, 실기기 확인 결과 문제가 없더라도 이 변경은 무해하며 두 게임의 처방이 갈라진 상태를 없앤다. R14-6의 "재현되지 않으면 코드 변경 없음" 조항은 **이 통일 작업에는 적용하지 않는다** — 재현 여부와 무관하게 일관성 자체가 값이다. 대신 TC를 추가해 회귀를 잡는다.

- 라벨 역회전(`rotate(-spin)`)은 그대로 둔다. 멈춘 순간 이름이 똑바로 선다(R14-4).
- `n > GAME_LABEL_MAX`면 조각 라벨을 번호로 바꾸고 범례를 붙인다.
- `aria-label`을 결과 표시 시점에 "돌림판 결과: OOO님"으로 갱신한다(R13-6).

### 6.6 손가락 룰렛 — `playFinger`

**인라인 스타일 복원(R8):** 건 값을 기억했다가 teardown에서 되돌린다.

```js
const prev = { touchAction: body.style.touchAction, overflowY: body.style.overflowY };
body.style.touchAction = "none";
body.style.overflowY   = "hidden";
// …
function restoreBody(){ body.style.touchAction = prev.touchAction; body.style.overflowY = prev.overflowY; }
```

`restoreBody()`는 `teardown()` 안에서 부른다. `teardown`은 이름 칩 선택 시(결과로 넘어갈 때), `그만두기`·✕·뒤로가기로 닫을 때 모두 불리므로 R8-1과 R8-3이 한 지점에서 해결된다. 진행 중에는 그대로 걸려 있어 좌표가 어긋나지 않는다(R8-4). `openGameOv`가 `innerHTML`을 갈아치우면 `gvBody`가 새로 만들어지므로 `한 판 더`에도 잔재가 없다(R8-5).

**경계 이탈(R15-1):** `pointerleave`를 `onUp`에서 떼어낸다. 대신 `onMove`에서 좌표를 본문 안으로 클램프해 손가락이 가장자리를 넘어도 점이 붙어 있게 한다.

```js
const at = e=>{ const r=body.getBoundingClientRect();
  return [ Math.max(0, Math.min(r.width,  e.clientX-r.left)),
           Math.max(0, Math.min(r.height, e.clientY-r.top)) ]; };
```

`pointerup`·`pointercancel`만 점을 제거한다(R15-2). 실제로 손가락을 뗄 때만 사라지므로 카운트다운이 헛돌지 않는다.

**안정화 대기(R15-3, R15-4):** 손가락 수가 바뀌면 즉시 3부터 세지 않고 `SETTLE = 900ms` 동안 변화가 없기를 기다린다.

```js
function refresh(){
  if(picked) return;
  stop();                                     // 카운트다운·안정화 타이머 모두 취소
  if(pts.size < 2){ mid.innerHTML = hint("손가락 "+pts.size+"개 — 두 개 이상 올려주세요"); return; }
  mid.innerHTML = hint("손가락 "+pts.size+"개 — 다 올리셨으면 곧 시작해요");
  settleT = setTimeout(startCountdown, SETTLE);
}
```

화면 문구가 "곧 시작"과 "3·2·1"로 갈려 규칙이 드러난다. 손가락이 추가되면 안정화가 다시 시작되므로 세 번째 사람이 올릴 시간이 생긴다.

**이름 칩(R3-7):** `choose()`가 만드는 칩은 `gamePlayers()`를 쓴다. 시작 시점에 잡아둔 배열이 아니라 호출 시점의 명단이다.

**정책 안내(R6-11):** `GS.policy==="soft"`이고 `GS.lastHostId`가 있으면 시작 화면에 한 줄 띄운다: "이 게임은 확률 조정이 적용되지 않아요".

`picked`가 true인 뒤의 포인터 입력은 이미 `onDown`/`onMove`/`onUp` 앞머리에서 무시된다(R15-5, 현재 동작 유지).

### 6.7 결과와 확정 — `showGameResult` / `commitGameWinner`

**확정 버튼(R18):**

```js
// 긴 이름이 버튼을 넘지 않게 — 이름은 위 결과 블록에 이미 크게 나와 있다
const okLabel = same ? "확인" : "✅ 이분으로 확정하기";
```

라벨에서 이름을 뺀다. 당첨자 이름은 바로 위 `.game-win .wn`에 25px로 크게 표시되므로 버튼에서 반복할 필요가 없고, 이름 길이에 따른 넘침(R18-3)과 조사 문제(R18-4)가 동시에 사라진다.

처리 중에는 버튼을 잠근다.

```js
bind("gvOk", async ()=>{
  const b = document.getElementById("gvOk");
  if(b){ b.disabled = true; b.textContent = "확정하는 중…"; }
  try{ ... } finally { if(b && document.body.contains(b)){ b.disabled=false; b.textContent=okLabel; } }
});
```

`guardWrite`의 재진입 차단은 그대로 두고, 그 위에 시각 상태를 얹는다(R18-1, R18-2).

**당첨자가 나일 때(R12):** `setOpenTab`을 거치지 않는다. 그 함수는 `openTab===t`면 즉시 return하고, 다른 탭이면 `history.back()`이라는 부수효과를 낸다. 둘 다 여기서는 곤란하다.

```js
closeGame();               // 게임이 쥔 히스토리 항목 소비
if(ok && w.id===ME){
  clearSubEntry();         // 탭·시트가 남긴 항목까지 정리 (7.3)
  forceGrid = true;
  openTab   = "order";     // 직접 대입 — setOpenTab 의 부수효과를 피한다
}
render();                  // render 는 이 뒤에 한 번만
```

`render()` 호출을 분기 **뒤로** 옮기는 것이 핵심 수정이다. 지금은 `render()`가 먼저 불려서 `forceGrid`가 반영될 기회가 없다. 실패 시에는 `forceGrid`를 세우지 않는다(R12-5). 당첨자가 내가 아니면 `openTab`을 건드리지 않으므로 게임을 연 탭에 머문다(R12-4). 히스토리 정리는 7.3 을 따른다 — 탭 항목은 `내 주문` 탭으로 넘어갈 때만 소비하므로, 당첨자가 내가 아닐 때는 `현황` 탭의 뒤로가기가 그대로 살아 있다.

---

## 7. 히스토리와 뒤로가기

### 7.1 현재 모델과 결함

`subActive`는 불리언 하나다. `pushSub()`는 이미 true면 아무것도 하지 않는다. 탭·시트·게임이 이 한 칸을 공유한다.

```
현황 탭 진입   → pushSub()  → 항목 1개, subActive=true
게임 시트 열기 → pushSub()  → no-op   (항목 그대로 1개)
게임 오버레이  → pushSub()  → no-op   (항목 그대로 1개)
뒤로가기 1회   → subActive=false, closeGame()
                 → 현황 탭인데 남은 항목 0개
뒤로가기 2회   → 앱 밖으로 나간다  ✗ '내 주문' 탭으로 가야 한다
```

### 7.2 바뀔 모델 — 게임이 자기 항목을 소유한다

`pushSub`/`subActive`의 공유 구조는 그대로 두고, **게임 오버레이만** `subActive`와 무관하게 자기 항목을 하나 push한다. 블라스트 반경을 게임 안으로 묶는 선택이다.

```js
function openGameOv(title, bodyHtml){
  // …innerHTML, classList.add("show")…
  if(!GS.open){
    GS.open = true;
    GS.pushed = true;
    try{ history.pushState({ sub:1, game:1 }, ""); }catch(e){ GS.pushed = false; }
  }
}

function closeGame(opts){
  const fromPop = !!(opts && opts.fromPop);
  clearGameTimers();
  if(GS.teardown){ try{ GS.teardown(); }catch(e){} GS.teardown = null; }
  const el = $gv(); el.classList.remove("show"); el.innerHTML = "";
  GS.open = false;
  gameA11yOff();                                  // aria-hidden 해제 + 포커스 복귀
  if(!fromPop && GS.pushed){ ignorePop++; try{ history.back(); }catch(e){ ignorePop--; } }
  GS.pushed = false;
}
```

popstate에서는 `subActive`를 건드리기 **전에** 게임을 처리한다.

```js
window.addEventListener("popstate", ()=>{
  if(ignorePop > 0){ ignorePop--; return; }
  if(confirmOpen){ /* 현재 로직 유지 */ return; }
  if(GS && GS.open){ closeGame({ fromPop:true }); return; }   // subActive 를 소비하지 않는다
  subActive = false;
  if(sheetOpen){ ... }
  if(openTab !== "order"){ ... }
  // 이하 현재 로직 유지
});
```

`ignorePop`을 **불리언에서 카운터로** 바꾼다. 호출 지점은 3곳뿐이다.

- 선언: `let ignorePop = false;` → `let ignorePop = 0;`
- `finishConfirm`: `ignorePop = true;` → `ignorePop++;`, 실패 시 `ignorePop--`
- popstate 진입부: 위와 같이

확정 직후처럼 히스토리 항목을 두 칸 정리해야 하는 경우가 있어 불리언으로는 부족하다.

### 7.3 검증 표

| 시나리오 | 항목 수 | 뒤로가기 1회 | 뒤로가기 2회 | 요구사항 |
|---|---|---|---|---|
| 현황 탭 → 게임 | 탭 1 + 게임 1 = 2 | 게임만 닫힘, 현황 탭 유지 | 내 주문 탭 | R11-1, R11-2 |
| 내 주문 탭 → 게임 | 시트 1 + 게임 1 = 2 | 게임만 닫힘, 내 주문 탭 | 화면 변화 없음 (시트가 남긴 항목을 소비) → 3회에 앱 밖 | R11-3 |
| 게임 시트 → 게임 실행 → 뒤로 | 2 | 게임 닫힘 (시트는 `closeSheet`로 이미 닫힘) | 원래 탭 | R11-4 |
| ✕ 또는 그만두기 | 2 → 1 | 게임을 안 열었을 때와 동일 | — | R11-5 |
| 참가자 고르기 → 완료 | 늘지 않음 | — | — | R11-7 |

두 번째 줄의 뒤로가기 2회가 아무 일도 하지 않는 이유는 `closeSheet()`가 자기 히스토리 항목을 소비하지 않고 `subActive`를 true로 남기기 때문이다(`index.html`의 `closeSheet` 줄에 "history 항목은 다음 뒤로가기/열기가 소비·재사용"으로 적혀 있는 기존 모델이며, 게임이 더는 그 항목을 오버레이 대신 소비하지 않게 되면서 눈에 보이게 된 것이다). R11의 수용 기준은 그대로 통과한다 — 사용자가 갇히지 않고, 한 번의 뒤로가기가 아무것도 바꾸지 않는 무동작(no-op)일 뿐이다.

**확정 후 전환(R11-6):** `commitGameWinner`는 `closeGame()`으로 게임 항목을 소비하고, 탭 항목이 남아 있으면 그것까지 정리한 뒤 `openTab`을 직접 대입한다.

```js
function clearSubEntry(){
  if(subActive){ subActive = false; ignorePop++; try{ history.back(); }catch(e){ ignorePop--; } }
}
```

두 번의 `history.back()`이 연달아 일어나므로 `ignorePop`이 2까지 오른다. 카운터로 바꾼 이유가 이것이다. 정리가 끝난 뒤 `render()`를 한 번 부르므로 뒤로가기가 게임 화면을 다시 열 일이 없다.

---

## 8. 접근성

```js
let gameA11yPrev = null;

function gameA11yOn(){
  GS.opener = GS.opener || document.activeElement;
  gameA11yPrev = [ document.getElementById("app"), document.getElementById("bottom") ];
  gameA11yPrev.forEach(el=>{ if(el) el.setAttribute("aria-hidden","true"); });
  const first = $gv().querySelector("#gvX");
  if(first) first.focus();
  $gv().addEventListener("keydown", gameTrap);
}
function gameA11yOff(){
  $gv().removeEventListener("keydown", gameTrap);
  (gameA11yPrev||[]).forEach(el=>{ if(el) el.removeAttribute("aria-hidden"); });
  gameA11yPrev = null;
  if(GS.opener && document.body.contains(GS.opener)) GS.opener.focus();
  GS.opener = null;
}
// Tab 순환을 오버레이 안에 묶는다
function gameTrap(e){
  if(e.key !== "Tab") return;
  const f = [...$gv().querySelectorAll('button:not([disabled]), [tabindex="0"]')]
              .filter(el=>el.offsetParent !== null);
  if(!f.length) return;
  const first = f[0], last = f[f.length-1];
  if(e.shiftKey && document.activeElement === first){ e.preventDefault(); last.focus(); }
  else if(!e.shiftKey && document.activeElement === last){ e.preventDefault(); first.focus(); }
}
```

`aria-hidden`은 오버레이 밖의 두 컨테이너에만 건다. `#gameOv`는 형제 노드이므로 자신은 영향받지 않는다(R13-1~R13-3).

- `#gvSay`에 `aria-live="polite"`, 결과 블록에 `role="status"`를 붙인다(R13-4).
- 손가락 룰렛 이름 칩은 `role="button" tabindex="0"`을 이미 갖고 있고, 835행의 전역 keydown 핸들러가 Enter/Space를 클릭으로 바꿔준다. 이 경로가 살아 있음을 TC로 지킨다(R13-5).
- SVG `aria-label`을 결과 시점에 갱신한다(R13-6, R14).

---

## 9. 진입점 정리 (R16)

```js
// 라벨과 조건을 맞춘다. 게임은 여전히 저절로 뜨지 않는다.
const canGame = gameEligible() && (SESSION.hostId === ME || !SESSION.hostId);
```

- 호스트가 **나**일 때: 라벨 `🎲 다른 분에게 넘길지 게임으로 정하기`
- 호스트가 **없을** 때: 라벨 `🎲 게임으로 섬길 사람 정하기`, 구역 제목 `누가 섬길지 아직 안 정했다면`

`gamepickBar`(하단바)도 같은 `canGame`을 쓴다(R16-3). 조건을 못 넘겨 버튼이 숨는 경우, 호스트 없는 섬김 화면에는 사유 한 줄을 남긴다: "주문이 2건 이상 모이면 게임으로 정할 수 있어요" (R16-2, R16-4).

주문 수 조건(`Object.keys(ORDERS).length>0`)은 `gameEligible()`이 이미 더 강하게 포함한다 — 음료 주문자 2명 이상이면 주문은 당연히 1건 이상이다. 그래서 중복 조건을 지운다. "주문이 없으면 unclaim이 섬김을 지운다"는 원래 방어도 유지된다(R16-5).

---

## 10. 실시간 갱신 (R17)

범위를 **감지·알림 + 확정 시점 재검증**까지로 정한다. 게임을 강제로 닫거나 결과를 몰래 바꾸지는 않는다.

```js
// 게임이 떠 있는 동안 명단이 바뀌면 결과 화면에 경고를 얹는다
function gameRosterSig(){ return gamePlayers().map(m=>m.id).sort().join(","); }
```

- `startGame` 시점의 서명을 `GS.sig`에 저장한다.
- `showGameResult`에서 현재 서명과 다르면 결과 블록 위에 배너를 띄운다: "게임 도중 참가자가 바뀌었어요 — 한 판 더 돌리시겠어요?" (R17-1, R17-2)
- 당첨자가 현재 `gamePlayers()`에 없으면 `확정하기`를 막고 `한 판 더`만 남긴다.
- `commitGameWinner`는 `prevHost`를 미리 잡아둔 값이 아니라 호출 시점의 `SESSION.hostId`로 다시 읽는다. `Sync.claim`은 이미 `host_id is null` 조건으로 원자적 인계를 하고 `false`를 돌려주므로, 그 반환값을 사유와 함께 사용자에게 전달한다(R17-3, R17-4).
- 오버레이는 하위 `render()`에 반응해 닫히지 않는다. 현재 동작 그대로다(R17-5).

---

## 11. 테스트 전략

리포지토리에 `package.json`도 테스트 러너도 없다. 새 의존성 없이 순수 로직을 검증한다.

### 11.1 마커 주석

`index.html`의 게임 로직 중 **DOM에 의존하지 않는 부분**을 마커로 감싼다.

```js
/* @test-export:start — 아래 블록은 tests/game-logic.test.mjs 가 그대로 읽어 평가한다.
   DOM·전역 상태에 의존하는 코드를 이 안에 넣지 말 것. */
const GS_SOFT_W = 1/3;
const GAME_LABEL_MAX = 10;
const GAME_MAX = { ladder:16, wheel:24, finger:Infinity, race:24 };
function gameFits(kind, n){ ... }
function gcolor(i, n){ ... }
function pickWeighted(players, w, rnd){ ... }
function rosterFrom(members, orders, on, off){ ... }   // gameRoster 의 순수 버전
function playersFrom(roster, policy, lastHostId){ ... } // gamePlayers 의 순수 버전
function ladderGeometry(n){ ... }                       // GAP·BOX_W·NFS 계산
/* @test-export:end */
```

`gameRoster()`/`gamePlayers()`는 전역 `MEMBERS`/`ORDERS`/`GS`를 읽는 얇은 껍데기가 되고, 판단은 순수 함수가 한다. 이 분리가 테스트를 가능하게 하는 유일한 프로덕션 측 변경이다.

### 11.2 테스트 러너

```js
// tests/game-logic.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const src  = html.split("/* @test-export:start")[1].split("/* @test-export:end")[0]
                 .replace(/^[^\n]*\n/, "");     // 마커 첫 줄 제거
const ctx  = vm.createContext({});
vm.runInContext(src + "\n;({ pickWeighted, rosterFrom, playersFrom, gcolor, gameFits, ladderGeometry, GS_SOFT_W, GAME_MAX });", ctx);
```

`node --test tests/` 로 실행한다. 의존성 0, 빌드 0.

### 11.3 검증 항목

**속성 기반 (반복 실행)**

- `pickWeighted` — 결정론적 난수를 주입해 각 참가자의 선택 빈도가 가중치 비율에 수렴하는지. `soft`에서 직전 섬긴 사람의 빈도가 `1/(n-1+1/3)`에 수렴하고 **0이 아닌지** (R6-4, R6-5, R6-15)
- `pickWeighted` — 임의의 `players`·`w`에 대해 반환값이 항상 `players` 안에 있는지 (부동소수 잔차 방어)
- `rosterFrom` — 임의의 주문 조합에서 `skip`인 사람이 절대 포함되지 않는지 (R2-2, R2-5)
- `rosterFrom` — `on`에 넣은 사람은 기본값과 무관하게 포함되고, `off`에 넣은 사람은 제외되는지 (R3-5)
- `playersFrom` — `policy==="skip"`이면 `lastHostId`가 항상 빠지는지, 그 외에는 항상 남는지 (R6-6, R6-7)
- `gcolor` — `n`이 2..60일 때 생성된 색 `n`개가 모두 서로 다른지, 인접 인덱스의 색상 차가 최소 임계값 이상인지 (R9-1~R9-3)
- `ladderGeometry` — `n`이 2..`GAME_MAX.ladder`일 때 `GAP >= 18`, `BOX_W >= 14`인지. 상한+1에서 이 불변식이 깨지는지(상한값이 실제 한계와 맞는지 역검증) (R10-1, R10-6)

**경계값**

- `n = 2` 세 게임 모두 (R10-5)
- `n = 10, 11` 색 생성 방식 전환 지점
- `n = 16, 17` 사다리 상한 / `n = 24, 25` 돌림판 상한 (R10-6)
- `policy==="skip"` 적용 후 참가자 1명 (R6-14)

### 11.4 사람이 밟는 테스트

DOM·터치·히스토리·애니메이션·스크린리더는 자동화하지 않는다. `QA-TESTCASES.md`에 TC64 이후로 추가한다.

- 토글 스위치 켜짐/꺼짐 구분, 44px 탭 영역, 스크롤 유지 (R1, R7)
- 손가락 룰렛 결과 화면 스크롤 (R8)
- 뒤로가기 시나리오 5종 — 7.3의 검증 표 그대로 (R11)
- 사다리 ☕ 선표시 + 선이 내려오는 것이 보이는지 (R4)
- 돌림판 회전이 보이는지 — TC63의 사다리 케이스와 짝 (R14)
- 확정 후 당첨자 본인 화면에 메뉴 그리드가 열리는지 (R12)
- 정책 3택 전환 시 참가자 수 표기가 따라 바뀌는지 (R6)
- RPC 미배포 상태에서 게임이 정상 동작하는지 (R5-6)

---

## 12. 요구사항 매핑

| 요구사항 | 설계 절 |
|---|---|
| R1 토글 스위치 | 6.2, 6.3 |
| R2 기본 참가자 | 1, 2, 6.1, 6.2 |
| R3 게임 간 연동 | 1, 2, 6.6 |
| R4 사다리 ☕ 선표시 | 6.4 |
| R5 직전 섬긴 사람 조회 | 4.1, 4.2 |
| R6 확률 정책 | 3, 6.1, 6.6 |
| R7 스크롤·포커스 유지 | 6.2 |
| R8 손가락 룰렛 스크롤 복원 | 6.6 |
| R9 색 구분 | 5 |
| R10 인원 상한 | 5, 6.4, 6.5 |
| R11 뒤로가기 | 7 |
| R12 당첨자 그리드 | 6.7 |
| R13 모달 접근성 | 8 |
| R14 돌림판 애니메이션 | 6.5 |
| R15 손가락 룰렛 카운트다운 | 6.6 |
| R16 진입점 정리 | 9 |
| R17 실시간 갱신 | 10 |
| R18 확정 버튼 | 6.7 |

---

## 13. 위험과 대비

| 위험 | 대비 |
|---|---|
| `ignorePop`을 카운터로 바꾸는 것이 확인창 동작에 영향 | 호출 지점이 3곳뿐이다. 확인창 뒤로가기=취소 시나리오를 QA에 명시적으로 남긴다. |
| `gcolor` 시그니처 변경 누락 | 호출부 3곳(`playLadder`·`playWheel`·`playFinger`)을 한 커밋에서 함께 고친다. 손가락 룰렛은 참가자 수와 무관하므로 기존 팔레트 순환을 유지한다. |
| `get_last_host` 미배포 상태 배포 | 폴백이 오늘 `SERVINGS`를 쓰므로 앱이 정상 동작한다. 프론트를 먼저 배포해도 되고 SQL을 먼저 적용해도 된다. |
| 마커 주석이 지워져 테스트가 조용히 통과 | 테스트 첫 단계에서 마커와 기대 심볼 존재를 assert 해 실패시킨다. |
| `openSheet` 1회 호출로 바꾼 뒤 부분 갱신이 상태와 어긋남 | `syncRosterRow`/`syncRosterCount`/`syncRosterAll`이 모두 `gameRoster()`·`gamePlayers()`에서 값을 다시 읽는다. 화면이 별도 상태를 들고 있지 않다. |

---

# 부록 A — 🏁 구슬 레이스 (R19)

본문 1~13절의 토대(`GS` 상태, `gamePlayers()`, 가중 추첨, `gcolor`, 오버레이 생명주기, 접근성)가 다 있다고 가정한다. 이 게임은 그 위에 네 번째 `kind`로 얹힌다.

## A.1 왜 물리 엔진을 쓰지 않는가

세 가지가 겹친다.

1. **새 라이브러리 금지**가 확정된 제약이다.
2. **확률 정책(R6)** — 물리가 결과를 만들면 `1/3` 가중치를 걸 지점이 없다. 손가락 룰렛이 확률 조정을 못 하는 것과 같은 이유다.
3. **결과를 먼저 뽑는다**는 이 앱의 기존 원칙. 사다리도 돌림판도 그렇게 한다.

그래서 경로를 미리 계산하고 연출이 그 결과를 향하게 한다. 잃는 것은 창발성이고, 얻는 것은 고른 확률과 20초 안에 끝나는 보장이다. 역전 장면은 구간별 속도 편차로 만든다 — 물리가 없어도 "쫓고 쫓기는" 그림은 나온다.

## A.2 코스 모델

세로로 긴 사행(蛇行) 코스다. 폭은 `W = 340`(다른 게임과 동일), 전체 길이 `TOTAL ≈ 2400`(약 7화면).

코스를 `SEGS = 12`개 구간으로 나눈다. 각 구간은 진폭과 위상을 갖는 사인 곡선이다.

```js
/* @test-export 블록에 들어갈 순수 함수들 */

// 코스 생성 — 구간별 길이·진폭·위상
function raceCourse(rnd){
  const SEGS = 12, W = 340, CX = W/2, SEG_LEN = 200;
  const segs = [];
  for(let s=0; s<SEGS; s++){
    segs.push({
      len:   SEG_LEN,
      amp:   40 + rnd()*70,                 // 좌우 흔들림 폭
      phase: rnd()*Math.PI*2,
      turns: 1 + Math.floor(rnd()*2)        // 구간 안에서 몇 번 꺾이는지
    });
  }
  return { segs, W, CX, total: SEGS*SEG_LEN };
}

// 진행률 p(0..1) → 코스 위 좌표
function raceXY(course, p){
  const y = p * course.total;
  let acc = 0, s = 0;
  while(s < course.segs.length-1 && acc + course.segs[s].len < y){ acc += course.segs[s].len; s++; }
  const g = course.segs[s], u = (y - acc) / g.len;
  const x = course.CX + g.amp * Math.sin(u * Math.PI * 2 * g.turns + g.phase);
  return { x, y };
}
```

코스 벽은 이 사인 곡선의 봉투(±구슬 반지름 + 여유)로 그린다. 구슬이 벽을 따라 미끄러지며 튕기는 것처럼 읽힌다. 사인 곡선의 극점에 페그(못)를 찍어 코스처럼 보이게 한다. 벽은 정적이므로 한 번만 그려 오프스크린 캔버스에 캐시한다.

## A.3 스케줄 — 당첨자를 1위로 만들면서 역전을 만들기

핵심은 "각 구슬이 구간마다 다른 속도를 갖는다"는 것 하나다. 총 소요 시간만 원하는 순서로 맞추면, 중간 순위는 자연히 뒤섞인다.

```js
// 구슬 i 의 구간별 속도 배수 — 구간마다 빠름/느림이 달라 역전이 생긴다
function raceSpeeds(n, segCount, rnd){
  const sp = [];
  for(let i=0;i<n;i++){
    const row = [];
    for(let s=0;s<segCount;s++) row.push(0.55 + rnd()*0.9);
    sp.push(row);
  }
  return sp;
}

// order[0] 이 1위. 총 소요 시간을 그 순서로 배분하고, 각 구슬의 구간 속도를 그 총합에 맞춰 스케일.
// 반환된 cum[i] 는 구슬 i 가 각 구간 끝에 도달하는 누적 시간(ms).
function raceSchedule(course, speeds, order, duration, rnd){
  const n = speeds.length, segs = course.segs;
  const raw = speeds.map(row => segs.reduce((a,g,s)=> a + g.len/row[s], 0));
  // 1위는 duration*0.80, 꼴찌는 duration*0.99 사이에 균등 배분 + 약간의 지터
  const band = 0.99 - 0.80;                // RACE_F_HI - RACE_F_LO
  const gap  = n<=1 ? band : band/(n-1);   // 인접 등수 사이의 간격
  const span = Math.min(0.015, gap*0.9);   // 지터 폭은 그 간격보다 넓어질 수 없다
  const want = new Array(n);
  order.forEach((idx, rank)=>{
    const f = n<=1 ? 0.80 : 0.80 + band*(rank/(n-1));
    want[idx] = duration * (f + (rnd()-0.5)*span);
  });
  const cum = [];
  for(let i=0;i<n;i++){
    const k = want[i]/raw[i];              // 이 구슬 전체를 want[i] 에 맞추는 배율
    let t = 0; const row = [0];
    for(let s=0;s<segs.length;s++){ t += (segs[s].len/speeds[i][s]) * k; row.push(t); }
    row[segs.length] = want[i];            // 부동소수 잔차를 덮는다 (아래 ③)
    cum.push(row);
  }
  return { cum, want };
}

// t(ms) 시점 구슬 i 의 진행률 0..1
function raceProgress(course, sched, i, t){
  const row = sched.cum[i], segs = course.segs, last = row[row.length-1];
  if(t >= last) return 1;
  let s = 0; while(s < segs.length-1 && row[s+1] < t) s++;
  const u = (t - row[s]) / (row[s+1] - row[s]);
  let acc = 0; for(let k=0;k<s;k++) acc += segs[k].len;
  return (acc + u*segs[s].len) / course.total;
}

// 선두가 바뀐 횟수 — R19-5 를 검증 가능하게 만드는 함수.
// 표본 구간은 duration 이 아니라 '1위 도착 시각'까지다 (아래 ④)
function raceLeadChanges(course, sched, n, duration, samples){
  const N = samples || 120;
  let end = duration;
  for(let i=0;i<n;i++) if(sched.want[i] < end) end = sched.want[i];
  let prev = -1, changes = 0;
  for(let k=1;k<=N;k++){
    const t = end*k/N;
    let lead = 0, best = -1;
    for(let i=0;i<n;i++){ const p = raceProgress(course, sched, i, t); if(p > best){ best = p; lead = i; } }
    if(prev !== -1 && lead !== prev) changes++;
    prev = lead;
  }
  return changes;
}
```

**구현(16.1)에서 드러난 산술 오류 4건.** 위 코드는 이미 고친 값이다. 원래 초안이 무엇이었고 왜 틀렸는지 남긴다 — 같은 함정을 다시 파지 않기 위해서다.

① **지터 폭이 등수 간격보다 넓었다.** 초안의 `±0.0075`(전체 폭 `0.015`)는 고정값인데 인접 등수 간격은 `0.19/(n-1)`이라 인원이 많으면 좁아진다 — `n=24`에서 `0.00826`이다. 그러면 2등이 1등보다 먼저 도착하는 배분이 실제로 나온다. R19-4는 "항상"이므로 확률적으로 드문 것으로는 부족하다. 폭을 `min(0.015, gap*0.9)`로 묶어 인접 도착 시간 차가 최소 간격의 `0.1`배(n=24·duration=20000에서 약 16ms) 남게 했다. 인원이 적으면 간격이 넓어 `0.015`가 그대로 쓰인다.

② **꼴찌 배분 상한은 `1.00`이 아니라 `0.99`다.** `1.00`에 두면 지터가 위로 삐져나가 도착 시간이 `duration`을 넘는다(R19-3 위반). `0.99 + 0.0075 = 0.9975`로 항상 안쪽이고, 아래쪽도 `0.80 - 0.0075 = 0.7925`로 `duration*0.75` 위다. 두 경계를 지터 폭과 함께 계산해 정한 값이다(`RACE_F_LO = 0.80`, `RACE_F_HI = 0.99`).

③ **`cum`의 마지막 칸을 `want[i]`로 덮어야 한다.** `Σ(len/v)*k`는 `raw*k = want`와 부동소수 잔차만큼 어긋난다. 그대로 두면 `t = want[i]`에서 진행률이 1에 아주 못 미치는 빌드가 나온다(실측 약 3.5%). 루프 종료 판정은 `want`를 보는데 그림은 아직 결승선 앞이라는 불일치가 그것이다.

④ **`raceLeadChanges`는 `duration`이 아니라 1위 도착 시각까지만 표본을 잡는다.** 레이스는 1위가 들어오면 끝나므로 그 뒤는 화면에 없다. 게다가 전원이 도착한 시점에는 모두 진행률이 1이라 `p > best` 비교의 인덱스 타이브레이크 때문에 선두가 바뀐 것처럼 한 번 더 세어진다. 그 유령 1회가 지루한 레이스를 문턱 위로 올려 재생성 루프를 무력화한다 — 실측으로 빌드의 48~94%가 과다 계수됐다.

**재생성 루프.** 사다리가 "아무도 자리를 안 바꾸는 사다리는 다시 만든다"고 하는 것과 같은 처방이다. 문턱은 인원에 따라 갈리고(R19-5), 40회를 다 쓰면 마지막이 아니라 **가장 잘 나온** 시도를 쓴다.

```js
const gate = n===2 ? 1 : 3;               // n=2 는 구조적으로 3회가 어렵다 (R19-5)
let best = null;
for(let t=0; t<40; t++){
  const course  = raceCourse(Math.random);
  const speeds  = raceSpeeds(n, course.segs.length, Math.random);
  const sched   = raceSchedule(course, speeds, order, DUR, Math.random);
  const changes = raceLeadChanges(course, sched, n, DUR, 120);
  if(!best || changes > best.changes) best = { course, speeds, sched, changes };
  if(changes >= gate) break;
}
```

`order`는 `[당첨자, ...나머지를 섞은 것]`이다. 당첨자는 `gamePickWinner(gamePlayers())`로 이미 뽑혀 있으므로 확률 정책이 그대로 반영된다(R19-4).

## A.4 렌더링

SVG가 아니라 `<canvas>`를 쓴다. 24개 구슬 × 20초 × 60fps에서 SVG 노드 갱신은 버겁고, 카메라 이동도 캔버스가 자연스럽다. 새 라이브러리는 아니다.

```js
function playRace(players, winner){
  const DUR = lessMotion() ? 10 : RACE_DUR;   // RACE_DUR = 25000 (아래 참고)
  // …코스·스케줄 생성(A.3)…
  openGameOv("🏁 구슬 레이스", `
    <div class="game-say" id="gvSay" aria-live="polite">출발!</div>
    <div class="race-wrap"><canvas id="raceCv" width="340" height="440"
      role="img" aria-label="구슬 레이스 진행 중"></canvas>
      <div class="race-hud" id="raceHud"></div></div>
    <div id="gvWin"></div>`);
  setGameFoot(`<button class="btn btn-soft" id="gvSkip">⏭ 건너뛰기</button>
    <button class="btn btn-ghost btn-close" id="gvCancel">그만두기</button>`);
```

**루프.** `dt`를 상한으로 묶어 백그라운드 복귀 시 한 번에 튀는 것을 막는다(R19-14).

```js
  let t = 0, last = performance.now(), raf = 0, done = false;
  function frame(now){
    const dt = Math.min(64, now - last);      // 탭이 숨었다 돌아와도 한 프레임분만 진행
    last = now; t += dt;
    draw(t);
    if(t >= sched.want[wi]) { finish(); return; }
    raf = requestAnimationFrame(frame);
  }
  raf = requestAnimationFrame(frame);
```

**카메라(R19-10).** 선두 구슬의 y를 따라간다.

```js
  const camY = leadY => Math.max(0, Math.min(course.total - H, leadY - H*0.42));
```

**HUD(R19-9).** 진행률 바 + 상위 3명의 번호·이름. `draw` 안에서 매 프레임 갱신하지 않고 200ms마다 갱신해 레이아웃 비용을 줄인다.

**구슬(R19-6).** `gcolor(i, n)` 색 원 + 흰 번호. 선두에는 테두리 강조.

**정리(R19-13).** `gameTeardown`에 `cancelAnimationFrame(raf)`을 등록한다. `closeGame`이 `teardown`을 부르므로 ✕·뒤로가기·`그만두기` 모든 경로에서 루프가 멈춘다.

**건너뛰기(R19-7).** `gvSkip`은 `cancelAnimationFrame` 후 `finish()`를 바로 부른다. `lessMotion()`이면 애초에 `DUR = 10`이라 사실상 즉시 끝난다(R19-8).

**결과(R19-16).** `finish()`는 마지막 프레임을 결승선 통과 상태로 그린 뒤 `showGameResult(winner)`를 부른다. 그 뒤 흐름(`한 판 더`·`확정하기`)은 다른 게임과 완전히 같다.

**⑤ `DUR`은 20000이 아니라 25000이다(16.1에서 정정).** 레이스는 1위가 결승선을 통과하면 끝나고 1위 도착 시각은 `DUR*0.80`이다. 초안의 `DUR = 20000`은 체감 15.85~16.15초짜리 게임이 되어 R19-3(18~22초)을 못 지킨다. 시간을 맞추려면 배분 상한이 아니라 `DUR`을 늘려야 한다 — `RACE_DUR = 25000` → `25000 × (0.80 ± 0.0075) = 19.81~20.19초`다.

## A.5 CSS

```css
/* 구슬 레이스 — 캔버스는 폭에 맞춰 늘리되 비율을 지킨다 */
.race-wrap { position:relative; width:100%; max-width:min(340px, 45vh); margin:0 auto; }
.race-wrap canvas { display:block; width:100%; height:auto; border-radius:12px;
                    background:#fffdf9; border:1.5px solid var(--line); }
.race-hud { margin-top:8px; font-size:12px; color:var(--sub); font-weight:600; line-height:1.5; }
.race-hud .bar { height:6px; border-radius:3px; background:var(--brand-soft); overflow:hidden; margin-bottom:6px; }
.race-hud .bar > i { display:block; height:100%; background:var(--brand); }
```

캔버스는 논리 크기 340×440에 `devicePixelRatio`를 곱해 실제 픽셀을 잡고, CSS로 폭에 맞춘다. 폰에서 흐릿하지 않게 하기 위한 표준 처방이다.

**⑥ 세로 상한은 `62vh`가 아니라 `45vh`다(16.2에서 정정).** `max-width`는 폭에 걸리는 값이고 캔버스 비율은 340:440 = 1:1.29다. `62vh`를 그대로 쓰면 높이가 `62 × 1.29 ≈ 80vh`가 되어 게임 안내 한 줄·HUD·결과 블록이 전부 스크롤 밖으로 밀린다. `45vh`면 높이가 약 58vh로 한 화면에 들어온다.

**오프스크린 벽 캐시의 dpr은 1.5로 묶는다(16.2).** 코스는 340×2400 논리 px이라 `dpr 3`을 그대로 곱하면 1020×7200이다. 메모리(≈29MB)보다 먼저 깨지는 것이 있다 — **iOS 사파리는 캔버스 한 변을 4096px로 제한하고, 넘으면 그림이 아예 안 나온다(빈 화면).** `1.5`로 묶으면 510×3600(≈7.3MB)이고 한 변도 4096 아래다. 흐려지는 것은 장식인 벽선·페그뿐이고, 읽어야 하는 구슬 번호는 매 프레임 화면 dpr 그대로 그린다.

## A.6 테스트

순수 함수 5개가 `@test-export` 블록에 들어가므로 `tests/game-logic.test.mjs`에서 그대로 검증한다.

- `raceSchedule` — `order[0]`의 도착 시간이 항상 최소인지. 임의의 `n`(2..24)과 임의의 난수 시드에서 성립해야 한다 (R19-4, R19-17)
- `raceSchedule` — 모든 도착 시간이 `duration` 이하이고 `duration*0.75` 이상인지 (R19-3)
- `raceProgress` — `t=0`에서 0, `t>=도착시간`에서 정확히 1, 그 사이에서 단조 증가인지
- `raceLeadChanges` — 재생성 루프를 통과한 코스에서 문턱(3명 이상 3회, 2명 1회) 이상인지. 그리고 루프 없이 생성했을 때 3 미만이 나오는 경우가 실제로 존재하는지(루프가 죽은 코드가 아님을 확인) (R19-5, R19-17)
- `raceXY` — 임의의 `p`에서 `x`가 `[0, W]` 안에 있는지 (구슬이 코스 밖으로 나가지 않는지)
- `gameFits("race", n)` — 24/25 경계 (R19-12)

캔버스 렌더링·카메라·HUD·백그라운드 복귀는 자동화하지 않고 `QA-TESTCASES.md`에 남긴다.
