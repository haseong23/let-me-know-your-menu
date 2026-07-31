# Implementation Plan — 게임으로 섬길 사람 정하기

작업 순서는 의존성을 따른다. 1~3번이 토대이고, 4번 이후는 그 위에 얹힌다. 16번(구슬 레이스)은 1~15번이 모두 끝난 뒤에, 17번(헤더 정리)은 가장 마지막에 착수한다. 각 작업은 `index.html` 하나(그리고 명시된 새 파일)만 건드린다.

**검증 방법:** 빌드 단계가 없다. 순수 로직은 리포지토리 루트에서 `node --test`, 화면은 브라우저에서 직접 확인한다. 각 작업 끝에 `node --test`가 통과해야 한다. (`node --test tests/`는 Node 22+ 에서 뒤 인자를 glob 으로 해석해 디렉터리를 테스트 파일로 열려다 실패한다 — 인자를 생략하거나 `node --test 'tests/**/*.test.mjs'`를 쓴다.)

---

- [x] 1. 순수 로직 토대와 테스트 하네스 만들기
  - 이후 모든 작업이 이 함수들 위에 얹힌다. 먼저 검증 가능한 바닥을 깐다.
  - _Requirements: 6.15_

- [x] 1.1 `index.html`에 마커 블록과 순수 함수 추가
  - 게임 코드 구역 시작부(현재 `GAME_COLORS` 선언 자리)에 `/* @test-export:start */` … `/* @test-export:end */` 블록을 만든다.
  - 블록 안에 상수를 넣는다: `GS_SOFT_W = 1/3`, `GAME_LABEL_MAX = 10`, `GAME_MAX = { ladder:16, wheel:24, finger:Infinity }`.
  - 블록 안에 순수 함수를 넣는다: `gameFits(kind, n)`, `gcolor(i, n)`, `pickWeighted(players, w, rnd)`, `rosterFrom(members, orders, on, off)`, `playersFrom(roster, policy, lastHostId)`, `ladderGeometry(n)`.
  - `gcolor`는 `n <= GAME_COLORS.length`면 기존 팔레트를, 넘으면 `hsl((i*137.508)%360, 52%, 34%)`를 돌려준다.
  - `ladderGeometry(n)`은 기존 `playLadder` 안에 흩어진 `GAP`·`BOX_W`·`NCH`·`NFS` 계산을 그대로 옮겨 담아 객체로 돌려준다. 값은 바꾸지 않는다.
  - 블록 안에는 DOM·전역 상태(`MEMBERS`, `ORDERS`, `GS`)를 참조하는 코드를 넣지 않는다.
  - _Requirements: 6.4, 6.5, 9.1, 9.2, 9.3, 10.1_

- [x] 1.2 `tests/game-logic.test.mjs` 작성
  - `node:test` + `node:assert/strict` + `node:vm`만 쓴다. 새 의존성·`package.json` 없이 동작해야 한다.
  - `index.html`을 읽어 마커 사이 블록을 추출하고 `vm.createContext()`에서 평가한다.
  - 첫 테스트로 마커와 기대 심볼(`pickWeighted`, `rosterFrom`, `playersFrom`, `gcolor`, `gameFits`, `ladderGeometry`, `GS_SOFT_W`, `GAME_MAX`)의 존재를 assert 한다. 마커가 지워지면 조용히 통과하는 대신 실패해야 한다.
  - `node --test tests/`로 실행되는 것을 확인한다.
  - _Requirements: 6.15_

- [x] 1.3 속성 기반 테스트 작성
  - `pickWeighted` — 결정론적 난수를 주입해 반복 실행하고, 각 참가자의 선택 빈도가 가중치 비율에 수렴하는지 검증한다. `soft` 정책에서 직전 섬긴 사람의 빈도가 `(1/3)/(n-1+1/3)`에 수렴하고 0이 아님을 확인한다.
  - `pickWeighted` — 임의의 `players`·`w` 조합에서 반환값이 항상 `players` 안에 있는지 (부동소수 잔차 방어).
  - `rosterFrom` — 임의의 주문 조합에서 `type==="skip"`인 사람이 절대 포함되지 않는지.
  - `rosterFrom` — `on`에 넣은 사람은 기본값과 무관하게 포함되고, `off`에 넣은 사람은 항상 제외되는지.
  - `playersFrom` — `policy==="skip"`이면 `lastHostId`가 항상 빠지고, `soft`·`even`이면 항상 남는지.
  - `gcolor` — `n`이 2..60일 때 생성된 색 `n`개가 모두 서로 다르고, 인접 인덱스의 색상(hue) 차가 최소 임계값 이상인지.
  - `ladderGeometry` — `n`이 2..16일 때 `GAP >= 18`이고 `BOX_W >= 14`인지. 불변식이 처음 깨지는 지점이 `n = 18`(GAP 17.18)인지 역검증한다. `n = 17`은 GAP 18.25 / BOX_W 14.97 로 아직 들어가므로, 상한 16 은 한 줄치 여유를 둔 값이다.
  - 경계값: `n = 2`, `n = 10`/`11`(색 생성 전환 지점), `n = 16`/`17`/`18`, `n = 24`/`25`, `skip` 적용 후 1명.
  - _Requirements: 2.2, 2.5, 3.5, 6.4, 6.5, 6.6, 6.7, 6.14, 6.15, 9.1, 9.2, 9.3, 10.1, 10.5, 10.6_

- [x] 2. `GS` 상태 모델로 게임 전역 통합
  - 흩어진 전역을 하나로 모아야 명단 연동과 정책 유지를 얹을 자리가 생긴다.
  - _Requirements: 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 2.1 `GS` 선언과 `gameEnsure` 도입, 기존 전역 제거
  - `gameOpen`, `gameOff`, `gameKind`, `gameTimers`, `gameTeardown` 선언을 지우고 `let GS = null`로 대체한다.
  - `gameEnsure(opener)`를 추가한다. `GS.seq !== (SESSION.seq ?? null)`이면 전체를 기본값으로 리셋한다.
  - `gameInit()`을 삭제한다. `gameServedIds()`는 남기되 `gameEnsure`에서 호출하지 않는다 — 이것이 "오늘 섬긴 분 전원 자동 제외" 제거다.
  - `gtimer`·`clearGameTimers`가 `GS.timers`를 쓰도록 고친다.
  - `GS`가 `null`일 때 호출될 수 있는 함수(`gameEligible` 등)의 진입 방어를 넣는다.
  - _Requirements: 2.1, 3.3, 3.4_

- [x] 2.2 참가자 파생 함수 연결
  - `gameDefaultOn(m)`(음료 주문자), `gameIsSkip(m)`을 추가한다.
  - `gameRoster()`를 1.1의 `rosterFrom`을 호출하는 얇은 껍데기로 다시 쓴다.
  - `gamePlayers()`를 `playersFrom(gameRoster(), GS.policy, GS.lastHostId)`로 추가한다.
  - `gameEligible()`이 `gamePlayers().length >= 2`를 쓰도록 고친다.
  - `gameToggle(id, on)`, `gameAllOn()`, `gameDropServed()`를 추가한다.
  - 참가자 수를 표시하거나 판정하는 모든 지점이 `gamePlayers()` 하나만 쓰는지 확인한다.
  - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.8, 2.9, 2.10, 3.1, 3.5, 3.6, 6.6_

- [x] 2.3 진입점 핸들러 교체
  - `bind("gamepick", ...)`과 `bind("gamepickBar", ...)`가 `gameInit()` 대신 `gameEnsure(누른 버튼 엘리먼트)`를 부르게 한다.
  - 버튼 엘리먼트를 `GS.opener`로 넘겨 나중에 포커스를 되돌릴 수 있게 한다.
  - 같은 섬김에서 게임을 닫고 다시 열면 명단과 정책이 유지되는 것을 확인한다.
  - _Requirements: 3.3, 3.4, 13.3_

- [x] 3. 오버레이 생명주기 — 히스토리와 접근성
  - `openGameOv`/`closeGame`/`popstate`를 한 번에 고친다. 히스토리와 포커스 관리가 같은 함수에 얹히므로 나눠서 하면 두 번 건드리게 된다.
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 13.1, 13.2, 13.3_

- [x] 3.1 `ignorePop`을 불리언에서 카운터로 변경
  - 선언을 `let ignorePop = 0`으로 바꾼다.
  - `finishConfirm`의 `ignorePop = true`를 `ignorePop++`로, 실패 경로를 `ignorePop--`로 바꾼다.
  - `popstate` 진입부를 `if(ignorePop > 0){ ignorePop--; return; }`로 바꾼다.
  - 확인창 뒤로가기=취소 동작이 그대로인지 확인한다. 이 변경의 유일한 회귀 위험 지점이다.
  - _Requirements: 11.5, 11.6_

- [x] 3.2 게임 오버레이가 자기 히스토리 항목을 소유하게 변경
  - `openGameOv`에서 `pushSub()` 호출을 없애고, `GS.open`이 false일 때 `history.pushState({sub:1, game:1}, "")`를 직접 호출하며 `GS.pushed = true`로 표시한다.
  - `closeGame(opts)`에 `fromPop` 옵션을 추가한다. `fromPop`이 아니고 `GS.pushed`면 `ignorePop++` 후 `history.back()`으로 자기 항목을 소비한다.
  - `popstate` 핸들러에서 `subActive = false` **앞에** `if(GS && GS.open){ closeGame({fromPop:true}); return; }`를 넣는다. 게임이 시트·탭의 항목을 소비하지 않아야 한다.
  - `clearSubEntry()`를 추가한다 — `subActive`가 true면 그 항목까지 소비한다.
  - design.md 7.3의 검증 표 5개 시나리오를 실기기 또는 데스크톱 브라우저에서 직접 밟아 확인한다.
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

- [x] 3.3 모달 포커스 관리와 라이브 리전
  - `gameA11yOn()` / `gameA11yOff()` / `gameTrap(e)`를 추가하고 `openGameOv` / `closeGame`에서 각각 부른다.
  - 열릴 때 `#app`·`#bottom`에 `aria-hidden="true"`를 걸고 `#gvX`로 포커스를 옮긴다. 닫을 때 되돌리고 `GS.opener`로 포커스를 복귀한다.
  - `gameTrap`으로 Tab / Shift+Tab 순환을 오버레이 안에 묶는다.
  - `#gvSay`에 `aria-live="polite"`, 결과 블록에 `role="status"`를 붙인다.
  - 손가락 룰렛 이름 칩이 기존 전역 keydown 핸들러(Enter/Space → click)로 여전히 동작하는지 확인한다.
  - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5_

- [x] 4. 직전에 섬긴 사람 조회
  - 확률 정책의 입력이므로 정책 UI보다 먼저 만든다.
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10_

- [x] 4.1 `db-migration-last-host.sql` 작성
  - `get_last_host(p_room text, p_date text, p_seq int) returns text`를 만든다.
  - `room_exists(p_room)` 검사 후, `host_id is not null` · `state in ('open','closed')` · 현재 섬김 제외 조건으로 `(date desc, seq desc)` 첫 행의 `host_id`를 돌려준다.
  - `security definer` + `set search_path = public` + `revoke all from public` + `grant execute to anon, authenticated` 패턴을 `get_room_history`와 동일하게 맞춘다.
  - `db-setup.sql`과 기존 마이그레이션 파일은 고치지 않는다. 이 SQL은 사람이 직접 DB에 적용하므로 작업 범위는 파일 작성까지다.
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_

- [x] 4.2 프론트엔드 조회와 폴백 구현
  - `LAST_HOST = { key, id }` 캐시와 `lastHostFromToday()` 폴백을 추가한다.
  - `fetchLastHost()`를 추가한다. `SHARED`일 때만 RPC를 부르고, 오류·미배포·오프라인이면 조용히 폴백값을 쓴다.
  - 조회 결과가 현재 구성원에 없으면 `null`로 처리한다.
  - `GS.lastHostId`의 세 상태(`undefined` 미조회 / `null` 없음 / `string` 있음)를 구분해 다룬다.
  - 마이그레이션 미적용 상태에서 게임이 정상 동작하는지 확인한다.
  - _Requirements: 5.6, 5.7, 5.8, 5.9_

- [x] 5. 확률 정책과 가중 추첨
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.7, 6.8, 6.9, 6.12, 6.13, 6.14_

- [x] 5.1 가중 추첨을 `startGame`에 배선
  - `gameWeights(players)`와 `gamePickWinner(players)`를 추가한다. `pickWeighted`(1.1)를 호출한다.
  - `startGame(kind)`이 `pickOne(roster)` 대신 `gamePickWinner(gamePlayers())`를 쓰게 고친다.
  - `gamePlayers()`가 2명 미만이면 시작하지 않고 사유를 토스트로 알린다.
  - `GS.kind`를 설정해 `한 판 더`가 같은 게임을 다시 돌리게 한다.
  - _Requirements: 6.4, 6.5, 6.7, 6.9, 6.12, 6.13, 6.14_

- [x] 6. 토글 스위치와 참가자 고르기 시트
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.4, 2.9, 2.10, 7.1, 7.2, 7.3, 7.4, 7.5_

- [x] 6.1 `.gsw` 토글 스위치 CSS와 마크업 추가
  - `.gsw` / `.gsw-track` / `.gsw-knob` 스타일을 게임 CSS 구역에 넣는다. 시각 높이 32px, `padding`+음수 `margin`으로 탭 영역 44px 확보.
  - `aria-checked="true"`에서 트랙 색(`--green`)과 손잡이 위치(`translateX`)가 함께 바뀌게 한다. 색 하나에만 의존하지 않는다.
  - `:focus-visible` 포커스 링을 넣는다.
  - `@media (prefers-reduced-motion: reduce)`에서 transition을 끈다.
  - 마크업은 `<button class="gsw" role="switch" aria-checked aria-labelledby="…">`로 만들어 Space/Enter와 포커스를 기본 동작으로 얻는다.
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7_

- [x] 6.2 `openRosterSheet`를 1회 렌더 + 부분 갱신으로 재작성
  - `openSheet()`를 최초 1회만 호출한다. 기존 `draw()`의 재호출 구조를 없앤다.
  - 목록 컨테이너에 이벤트 위임을 걸어 `.gsw` 클릭을 처리한다. 행을 갱신해도 재배선이 필요 없게 한다.
  - `syncRosterRow(id)` / `syncRosterCount()` / `syncRosterAll()`을 추가한다. 컨테이너를 재생성하지 않으므로 `scrollTop`이 유지된다.
  - 토글 후 방금 누른 스위치로 포커스를 되돌린다.
  - 행 부제를 상태별로 표시한다: `주문 완료` / `아직 주문 전 — 넣으려면 켜주세요` / `오늘 이미 섬기셨어요` / `직전에 섬기신 분`.
  - `안 마실게요` 선택자는 스위치 대신 `안마심` 배지를 보여주고 참가시킬 수 없게 한다.
  - 아바타 배경을 `--sub`로 바꾸던 기존 처방을 삭제하고, 제외된 행은 이름·부제에 `opacity:.55`를 준다.
  - `전원 참가` / `오늘 섬긴 분 빼기`가 `syncRosterAll()`로 갱신하게 한다.
  - `완료`가 히스토리 항목을 늘리지 않고 게임 고르기 시트로 돌아가게 한다.
  - _Requirements: 1.8, 1.9, 2.4, 2.5, 2.9, 2.10, 7.1, 7.2, 7.3, 7.4, 7.5, 11.7_

- [x] 7. 게임 고르기 시트 재작성
  - _Requirements: 2.6, 2.7, 3.6, 6.1, 6.2, 6.3, 6.8, 6.11, 7.6, 10.4_

- [x] 7.1 `drawGameSheet`로 분리하고 참가자 카드 갱신
  - `openGameSheet()`를 `drawGameSheet()` 호출과 비동기 조회 배선으로 나눈다.
  - 참가자 카드가 `gamePlayers().length`를 쓰게 하고, 기본값 기준 안내 한 줄을 넣는다: "메뉴를 고른 분이 기본으로 들어가 있어요".
  - `gamePlayers()`가 2명 미만이면 게임 선택 블록 대신 사유 배너를 띄우고 `바꾸기`로 유도한다.
  - _Requirements: 2.6, 2.7, 3.6_

- [x] 7.2 확률 정책 카드 추가
  - `GS.lastHostId`가 문자열일 때만 정책 카드를 그린다. `직전에 섬긴 분: OOO님`으로 이름을 표시한다.
  - `확률 낮추기` · `제외` · `평등` 3택을 기존 `.chips`/`.chip.sel` 패턴으로 만든다. 현재 선택이 드러나야 한다.
  - 기본값은 `확률 낮추기`(`GS.policy = "soft"`)다.
  - 칩 클릭 시 시트를 다시 그리지 않고 정책 카드와 참가자 카드만 부분 갱신한다. `제외`는 참가자 수를 바꾸므로 두 블록이 함께 갱신돼야 한다.
  - `syncPolicyBlock()`을 추가해 `fetchLastHost()` 완료 시 그 블록만 채운다. 시트가 이미 닫혔으면 아무것도 하지 않는다.
  - _Requirements: 6.1, 6.2, 6.3, 6.8, 6.12, 7.6_

- [x] 7.3 인원 상한 초과 시 게임 선택 비활성화
  - `gameFits(kind, gamePlayers().length)`가 false면 해당 `.game-pick` 버튼을 `disabled`로 만들고 사유를 붙인다.
  - 사다리 16명 / 돌림판 24명 / 손가락 룰렛 무제한. 세 개가 모두 막히는 경우는 없어야 한다.
  - _Requirements: 10.4_

- [x] 8. 색 배정, 번호 라벨, 범례
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 10.1, 10.2_

- [x] 8.1 `gcolor` 호출부 3곳 갱신
  - `playLadder`·`playWheel`의 `gcolor(i)`를 `gcolor(i, n)`으로 고친다.
  - `playFinger`의 `gcolor(seq++)`는 손가락 순번이라 참가자 수와 무관하다. 기존 `GAME_COLORS` 순환을 유지하도록 별도 처리한다.
  - 한 커밋에서 세 곳을 함께 고쳐 시그니처 불일치가 남지 않게 한다.
  - _Requirements: 9.1, 9.2, 9.3, 9.4_

- [x] 8.2 번호 라벨 전환과 범례 렌더 추가
  - 참가자가 `GAME_LABEL_MAX`(10)를 넘으면 사다리 상단 라벨과 돌림판 조각 라벨에 번호(`i+1`)만 넣는다.
  - 10명 이하는 기존 `shortName`/`NCH`/`NFS` 로직을 그대로 쓴다.
  - 번호–색–이름 목록을 SVG 아래에 렌더하는 공통 함수를 만들어 사다리·돌림판이 함께 쓴다. `.game-body` 안에 두어 함께 스크롤되게 한다.
  - 잘린 이름이 범례에서 온전히 읽히는지 확인한다.
  - _Requirements: 9.5, 10.1, 10.2_

- [x] 9. 사다리타기 — ☕ 선표시
  - 도착 상자를 만들 때 `i === goal`이면 `☕` + 강조 배경/테두리, 아니면 `·` + 중립 배경으로 정적 마크업에 박는다. `?`를 없앤다.
  - `openBox` 함수와 계단식 공개 타이머를 삭제하고, 선 그리기가 끝나면 바로 `showGameResult(winner)`를 부른다.
  - 상자 안 기호 크기를 `Math.min(14, BOX_W * 0.62)`로 상자에 맞춘다.
  - 선이 위에서 아래로 그려지는 애니메이션(`stroke-dashoffset` + 강제 리플로우)은 건드리지 않는다. TC63이 지키는 동작이다.
  - 사다리 재생성 루프(`t<60`, `total>=n`, 제자리 방지)도 그대로 둔다.
  - ☕ 칸에 도착한 선의 주인이 결과 발표와 일치하는지 확인한다.
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 10.3_

- [x] 10. 돌림판 — 애니메이션 시작 통일
  - `transition = "none"` → `transform = rotate(0deg)` → 강제 리플로우(`void $gv().offsetHeight`) → transition 설정 → 목표 각도 순서로 바꾼다. 사다리와 같은 처방으로 맞춘다.
  - `prefers-reduced-motion`에서 회전을 생략하고 결과를 바로 표시하는 현재 동작은 유지한다.
  - 라벨 역회전(`rotate(-spin)`)은 그대로 둔다. 멈춘 순간 이름이 똑바로 서는지 확인한다.
  - 핀(12시) 아래 조각이 당첨자 조각과 일치하는지 확인한다.
  - 결과 표시 시점에 SVG `aria-label`을 "돌림판 결과: OOO님"으로 갱신한다.
  - `한 판 더`로 다시 돌릴 때 회전이 매번 처음부터 보이는지 확인한다.
  - _Requirements: 13.6, 14.1, 14.2, 14.3, 14.4, 14.5_

- [x] 11. 손가락 룰렛
  - _Requirements: 3.7, 6.10, 6.11, 8.1, 8.2, 8.3, 8.4, 8.5, 15.1, 15.2, 15.3, 15.4, 15.5_

- [x] 11.1 인라인 스타일 복원
  - `touchAction`·`overflowY`의 기존 값을 저장하고 `restoreBody()`로 되돌린다.
  - `restoreBody()`를 `teardown()` 안에서 부른다. 이름 칩 선택·`그만두기`·✕·뒤로가기 모든 경로가 `teardown`을 지나므로 한 지점에서 해결된다.
  - 진행 중에는 제한이 유지되어 손가락 좌표가 어긋나지 않는지 확인한다.
  - 결과 화면이 화면 높이를 넘칠 때 손가락으로 스크롤해 모든 버튼에 닿는지 확인한다.
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

- [x] 11.2 경계 이탈 처리와 좌표 클램프
  - `pointerleave` 리스너를 `onUp`에서 떼어낸다. `pointerup`·`pointercancel`만 점을 제거한다.
  - `at(e)`가 좌표를 본문 경계 안으로 클램프하게 고쳐, 손가락이 가장자리를 넘어도 점이 붙어 있게 한다.
  - `teardown`의 `removeEventListener` 목록도 함께 맞춘다.
  - _Requirements: 15.1, 15.2_

- [x] 11.3 카운트다운 안정화 대기 추가
  - 손가락 수가 바뀌면 즉시 3부터 세지 않고 `SETTLE = 900ms` 동안 변화가 없기를 기다린다.
  - `stop()`이 카운트다운 타이머와 안정화 타이머를 모두 취소하게 한다.
  - 화면 문구를 "손가락 N개 — 다 올리셨으면 곧 시작해요"와 "3·2·1"로 나눠 규칙이 드러나게 한다.
  - 손가락 2개 상태에서 세 번째 사람이 올릴 시간이 생기는지 확인한다.
  - 당첨 확정 후의 터치 입력이 결과를 바꾸지 않는지 확인한다.
  - _Requirements: 15.3, 15.4, 15.5_

- [x] 11.4 이름 칩과 정책 안내
  - `choose()`가 만드는 이름 칩이 호출 시점의 `gamePlayers()`를 쓰게 고친다. 시작 시점에 잡아둔 배열을 쓰지 않는다.
  - `GS.policy === "soft"`이고 `GS.lastHostId`가 있으면 시작 화면에 "이 게임은 확률 조정이 적용되지 않아요"를 한 줄 표시한다.
  - `제외` 정책은 명단에서 이미 빠지므로 칩에도 자동으로 반영되는지 확인한다.
  - _Requirements: 3.7, 6.10, 6.11_

- [x] 12. 결과와 확정
  - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 18.1, 18.2, 18.3, 18.4_

- [x] 12.1 확정 버튼 라벨과 처리 중 잠금
  - 버튼 라벨에서 이름을 뺀다. `✅ 이분으로 확정하기` / 호스트가 그대로면 `확인`.
  - 처리 중에는 `disabled`로 만들고 텍스트를 `확정하는 중…`으로 바꾼다. 완료 후 되돌린다.
  - `guardWrite`의 재진입 차단은 그대로 두고 그 위에 시각 상태만 얹는다.
  - 긴 이름에서도 버튼 글자가 넘치지 않는지 확인한다.
  - _Requirements: 18.1, 18.2, 18.3, 18.4_

- [x] 12.2 `commitGameWinner`의 렌더 순서와 탭 전환 수정
  - `closeGame()`으로 게임 히스토리 항목을 소비한다.
  - 당첨자가 나이고 성공했을 때만 `clearSubEntry()` → `forceGrid = true` → `openTab = "order"` 직접 대입 순으로 처리한다. `setOpenTab`을 쓰지 않는다.
  - `render()`를 분기 **뒤로** 옮긴다. 이것이 메뉴 그리드가 안 열리던 원인이다.
  - 확정 실패 시 `forceGrid`를 세우지 않는다.
  - 당첨자가 내가 아니면 `openTab`을 건드리지 않아 게임을 연 탭에 머무는지 확인한다.
  - `현황` 탭과 `내 주문` 탭 양쪽에서 게임을 열어 확정한 뒤 그리드가 열리는지 각각 확인한다.
  - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 11.6_

- [x] 13. 게임 진입점 조건과 문구 정리
  - `canGame`을 `gameEligible() && (SESSION.hostId === ME || !SESSION.hostId)`로 바꾼다. 중복된 `Object.keys(ORDERS).length > 0` 조건을 지운다.
  - 호스트가 나일 때와 없을 때의 라벨을 나눈다. 라벨이 실제 노출 조건과 맞아야 한다.
  - 하단바 `gamepickBar`도 같은 `canGame`을 쓰게 한다.
  - 조건을 못 넘겨 버튼이 숨을 때, 호스트 없는 섬김 화면에 사유 한 줄을 남긴다.
  - "게임은 자동으로 뜨지 않는다"와 "주문이 없으면 unclaim이 섬김을 지운다"는 기존 원칙이 깨지지 않았는지 확인한다.
  - _Requirements: 16.1, 16.2, 16.3, 16.4, 16.5_

- [x] 14. 게임 중 실시간 갱신 처리
  - `gameRosterSig()`를 추가하고 `startGame` 시점의 서명을 `GS.sig`에 저장한다.
  - `showGameResult`에서 현재 서명이 다르면 결과 위에 경고 배너를 띄운다: "게임 도중 참가자가 바뀌었어요 — 한 판 더 돌리시겠어요?".
  - 당첨자가 현재 `gamePlayers()`에 없으면 `확정하기`를 막고 `한 판 더`만 남긴다.
  - `commitGameWinner`가 `prevHost`를 미리 잡아둔 값이 아니라 호출 시점의 `SESSION.hostId`로 다시 읽게 한다.
  - `Sync.claim`이 `false`를 돌려줄 때(다른 사람이 먼저 이어받음) 사유를 사용자에게 전달한다.
  - 오버레이가 하위 `render()`에 반응해 닫히지 않는 현재 동작이 유지되는지 확인한다.
  - _Requirements: 17.1, 17.2, 17.3, 17.4, 17.5_

- [x] 15. `QA-TESTCASES.md`에 회귀 테스트케이스 추가
  - TC64 이후로 이어서 작성한다. 기존 파일의 체크박스·번호 형식을 그대로 따른다.
  - 토글 스위치 켜짐/꺼짐 구분과 44px 탭 영역 (R1)
  - 참가자 토글 시 스크롤·포커스 유지 (R7)
  - 기본 참가자가 메뉴를 고른 사람인지, 무응답자를 수동으로 넣을 수 있는지 (R2)
  - 게임 종류를 바꿔도·`한 판 더`를 눌러도·닫고 다시 열어도 명단이 유지되는지 (R3)
  - 사다리 ☕ 선표시 + 선이 위에서 아래로 그려지는 것이 보이는지 (R4)
  - 정책 3택 전환 시 참가자 수 표기가 따라 바뀌는지, 직전 섬긴 분 이름이 표시되는지 (R6)
  - 손가락 룰렛 결과 화면을 손가락으로 스크롤할 수 있는지 (R8)
  - 뒤로가기 시나리오 5종 — design.md 7.3 검증 표 그대로 (R11)
  - 확인창 뒤로가기=취소가 여전히 동작하는지 — `ignorePop` 카운터화 회귀 확인 (R11)
  - 확정 후 당첨자 본인 화면에 메뉴 그리드가 열리는지, `현황`/`내 주문` 양쪽 진입 모두 (R12)
  - 돌림판 회전이 보이는지 — TC63 사다리 케이스와 짝 (R14)
  - 11명 이상에서 번호 라벨과 범례가 보이는지, 이름이 겹치지 않는지 (R9, R10)
  - 사다리 17명·돌림판 25명에서 해당 게임이 사유와 함께 비활성화되는지 (R10)
  - `get_last_host` 미배포 상태에서 게임이 정상 동작하는지 (R5)
  - _Requirements: 1.1, 2.1, 3.1, 4.1, 5.6, 6.1, 7.1, 8.2, 9.5, 10.4, 11.1, 12.1, 14.1_

- [x] 16. 🏁 구슬 레이스 추가 (약 20초)
  - 1~15번이 모두 끝난 뒤에 착수한다. `GS` 상태·`gamePlayers()`·가중 추첨·`gcolor`·오버레이 생명주기·접근성이 모두 준비되어 있어야 한다.
  - 설계는 design.md 부록 A를 따른다.
  - _Requirements: 19.1, 19.11_

- [x] 16.1 코스·스케줄 순수 함수 추가와 테스트
  - `@test-export` 블록에 `raceCourse(rnd)`, `raceXY(course, p)`, `raceSpeeds(n, segCount, rnd)`, `raceSchedule(course, speeds, order, duration, rnd)`, `raceProgress(course, sched, i, t)`, `raceLeadChanges(course, sched, n, duration, samples)`를 추가한다.
  - `GAME_MAX`에 `race:24`를 추가한다.
  - 난수를 인자로 받아 결정론적으로 검증 가능하게 만든다. `Math.random`을 직접 부르지 않는다.
  - `tests/game-logic.test.mjs`에 검증을 추가한다: `order[0]`의 도착 시간이 항상 최소인지, 모든 도착 시간이 `duration*0.75`~`duration` 범위인지, `raceProgress`가 `t=0`에서 0·도착 후 1이며 단조 증가인지, `raceXY`의 `x`가 `[0, W]` 안인지, `gameFits("race", n)`의 24/25 경계.
  - `raceLeadChanges` 검증: 재생성 루프를 통과한 코스에서 항상 3 이상이고, 루프 없이 생성하면 3 미만이 실제로 나오는 경우가 존재하는지(루프가 죽은 코드가 아님을 확인).
  - _Requirements: 19.3, 19.4, 19.5, 19.12, 19.17_

- [x] 16.2 캔버스 렌더러와 애니메이션 루프 구현
  - `playRace(players, winner)`를 추가한다. `<canvas id="raceCv">` + `.race-wrap` + `.race-hud` 마크업을 `openGameOv`로 띄운다.
  - `.race-wrap` / `.race-hud` CSS를 게임 CSS 구역에 추가한다. `devicePixelRatio`를 곱해 실제 픽셀을 잡고 CSS로 폭에 맞춘다.
  - 코스 벽(사인 봉투)과 페그를 오프스크린 캔버스에 한 번만 그려 캐시한다.
  - 구슬은 `gcolor(i, n)` 색 원 + 흰 번호. 선두는 테두리로 강조한다.
  - 카메라가 선두 구슬 y를 따라가되 코스 끝을 넘지 않게 클램프한다.
  - HUD에 진행률 바와 상위 3명을 표시한다. 200ms마다 갱신한다.
  - 루프의 `dt`를 `Math.min(64, now-last)`로 상한을 둔다. 탭이 숨었다 돌아와도 한 번에 튀지 않는다.
  - `prefers-reduced-motion`이면 `DUR = 10`으로 연출을 사실상 생략한다.
  - _Requirements: 19.3, 19.6, 19.8, 19.9, 19.10, 19.11, 19.14_

- [x] 16.3 게임 등록·중단 처리·결과 흐름 연결
  - `startGame(kind)`에 `"race"` 분기를 추가하고, 당첨자는 `gamePickWinner(gamePlayers())`로 뽑는다. 확률 정책이 그대로 반영된다.
  - 게임 고르기 시트에 네 번째 `.game-pick` 버튼을 추가한다. 부제에 소요 시간을 넣는다: `다 같이 20초 · 제일 오래 즐겨요`.
  - `gameFits("race", ...)`로 인원 상한(24명) 초과 시 사유와 함께 비활성화한다.
  - `⏭ 건너뛰기` 버튼을 푸터에 추가한다. `cancelAnimationFrame` 후 결과를 즉시 표시한다.
  - `gameTeardown`에 `cancelAnimationFrame(raf)`을 등록한다. ✕·뒤로가기·`그만두기`·`건너뛰기` 모든 경로에서 예약된 프레임이 남지 않는지 확인한다.
  - `finish()`가 결승선 통과 상태를 마지막으로 그린 뒤 `showGameResult(winner)`를 부르게 한다. 이후 `한 판 더`·`확정하기` 흐름은 다른 게임과 동일해야 한다.
  - `한 판 더`가 코스를 새로 생성하는지, 참가자 명단·정책이 다른 세 게임과 연동되는지 확인한다.
  - 결과 표시 시점에 캔버스 `aria-label`을 "구슬 레이스 결과: OOO님"으로 갱신한다.
  - _Requirements: 19.1, 19.2, 19.4, 19.7, 19.12, 19.13, 19.15, 19.16_

- [x] 16.4 `QA-TESTCASES.md`에 구슬 레이스 케이스 추가
  - 레이스가 약 20초 만에 끝나는지, 결승선 1위가 결과 발표와 일치하는지 (R19-3, R19-4)
  - 진행 중 선두가 최소 3회 바뀌는 게 눈에 보이는지 (R19-5)
  - 화면이 선두를 따라 내려가고 선두 구슬이 항상 보이는지 (R19-10)
  - `건너뛰기`가 즉시 결과로 넘어가는지 (R19-7)
  - `prefers-reduced-motion`에서 연출이 생략되는지 (R19-8)
  - 레이스 도중 ✕·뒤로가기·`그만두기`로 나갔을 때 화면이 멈추고 배터리가 계속 소모되지 않는지 (R19-13)
  - 레이스 도중 앱을 백그라운드로 보냈다 돌아왔을 때 구슬이 튀지 않고 이어지는지 (R19-14)
  - 25명에서 구슬 레이스가 사유와 함께 비활성화되는지 (R19-12)
  - _Requirements: 19.3, 19.4, 19.5, 19.7, 19.8, 19.10, 19.12, 19.13, 19.14_

- [x] 17. 헤더 정리
  - 가장 마지막에 착수한다. 게임 작업과 겹치는 코드가 없으므로 순서만 뒤로 둔다.
  - _Requirements: 20.1, 20.2_

- [x] 17.1 헤더에서 `공유중 · 마지막 갱신` 표시 제거
  - `renderHeader()`의 `connHtml`에서 공유 모드 분기를 없앤다. `SHARED`면 아무것도 붙이지 않고, 아니면 `이 기기 전용` 경고만 남긴다.
  - 날짜 줄의 구분자를 조건부로 만든다. 붙을 항목이 없으면 `·`도 나오지 않아야 한다.
  - `syncAgoText()`와 `#syncAgo`를 갱신하는 10초 주기 `setInterval`(약 673~674행)을 제거한다.
  - `lastSyncAt`의 남은 참조를 전부 찾아본다. 표시 외에 쓰는 곳이 없으면 변수와 대입 지점까지 제거하고, 쓰는 곳이 있으면 남기고 그 이유를 보고한다.
  - `.dot` / `.dot.on` / `.dot.off` CSS(약 61~62행)의 남은 사용처를 확인하고, 없으면 제거한다.
  - 폴링 동기화(`startPolling`·`reload`)는 건드리지 않는다. 표시만 없애고 갱신 동작은 그대로 둔다.
  - `데모·공용` 배지와 `N번째 섬김` 배지가 그대로 남는지 확인한다.
  - 공유 모드와 이 기기 전용 모드 양쪽에서 헤더를 눈으로 확인한다.
  - _Requirements: 20.1, 20.2, 20.3, 20.4, 20.5, 20.6, 20.7, 20.8_

- [x] 17.2 `QA-TESTCASES.md`에 헤더 케이스 추가
  - 공유 모드에서 날짜 줄에 날짜만 보이고 `공유중`·점·`마지막 갱신`이 없는지 (R20-1)
  - 이 기기 전용 모드에서 `이 기기 전용` 경고가 여전히 보이는지 (R20-2)
  - 날짜 뒤에 떠 있는 `·`가 없는지 (R20-6)
  - 주문을 다른 기기에서 넣었을 때 폴링으로 화면이 여전히 갱신되는지 (R20-7)
  - _Requirements: 20.1, 20.2, 20.6, 20.7_
