// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Read cadence and batching (runtime/chainLoop.ts, chain/reads.ts): liquidations and breaker pokes are checked at
// every head; the instance's status, pending settlement and configuration pokes at the first head
// KEEPER_SLOW_JOB_SECONDS after their last check
// (0: every head); the funding alerts found at a complete slow check are posted again at every head until the next
// one, and kept when a check fails. A view read is made once per block reader; a simulation of a write is not batched
// with reads, and the breaker pokes of all markets share one. A log range a provider refused is not asked for again in
// the same read, and an incremental sweep never starts above the head it read to.

import { describe, expect, it, vi } from "vitest";
import { type Address, type Hex, type PublicClient } from "viem";
import { CHAINS } from "@avana/services-common";
import { createChainReader } from "../src/chain/reads.ts";
import { type ChainConfig, type KeeperConfig, SLOW_JOB_SECONDS, slowJobSeconds } from "../src/config.ts";
import { AccountCache } from "../src/discovery/accountCache.ts";
import { getLogsChunked, nextSweepFrom } from "../src/discovery/backfill.ts";
import { type Alert, HeldAlerts } from "../src/monitoring/alerts.ts";
import { chainLoop } from "../src/runtime/chainLoop.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const LENS = addr(0x10);
const SWAP = addr(0x11);
const REGISTRY = addr(0x12);
const COLLATERALIZATION = addr(0x13);
const RISK = addr(0x14);
const VAULT = addr(0x20);
const ORACLE = addr(0x30);
const IMPL = addr(0x50);
const HELPER = addr(0x60);

const manifest = {
  markets: [{ marketId: 1n, vaultToken: { address: VAULT }, lpOracle: { address: ORACLE }, feeds: [], routes: [] }],
  debtReserves: [],
  aave: { borrowSpokes: [] },
  avana: {
    lens: { address: LENS },
    lpVaultSwap: { address: SWAP },
    marketRegistry: { address: REGISTRY },
    collateralization: { address: COLLATERALIZATION },
    riskModule: { address: RISK, implementation: IMPL },
  },
};

/** A node answering the keeper's reads, counting them by function name. */
function node() {
  const reads = new Map<string, number>();
  const count = (name: string) => reads.set(name, (reads.get(name) ?? 0) + 1);
  const client = {
    readContract: async ({ functionName }: { functionName: string }) => {
      count(functionName);
      switch (functionName) {
        case "isApprovedKeeper":
          return true;
        case "activeKeeperCount":
          return 1n;
        case "getPendingSettlement":
          return { units: 0n, settleable: false, settleableUnits: 0n };
        case "getSpokes":
          return [];
        default:
          throw new Error(`unexpected read ${functionName}`);
      }
    },
    multicall: async () => [],
    call: async (args: { account?: Address; batch?: boolean }) => {
      count(args.account ? "simulate" : "callAt");
      return { data: undefined };
    },
    estimateGas: async () => 21_000n,
    getStorageAt: async () => `0x${IMPL.slice(2).padStart(64, "0")}` as Hex,
  };
  return { client: client as unknown as PublicClient, reads };
}

function loop(slowSeconds: number) {
  const { client, reads } = node();
  const fundingAt: boolean[] = [];
  const onHead = chainLoop({
    keeper: { mode: "observe", role: "primary", shard: null, slowJobSeconds: slowSeconds } as unknown as KeeperConfig,
    cfg: { chain: CHAINS.mainnet, manifest } as unknown as ChainConfig,
    primary: client,
    fallback: client,
    cache: new AccountCache(),
    safety: { halted: false, codeMismatch: null, frozenHelperChains: new Set() },
    alerts: { send: async () => {} },
    submitter: null,
    from: addr(0x70),
    helper: { address: HELPER, maxTopUpBps: 0n },
    onReorg: async () => {},
    funding: async (_head, slow) => void fundingAt.push(slow),
  });
  const hash = (n: bigint) => `0x${n.toString(16).padStart(64, "0")}` as Hex;
  const run = async (heads: number, from = 1) => {
    for (let n = BigInt(from); n <= BigInt(heads); n++) await onHead({ number: n, hash: hash(n), parentHash: hash(n - 1n), timestamp: 1_700_000_000n + n * 12n });
  };
  return { run, reads, fundingAt };
}

describe("slow-cadence jobs", () => {
  it("checks status and pending settlement once per 60 s of block time, funding at the same heads", async () => {
    vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const { run, reads, fundingAt } = loop(60);
    await run(10); // 12 s blocks: heads 1 and 6 are 60 s apart
    expect(reads.get("getPendingSettlement")).toBe(2);
    expect(fundingAt).toEqual([true, false, false, false, false, true, false, false, false, false]);
    vi.restoreAllMocks();
  });

  it("checks everything at every head with KEEPER_SLOW_JOB_SECONDS=0", async () => {
    vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const { run, reads, fundingAt } = loop(0);
    await run(5);
    expect(reads.get("getPendingSettlement")).toBe(5);
    expect(fundingAt.every(Boolean)).toBe(true);
    vi.restoreAllMocks();
  });
});

describe("KEEPER_SLOW_JOB_SECONDS", () => {
  it("defaults to 60, accepts 0 to 3600 and refuses anything else", () => {
    expect(slowJobSeconds({})).toBe(SLOW_JOB_SECONDS);
    expect(slowJobSeconds({ KEEPER_SLOW_JOB_SECONDS: "0" })).toBe(0);
    expect(slowJobSeconds({ KEEPER_SLOW_JOB_SECONDS: "120" })).toBe(120);
    expect(() => slowJobSeconds({ KEEPER_SLOW_JOB_SECONDS: "-1" })).toThrow();
    expect(() => slowJobSeconds({ KEEPER_SLOW_JOB_SECONDS: "3601" })).toThrow();
    expect(() => slowJobSeconds({ KEEPER_SLOW_JOB_SECONDS: "1.5" })).toThrow();
  });
});

describe("HeldAlerts", () => {
  const alert = (blockNumber: bigint, subject: string): Alert => ({ signal: "M-16", level: "warn", chainId: 1, blockNumber, subject, detail: {} });

  it("posts the last run's alerts again at each head until the next run", async () => {
    const sent: Alert[] = [];
    const held = new HeldAlerts({ send: async (a) => void sent.push(a) });
    await held.run(10n, () => held.sink.send(alert(10n, "float:a")));
    await held.replay(11n);
    await held.replay(12n);
    expect(sent.map((a) => `${a.blockNumber} ${a.subject}`)).toEqual(["10 float:a", "11 float:a", "12 float:a"]);
    await held.run(13n, async () => {});
    await held.replay(14n);
    expect(sent).toHaveLength(3);
  });

  it("keeps the previous run's alerts, and posts them for the head, when a run throws", async () => {
    const sent: Alert[] = [];
    const held = new HeldAlerts({ send: async (a) => void sent.push(a) });
    await held.run(10n, () => held.sink.send(alert(10n, "float:a")));
    await expect(held.run(15n, async () => { throw new Error("read failed"); })).rejects.toThrow("read failed");
    await held.replay(16n);
    expect(sent.map((a) => `${a.blockNumber} ${a.subject}`)).toEqual(["10 float:a", "15 float:a", "16 float:a"]);
  });
});

describe("block reader", () => {
  it("reads a view once per block and never batches a simulated write", async () => {
    const { client, reads } = node();
    const calls: { batch?: boolean }[] = [];
    (client as unknown as { call: (a: { batch?: boolean }) => Promise<{ data: undefined }> }).call = async (a) => {
      calls.push(a);
      return { data: undefined };
    };
    const reader = createChainReader(client, manifest as never, 5n);
    await Promise.all([reader.pendingSettlement(VAULT), reader.pendingSettlement(VAULT), reader.approvedSpokes(), reader.approvedSpokes()]);
    await reader.pendingSettlement(VAULT);
    expect(reads.get("getPendingSettlement")).toBe(1);
    expect(reads.get("getSpokes")).toBe(1);
    await reader.callAt(RISK, "0x1234");
    expect(calls[0]?.batch).toBe(false);
  });

});

describe("incremental sweep", () => {
  it("starts at the finalized block, or at the head read to when a lagging node answered one below it", () => {
    expect(nextSweepFrom(100n, 130n)).toBe(100n);
    expect(nextSweepFrom(100n, 90n)).toBe(90n);
  });
});

describe("getLogsChunked", () => {
  it("does not grow back to a range the provider refused", async () => {
    const ranges: bigint[] = [];
    const client = {
      getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
        const size = toBlock - fromBlock + 1n;
        ranges.push(size);
        if (size > 5_000n) throw new Error("query exceeds max block range 5000");
        return [];
      },
    } as unknown as PublicClient;
    await getLogsChunked(client, addr(1), { type: "event", name: "E", inputs: [] }, 0n, 29_999n);
    // One refusal, then 5,000-block ranges to the end; before the fix every second request was a refused 10,000.
    expect(ranges).toEqual([10_000n, 5_000n, 5_000n, 5_000n, 5_000n, 5_000n, 5_000n]);
  });
});
