/* 구슬 레이스 — 물리·맵 회귀 테스트. 배포되는 index.html 의 마커 블록을 본다.
   race-lab.html 은 같은 코드를 떼어 둔 실험판이고, 지켜야 하는 것은 본체다.

   지키는 것은 하나다 — '어떤 인원수 · 어떤 시드로도 1등이 나온다'.
   이 판정이 없으면 장애물 하나가 판 전체를 막아도 눈으로는 안 보인다. 실제로 축이 코스에서
   멀고 팔이 긴 큰 날 하나가 '움직이는 선반'이 되어 60판 중 11판을 90초 상한까지 끌고 갔고,
   그때도 화면상으로는 그냥 '좀 오래 걸리는 판'처럼 보였다. */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const blocks = [...html.matchAll(/\/\* @test-export:start \*\/([\s\S]*?)\/\* @test-export:end \*\//g)].map((m) => m[1]);
assert.ok(blocks.length, "index.html 에서 마커 블록을 못 찾았다");
const pure = blocks.join("\n");

const G = runInContext(pure + "\n;({raceMapBuild,raceSimulate,raceRnd,RACE_W,RACE_R})", createContext({}));

const SEEDS = 20;
const CREW = [2, 3, 5, 10, 16, 24];
const run = (n, s) => {
  const rnd = G.raceRnd((s * 7919 + n) >>> 0);
  const st = G.raceMapBuild(rnd);
  return { st, r: G.raceSimulate(st, n, rnd) };
};

test("어떤 인원수 · 어떤 시드로도 1등이 나온다", () => {
  const stuck = [];
  for (const n of CREW) {
    for (let s = 1; s <= SEEDS; s++) if (!run(n, s).r.ok) stuck.push(`n=${n} seed=${s}`);
  }
  assert.deepEqual(stuck, [], `1등이 안 나온 판: ${stuck.join(", ")}`);
});

test("소요 시간이 볼 만한 구간에 들어온다", () => {
  const ds = [];
  for (const n of CREW) for (let s = 1; s <= SEEDS; s++) ds.push(run(n, s).r.frames / 60);
  ds.sort((a, b) => a - b);
  const med = ds[Math.floor(ds.length / 2)];
  assert.ok(ds[0] >= 8, `가장 짧은 판이 ${ds[0].toFixed(1)}초 — 너무 빨리 끝나 볼 게 없다`);
  assert.ok(ds.at(-1) <= 50, `가장 긴 판이 ${ds.at(-1).toFixed(1)}초 — 기다리다 지친다`);
  assert.ok(med >= 12 && med <= 30, `중앙값 ${med.toFixed(1)}초가 12~30초 밖이다`);
});

test("구슬이 벽 밖으로 새지 않는다", () => {
  const n = 12, out = [];
  for (let s = 1; s <= SEEDS; s++) {
    const { st, r } = run(n, s);
    for (let f = 0; f < r.frames; f += 20) {
      for (let i = 0; i < n; i++) {
        if (r.done[i] >= 0 && r.done[i] < f) continue;
        const x = r.path[f * n * 2 + i * 2], y = r.path[f * n * 2 + i * 2 + 1];
        const [l, rr] = st.bnd(y);
        if (x < l - 0.3 || x > rr + 0.3) out.push(`seed ${s} f${f}: x=${x.toFixed(1)} y=${y.toFixed(1)}`);
      }
    }
  }
  assert.deepEqual(out.slice(0, 5), [], `벽 밖으로 나간 구슬 ${out.length}건`);
});

/* 벽이 완만하면 '선반'이 되어 구슬이 얹힌 채 안 내려온다. 벽에도 장애물과 같은 기울기 하한을
   건다 — 이 규칙을 어긴 관문 때문에 한 번 전판이 막혔다. */
test("벽 기울기가 하한(|Δx|/Δy ≤ 1.4)을 지킨다", () => {
  const src = pure.match(/const LW = (\[[\s\S]*?\]);[\s\S]*?const RW = (\[[\s\S]*?\]);/);
  assert.ok(src, "벽 좌표 LW · RW 를 못 찾았다");
  const bad = [];
  for (const [nm, raw] of [["LW", src[1]], ["RW", src[2]]]) {
    const pts = JSON.parse(raw.replace(/\s+/g, ""));
    for (let i = 1; i < pts.length; i++) {
      const dx = Math.abs(pts[i][0] - pts[i - 1][0]), dy = pts[i][1] - pts[i - 1][1];
      if (dy > 0 && dx / dy > 1.4) bad.push(`${nm} ${JSON.stringify(pts[i - 1])}→${JSON.stringify(pts[i])} = ${(dx / dy).toFixed(2)}`);
    }
  }
  assert.deepEqual(bad, [], `선반이 되는 벽: ${bad.join(" · ")}`);
});

/* 출발 자리가 결과를 정하면 안 된다. 자리는 시드로 섞이므로 번호와 1등은 무관해야 한다. */
test("1등이 특정 번호로 쏠리지 않는다", () => {
  const n = 6, win = new Array(n).fill(0);
  for (let s = 1; s <= 600; s++) { const { r } = run(n, s); if (r.ok) win[r.winner]++; }
  const tot = win.reduce((a, b) => a + b, 0), exp = tot / n;
  const chi = win.reduce((a, c) => a + (c - exp) ** 2 / exp, 0);
  assert.ok(tot > 500, `판이 ${tot}개뿐이다`);
  assert.ok(chi < 20.5, `χ²=${chi.toFixed(1)} — 자유도 5 에서 0.1% 임계(20.5)를 넘었다: ${win.join(",")}`);
});

/* 버블은 닿으면 사라진다 — 판 중에 지형이 바뀌는 유일한 자리다. 안 터지면 그냥 벽이다. */
test("버블이 실제로 터진다", () => {
  let popped = 0, total = 0;
  for (let s = 1; s <= 10; s++) {
    const { st } = run(12, s);
    const bubbles = st.E.filter((e) => e.life);
    total += bubbles.length;
    popped += bubbles.filter((e) => e.dead != null).length;
  }
  assert.ok(total > 0, "버블이 하나도 없다");
  assert.ok(popped >= total * 0.15, `${total}개 중 ${popped}개만 터졌다 — 지나가는 길이 아니라 벽이 됐다`);
});
