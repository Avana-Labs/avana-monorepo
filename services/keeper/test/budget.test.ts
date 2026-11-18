// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The spend log and the class budgets (keeper DESIGN.md, Fees): a scheduled or lazy class that spends its budget in a
// rolling 24 h stops sending and pages M-32, urgent never stops, older spend leaves the window, M-31 warns at 3× and
// pages at 5× the 7-day median, and each included transaction is logged with its cost, class, market and Hub.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Address, type PublicClient, serializeTransaction } from "viem";
import { CHAINS, type ServiceManifest } from "@avana/services-common";
import { GWEI, URGENT_ONLY } from "../src/chain/gas.ts";
import type { ChainReader } from "../src/chain/reads.ts";
import type { TxSigner } from "../src/chain/signer.ts";
import { type ChainConfig, dailyBudgets } from "../src/config.ts";
import { InventoryBook } from "../src/inventory.ts";
import { DAY_SECONDS, HubBook, SpendBook, attributeSubject, m31Level } from "../src/runtime/budget.ts";
import { type IncludedSpend, NotSent, Submitter } from "../src/runtime/submitter.ts";
import type { BlockContext, JobClass, TxPlan } from "../src/types.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const T0 = 1_800_000_000n;
const BUDGETS = { scheduled: 1_000n, lazy: 500n };

const entry = (jobClass: JobClass, costWei: bigint, at: bigint, hub: Address | null = null) => ({ chainId: 1, jobClass, at, costWei, market: null, hub });

const plan = (jobClass: JobClass, subject = `1:${addr(0xa1)}`): TxPlan => ({
  job: jobClass === "urgent" ? "liquidation" : jobClass === "scheduled" ? "breakerPoke" : "settlePending",
  jobClass,
  subject,
  to: addr(0xf1),
  data: "0x1234",
  deadline: null,
  reservations: [],
  targets: [],
  params: {},
});

function submitter(book: SpendBook, extra: { receipt?: unknown; spend?: { attribute: (p: TxPlan) => Promise<{ market: string | null; hub: Address | null }>; record: (s: IncludedSpend) => void } } = {}) {
  const state = { confirmed: 5 };
  const client = {
    getFeeHistory: async () => ({ reward: [[GWEI]], baseFeePerGas: [GWEI] }),
    readContract: async () => 10n ** 30n,
    getTransactionCount: async (q: { blockTag?: string }) => (q.blockTag === "pending" ? 5 : state.confirmed),
    getBlock: async () => ({ number: 0n }),
    call: async () => ({ data: "0x" }),
    estimateGas: async () => 100_000n,
    getTransactionReceipt: async () => {
      if (!extra.receipt) throw new Error("not found");
      return extra.receipt;
    },
  } as unknown as PublicClient;
  const signer: TxSigner = { address: addr(0x51), signTransaction: async (tx) => serializeTransaction(tx) };
  const post = vi.fn(async () => ({}));
  const cfg = { chain: CHAINS.base, rpc: { privateSend: ["http://sequencer"] } } as unknown as ChainConfig;
  const s = new Submitter(cfg, client, signer, new InventoryBook(), post, addr(0x5afe), { ceilingWei: 10n ** 30n, l1Fee: null, onCeiling: vi.fn(), fees: URGENT_ONLY, budget: book, ...(extra.spend ? { spend: extra.spend } : {}) });
  return { s, post, state };
}

const ctx = (timestamp: bigint, blockNumber = 10n): BlockContext => ({ config: { chain: CHAINS.base } as ChainConfig, blockNumber, blockTimestamp: timestamp, reader: {} as ChainReader });
const sim = { ok: true, gasEstimate: 100_000n };

let lines: Record<string, unknown>[];
beforeEach(() => {
  lines = [];
  vi.spyOn(process.stdout, "write").mockImplementation((x: string | Uint8Array) => {
    lines.push(JSON.parse(String(x)));
    return true;
  });
});
afterEach(() => vi.restoreAllMocks());

describe("class budgets", () => {
  it("urgentNeverBudgetLimited", async () => {
    const book = new SpendBook(1, BUDGETS, 100n);
    book.record(entry("urgent", 10n ** 24n, T0));
    book.record(entry("scheduled", 1_000n, T0));
    book.record(entry("lazy", 500n, T0));
    expect(book.allows("urgent", T0)).toBe(true);
    expect(book.budgetOf("urgent")).toBeNull();
    expect(book.alerts({ number: 1n, timestamp: T0 }).filter((a) => a.signal === "M-32").map((a) => a.subject)).toEqual(["budget:scheduled", "budget:lazy"]);
    const { s, post } = submitter(book);
    await s.submit(ctx(T0), plan("urgent"), sim);
    expect(post).toHaveBeenCalledOnce();
  });

  it("scheduledStopsAtBudgetAndPages", async () => {
    const book = new SpendBook(1, BUDGETS, 100n);
    book.record(entry("scheduled", 999n, T0));
    expect(book.allows("scheduled", T0)).toBe(true);
    expect(book.alerts({ number: 1n, timestamp: T0 }).some((a) => a.signal === "M-32")).toBe(false);
    book.record(entry("scheduled", 1n, T0 + 1n));
    expect(book.allows("scheduled", T0 + 1n)).toBe(false);
    expect(book.allows("lazy", T0 + 1n)).toBe(true); // each class has its own budget
    const pages = book.alerts({ number: 2n, timestamp: T0 + 1n }).filter((a) => a.signal === "M-32");
    expect(pages).toEqual([expect.objectContaining({ level: "page", subject: "budget:scheduled", detail: expect.objectContaining({ spent24hWei: "1000", budgetWei: "1000" }) })]);

    const { s, post } = submitter(book);
    await expect(s.submit(ctx(T0 + 1n), plan("scheduled"), sim)).rejects.toMatchObject({ reason: "budgetReached" });
    await expect(s.submit(ctx(T0 + 1n), plan("scheduled"), sim)).rejects.toBeInstanceOf(NotSent);
    expect(post).not.toHaveBeenCalled();
    await s.submit(ctx(T0 + 1n), plan("lazy", `1:market:7`), sim);
    expect(post).toHaveBeenCalledOnce();
  });

  it("rolling24hWindow", () => {
    const book = new SpendBook(1, BUDGETS, 100n);
    book.record(entry("lazy", 500n, T0));
    expect(book.spent24h(T0 + DAY_SECONDS - 1n, "lazy")).toBe(500n);
    expect(book.allows("lazy", T0 + DAY_SECONDS - 1n)).toBe(false);
    expect(book.spent24h(T0 + DAY_SECONDS, "lazy")).toBe(0n); // the spend left the window
    expect(book.allows("lazy", T0 + DAY_SECONDS)).toBe(true);
    expect(book.alerts({ number: 3n, timestamp: T0 + DAY_SECONDS }).some((a) => a.signal === "M-32")).toBe(false);
  });

  it("defaults the budgets to 3 and 1 days of the expected spend, and reads KEEPER_DAILY_BUDGET_WEI_*", () => {
    expect(dailyBudgets({}, "BASE", 10n)).toEqual({ scheduled: 30n, lazy: 10n });
    expect(dailyBudgets({ KEEPER_DAILY_BUDGET_WEI_LAZY_BASE: "4" }, "BASE", 10n)).toEqual({ scheduled: 30n, lazy: 4n });
    expect(dailyBudgets({}, "BASE", undefined)).toBeUndefined();
    expect(() => dailyBudgets({ KEEPER_DAILY_BUDGET_WEI_LAZY_BASE: "4" }, "BASE", undefined)).toThrow(/KEEPER_GAS_DAILY_SPEND_WEI_BASE/);
    expect(() => dailyBudgets({ KEEPER_DAILY_BUDGET_WEI_SCHEDULED_BASE: "0" }, "BASE", 10n)).toThrow(/positive integer/);
  });
});

describe("M-31 spend anomaly", () => {
  it("warns above 3x and pages above 5x the 7-day median, never below the expected daily spend", () => {
    expect([300n, 301n, 500n, 501n].map((x) => m31Level(x, 100n))).toEqual(["ok", "warn", "warn", "page"]);
    const book = new SpendBook(1, undefined, 100n);
    book.watchFrom(T0 - 8n * DAY_SECONDS);
    // Seven complete days at 200 wei each: the median is 200, above the floor.
    for (let d = 7n; d >= 1n; d--) book.record(entry("scheduled", 200n, T0 - d * DAY_SECONDS));
    expect(book.dailyMedian(T0)).toBe(200n);
    book.record(entry("urgent", 601n, T0));
    expect(book.alerts({ number: 1n, timestamp: T0 })).toEqual([expect.objectContaining({ signal: "M-31", level: "warn", subject: "spend" })]);
    book.record(entry("urgent", 400n, T0 + 1n));
    expect(book.alerts({ number: 2n, timestamp: T0 + 1n })).toEqual([expect.objectContaining({ signal: "M-31", level: "page", detail: expect.objectContaining({ urgent24hWei: "1001" }) })]);
    // Before a complete day is watched, the floor stands in for the median.
    expect(new SpendBook(1, undefined, 100n).dailyMedian(T0)).toBe(100n);
  });
});

describe("spend attribution", () => {
  const SPOKE_A = addr(0x5a);
  const SPOKE_B = addr(0x5b);
  const HUB_1 = addr(0x41);
  const HUB_2 = addr(0x42);
  const LP_7 = addr(0xa7);
  const manifest = {
    markets: [{ marketId: 7n, spoke: SPOKE_A, lpOracle: { address: LP_7 } }],
    aave: { borrowSpokes: [{ address: SPOKE_A }, { address: SPOKE_B }] },
  } as unknown as ServiceManifest;

  it("spendAttributedToHub", async () => {
    // Every subject kind names its market (where it has one) and the CDP Spoke, whose Hub MarketRegistry.hubOf gives.
    expect(attributeSubject(manifest, "1:market:7")).toEqual({ market: "7", spoke: SPOKE_A });
    // An LPOracle is never a transaction subject (the oracles are stateless): it names nothing.
    expect(attributeSubject(manifest, `1:${LP_7}`)).toEqual({ market: null, spoke: null });
    expect(attributeSubject(manifest, `1:${SPOKE_B}`)).toEqual({ market: null, spoke: SPOKE_B });
    expect(attributeSubject(manifest, `1:${SPOKE_A}:${addr(0xbeef)}@5`, () => 7n)).toEqual({ market: "7", spoke: SPOKE_A });
    expect(attributeSubject(manifest, "1:market:99")).toEqual({ market: null, spoke: null });

    const hubOf = vi.fn(async (spoke: Address) => (spoke === SPOKE_A ? HUB_1 : HUB_2));
    const hubs = new HubBook(hubOf);
    expect(await hubs.of(SPOKE_A)).toBe(HUB_1);
    expect(await hubs.of(SPOKE_A)).toBe(HUB_1);
    expect(hubOf).toHaveBeenCalledOnce(); // a Spoke's Hub is read once
    expect(await hubs.of(null)).toBeNull();

    // An included poke: its receipt's cost (with Base's L1 fee) is logged with class, market and Hub, and recorded.
    const book = new SpendBook(1, BUDGETS, 100n);
    const recorded: IncludedSpend[] = [];
    const receipt = { blockNumber: 11n, gasUsed: 500_000n, effectiveGasPrice: 3n, l1Fee: "0x64", logs: [] };
    const { s, state } = submitter(book, {
      receipt,
      spend: {
        attribute: async (p) => {
          const a = attributeSubject(manifest, p.subject);
          return { market: a.market, hub: await hubs.of(a.spoke) };
        },
        record: (x) => {
          recorded.push(x);
          book.record({ chainId: 1, jobClass: x.plan.jobClass, at: x.at, costWei: x.costWei, market: x.market, hub: x.hub });
        },
      },
    });
    const poke = plan("scheduled", "1:market:7");
    await s.submit(ctx(T0), poke, sim);
    state.confirmed = 6;
    await s.followUps(ctx(T0 + 2n, 11n), async () => true, () => {});
    expect(recorded).toHaveLength(1);
    expect(recorded[0]).toMatchObject({ costWei: 1_500_100n, l1Fee: 100n, market: "7", hub: HUB_1 });
    expect(book.byHub24h(T0 + 2n).get(HUB_1)).toBe(1_500_100n);
    expect(book.spent24h(T0 + 2n, "scheduled")).toBe(1_500_100n);
    expect(lines).toContainEqual(expect.objectContaining({
      outcome: "included",
      jobClass: "scheduled",
      spend: { gasUsed: "500000", effectiveGasPrice: "3", l1Fee: "100", costWei: "1500100", market: "7", hub: HUB_1 },
    }));
  });
});
