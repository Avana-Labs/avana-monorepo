// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The /metrics text: stable names and labels, one HELP and TYPE per family with its samples together, gauges without a
// value left out, and the open alerts as those raised for the last processed head.

import { describe, expect, it } from "vitest";
import { ChainMetrics, renderMetrics } from "../src/metrics.ts";
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
    expect(types).toEqual(["keeper_mode", "keeper_head_block", "keeper_indexer_block", "keeper_rpc_backfill_block", "keeper_discovered_accounts", "keeper_discovery_one_sided", "keeper_alerts_open", "keeper_alerts_total"]);
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
