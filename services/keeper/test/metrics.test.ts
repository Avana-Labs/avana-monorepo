// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The /metrics text: stable names and labels, one HELP and TYPE per family with its samples together, gauges without a
// value left out, the open alerts as those raised for the last processed head, the gas spend by class and Hub, and the
// small-account spend (D4): liquidations whose reward Kr, valued in wei, was below their gas cost.

import { describe, expect, it } from "vitest";
import { type Address, type Hex, encodeAbiParameters, encodeEventTopics } from "viem";
import { lpVaultSwapAbi } from "@avana/protocol/abis";
import { ChainMetrics, SmallAccountSpend, UNKNOWN_HUB, renderMetrics, valueInWei } from "../src/metrics.ts";
import { liquidationReward } from "../src/runtime/budget.ts";
import type { Alert } from "../src/monitoring/alerts.ts";

const alert = (signal: `M-${string}`, level: "warn" | "page", blockNumber: bigint): Alert => ({ signal, level, chainId: 1, blockNumber, subject: "s", detail: {} });

const samples = (text: string) => text.split("\n").filter((l) => l !== "" && !l.startsWith("#"));

describe("renderMetrics", () => {
  it("writes only keeper_mode and the empty families before any head", () => {
    const text = renderMetrics([{ chain: "mainnet", mode: "observe", metrics: new ChainMetrics() }]);
    expect(samples(text)).toEqual(['keeper_mode{chain="mainnet",mode="observe"} 1']);
    expect(text).toContain("# TYPE keeper_alerts_total counter");
    expect(text.endsWith("\n")).toBe(true);
  });

  it("writes every gauge per chain with its labels", () => {
    const eth = new ChainMetrics();
    eth.indexedBlock = 99n;
    eth.rpcThrough = 98n;
    eth.accounts = 12;
    eth.oneSided = { indexer: 1, rpc: 2 };
    eth.processed(100n);
    const base = new ChainMetrics();
    base.processed(500n);
    const text = renderMetrics([
      { chain: "mainnet", mode: "active", metrics: eth },
      { chain: "base", mode: "halted", metrics: base },
    ]);
    expect(samples(text)).toEqual([
      'keeper_mode{chain="mainnet",mode="active"} 1',
      'keeper_mode{chain="base",mode="halted"} 1',
      'keeper_head_block{chain="mainnet"} 100',
      'keeper_head_block{chain="base"} 500',
      'keeper_indexer_block{chain="mainnet"} 99',
      'keeper_rpc_backfill_block{chain="mainnet"} 98',
      'keeper_discovered_accounts{chain="mainnet"} 12',
      'keeper_discovery_one_sided{chain="mainnet",only="indexer"} 1',
      'keeper_discovery_one_sided{chain="mainnet",only="rpc"} 2',
    ]);
  });

  it("keeps each family's samples together under one HELP and TYPE", () => {
    const text = renderMetrics([
      { chain: "mainnet", mode: "active", metrics: new ChainMetrics() },
      { chain: "base", mode: "active", metrics: new ChainMetrics() },
    ]);
    const types = text.split("\n").filter((l) => l.startsWith("# TYPE")).map((l) => l.split(" ")[2]);
    expect(types).toEqual([
      "keeper_mode", "keeper_head_block", "keeper_indexer_block", "keeper_rpc_backfill_block", "keeper_discovered_accounts", "keeper_discovery_one_sided", "keeper_alerts_open", "keeper_alerts_total",
      "keeper_gas_spend_24h_wei", "keeper_gas_spend_wei_total", "keeper_small_account_gas_wei_total", "keeper_small_account_liquidations_total",
    ]);
    expect(new Set(types).size).toBe(types.length);
  });
});

describe("ChainMetrics alerts", () => {
  it("counts every alert in the total and the last processed head's alerts as open", () => {
    const m = new ChainMetrics();
    m.alert(alert("M-09", "warn", 10n));
    m.alert(alert("M-09", "warn", 10n));
    m.alert(alert("M-30", "page", 10n));
    m.processed(10n);
    expect([...m.open()]).toEqual([["M-09|warn", 2], ["M-30|page", 1]]);

    // Head 11 is being processed: head 10's set stays open until 11 is done.
    m.alert(alert("M-30", "page", 11n));
    expect([...m.open()]).toEqual([["M-09|warn", 2], ["M-30|page", 1]]);
    m.processed(11n);
    expect([...m.open()]).toEqual([["M-30|page", 1]]);

    // A head without alerts closes them all.
    m.processed(12n);
    expect(m.open().size).toBe(0);
    expect([...m.total()]).toEqual([["M-09|warn", 2], ["M-30|page", 2]]);
  });

  it("adds an alert raised outside the pass for the processed head (the gas ceiling) to the open set", () => {
    const m = new ChainMetrics();
    m.processed(20n);
    m.alert(alert("M-17", "page", 21n)); // pass of head 21 has started
    m.alert(alert("M-17", "page", 20n)); // gas ceiling, carrying the last processed head
    expect([...m.open()]).toEqual([["M-17|page", 1]]);
  });

  it("renders the alert families by signal and level", () => {
    const m = new ChainMetrics();
    m.alert(alert("M-26", "page", 5n));
    m.processed(5n);
    const lines = samples(renderMetrics([{ chain: "base", mode: "observe", metrics: m }]));
    expect(lines).toContain('keeper_alerts_open{chain="base",signal="M-26",level="page"} 1');
    expect(lines).toContain('keeper_alerts_total{chain="base",signal="M-26",level="page"} 1');
  });
});

describe("small-account spend (D4)", () => {
  const HUB_1 = "0x0000000000000000000000000000000000000041";
  const HUB_2 = "0x0000000000000000000000000000000000000042";

  it("smallAccountSpendCountsOnlyUncoveredCalls", () => {
    const s = new SmallAccountSpend();
    expect(s.record({ hub: HUB_1, gasCostWei: 1_000n, rewardWei: 999n })).toBe(true); // reward below gas: counted
    expect(s.record({ hub: HUB_1, gasCostWei: 1_000n, rewardWei: 1_000n })).toBe(false); // covered exactly: not counted
    expect(s.record({ hub: HUB_1, gasCostWei: 1_000n, rewardWei: 50_000n })).toBe(false);
    expect(s.record({ hub: HUB_1, gasCostWei: 700n, rewardWei: 0n })).toBe(true); // a dust account: no reward at all
    expect([...s.byHub()]).toEqual([[HUB_1, { gasWei: 1_700n, count: 2 }]]);
  });

  it("smallAccountSpendPerHub", () => {
    const m = new ChainMetrics();
    m.smallAccounts.record({ hub: HUB_2, gasCostWei: 300n, rewardWei: 1n });
    m.smallAccounts.record({ hub: HUB_1, gasCostWei: 100n, rewardWei: 1n });
    m.smallAccounts.record({ hub: HUB_1, gasCostWei: 200n, rewardWei: 1n });
    m.smallAccounts.record({ hub: null, gasCostWei: 5n, rewardWei: 1n });
    const lines = samples(renderMetrics([{ chain: "base", mode: "active", metrics: m }]));
    expect(lines.filter((l) => l.startsWith("keeper_small_account"))).toEqual([
      `keeper_small_account_gas_wei_total{chain="base",hub="${HUB_1}"} 300`,
      `keeper_small_account_gas_wei_total{chain="base",hub="${HUB_2}"} 300`,
      `keeper_small_account_gas_wei_total{chain="base",hub="${UNKNOWN_HUB}"} 5`,
      `keeper_small_account_liquidations_total{chain="base",hub="${HUB_1}"} 2`,
      `keeper_small_account_liquidations_total{chain="base",hub="${HUB_2}"} 1`,
      `keeper_small_account_liquidations_total{chain="base",hub="${UNKNOWN_HUB}"} 1`,
    ]);
  });

  it("values Kr in wei from USD prices and reads it from LiquidationSettled", () => {
    // 0.809 USDC (6 decimals) at 1 USD, gas token at 2,500 USD: 0.809 / 2,500 ETH = 323,600,000,000,000 wei.
    expect(valueInWei(809_000n, 6, 100_000_000n, 250_000_000_000n)).toBe(323_600_000_000_000n);
    expect(() => valueInWei(1n, 6, 1n, 0n)).toThrow(/positive/);

    const swap = "0x00000000000000000000000000000000000000c1" as Address;
    const asset = "0x00000000000000000000000000000000000000a1" as Address;
    const event = lpVaultSwapAbi.find((e) => e.type === "event" && e.name === "LiquidationSettled")! as Extract<(typeof lpVaultSwapAbi)[number], { type: "event"; name: "LiquidationSettled" }>;
    const report = {
      debtReserveId: 1n, debtAsset: asset, debtRepaid: 780_000n, unitsSeized: 1n, amountsOut: [], recovered: 770_000n, minOut: 0n, effectiveSlippageBps: 0n, bonusBps: 0n,
      callerFunds: 819_000n, surplus: 0n, avanaFee: 0n, keeperReward: 12_345n, borrowerSurplus: 0n, keeperOut: 809_000n, minPayout: 0n, routeMode: 0, routeUsed: [], shortfall: 0n,
    };
    const topics = encodeEventTopics({ abi: [event], eventName: "LiquidationSettled", args: { caller: asset, proxy: asset, marketId: 7n } }) as Hex[];
    const data = encodeAbiParameters(event.inputs.filter((i) => !i.indexed), [report] as never);
    const r = liquidationReward([{ address: swap, topics, data }], swap);
    expect(r?.keeperReward).toBe(12_345n);
    expect(r?.debtAsset.toLowerCase()).toBe(asset); // decoded checksummed
    expect(liquidationReward([{ address: asset, topics, data }], swap)).toBeNull(); // another contract's log
  });
});

describe("gas spend", () => {
  it("renders the rolling 24 h spend by class and the spend counter by class and Hub", () => {
    const m = new ChainMetrics();
    m.spend24h = new Map([["urgent", 5n], ["scheduled", 7n], ["lazy", 0n]]);
    m.spent({ jobClass: "scheduled", hub: "0x0000000000000000000000000000000000000041", costWei: 4n });
    m.spent({ jobClass: "scheduled", hub: "0x0000000000000000000000000000000000000041", costWei: 3n });
    m.spent({ jobClass: "urgent", hub: null, costWei: 5n });
    const lines = samples(renderMetrics([{ chain: "mainnet", mode: "active", metrics: m }]));
    expect(lines.filter((l) => l.startsWith("keeper_gas_spend"))).toEqual([
      'keeper_gas_spend_24h_wei{chain="mainnet",class="urgent"} 5',
      'keeper_gas_spend_24h_wei{chain="mainnet",class="scheduled"} 7',
      'keeper_gas_spend_24h_wei{chain="mainnet",class="lazy"} 0',
      'keeper_gas_spend_wei_total{chain="mainnet",class="scheduled",hub="0x0000000000000000000000000000000000000041"} 7',
      `keeper_gas_spend_wei_total{chain="mainnet",class="urgent",hub="${UNKNOWN_HUB}"} 5`,
    ]);
  });
});
