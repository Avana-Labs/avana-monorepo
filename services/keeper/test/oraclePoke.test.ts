// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// REQ-ORACLE-037: every market's LPOracle and every DebtOracle is poked at least once per CHECKPOINT_INTERVAL
// (3,600 s) and at least once per heartbeat of its fastest leg, whichever is shorter, on a new round at once, and
// the poke is sent early enough to be mined inside the interval.

import { describe, expect, it } from "vitest";
import type { Address } from "viem";
import type { ChainReader } from "../src/chain/reads.ts";
import type { ChainConfig } from "../src/config.ts";
import {
  CHECKPOINT_INTERVAL_SECONDS,
  POKE_LEAD_SECONDS,
  PokeBook,
  oraclePokeJob,
  pokeDue,
  pokeIntervalSeconds,
} from "../src/jobs/oraclePoke.ts";
import type { BlockContext } from "../src/types.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const LP_DAY = addr(0xa1); // stablecoin legs, 86,400 s heartbeats
const LP_FAST = addr(0xa2); // one 1,200 s leg
const DEBT = addr(0xd1); // 3,600 s and 86,400 s legs
const DEBT_NO_LEGS = addr(0xd2);
const IMPL = addr(0x1);

const feed = (n: number, heartbeatSeconds: number) => ({ feed: addr(0xf00 + n), heartbeatSeconds });

const manifest = {
  markets: [
    { lpOracle: { address: LP_DAY, implementation: IMPL }, feeds: [feed(1, 86_400), feed(2, 86_400)] },
    { lpOracle: { address: LP_FAST, implementation: IMPL }, feeds: [feed(3, 86_400), feed(4, 1_200)] },
  ],
  debtReserves: [
    { debtOracle: { address: DEBT, implementation: IMPL }, feeds: [feed(5, 3_600), feed(6, 86_400)] },
    { debtOracle: { address: DEBT_NO_LEGS, implementation: IMPL }, feeds: [] },
    { debtOracle: null, feeds: [feed(7, 86_400)] }, // GHO: fixed source, no DebtOracle
  ],
};

/** Feed rounds that change only when the test bumps them. */
function chain(blockSeconds: number) {
  const rounds = new Map<Address, bigint>();
  const reader = { feedRound: async (f: Address) => [rounds.get(f) ?? 1n, 0n, 0n, 0n, 1n] as const };
  const ctx = (n: bigint): BlockContext => ({
    config: { chain: { id: 1 }, manifest } as unknown as ChainConfig,
    blockNumber: n,
    blockTimestamp: 1_700_000_000n + n * BigInt(blockSeconds),
    reader: reader as unknown as ChainReader,
  });
  return { rounds, ctx };
}

/** Runs the job's discover → check → build for every block in [from, to] and returns each oracle's poke times. */
async function run(blockSeconds: number, blocks: number, onBlock?: (n: bigint, c: ReturnType<typeof chain>) => void) {
  const c = chain(blockSeconds);
  const job = oraclePokeJob(new PokeBook());
  const pokes = new Map<Address, bigint[]>();
  for (let n = 0n; n < BigInt(blocks); n++) {
    onBlock?.(n, c);
    const ctx = c.ctx(n);
    for (const t of await job.discover(ctx)) {
      const check = await job.check(ctx, t);
      if (!check.act) continue;
      const plan = await job.build(ctx, check.decision);
      expect(plan.to).toBe(t.oracle);
      expect(plan.data).toBe("0x18178358"); // poke()
      pokes.set(t.oracle, [...(pokes.get(t.oracle) ?? []), ctx.blockTimestamp]);
    }
  }
  return pokes;
}

function maxGap(times: readonly bigint[]): bigint {
  let gap = 0n;
  for (let i = 1; i < times.length; i++) if (times[i]! - times[i - 1]! > gap) gap = times[i]! - times[i - 1]!;
  return gap;
}

describe("REQ-ORACLE-037 poke interval", () => {
  it("is CHECKPOINT_INTERVAL (3,600 s) when every leg is slower, and never longer", () => {
    expect(CHECKPOINT_INTERVAL_SECONDS).toBe(3_600);
    expect(pokeIntervalSeconds([86_400, 86_400])).toBe(3_600);
    expect(pokeIntervalSeconds([82_800])).toBe(3_600);
    expect(pokeIntervalSeconds([3_600, 86_400])).toBe(3_600);
    expect(pokeIntervalSeconds([])).toBe(3_600);
  });

  it("is the fastest leg's heartbeat when that is shorter", () => {
    expect(pokeIntervalSeconds([86_400, 1_200])).toBe(1_200);
    expect(pokeIntervalSeconds([3_599, 86_400])).toBe(3_599);
    expect(pokeIntervalSeconds([60, 27])).toBe(27);
  });

  it("is never lengthened by a malformed heartbeat", () => {
    expect(pokeIntervalSeconds([Number.NaN])).toBe(3_600);
    expect(pokeIntervalSeconds([0, -5, Number.POSITIVE_INFINITY])).toBe(3_600);
    expect(pokeIntervalSeconds([Number.NaN, 1_200])).toBe(1_200);
  });

  it("is due on first sight, on a new round, and from the interval less the lead", () => {
    const at = 1_000_000n;
    expect(pokeDue(at, undefined, 3_600, false)).toBe(true);
    expect(pokeDue(at + 1n, at, 3_600, true)).toBe(true);
    const due = at + BigInt(3_600 - POKE_LEAD_SECONDS);
    expect(pokeDue(due - 1n, at, 3_600, false)).toBe(false);
    expect(pokeDue(due, at, 3_600, false)).toBe(true);
    expect(pokeDue(at + 1n, at, 30, false)).toBe(true); // an interval within the lead: every block
  });
});

describe("REQ-ORACLE-037 schedule over two days", () => {
  for (const [chainName, blockSeconds] of [["Ethereum", 12], ["Base", 2]] as const) {
    it(`pokes every oracle inside its interval, landing in the next block (${chainName})`, async () => {
      const blocks = (2 * 86_400) / blockSeconds;
      const pokes = await run(blockSeconds, blocks);
      const limits: [Address, number][] = [[LP_DAY, 3_600], [LP_FAST, 1_200], [DEBT, 3_600], [DEBT_NO_LEGS, 3_600]];
      expect([...pokes.keys()].sort()).toEqual(limits.map(([a]) => a).sort());
      for (const [oracle, limit] of limits) {
        const times = pokes.get(oracle)!;
        // Sent at most `limit - lead` after the last one, so the transaction mined in a following block (one block
        // here, up to lead / block time blocks in general) still lands within `limit`.
        expect(maxGap(times) + BigInt(blockSeconds)).toBeLessThanOrEqual(BigInt(limit));
        expect(maxGap(times)).toBeGreaterThan(BigInt(limit - POKE_LEAD_SECONDS - blockSeconds)); // not every block
        expect(times.length).toBeGreaterThanOrEqual(Math.floor((2 * 86_400) / limit));
      }
    });
  }

  it("pokes at once on a new round of any leg, and the interval restarts from that poke", async () => {
    const bump = 1_000n; // block of the new round, Ethereum
    const pokes = await run(12, 1_500, (n, c) => {
      if (n === bump) c.rounds.set(feed(2, 0).feed, 2n);
    });
    const times = pokes.get(LP_DAY)!;
    const at = 1_700_000_000n + bump * 12n;
    expect(times).toContain(at);
    const next = times[times.indexOf(at) + 1]!;
    expect(next - at).toBe(BigInt(Math.ceil((3_600 - POKE_LEAD_SECONDS) / 12) * 12));
    expect(pokes.get(LP_FAST)).not.toContain(at); // another oracle's feed: not due
  });
});
