// index.html 의 게임 순수 로직을 검증한다.
// 리포지토리에 빌드 단계도 패키지 매니저도 없어서, 모듈로 쪼개는 대신 마커로 감싼 구간만
// 떼어내 샌드박스에서 평가한다. 그래서 여기서는 Node 내장 모듈만 쓴다 — 의존성 0, 빌드 0.
// 실행: 리포지토리 루트에서 `node --test` (또는 `node --test 'tests/**/*.test.mjs'`).
// Node 22 이후로는 --test 뒤의 인자를 glob 으로 해석해서 `node --test tests/` 는 디렉터리 자체를
// 테스트 파일로 열려다 실패한다 — 디렉터리 대신 패턴을 주거나 인자를 생략한다.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const HTML_URL = new URL("../index.html", import.meta.url);
const HTML = readFileSync(HTML_URL, "utf8");

const MARK_START = "/* @test-export:start";
const MARK_END = "/* @test-export:end";

// 이 목록이 곧 프로덕션과의 계약이다. 함수 이름을 바꾸면 여기서 먼저 깨져야 한다.
const REQUIRED = [
  "pickWeighted",
  "rosterFrom",
  "playersFrom",
  "gcolor",
  "gameFits",
  "ladderGeometry",
  "GS_SOFT_W",
  "GAME_MAX",
  "wheelSpin",
  // 아래 둘은 두 번째 마커 블록(대시보드 기간)에 있다. 여기 적어두면 그 블록이 통째로
  // 사라졌을 때 "조용한 통과" 대신 심볼 누락으로 터진다.
  "weekBackDays",
  "q3Start",
];

// 실패 원인을 구분하기 위한 접두어. "마커가 지워져 테스트가 조용히 통과"하는 사고를 막는 게
// 이 파일의 첫 번째 임무라서, 네 가지 실패 모드가 서로 다른 메시지로 터져야 한다.
const ERR_NO_START = "추출 실패: 시작 마커";
const ERR_NO_END = "추출 실패: 종료 마커";
const ERR_EVAL = "평가 실패:";
const ERR_MISSING = "심볼 누락:";

// 마커 사이 소스를 떼어낸다.
//
// 주의: 시작 마커 뒤의 "첫 한 줄"을 통째로 버린다 — 마커 주석을 닫는 부분과 그 줄에 딸린
// 설명을 걷어내려는 것이다. 따라서 index.html 의 시작 마커 주석은 반드시 한 줄로 유지해야
// 한다. 여러 줄 주석으로 "정리"하면 두 번째 줄부터가 코드로 평가되어 문법 오류가 난다.
// 아래 "시작 마커는 한 줄이어야 한다" 테스트가 이를 지킨다.
//
// source 를 인자로 받는 이유는 실패 모드를 실제 파일을 망가뜨리지 않고 검증하기 위함이다.
//
// 블록은 여러 개일 수 있고, 파일에 나온 순서대로 이어 붙여 한 번에 평가한다. 한 블록만
// 읽으면 도메인이 다른 순수 함수(게임 · 대시보드 기간 …)가 전부 한 블록에 몰려 그 블록이
// 잡동사니 서랍이 되고, 함수가 유일한 호출부에서 수천 행 떨어진다. 이어 붙이므로 블록 간에
// 선언 이름이 겹치면 안 된다 — 겹치면 평가 단계에서 SyntaxError 로 터진다.
function extractBlock(source) {
  const parts = source.split(MARK_START);
  assert.ok(parts.length >= 2, `${ERR_NO_START} '${MARK_START}' 를 index.html 에서 찾을 수 없다`);
  return parts
    .slice(1)
    .map((seg, i) => {
      const body = seg.split(MARK_END);
      assert.ok(
        body.length >= 2,
        `${ERR_NO_END} '${MARK_END}' 를 index.html 에서 찾을 수 없다 (${i + 1}번째 블록)`
      );
      return body[0].replace(/^[^\n]*\n/, ""); // 마커 첫 줄 제거
    })
    .join("\n");
}

// 블록을 샌드박스에서 평가하고 기대 심볼을 꺼낸다.
//
// 블록 안의 선언은 const·function 이라 스크립트의 렉시컬 스코프에만 남고 컨텍스트의 전역
// 객체에는 붙지 않는다. 그래서 값을 걷어오는 코드까지 한 번의 실행에 함께 넣는다.
// 심볼별로 try/catch 를 두는 것은, 하나가 없을 때 ReferenceError 로 전체가 죽는 대신
// "무엇이 없는지"를 이름으로 보고하게 하려는 것이다.
// names 를 인자로 받는 이유: 16.1 이 구슬 레이스 함수들을 같은 블록에서 따로 꺼내 쓴다.
// 기본값이 REQUIRED 라서 기존 호출부와 기존 테스트의 동작은 그대로다.
function loadGameLogic(source = HTML, names = REQUIRED) {
  const src = extractBlock(source);
  const epilogue =
    "\n;(() => { const out = {}, missing = [];\n" +
    names.map((n) => {
      const q = JSON.stringify(n);
      return `try { if (typeof ${n} === "undefined") missing.push(${q}); else out[${q}] = ${n}; } catch (e) { missing.push(${q}); }`;
    }).join("\n") +
    "\nreturn { out, missing }; })()";

  let result;
  try {
    result = vm.runInContext(src + epilogue, vm.createContext({}), { filename: "index.html#test-export" });
  } catch (e) {
    throw new Error(`${ERR_EVAL} 마커 블록을 평가할 수 없다 — ${e.message}`, { cause: e });
  }
  assert.equal(
    result.missing.length,
    0,
    `${ERR_MISSING} 마커 블록에 ${result.missing.join(", ")} 가 없다`
  );
  return result.out;
}

// 모듈 스코프에서 한 번만 로드한다. 테스트마다 index.html 을 다시 파싱할 이유가 없고,
// 1.3 이 아래에 test() 를 덧붙일 때 그대로 쓸 수 있게 한다.
export const gameLogic = loadGameLogic();
export const { pickWeighted, rosterFrom, playersFrom, gcolor, gameFits, ladderGeometry, GS_SOFT_W, GAME_MAX } =
  gameLogic;

test("마커 블록에서 기대 심볼이 모두 나온다", () => {
  for (const name of REQUIRED) {
    assert.ok(name in gameLogic, `${name} 이(가) 마커 블록에서 추출되지 않았다`);
  }
  for (const name of ["pickWeighted", "rosterFrom", "playersFrom", "gcolor", "gameFits", "ladderGeometry"]) {
    assert.equal(typeof gameLogic[name], "function", `${name} 은(는) 함수여야 한다`);
  }
  assert.equal(typeof GS_SOFT_W, "number");
  assert.ok(GS_SOFT_W > 0, "GS_SOFT_W 가 0 이면 '평등하지 않을 뿐'이 아니라 완전 제외가 된다");
  assert.equal(typeof GAME_MAX, "object");
  for (const kind of ["ladder", "wheel", "finger"]) {
    assert.equal(typeof GAME_MAX[kind], "number", `GAME_MAX.${kind} 가 없다`);
  }
});

test("시작 마커는 (블록마다) 한 줄이어야 한다", () => {
  // 추출기가 마커 뒤 첫 줄을 버리므로, 시작 마커 주석이 그 줄에서 닫히지 않으면
  // 남은 설명 줄이 코드로 평가된다. 여러 줄로 흩어지는 순간 이 테스트가 잡는다.
  // 블록이 여러 개이므로 하나만 보지 않고 전부 본다.
  const lines = HTML.split("\n").filter((l) => l.includes(MARK_START));
  assert.ok(lines.length >= 1, "시작 마커가 있는 줄을 찾을 수 없다");
  for (const line of lines) {
    assert.ok(
      line.slice(line.indexOf(MARK_START) + MARK_START.length).includes("*/"),
      `시작 마커 주석이 같은 줄에서 닫히지 않았다 — 한 줄로 유지할 것: ${line.trim()}`
    );
  }
});

test("마커 블록이 둘 이상이고 시작·종료 개수가 맞는다", () => {
  // 블록을 하나로 되돌리는 변경이 조용히 들어오면 여기서 잡힌다. 개수가 어긋나면
  // 추출기가 엉뚱한 구간을 코드로 평가하므로 짝이 맞는지도 함께 본다.
  const starts = HTML.split(MARK_START).length - 1;
  const ends = HTML.split(MARK_END).length - 1;
  assert.ok(starts >= 2, `마커 블록이 ${starts}개다 — 게임과 대시보드 기간 두 벌이 있어야 한다`);
  assert.equal(ends, starts, `시작 마커 ${starts}개 · 종료 마커 ${ends}개 — 짝이 안 맞는다`);
});

// 아래 네 개는 "조용한 통과"를 막는 안전장치가 실제로 동작하는지 본다.
// 실제 index.html 은 건드리지 않고, 로더에 깨진 소스를 넣어 확인한다.
const wrap = (body) => `${MARK_START} */\n${body}\n${MARK_END} */\n`;

// 블록이 여러 개라 replace(첫 번째만) 로는 픽스처가 안 만들어진다 — 전부 지운다.
const dropAll = (s, needle) => s.split(needle).join("");

test("시작 마커가 없으면 실패한다", () => {
  const broken = dropAll(HTML, `${MARK_START} */`);
  assert.ok(!broken.includes(MARK_START), "테스트 픽스처가 시작 마커를 지우지 못했다");
  assert.throws(() => loadGameLogic(broken), new RegExp(ERR_NO_START));
});

test("종료 마커가 없으면 실패한다", () => {
  const broken = dropAll(HTML, `${MARK_END} */`);
  assert.ok(!broken.includes(MARK_END), "테스트 픽스처가 종료 마커를 지우지 못했다");
  assert.throws(() => loadGameLogic(broken), new RegExp(ERR_NO_END));
});

test("한 블록의 종료 마커만 사라져도 실패한다", () => {
  // 이어 붙이기로 바꾼 뒤 새로 생긴 실패 모드다. 마지막 블록의 종료 마커가 사라지면
  // 그 앞 블록들은 멀쩡하므로, 블록별로 확인하지 않으면 조용히 통과할 수 있다.
  const idx = HTML.lastIndexOf(`${MARK_END} */`);
  const broken = HTML.slice(0, idx) + HTML.slice(idx + `${MARK_END} */`.length);
  assert.throws(() => loadGameLogic(broken), new RegExp(ERR_NO_END));
});

test("블록이 평가되지 않으면 실패한다", () => {
  assert.throws(() => loadGameLogic(wrap("const x = ;")), new RegExp(ERR_EVAL)); // 문법 오류
  assert.throws(() => loadGameLogic(wrap("null.nope;")), new RegExp(ERR_EVAL)); // 실행 중 오류
});

test("심볼 하나가 빠지면 실패한다", () => {
  const partial = REQUIRED.filter((n) => n !== "pickWeighted")
    .map((n) => `const ${n} = 1;`)
    .join("\n");
  assert.throws(() => loadGameLogic(wrap(partial)), new RegExp(`${ERR_MISSING}.*pickWeighted`));
});

// ===================== 1.3 속성 기반 테스트 =====================
// **Validates: Requirements 2.2, 2.5, 3.5, 6.4, 6.5, 6.6, 6.7, 6.14, 6.15, 9.1, 9.2, 9.3, 10.1, 10.5, 10.6**
//
// PBT 라이브러리를 쓰지 않는다(의존성 0 원칙). 대신 시드를 고정한 PRNG 로 입력을 많이 만들고,
// 입력마다 불변식을 확인한다. 실패 메시지에는 항상 시드와 문제가 된 입력을 함께 싣는다 —
// 그게 없으면 "어쩌다 한 번 빨간불"이 되어 재현할 수가 없다.
//
// 난수를 쓰지만 시드가 고정이라 결과는 매 실행 동일하다. 확률 수렴 검증까지 결정론적이므로
// 이 파일에는 "20번 중 1번 깨지는 테스트"가 없다.

// mulberry32 — 32bit 상태 한 개짜리 PRNG. 짧고, 시드 하나로 완전히 재현되고,
// 분포가 균일해서 빈도 수렴 검증에 쓸 수 있다. 암호용이 아니지만 여기서는 그럴 필요가 없다.
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const ri = (rnd, lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1)); // [lo, hi] 정수
const pick = (rnd, arr) => arr[Math.floor(rnd() * arr.length)];
const mk = (n) => Array.from({ length: n }, (_, i) => ({ id: "m" + i, name: "이름" + i }));
const ids = (arr) => arr.map((m) => m.id);
const show = (v) => JSON.stringify(v);

// 실패 메시지 접두어. 어느 시드의 몇 번째 입력이었는지 없으면 재현이 불가능하다.
const at = (seed, iter, extra) => `seed=${seed} iter=${iter} ${extra}`;

// ---------- pickWeighted: 빈도가 가중치에 수렴한다 (R6-4, R6-5, R6-15) ----------
//
// 표본 수와 허용 오차 — 왜 이 숫자인가:
//   가장 까다로운 경우는 아래 케이스 중 확률이 가장 작은 것(n=8 soft, p=(1/3)/(7+1/3)≈0.0455)이다.
//   비율 추정치의 표준오차는 sqrt(p(1-p)/N) 이고 N=300000 에서 3.8e-4 — 기대값 대비 약 0.84% 다.
//   허용 오차를 상대 5% 로 두면 약 6σ 여유가 된다. 아래 케이스·시드 전체를 돌려본 실측
//   최대 편차는 1.05% 였다(허용치의 1/5).
//   반대쪽도 확인했다: soft 를 1/3 대신 1/2 로 잘못 구현하면 기대값에서 33~45% 벗어나
//   같은 허용 오차로 즉시 잡힌다. 즉 5% 는 잡음은 통과시키고 실제 오구현은 잡는 폭이다.
//   시드가 고정이므로 통과/실패는 매 실행 동일하다 — 여유를 두는 이유는 흔들림이 아니라
//   "우연히 통과하는 잘못된 가중치"를 막기 위해서다.
const SAMPLES = 300000;
const FREQ_TOL = 0.05; // 기대 비율 대비 상대 허용 오차
const FREQ_SEEDS = [1, 42, 20240115];

function frequencies(players, w, rnd, samples) {
  const cnt = new Map(players.map((p) => [p.id, 0]));
  for (let i = 0; i < samples; i++) {
    const got = pickWeighted(players, w, rnd);
    cnt.set(got.id, cnt.get(got.id) + 1);
  }
  return cnt;
}

test("pickWeighted — 선택 빈도가 가중치 비율에 수렴한다", () => {
  // n·가중치 조합을 몇 가지 고정해 둔다. 무작위 조합까지 돌리면 표본이 흩어져
  // 수렴 판정 자체가 헐거워진다 — 수렴은 정해진 조합으로 확인하고, 임의 입력은 아래 테스트가 본다.
  const cases = [
    { label: "even n=2", n: 2, w: [1, 1] },
    { label: "even n=6", n: 6, w: [1, 1, 1, 1, 1, 1] },
    { label: "soft n=2", n: 2, w: [GS_SOFT_W, 1] },
    { label: "soft n=6", n: 6, w: [GS_SOFT_W, 1, 1, 1, 1, 1] },
    { label: "치우친 가중치", n: 3, w: [5, 2, 1] },
  ];
  for (const seed of FREQ_SEEDS) {
    for (const c of cases) {
      const players = mk(c.n);
      const total = c.w.reduce((a, b) => a + b, 0);
      const cnt = frequencies(players, c.w, mulberry32(seed), SAMPLES);
      for (let i = 0; i < c.n; i++) {
        const exp = c.w[i] / total;
        const got = cnt.get(players[i].id) / SAMPLES;
        assert.ok(
          Math.abs(got - exp) <= exp * FREQ_TOL,
          at(seed, c.label, `${players[i].id} 빈도 ${got.toFixed(5)} 가 기대값 ${exp.toFixed(5)} 에서 상대 ${FREQ_TOL * 100}% 를 벗어났다 (w=${show(c.w)})`)
        );
      }
    }
  }
});

test("pickWeighted — soft 정책에서 직전 섬긴 분의 빈도가 (1/3)/(n-1+1/3) 에 수렴하고 0이 아니다", () => {
  // R6-4 는 "다른 참가자 한 명의 1/3", R6-5 는 "0이 아니다". 두 개를 한 자리에서 본다.
  // 0 이 아님은 허용 오차와 무관하게 따로 확인한다 — 확률을 0 으로 만들면 그건 '제외'라서
  // 정책이 세 개가 아니라 두 개가 되어버린다.
  for (const n of [2, 3, 5, 8]) {
    const players = mk(n);
    const w = [GS_SOFT_W, ...Array(n - 1).fill(1)]; // 0번이 직전 섬긴 분
    const expected = GS_SOFT_W / (n - 1 + GS_SOFT_W);
    for (const seed of FREQ_SEEDS) {
      const cnt = frequencies(players, w, mulberry32(seed), SAMPLES);
      const got = cnt.get(players[0].id) / SAMPLES;
      assert.ok(got > 0, at(seed, `n=${n}`, "soft 대상이 한 번도 뽑히지 않았다 — 이건 '확률 낮추기'가 아니라 '제외'다"));
      assert.ok(
        Math.abs(got - expected) <= expected * FREQ_TOL,
        at(seed, `n=${n}`, `soft 빈도 ${got.toFixed(5)} 가 기대값 ${expected.toFixed(5)} 에서 벗어났다`)
      );
      // 다른 한 명 대비 정확히 1/3 인지도 본다. 총합이 아니라 '한 명 대비'가 요구사항이다.
      const other = cnt.get(players[1].id) / SAMPLES;
      assert.ok(
        Math.abs(got / other - GS_SOFT_W) <= GS_SOFT_W * FREQ_TOL,
        at(seed, `n=${n}`, `soft/일반 비율 ${(got / other).toFixed(4)} 가 ${GS_SOFT_W} 에서 벗어났다`)
      );
    }
  }
});

test("pickWeighted — 임의의 players·w 조합에서 반환값이 항상 players 안에 있다", () => {
  // 부동소수 잔차 방어. 가중치 합이 아주 작거나 0 이거나, 몇 개가 0 이거나,
  // 크기가 극단적으로 섞여 있을 때 마지막 원소로 떨어지는 폴백이 실제로 동작해야 한다.
  const MAGS = [1e-12, 1e-6, 1, 1e6, 1e12];
  for (const seed of [7, 99, 12345]) {
    const rnd = mulberry32(seed);
    for (let iter = 0; iter < 3000; iter++) {
      const n = ri(rnd, 1, 12);
      const players = mk(n);
      const shape = ri(rnd, 0, 3);
      const w = Array.from({ length: n }, () => {
        if (shape === 0) return 1; // 평등
        if (shape === 1) return rnd() * pick(rnd, MAGS); // 크기 뒤섞기
        if (shape === 2) return rnd() < 0.5 ? 0 : rnd(); // 0 이 섞인 경우
        return Number.MIN_VALUE; // 합이 사실상 0
      });
      // 난수 스텁도 경계를 훑는다. 0 과 1 에 가까운 값에서 루프가 어떻게 끝나는지가 관심사다.
      const stub = pick(rnd, [() => 0, () => 1 - Number.EPSILON, () => 0.999999999999, rnd]);
      const got = pickWeighted(players, w, stub);
      assert.ok(
        players.includes(got),
        at(seed, iter, `반환값 ${show(got)} 이 players 밖이다 (n=${n}, w=${show(w)})`)
      );
    }
  }
});

// ---------- rosterFrom (R2-2, R2-5, R3-5) ----------
// on/off 는 Set 처럼 .has 만 쓰이고, orders 는 구성원 id 로 색인한 객체다.
function randomRoster(rnd) {
  const n = ri(rnd, 1, 20);
  const members = mk(n);
  const orders = {};
  for (const m of members) {
    const t = pick(rnd, ["drink", "skip", null, null]); // 무응답을 조금 더 자주 만든다
    if (t) orders[m.id] = { type: t };
  }
  const on = new Set(members.filter(() => rnd() < 0.3).map((m) => m.id));
  const off = new Set(members.filter(() => rnd() < 0.3).map((m) => m.id));
  return { members, orders, on, off };
}

test("rosterFrom — skip 인 사람은 어떤 조합에서도 포함되지 않는다", () => {
  for (const seed of [3, 77, 4242]) {
    const rnd = mulberry32(seed);
    for (let iter = 0; iter < 2000; iter++) {
      const { members, orders, on, off } = randomRoster(rnd);
      const got = rosterFrom(members, orders, on, off);
      for (const m of got) {
        assert.notEqual(
          orders[m.id] && orders[m.id].type,
          "skip",
          at(seed, iter, `'안 마심'인 ${m.id} 가 명단에 들어왔다 (on=${show([...on])}, off=${show([...off])})`)
        );
      }
    }
  }
});

test("rosterFrom — on 은 기본값을 덮고, off 는 항상 이긴다", () => {
  for (const seed of [11, 505, 987654]) {
    const rnd = mulberry32(seed);
    for (let iter = 0; iter < 2000; iter++) {
      const { members, orders, on, off } = randomRoster(rnd);
      const got = new Set(ids(rosterFrom(members, orders, on, off)));
      for (const m of members) {
        const skip = !!(orders[m.id] && orders[m.id].type === "skip");
        const drink = !!(orders[m.id] && orders[m.id].type === "drink");
        const ctx = at(seed, iter, `${m.id} (skip=${skip}, drink=${drink}, on=${on.has(m.id)}, off=${off.has(m.id)})`);
        if (skip || off.has(m.id)) {
          // skip 과 off 가 가장 강하다. on 과 겹쳐도 제외가 이긴다.
          assert.ok(!got.has(m.id), `${ctx} — 제외돼야 하는데 포함됐다`);
        } else if (on.has(m.id)) {
          // 무응답이어도 사용자가 켰으면 들어간다 (R2-4).
          assert.ok(got.has(m.id), `${ctx} — on 인데 빠졌다`);
        } else {
          // 명시적 선택이 없으면 기본값 = 음료 주문자.
          assert.equal(got.has(m.id), drink, `${ctx} — 기본값(음료 주문자)과 다르다`);
        }
      }
    }
  }
});

// ---------- playersFrom (R6-6, R6-7) ----------
test("playersFrom — skip 정책은 직전 섬긴 분을 빼고, soft·even 은 남긴다", () => {
  for (const seed of [13, 606, 31337]) {
    const rnd = mulberry32(seed);
    for (let iter = 0; iter < 2000; iter++) {
      const roster = mk(ri(rnd, 1, 12));
      // lastHostId 는 세 상태를 갖는다: 명단 안의 누군가 / 명단에 없는 id / null(없음).
      const lastHostId = pick(rnd, [...ids(roster), "없는사람", null]);
      const policy = pick(rnd, ["skip", "soft", "even"]);
      const got = playersFrom(roster, policy, lastHostId);
      const ctx = at(seed, iter, `policy=${policy} lastHostId=${show(lastHostId)} roster=${show(ids(roster))}`);
      if (policy === "skip" && lastHostId) {
        assert.ok(!ids(got).includes(lastHostId), `${ctx} — skip 인데 직전 섬긴 분이 남았다`);
        // 그 한 명 말고는 아무도 사라지지 않아야 한다.
        const removed = ids(roster).filter((id) => !ids(got).includes(id));
        assert.deepEqual(removed, ids(roster).includes(lastHostId) ? [lastHostId] : [], `${ctx} — 엉뚱한 사람이 빠졌다`);
      } else {
        assert.deepEqual(ids(got), ids(roster), `${ctx} — soft·even 은 명단을 줄이지 않아야 한다`);
      }
    }
  }
});

// ---------- gcolor (R9-1 ~ R9-3) ----------
// 분기가 둘이고 성질이 다르다.
//   n <= 10  : 고정 팔레트를 그대로 쓴다. 팔레트 색은 골든앵글로 배치된 게 아니라 손으로 고른
//              값이므로 색상(hue) 간격은 규칙이 없다 — 여기서는 '서로 다름'만 본다.
//   n > 10   : hsl 로 생성한다. 이때만 인접 인덱스의 색상차를 확인할 수 있다.
const HUE_MIN_ADJ = 137; // 골든앵글 137.508° 의 원형 거리. toFixed(1) 반올림 여유로 137 로 둔다.

const hueOf = (css) => {
  const m = /^hsl\(\s*([\d.]+)/.exec(css);
  assert.ok(m, `hsl 형식이 아니다: ${css}`);
  return Number(m[1]);
};
const hueGap = (a, b) => {
  const d = Math.abs(a - b) % 360;
  return Math.min(d, 360 - d);
};

test("gcolor — n 이 2..60 일 때 색 n 개가 모두 서로 다르다", () => {
  for (let n = 2; n <= 60; n++) {
    const cols = Array.from({ length: n }, (_, i) => gcolor(i, n));
    const uniq = new Set(cols);
    assert.equal(uniq.size, n, `n=${n} 에서 색이 겹쳤다: ${show(cols)}`);
  }
});

test("gcolor — n > 10 에서만 인접 인덱스의 색상차가 임계값 이상이다", () => {
  // 돌림판의 이웃 조각이 같은 색이 되는 것을 막는 게 목적이라, 관심은 '인접 인덱스'다.
  for (let n = 11; n <= 60; n++) {
    const hues = Array.from({ length: n }, (_, i) => hueOf(gcolor(i, n)));
    for (let i = 0; i + 1 < n; i++) {
      const gap = hueGap(hues[i], hues[i + 1]);
      assert.ok(
        gap >= HUE_MIN_ADJ,
        `n=${n} i=${i} 색상차 ${gap.toFixed(2)}° 가 ${HUE_MIN_ADJ}° 미만이다 (${hues[i]} vs ${hues[i + 1]})`
      );
    }
    // 돌림판은 원형이라 마지막 조각과 첫 조각도 이웃이다. 골든앵글은 이쪽을 보장하지 않으므로
    // 같은 색만 아니면 된다 — 요구사항(R9-2)이 요구하는 것도 '같은 색이 아님'이다.
    assert.ok(hueGap(hues[n - 1], hues[0]) > 0, `n=${n} 에서 마지막·첫 조각의 색상이 같다`);
  }
});

// ---------- ladderGeometry (R10-1, R10-6) ----------
// 불변식은 GAP >= 18 && BOX_W >= 14 다. 상한이 실제 한계와 맞는지 역검증까지 한다.
const LADDER_OK = (g) => g.GAP >= 18 && g.BOX_W >= 14;
const LADDER_FIRST_BREAK = 18; // 처음 깨지는 지점. n=18 은 GAP 17.18 로 미달이다.

test("ladderGeometry — n 이 2..GAME_MAX.ladder 일 때 GAP >= 18, BOX_W >= 14", () => {
  for (let n = 2; n <= GAME_MAX.ladder; n++) {
    const g = ladderGeometry(n);
    assert.ok(LADDER_OK(g), `n=${n} 에서 치수가 무너졌다: ${show(g)}`);
  }
});

test("ladderGeometry — 불변식이 처음 깨지는 지점이 n=18 이고, 상한 16 은 한 줄치 여유다", () => {
  // 상한을 바꾸면 이 테스트가 관계를 설명하며 깨져야 한다. 그래서 16 을 다시 적지 않고
  // GAME_MAX.ladder 에서 끌어온다.
  assert.ok(
    GAME_MAX.ladder < LADDER_FIRST_BREAK,
    `상한 ${GAME_MAX.ladder} 가 한계 ${LADDER_FIRST_BREAK} 이상이다 — 화면이 깨지는 인원을 허용하고 있다`
  );
  for (let n = 2; n < LADDER_FIRST_BREAK; n++) {
    assert.ok(LADDER_OK(ladderGeometry(n)), `n=${n} 은 아직 들어가야 한다: ${show(ladderGeometry(n))}`);
  }
  const broken = ladderGeometry(LADDER_FIRST_BREAK);
  assert.ok(
    !LADDER_OK(broken),
    `n=${LADDER_FIRST_BREAK} 에서 불변식이 깨져야 한다 — 깨지지 않으면 상한을 올릴 수 있다는 뜻이다: ${show(broken)}`
  );
  // 상한과 한계 사이의 여유가 정확히 한 줄인지도 남겨둔다. 17 명은 아직 들어가지만 상한에서 빠져 있다.
  const headroom = LADDER_FIRST_BREAK - 1 - GAME_MAX.ladder;
  assert.equal(headroom, 1, `상한과 한계 사이 여유가 ${headroom} 이다 — 설계는 한 줄치(1)를 의도했다`);
});

// ---------- 경계값 ----------
test("경계값 — n=2 에서 사다리·돌림판·손가락 룰렛이 모두 가능하다 (R10-5)", () => {
  for (const kind of ["ladder", "wheel", "finger"]) {
    assert.ok(gameFits(kind, 2), `${kind} 가 2명에서 막혔다`);
  }
  const g = ladderGeometry(2);
  assert.ok(LADDER_OK(g), `n=2 사다리 치수: ${show(g)}`);
  assert.notEqual(gcolor(0, 2), gcolor(1, 2), "2명인데 두 색이 같다");
});

test("경계값 — n=10/11 이 색 생성 방식의 전환 지점이다", () => {
  // 10 이하는 팔레트(hex), 11 이상은 hsl. 이 경계가 흔들리면 8.1 의 호출부 수정이 무의미해진다.
  for (let i = 0; i < 10; i++) assert.match(gcolor(i, 10), /^#[0-9a-f]{6}$/i, `n=10 i=${i} 는 팔레트여야 한다`);
  for (let i = 0; i < 11; i++) assert.match(gcolor(i, 11), /^hsl\(/, `n=11 i=${i} 는 hsl 이어야 한다`);
  // n 을 넘기지 않으면 예전처럼 팔레트를 순환한다 — 아직 고쳐지지 않은 호출부(playFinger)가 여기에 의존한다.
  assert.equal(gcolor(10), gcolor(0), "n 없이 부르면 팔레트를 순환해야 한다");
  // hsl 분기의 색상은 i 에만 의존한다 — 인원이 한 명 늘어도 기존 참가자의 색이 바뀌지 않는다.
  for (let i = 0; i < 11; i++) assert.equal(gcolor(i, 11), gcolor(i, 12), `i=${i} 의 색이 n 에 따라 흔들린다`);
});

test("경계값 — 사다리 16/17/18, 돌림판 24/25 (R10-6)", () => {
  assert.ok(gameFits("ladder", GAME_MAX.ladder), "상한값에서 사다리가 막히면 안 된다");
  assert.ok(!gameFits("ladder", GAME_MAX.ladder + 1), "상한+1 에서 사다리는 막혀야 한다");
  assert.ok(gameFits("wheel", GAME_MAX.wheel), "상한값에서 돌림판이 막히면 안 된다");
  assert.ok(!gameFits("wheel", GAME_MAX.wheel + 1), "상한+1 에서 돌림판은 막혀야 한다");
  assert.equal(GAME_MAX.wheel, 24, "돌림판 상한은 24 로 정해져 있다");
  // 17 명은 치수로는 들어가지만 상한에서 빠져 있다. 상한이 계산이 아니라 결정이라는 뜻이다.
  assert.ok(LADDER_OK(ladderGeometry(17)), `17명 치수는 아직 성립한다: ${show(ladderGeometry(17))}`);
  assert.ok(!gameFits("ladder", 17), "17명은 상한 밖이다");
  // 손가락 룰렛은 상한이 없다 — 세 게임이 동시에 막히는 상황은 없어야 한다.
  assert.ok(gameFits("finger", 999), "손가락 룰렛은 인원 상한이 없다");
});

test("경계값 — skip 정책 적용 후 참가자가 1명이 될 수 있다 (R6-14)", () => {
  // 순수 함수는 막지 않는다. 2명 미만이면 시작하지 않는 판단은 호출부(5.1)의 몫이라,
  // 여기서는 '1명이 된다'는 사실만 고정해 둔다. 이 값이 호출부 방어의 입력이다.
  const roster = mk(2);
  const left = playersFrom(roster, "skip", roster[0].id);
  assert.equal(left.length, 1, "2명 중 직전 섬긴 분을 빼면 1명이 남는다");
  assert.equal(left[0].id, roster[1].id);
  assert.ok(left.length < 2, "1명으로는 게임을 돌릴 수 없다 — 호출부가 막아야 한다");
  // soft·even 이면 2명이 그대로 남아 게임이 가능하다.
  assert.equal(playersFrom(roster, "soft", roster[0].id).length, 2);
  assert.equal(playersFrom(roster, "even", roster[0].id).length, 2);
});

// ===================== 16.1 구슬 레이스 순수 함수 =====================
// **Validates: Requirements 19.3, 19.4, 19.5, 19.12, 19.17**
//
// R19-17 이 요구하는 것은 "당첨자가 항상 1위인지, 역전이 최소 3회인지 검증 가능하다"다.
// 그래서 이 구역은 전부 시드 고정 PRNG(위 mulberry32)로 돌아간다 — Math.random 이 한 번이라도
// 끼면 "가끔 2등이 이긴다"를 재현할 수 없고, 그 재현 불가능이 곧 R19-4 위반의 은폐다.

const RACE_REQUIRED = [
  "raceCourse",
  "raceXY",
  "raceSpeeds",
  "raceSchedule",
  "raceProgress",
  "raceLeadChanges",
  "RACE_F_LO",
  "RACE_F_HI",
];

export const raceLogic = loadGameLogic(HTML, RACE_REQUIRED);
const { raceCourse, raceXY, raceSpeeds, raceSchedule, raceProgress, raceLeadChanges, RACE_F_LO, RACE_F_HI } =
  raceLogic;

// 테스트 안에서만 쓰는 duration 이다. 앱의 RACE_DUR 은 25000 이지만(1위 도착이 duration*0.80 이라
// 화면에서 보이는 레이스가 약 20초가 되는 값), 아래 판정이 전부 duration 에 대한 비율이라 값이
// 달라도 결과가 같다 — 그래서 읽기 쉬운 20000 하나로 고정한다.
const RACE_DUR = 20000;
const RACE_N_MAX = 24; // GAME_MAX.race 와 같아야 한다 — 아래 경계값 테스트가 그 일치를 본다

// 16.3 의 호출부를 그대로 흉내낸다: 코스 → 속도 → order([당첨자, ...섞은 나머지]) → 스케줄.
// order 를 여기서 섞는 게 중요하다. 당첨자 인덱스가 늘 0 이면 "인덱스 0 이 1위"라는 우연한
// 구현으로도 통과해버린다.
function raceBuild(rnd, n) {
  const course = raceCourse(rnd);
  const speeds = raceSpeeds(n, course.segs.length, rnd);
  const order = Array.from({ length: n }, (_, i) => i);
  for (let i = n - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    const t = order[i];
    order[i] = order[j];
    order[j] = t;
  }
  const sched = raceSchedule(course, speeds, order, RACE_DUR, rnd);
  return { course, speeds, order, sched, n };
}

// 인접 등수 사이 도착 시간 간격의 이론적 하한. 지터 폭을 간격의 0.9 배로 묶어두었으므로
// 최소 0.1 배가 남는다. 이 식이 무너지면(=지터가 간격보다 넓어지면) 순서가 뒤집힌다.
const raceMinGapMs = (n) => (n <= 1 ? RACE_DUR : RACE_DUR * ((RACE_F_HI - RACE_F_LO) / (n - 1)) * 0.095);

test("구슬 레이스 — 마커 블록에서 순수 함수가 모두 나온다", () => {
  for (const name of RACE_REQUIRED) assert.ok(name in raceLogic, `${name} 이(가) 추출되지 않았다`);
  for (const name of ["raceCourse", "raceXY", "raceSpeeds", "raceSchedule", "raceProgress", "raceLeadChanges"]) {
    assert.equal(typeof raceLogic[name], "function", `${name} 은(는) 함수여야 한다`);
  }
  // 코스는 인원과 무관하게 같은 길이여야 한다 — 도착 시간 배분이 인원에 따라 흔들리지 않게 하는 전제다.
  const a = raceCourse(mulberry32(1)),
    b = raceCourse(mulberry32(2));
  assert.equal(a.total, b.total, "코스 총 길이가 시드에 따라 달라졌다");
  assert.equal(a.W / 2, a.CX, "CX 가 W/2 가 아니다");
  assert.ok(a.segs.length >= 8, `구간이 ${a.segs.length} 개면 역전을 넣을 자리가 부족하다`);
  const sp = raceSpeeds(3, a.segs.length, mulberry32(9));
  assert.equal(sp.length, 3);
  assert.equal(sp[0].length, a.segs.length, "구슬마다 구간 수만큼의 속도가 있어야 한다");
  for (const row of sp) for (const v of row) assert.ok(v > 0, `속도 ${v} 가 0 이하다 — 구간 시간이 무한이 된다`);
});

test("raceSchedule — order[0] 의 도착 시간이 항상 최소다 (R19-4, R19-17)", () => {
  // 여기가 R19-4 의 전부다. '거의 항상'은 통과가 아니다.
  // 부록 A.3 원안은 지터 폭이 고정 0.015 였고, 인접 등수 간격은 0.20/(n-1) 이라 n=24 에서 0.0087 —
  // 지터가 간격보다 넓어 2등이 1등을 앞지르는 배분이 실제로 나왔다. 구현은 지터 폭을 간격의
  // 0.9 배로 묶어 그 구멍을 막았고, 이 테스트가 그 보장을 지킨다.
  let checked = 0;
  let minMargin = Infinity;
  let worst = null;
  for (const seed of [1, 42, 1337, 20240115, 987654321]) {
    const rnd = mulberry32(seed);
    for (let round = 0; round < 8; round++) {
      for (let n = 2; n <= RACE_N_MAX; n++) {
        const b = raceBuild(rnd, n);
        const w = b.sched.want;
        const wi = b.order[0];
        const others = w.filter((_, i) => i !== wi);
        const runnerUp = Math.min(...others);
        const ctx = at(seed, `round=${round} n=${n}`, `want=${show(w.map((v) => +(v / RACE_DUR).toFixed(5)))} order=${show(b.order)}`);
        assert.ok(w[wi] < runnerUp, `${ctx} — 당첨자(idx=${wi})가 1위가 아니다`);
        // 등수 순서 전체가 order 와 일치하는지도 본다. 1위만 맞고 중간이 뒤섞이면
        // 순위 표시(HUD)와 도착 순서가 어긋난다.
        for (let r = 1; r < n; r++) {
          assert.ok(
            w[b.order[r - 1]] < w[b.order[r]],
            `${ctx} — ${r}등(idx=${b.order[r]})이 ${r - 1}등(idx=${b.order[r - 1]})보다 먼저 도착한다`
          );
        }
        const margin = runnerUp - w[wi];
        assert.ok(
          margin >= raceMinGapMs(n),
          `${ctx} — 1·2위 간격 ${margin.toFixed(2)}ms 가 하한 ${raceMinGapMs(n).toFixed(2)}ms 미만이다`
        );
        if (margin < minMargin) {
          minMargin = margin;
          worst = `n=${n} seed=${seed}`;
        }
        checked++;
      }
    }
  }
  assert.ok(checked >= 900, `표본이 ${checked} 개면 부족하다`);
  assert.ok(minMargin > 0, `최소 간격이 ${minMargin} 이다 (${worst})`);
});

test("raceSchedule — 모든 도착 시간이 duration*0.75 이상 duration 이하다 (R19-3)", () => {
  // 아래로 벗어나면 레이스가 너무 빨리 끝나고, 위로 벗어나면 duration 안에 못 들어오는 구슬이 생긴다.
  // 부록 A.3 원안은 꼴찌를 1.00 에 두고 지터를 얹어 최대 1.0075 — duration 을 넘겼다. 상한을 0.99 로
  // 내려 지터를 포함해도 항상 duration 안이다.
  let lo = Infinity,
    hi = -Infinity;
  for (const seed of [2, 77, 31337, 5150]) {
    const rnd = mulberry32(seed);
    for (let round = 0; round < 6; round++) {
      for (let n = 2; n <= RACE_N_MAX; n++) {
        const b = raceBuild(rnd, n);
        for (let i = 0; i < n; i++) {
          const f = b.sched.want[i] / RACE_DUR;
          assert.ok(
            f >= 0.75 && f <= 1,
            at(seed, `round=${round} n=${n}`, `구슬 ${i} 도착 시간 비율 ${f.toFixed(6)} 가 [0.75, 1] 밖이다`)
          );
          if (f < lo) lo = f;
          if (f > hi) hi = f;
        }
      }
    }
  }
  // 실측 범위가 경계에 붙어 있지 않은지도 남긴다. 여유가 사라지면 다음 파라미터 변경에서 터진다.
  assert.ok(lo > 0.78, `최소 비율 ${lo.toFixed(6)} 가 0.75 경계에 너무 가깝다`);
  assert.ok(hi < 0.999, `최대 비율 ${hi.toFixed(6)} 가 duration 에 너무 가깝다`);
});

test("raceProgress — t=0 에서 0, 도착 이후 정확히 1, 그 사이 단조 증가다", () => {
  const STEPS = 400;
  for (const seed of [3, 101, 424242]) {
    const rnd = mulberry32(seed);
    for (let round = 0; round < 4; round++) {
      for (const n of [2, 5, 13, RACE_N_MAX]) {
        const b = raceBuild(rnd, n);
        for (let i = 0; i < n; i++) {
          const arrive = b.sched.want[i];
          const ctx = at(seed, `round=${round} n=${n} i=${i}`, `arrive=${arrive.toFixed(2)}`);
          assert.equal(raceProgress(b.course, b.sched, i, 0), 0, `${ctx} — t=0 에서 0 이 아니다`);
          // 음수 t 와 NaN 도 0 으로 잠근다. 프레임 dt 계산이 어긋나도 구슬이 뒤로 가지 않아야 한다.
          assert.equal(raceProgress(b.course, b.sched, i, -1), 0, `${ctx} — t<0 에서 0 이 아니다`);
          assert.equal(raceProgress(b.course, b.sched, i, NaN), 0, `${ctx} — t=NaN 에서 0 이 아니다`);
          // 도착 시각 '정확히 그 순간'에 1 이어야 한다. 16.2 의 종료 판정이 want 를 보기 때문에,
          // 여기서 1 에 못 미치면 결승선 앞에서 레이스가 끝나는 그림이 된다.
          assert.equal(raceProgress(b.course, b.sched, i, arrive), 1, `${ctx} — 도착 시각에 1 이 아니다`);
          assert.equal(raceProgress(b.course, b.sched, i, arrive * 1.5), 1, `${ctx} — 도착 이후 1 이 아니다`);
          assert.equal(raceProgress(b.course, b.sched, i, RACE_DUR * 10), 1, `${ctx} — 한참 뒤에도 1 이 아니다`);
          let prev = 0;
          for (let k = 1; k < STEPS; k++) {
            const p = raceProgress(b.course, b.sched, i, (arrive * k) / STEPS);
            assert.ok(p >= prev, `${ctx} — t 가 커졌는데 진행률이 ${prev} → ${p} 로 줄었다`);
            assert.ok(p > prev, `${ctx} — k=${k} 에서 진행률이 ${p} 로 멈췄다 (구슬이 서 있다)`);
            assert.ok(p < 1, `${ctx} — 도착 전인데 진행률이 ${p} 다`);
            prev = p;
          }
        }
      }
    }
  }
});

test("raceXY — 임의의 p 에서 x 가 [0, W] 안이고 벽까지 여유가 남는다", () => {
  // 목적은 '구슬이 코스 밖으로 나가지 않는지'다. 진폭 상한이 40+70=110, CX=170 이라 x 는
  // (60, 280) 안이고 좌우로 60px 이 남는다 — 반지름 10px 짜리 구슬과 벽선을 그려도 넉넉하다.
  const MARGIN = 30; // 렌더러가 반지름·벽선에 쓸 수 있는 최소 여유
  let xmin = Infinity,
    xmax = -Infinity;
  for (const seed of [4, 555, 8675309]) {
    const rnd = mulberry32(seed);
    for (let round = 0; round < 30; round++) {
      const course = raceCourse(rnd);
      let prevY = -1;
      for (let k = 0; k <= 500; k++) {
        const p = k / 500;
        const { x, y } = raceXY(course, p);
        const ctx = at(seed, `round=${round} p=${p.toFixed(3)}`, `x=${x.toFixed(3)} y=${y.toFixed(3)}`);
        assert.ok(x >= 0 && x <= course.W, `${ctx} — x 가 [0, ${course.W}] 밖이다`);
        assert.ok(x >= MARGIN && x <= course.W - MARGIN, `${ctx} — 벽까지 여유가 ${MARGIN}px 미만이다`);
        assert.ok(y >= 0 && y <= course.total, `${ctx} — y 가 [0, ${course.total}] 밖이다`);
        assert.ok(y >= prevY, `${ctx} — p 가 커졌는데 y 가 줄었다`);
        prevY = y;
        if (x < xmin) xmin = x;
        if (x > xmax) xmax = x;
      }
      // p 를 벗어난 값으로 불러도 코스 안에 머문다 — 카메라·마지막 프레임 계산이 1 을 살짝 넘길 수 있다.
      for (const p of [-1, 0, 1, 1.5]) {
        const { x, y } = raceXY(course, p);
        assert.ok(x >= 0 && x <= course.W, `p=${p} 에서 x=${x} 가 코스 밖이다`);
        assert.ok(y >= 0 && y <= course.total, `p=${p} 에서 y=${y} 가 코스 밖이다`);
      }
    }
  }
  assert.ok(xmin > 0 && xmax < 340, `실측 x 범위 ${xmin.toFixed(2)}~${xmax.toFixed(2)} 가 코스를 벗어났다`);
});

test("raceLeadChanges — 재생성 루프를 통과한 코스는 3 이상, 루프 없이는 3 미만이 나온다 (R19-5, R19-17)", () => {
  const GATE = 3; // R19-5 의 '최소 3회'
  const TRIES = 40; // 16.3 재생성 루프의 시도 횟수
  // (1) 루프가 죽은 코드가 아님 — 그냥 생성하면 3 미만이 실제로 나온다.
  //     여기서 0 이 나오면 게이트가 무의미하다는 뜻이라 16.3 의 루프를 지워야 한다.
  let below = 0,
    total = 0;
  let firstBelow = null;
  for (const seed of [5, 35, 909, 1234567]) {
    const rnd = mulberry32(seed);
    for (let round = 0; round < 10; round++) {
      for (const n of [2, 3, 6, 12, RACE_N_MAX]) {
        const b = raceBuild(rnd, n);
        const c = raceLeadChanges(b.course, b.sched, n, RACE_DUR, 120);
        assert.ok(Number.isInteger(c) && c >= 0, `역전 횟수 ${c} 가 음수거나 정수가 아니다`);
        if (c < GATE) {
          below++;
          if (!firstBelow) firstBelow = `seed=${seed} round=${round} n=${n} changes=${c}`;
        }
        total++;
      }
    }
  }
  assert.ok(below > 0, `${total} 개 표본에서 역전 ${GATE} 회 미만이 한 번도 안 나왔다 — 재생성 루프가 죽은 코드다`);
  assert.ok(below < total, `${total} 개 표본이 전부 ${GATE} 회 미만이다 — 루프가 통과할 코스를 못 찾는다`);

  // (2) 재생성 루프를 통과한 코스는 반드시 3 이상 — 16.3 이 쓸 판정이 실제로 성립하는지.
  //     n>=3 은 40 회 안에 항상 찾는다(실측 실패 0%). n=2 는 두 구슬이 네 번 교차해야 해서
  //     구조적으로 어렵고 40 회를 다 써도 못 찾는 경우가 약 13% 있다 — 그래서 n=2 는
  //     '적어도 찾아지기는 한다'만 확인하고, 못 찾았을 때의 처리는 16.3 의 몫으로 남긴다.
  let twoFound = 0,
    twoTried = 0;
  for (const seed of [6, 6060, 77777]) {
    const rnd = mulberry32(seed);
    for (const n of [2, 3, 4, 8, 16, RACE_N_MAX]) {
      let accepted = null;
      for (let t = 0; t < TRIES; t++) {
        const b = raceBuild(rnd, n);
        if (raceLeadChanges(b.course, b.sched, n, RACE_DUR, 120) >= GATE) {
          accepted = b;
          break;
        }
      }
      if (n === 2) {
        twoTried++;
        if (accepted) twoFound++;
      } else {
        assert.ok(accepted, at(seed, `n=${n}`, `${TRIES} 회 안에 역전 ${GATE} 회 이상인 코스를 못 만들었다`));
      }
      if (accepted) {
        const c = raceLeadChanges(accepted.course, accepted.sched, n, RACE_DUR, 120);
        assert.ok(c >= GATE, at(seed, `n=${n}`, `통과했다는 코스의 역전이 ${c} 회다`));
        // 통과한 코스에서도 1위는 당첨자여야 한다 — 재생성이 R19-4 를 깨지 않는지.
        const wi = accepted.order[0];
        assert.equal(
          accepted.sched.want.indexOf(Math.min(...accepted.sched.want)),
          wi,
          at(seed, `n=${n}`, "재생성된 스케줄에서 당첨자가 1위가 아니다")
        );
      }
    }
  }
  assert.ok(twoFound > 0, `n=2 에서 ${twoTried} 번 시도해 한 번도 역전 ${GATE} 회를 못 만들었다`);

  // samples 를 생략하면 120 이 기본값이다 — 16.3 이 인자를 빼먹어도 같은 판정을 받아야 한다.
  const b = raceBuild(mulberry32(31), 8);
  assert.equal(
    raceLeadChanges(b.course, b.sched, 8, RACE_DUR),
    raceLeadChanges(b.course, b.sched, 8, RACE_DUR, 120),
    "samples 기본값이 120 이 아니다"
  );
});

test("경계값 — 구슬 레이스 24/25 (R19-12)", () => {
  assert.equal(GAME_MAX.race, 24, "구슬 레이스 상한은 24 로 정해져 있다");
  assert.ok(gameFits("race", GAME_MAX.race), "상한값에서 구슬 레이스가 막히면 안 된다");
  assert.ok(!gameFits("race", GAME_MAX.race + 1), "상한+1 에서 구슬 레이스는 막혀야 한다");
  assert.ok(gameFits("race", 2), "2명에서 구슬 레이스가 막혔다");
  assert.equal(RACE_N_MAX, GAME_MAX.race, "테스트가 상한과 다른 인원까지만 검증하고 있다");
  // 상한이 돌림판과 같은 이유: 색·번호 구분이 한계이고, 구슬 지름 기준은 그보다 여유가 있다.
  assert.equal(GAME_MAX.race, GAME_MAX.wheel, "구슬 레이스 상한은 돌림판과 같은 근거(색 구분)를 쓴다");
});

// ===================== 대시보드 기간 프리셋 (R1, R2) =====================
// 달·해 경계에서 틀리기 쉬운 산수라 경계를 직접 짚는다. 계산은 'YYYY-MM-DD' 문자열과 UTC
// Date 로만 이뤄지므로 로컬 시간대와 무관하게 결과가 같다 (R1-5).
const { weekBackDays, q3Start } = gameLogic;

const ymd = (y, m, d) =>
  `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
const shiftDate = (ds, n) => {
  const d = new Date(ds + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const dow = (ds) => new Date(ds + "T00:00:00Z").getUTCDay(); // 0=일 … 1=월

test("weekBackDays — 월~일 7일 전부에서 0~6 이 나온다 (R1-1, R1-3, R1-4)", () => {
  // 2026-08-03 은 월요일이다. 거기서 하루씩 밀며 월→0 … 일→6 을 확인한다.
  const mon = "2026-08-03";
  assert.equal(dow(mon), 1, "픽스처가 월요일이 아니다");
  for (let i = 0; i < 7; i++) {
    const day = shiftDate(mon, i);
    assert.equal(weekBackDays(day), i, `${day}(요일 ${dow(day)}) 의 되돌릴 일수가 ${i} 가 아니다`);
  }
  assert.equal(weekBackDays(mon), 0, "월요일이면 되돌릴 일수가 0 이라 시작=종료다 (R1-3)");
  assert.equal(weekBackDays(shiftDate(mon, 6)), 6, "일요일이면 6 이라 범위가 7일이다 (R1-4)");
});

test("weekBackDays — 임의의 날짜에서 시작일이 항상 월요일이다 (R1-1)", () => {
  // 2년치를 전부 밟는다. 윤년(2028)과 연·월 경계가 그 안에 다 들어온다.
  let ds = "2026-01-01";
  for (let i = 0; i < 730; i++) {
    const from = shiftDate(ds, -weekBackDays(ds));
    assert.equal(dow(from), 1, `${ds} → 시작일 ${from} 이 월요일이 아니다`);
    assert.ok(from <= ds, `${ds} → 시작일 ${from} 이 미래다`);
    ds = shiftDate(ds, 1);
  }
});

test("weekBackDays — 범위 길이가 1~7일이라 31일 상한에 안 걸린다 (R1-10)", () => {
  let ds = "2026-01-01";
  for (let i = 0; i < 400; i++) {
    const span = weekBackDays(ds) + 1; // from~to 양끝 포함
    assert.ok(span >= 1 && span <= 7, `${ds} 의 범위 길이가 ${span} 일이다`);
    ds = shiftDate(ds, 1);
  }
});

// vm 샌드박스가 만든 배열은 다른 realm 의 Array 라서 deepStrictEqual 이 프로토타입에서
// 걸린다(값은 같은데 실패한다). 값만 비교한다.
const ym = (pair) => `${pair[0]}-${pair[1]}`;

test("q3Start — 1월·2월은 전년으로 넘어간다 (R2-1 ~ R2-4)", () => {
  assert.equal(ym(q3Start(2026, 1)), "2025-11", "1월 → (y-1)-11 (R2-2)");
  assert.equal(ym(q3Start(2026, 2)), "2025-12", "2월 → (y-1)-12 (R2-3)");
  for (let m = 3; m <= 12; m++) {
    assert.equal(ym(q3Start(2026, m)), `2026-${m - 2}`, `${m}월 → y-(m-2) (R2-4)`);
  }
  // 연도가 바뀌어도 같은 규칙이다 — 2026 한 해에만 맞는 산수가 아닌지 확인한다.
  assert.equal(ym(q3Start(2030, 1)), "2029-11");
  assert.equal(ym(q3Start(2030, 2)), "2029-12");
});

test("q3Start — 시작일은 항상 1일이고 길이는 92일 이하다 (R2-5, R2-6)", () => {
  // 366일 상한(v_from := greatest(v_from, v_to - 365))에 걸리는지 보는 게 목적이다.
  for (let y = 2024; y <= 2028; y++) {
    for (let m = 1; m <= 12; m++) {
      const [qy, qm] = q3Start(y, m);
      const from = ymd(qy, qm, 1);
      assert.ok(from.endsWith("-01"), `${y}-${m} 의 시작일 ${from} 이 1일이 아니다`);
      // 그 달의 마지막 날을 종료일로 잡으면 그게 이 프리셋이 가질 수 있는 최대 길이다.
      const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate();
      const to = ymd(y, m, lastDay);
      const span = Math.round((Date.parse(to) - Date.parse(from)) / 86400000) + 1;
      assert.ok(span <= 92, `${y}-${m}: ${from}~${to} 가 ${span} 일이다 — 92 일을 넘었다`);
      assert.ok(span >= 89, `${y}-${m}: ${span} 일 — 달력 3개월이 아니다`);
    }
  }
});

// ===================== 돌림판 정보 누출 (R6) =====================
// 이 회귀는 조용히 돌아올 수 있는 종류다 — labelStart 를 상수 −spin 으로 되돌리면 화면은
// 멀쩡해 보이는데 정지 상태의 기울기가 곧 당첨자다. 그래서 값 자체를 못 박아 둔다.
const { wheelSpin } = gameLogic;
const WHEEL_NS = [2, 3, 5, 10, 11, 24];
const norm360 = (deg) => ((deg % 360) + 360) % 360;

test("wheelSpin — 시작 시점 라벨 각도가 wi 와 무관하게 항상 같다 (R6-1, R6-2, R6-8)", () => {
  for (const n of WHEEL_NS) {
    const seen = new Set();
    for (let wi = 0; wi < n; wi++) {
      // 난수도 함께 흔든다 — wi 뿐 아니라 jitter 와도 무관해야 한다 (R6-2).
      for (const r of [0, 0.13, 0.5, 0.87, 0.999]) {
        seen.add(wheelSpin(n, wi, () => r).labelStart);
      }
    }
    assert.equal(
      seen.size,
      1,
      `n=${n}: 시작 시점 라벨 각도가 ${[...seen].join(", ")} 로 갈린다 — 여기서 당첨자가 샌다`
    );
    assert.equal([...seen][0], 0, `n=${n}: 시작 각도는 0(똑바로)이어야 한다`);
  }
});

test("wheelSpin — 종료 시점 글자의 절대 각도가 0 으로 수렴한다 (R6-3, R6-9)", () => {
  for (const n of WHEEL_NS) {
    for (let wi = 0; wi < n; wi++) {
      for (const r of [0, 0.5, 0.999]) {
        const { spin, labelEnd } = wheelSpin(n, wi, () => r);
        assert.equal(
          Math.round(norm360(spin + labelEnd) * 1e6) / 1e6,
          0,
          `n=${n} wi=${wi} r=${r}: 멈춘 뒤 글자가 ${norm360(spin + labelEnd)}° 기울어 있다`
        );
      }
    }
  }
});

test("wheelSpin — 멈춘 순간 승자 조각이 핀(12시) 아래에 온다 (R6-6)", () => {
  for (const n of WHEEL_NS) {
    const a = 360 / n;
    for (let wi = 0; wi < n; wi++) {
      for (const r of [0, 0.25, 0.75, 0.999]) {
        const { spin, mid } = wheelSpin(n, wi, () => r);
        // 조각 wi 는 [mid−a/2, mid+a/2] 를 차지한다. spin 만큼 돌린 뒤 그 구간이 0°(12시)를 품어야 한다.
        const lo = norm360(mid - a / 2 + spin), hi = norm360(mid + a / 2 + spin);
        const covers = lo <= hi ? lo <= 360 && hi >= 360 - 1e-9 || (lo <= 0 + 1e-9 && hi >= 0) : true;
        assert.ok(
          covers || lo > hi, // 구간이 0° 를 넘어가며 감싸는 경우
          `n=${n} wi=${wi} r=${r}: 승자 조각 [${lo.toFixed(2)}, ${hi.toFixed(2)}] 가 12시를 안 품는다`
        );
        // 조각 중심과 12시의 거리가 반칸(a/2) 이내여야 한다 — jitter 범위가 (a−10)/2 라 항상 성립한다.
        const d = Math.min(norm360(mid + spin), 360 - norm360(mid + spin));
        assert.ok(
          d <= a / 2 + 1e-9,
          `n=${n} wi=${wi} r=${r}: 승자 조각 중심이 12시에서 ${d.toFixed(2)}° 떨어져 반칸(${(a / 2).toFixed(2)}°)을 넘었다`
        );
      }
    }
  }
});

test("wheelSpin — 5바퀴 이상 돌고 jitter 가 조각 안에 머문다", () => {
  for (const n of WHEEL_NS) {
    const a = 360 / n;
    for (let wi = 0; wi < n; wi++) {
      const lo = wheelSpin(n, wi, () => 0).spin, hi = wheelSpin(n, wi, () => 1).spin;
      const jit = (hi - lo) / 2;
      assert.ok(
        Math.abs(jit) <= Math.max(0, a - 10) / 2 + 1e-9,
        `n=${n}: jitter 반경 ${jit} 가 (a−10)/2 를 넘었다 — 옆 조각으로 넘어갈 수 있다`
      );
      assert.ok(lo > 360 * 4, `n=${n} wi=${wi}: 회전량 ${lo} 가 5바퀴에 못 미친다`);
    }
  }
});
