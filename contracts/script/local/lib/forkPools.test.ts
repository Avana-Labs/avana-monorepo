// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/local/lib/forkPools.test.ts (from contracts/)

import assert from "node:assert/strict";
import { test } from "node:test";
import type { Address } from "viem";
import { fillPool, fillPools, maxWrites, minObservations, type PoolIo, type PoolState, writesToGrow } from "./forkPools.ts";

/** A pool's oracle as Uniswap v3's Oracle library keeps it: a ring of observations that grows on wrap. */
class OracleModel {
  obs: { ts: number; init: boolean }[];
  index: number;
  cardinality: number;
  next: number;
  now: number;
  constructor(cardinality: number, index: number, oldestAge: number, now: number) {
    this.now = now;
    // The fork's history: `cardinality` observations, the newest at `index`, the oldest `oldestAge` seconds old.
    this.obs = Array.from({ length: cardinality }, () => ({ ts: 0, init: true }));
    for (let k = 0; k < cardinality; k++) {
      const age = cardinality === 1 ? 0 : Math.round((oldestAge * (cardinality - 1 - k)) / (cardinality - 1));
      this.obs[(index + 1 + k) % cardinality] = { ts: now - age, init: true };
    }
    this.index = index;
    this.cardinality = cardinality;
    this.next = cardinality;
  }
  grow(n: number) {
    while (this.obs.length < n) this.obs.push({ ts: 1, init: false });
    this.next = Math.max(this.next, n);
  }
  write(t: number) {
    if (this.obs[this.index]!.ts === t) return;
    if (this.next > this.cardinality && this.index === this.cardinality - 1) this.cardinality = this.next;
    this.index = (this.index + 1) % this.cardinality;
    this.obs[this.index] = { ts: t, init: true };
  }
  observeOk(window: number) {
    let oldest = this.obs[(this.index + 1) % this.cardinality]!;
    if (!oldest.init) oldest = this.obs[0]!;
    return oldest.ts <= this.now - window;
  }
}

function io(pools: Record<string, OracleModel>, blockTime: number, calls: string[] = []): PoolIo {
  return {
    async state(p) {
      const m = pools[p]!;
      return { observationIndex: m.index, observationCardinality: m.cardinality, observationCardinalityNext: m.next };
    },
    async raise(p, n) {
      calls.push(`raise ${p} ${n}`);
      pools[p]!.grow(n);
    },
    async write(p) {
      // The chain's clock is shared: every pool sees each block.
      for (const m of Object.values(pools)) m.now += blockTime;
      pools[p]!.write(pools[p]!.now);
      calls.push(`write ${p}`);
    },
    async observeOk(p, w) {
      return pools[p]!.observeOk(w);
    },
  };
}

const A = "0x00000000000000000000000000000000000000aa" as Address;
const B = "0x00000000000000000000000000000000000000bb" as Address;

test("minObservations matches LPPriceMath: ceil(window / blockTime) + 1", () => {
  assert.equal(minObservations(1800, 12), 151);
  assert.equal(minObservations(1800, 2), 901);
  assert.equal(minObservations(1801, 12), 152);
  assert.throws(() => minObservations(1800, 0));
});

test("writesToGrow: the index must wrap onto the new slots", () => {
  const s: PoolState = { observationIndex: 3, observationCardinality: 10, observationCardinalityNext: 151 };
  assert.equal(writesToGrow(s, 151), 7);
  assert.equal(writesToGrow({ ...s, observationCardinality: 151 }, 151), 0);
  assert.equal(maxWrites(s, 151), 7 + 151);
});

for (const [name, card, index, oldestAge, blockTime] of [
  ["Ethereum pool, 10 slots, a day of history", 10, 3, 86_400, 12],
  ["Ethereum pool, 1 slot", 1, 0, 0, 12],
  ["Ethereum pool, 65 slots, newest last", 65, 64, 3_000, 12],
  ["Base pool, 300 slots, 10 minutes of history", 300, 120, 600, 2],
] as const) {
  test(`fillPool reaches the LPOracle's need: ${name}`, async () => {
    const m = new OracleModel(card, index, oldestAge, 1_700_000_000);
    const calls: string[] = [];
    const r = await fillPool(io({ [A]: m }, blockTime, calls), A, 1800, blockTime);
    const need = minObservations(1800, blockTime);
    assert.ok(m.cardinality >= need, `cardinality ${m.cardinality} < ${need}`);
    assert.ok(m.observeOk(1800));
    assert.equal(r.raised, true);
    assert.equal(calls.filter((c) => c.startsWith("raise")).length, 1);
    assert.ok(r.writes <= maxWrites(r.before, need), `${r.writes} writes`);
  });
}

test("fillPool leaves a pool that already serves the window alone", async () => {
  const m = new OracleModel(1801, 900, 7_200, 1_700_000_000);
  const calls: string[] = [];
  const r = await fillPool(io({ [A]: m }, 2, calls), A, 1800, 2);
  assert.equal(r.writes, 0);
  assert.equal(r.raised, false);
  assert.deepEqual(calls, []);
});

test("fillPool refuses a pool whose cardinality does not grow", async () => {
  const m = new OracleModel(10, 3, 86_400, 1_700_000_000);
  const broken = { ...io({ [A]: m }, 12), async raise() {} };
  await assert.rejects(fillPool(broken, A, 1800, 12), /cardinality 10 of 151/);
});

test("fillPools fills each pool once, on one shared clock", async () => {
  const pools = { [A]: new OracleModel(10, 3, 86_400, 1_700_000_000), [B]: new OracleModel(32, 0, 600, 1_700_000_000) };
  const out = await fillPools(io(pools, 12), [A, B, A.toUpperCase().replace("0X", "0x") as Address], 1800, 12);
  assert.equal(out.length, 2);
  for (const m of Object.values(pools)) {
    assert.ok(m.cardinality >= 151);
    assert.ok(m.observeOk(1800));
  }
});
