// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// REQ-ORACLE-037: every market's LPOracle and every DebtOracle is poked at least once per CHECKPOINT_INTERVAL
// (3,600 s) and at least once per heartbeat of its fastest leg, whichever is shorter, on a new round at once, and
// the poke is sent early enough to be mined inside the interval. While an oracle is not Live it is checked every block
// and poked only when the poke would change what it stores (send on change), from eth_simulateV1 logs or, without
// that method, from the stored state and the reports read around a simulated poke.

import { describe, expect, it } from "vitest";
import { type Address, type Hex, encodeEventTopics } from "viem";
import { debtOracleAbi, lpOracleAbi } from "@avana/protocol/abis";
import type { ChainReader } from "../src/chain/reads.ts";
import type { ChainConfig } from "../src/config.ts";
import {
  CHANGE_TOPICS,
  CHECKPOINT_INTERVAL_SECONDS,
  POKE_LEAD_SECONDS,
  PokeBook,
  logsChangeState,
  oraclePokeJob,
  pokeDue,
  pokeIntervalSeconds,
  viewsChangeState,
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
  // Every oracle reads Live here: only the schedule decides (the not-Live rule is tested below).
  const reader = { feedRound: async (f: Address) => [rounds.get(f) ?? 1n, 0n, 0n, 0n, 1n] as const, oracleState: async () => 0 };
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
      expect(plan.jobClass).toBe("scheduled");
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

// While not Live: check every block, send on change. A scripted oracle stores its last state and its disagreement
// timer; a poke the job decides is mined at once. The job sends an urgent poke only when the poke would write.
describe("REQ-ORACLE-037 not Live: send only on change", () => {
  const LP = addr(0xa1);
  const oneOracle = { markets: [{ lpOracle: { address: LP, implementation: IMPL }, feeds: [feed(1, 86_400)] }], debtReserves: [] };
  const topicOf = (eventName: "PriceStateChanged" | "DisagreementRecorded" | "PriceCheckpointed") => encodeEventTopics({ abi: lpOracleAbi, eventName })[0] as Hex;

  /** The oracle: `state` is what getPriceState computes now; `stored` is what the last poke wrote. */
  class FakeOracle {
    state = 0;
    disagreeing = false;
    stored = { lastState: 0, disagreeSince: 0n };
    /** The logs a poke would emit now, and the storage it would leave. */
    poke(now: bigint) {
      const logs: { address: Address; topics: Hex[] }[] = [];
      const next = { ...this.stored };
      if (this.state !== next.lastState) {
        logs.push({ address: LP, topics: [topicOf("PriceStateChanged")] });
        next.lastState = this.state;
      }
      if (this.disagreeing && next.disagreeSince === 0n) {
        logs.push({ address: LP, topics: [topicOf("DisagreementRecorded")] });
        next.disagreeSince = now;
      }
      if (!this.disagreeing) next.disagreeSince = 0n;
      logs.push({ address: LP, topics: [topicOf("PriceCheckpointed")] }); // not a state change
      return { logs, next };
    }
    /** getPriceState as raw bytes: the computed state and the stored timer (lastState is not in the view). */
    report(stored = this.stored): Hex {
      return `0x${this.state.toString(16).padStart(2, "0")}${stored.disagreeSince.toString(16).padStart(16, "0")}`;
    }
  }

  async function runEpisode(opts: { simulateV1: boolean; blocks: number; script: (n: bigint, o: FakeOracle) => void }) {
    const o = new FakeOracle();
    const calls = { simulate: 0, effect: 0 };
    let now = 0n;
    const reader = {
      feedRound: async () => [1n, 0n, 0n, 0n, 1n] as const,
      oracleState: async () => o.state,
      simulateLogs: async () => {
        calls.simulate++;
        return opts.simulateV1 ? o.poke(now).logs : null;
      },
      pokeEffect: async () => {
        calls.effect++;
        return { before: o.report(), after: o.report(o.poke(now).next), pokeOk: true };
      },
    };
    const job = oraclePokeJob(new PokeBook());
    const sends: { block: bigint; jobClass: string }[] = [];
    for (let n = 0n; n < BigInt(opts.blocks); n++) {
      opts.script(n, o);
      now = 1_700_000_000n + n * 12n;
      const ctx: BlockContext = { config: { chain: { id: 1 }, manifest: oneOracle } as unknown as ChainConfig, blockNumber: n, blockTimestamp: now, reader: reader as unknown as ChainReader };
      for (const t of await job.discover(ctx)) {
        const check = await job.check(ctx, t);
        if (!check.act) continue;
        const plan = await job.build(ctx, check.decision);
        sends.push({ block: n, jobClass: plan.jobClass });
        o.stored = o.poke(now).next; // mined in this block
      }
    }
    return { sends, calls };
  }

  for (const simulateV1 of [true, false]) {
    const via = simulateV1 ? "eth_simulateV1" : "the view comparison";
    it(`nonLiveSendsOncePerEpisode (${via})`, async () => {
      // Live, then a disagreement holds the oracle Cached for 110 blocks: one scheduled poke at first sight, one urgent
      // poke when the episode starts, nothing more (the drill allows at most 2 sends).
      const { sends } = await runEpisode({
        simulateV1,
        blocks: 120,
        script: (n, o) => {
          if (n === 10n) {
            o.state = 2;
            o.disagreeing = true;
          }
        },
      });
      expect(sends).toEqual([{ block: 0n, jobClass: "scheduled" }, { block: 10n, jobClass: "urgent" }]);
    });

    it(`sendsOnStateChange (${via})`, async () => {
      // Cached at 10, Expired at 50, Live again at 80 (the recovery poke stores the grace window): one urgent poke each.
      const { sends } = await runEpisode({
        simulateV1,
        blocks: 100,
        script: (n, o) => {
          if (n === 10n) o.state = 2;
          if (n === 50n) o.state = 3;
          if (n === 80n) o.state = 0;
        },
      });
      expect(sends.filter((s) => s.jobClass === "urgent").map((s) => s.block)).toEqual([10n, 50n, 80n]);
      expect(sends.filter((s) => s.jobClass === "scheduled").map((s) => s.block)).toEqual([0n]);
    });

    it(`sendsOnStateChange: a timer written while the state stays the same (${via})`, async () => {
      // Drifting from block 5 with no timer; the alternate route starts disagreeing at block 30: the poke writes disagreeSince.
      const { sends } = await runEpisode({
        simulateV1,
        blocks: 60,
        script: (n, o) => {
          if (n === 5n) o.state = 1;
          if (n === 30n) o.disagreeing = true;
        },
      });
      expect(sends.filter((s) => s.jobClass === "urgent").map((s) => s.block)).toEqual([5n, 30n]);
    });
  }

  it("fallbackWithoutSimulateV1: compares the stored state and the reports around a simulated poke", async () => {
    const { calls } = await runEpisode({
      simulateV1: false,
      blocks: 40,
      script: (n, o) => {
        if (n === 10n) o.state = 2;
      },
    });
    // Each not-Live block asks eth_simulateV1 first; the report comparison runs only when the state alone shows no change.
    expect(calls.simulate).toBe(30);
    expect(calls.effect).toBe(29);
    expect(viewsChangeState(2, undefined, { before: null, after: null, pokeOk: false })).toBe(true); // after a restart: once
    expect(viewsChangeState(2, 2, { before: "0x02", after: "0x02", pokeOk: true })).toBe(false);
    expect(viewsChangeState(2, 2, { before: "0x02", after: "0x03", pokeOk: true })).toBe(true);
    expect(viewsChangeState(2, 2, { before: "0x02", after: "0x03", pokeOk: false })).toBe(false); // a reverting poke writes nothing
  });

  it("counts only the oracle's own state-change events in simulated logs", () => {
    const other = addr(0xbad);
    expect(logsChangeState("lp", LP, [{ address: LP, topics: [topicOf("PriceCheckpointed")] }])).toBe(false);
    expect(logsChangeState("lp", LP, [{ address: other, topics: [topicOf("PriceStateChanged")] }])).toBe(false);
    expect(logsChangeState("lp", LP, [{ address: LP, topics: [topicOf("PriceStateChanged")] }])).toBe(true);
    const debtState = encodeEventTopics({ abi: debtOracleAbi, eventName: "DebtPriceStateChanged" })[0] as Hex;
    expect(logsChangeState("debt", LP, [{ address: LP, topics: [debtState] }])).toBe(true);
    expect(CHANGE_TOPICS.lp.size).toBe(11);
    expect(CHANGE_TOPICS.debt.size).toBe(9);
  });
});
