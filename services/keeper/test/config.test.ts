// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot runner's configuration: the LiquidationBot settings with the manifest's chain, the optional stream, monitor
// and kill-switch sets (all or none), secrets from files only, and each integration's contracts with the
// FlashLiquidator this signer operates.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import type { Address } from "viem";
import { integrationsOf, loadRunnerConfig, spokeDebtReservesOf } from "../src/config.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const SIGNER = A(0x55);
const stack = (id: number, base: number) => ({ integrationId: id, kind: "uniswap-v3", aaveAdapter: { address: A(base + 3), startBlock: 5 }, liquidationModule: { address: A(base + 2), startBlock: 5 } });
const manifest = {
  chainId: 8453,
  avana: { integrations: [stack(1, 0x100), stack(2, 0x200)], flashLiquidators: [{ integrationId: 2, address: A(0x2f), operator: SIGNER }, { integrationId: 1, address: A(0x1f), operator: A(0x99) }] },
  debtReserves: [{ spoke: A(0xb0), debtReserveId: 1n }, { spoke: A(0xb0), debtReserveId: 2n }, { spoke: A(0xb1), debtReserveId: 1n }],
  roles: { keepers: [SIGNER] },
} as unknown as ServiceManifest;

const base = { AVANA_MANIFEST: "base.json", LIQUIDATION_BOT_RPC_URL: "http://rpc", LIQUIDATION_BOT_CHAIN_ID: "8453", LIQUIDATION_BOT_KEYSTORE: "/k", KEEPER_HALT_STATE_PATH: "/data/halt.json" };
const load = (env: Record<string, string>) => loadRunnerConfig(env, () => manifest, () => "token\n");

describe("loadRunnerConfig", () => {
  it("reads a minimal configuration: RPC discovery, no monitor, no kill switch", () => {
    const c = load(base);
    expect([c.settings.chainId, c.indexer, c.monitor, c.killSwitch, c.metricsPort, c.haltStatePath]).toEqual([8453, null, null, null, null, "/data/halt.json"]);
  });

  it("reads the stream, the monitor (token from its file) and the kill switch when each is set whole", () => {
    const c = load({ ...base, KEEPER_INDEXER_URL: "http://indexer", KEEPER_INDEXER_KEY_FILE: "/k/stream", KEEPER_MONITOR_URL: "http://monitor", KEEPER_MONITOR_INSTANCE: "base-primary", KEEPER_MONITOR_TOKEN_FILE: "/k/monitor", KEEPER_KILL_SWITCH_PORT: "9443", KEEPER_KILL_SWITCH_TLS_CERT: "c", KEEPER_KILL_SWITCH_TLS_KEY: "k", KEEPER_KILL_SWITCH_CLIENT_CA: "ca", KEEPER_METRICS_PORT: "9464" });
    expect(c.indexer).toEqual({ url: "http://indexer", keyFile: "/k/stream" });
    expect(c.monitor).toEqual({ url: "http://monitor", instance: "base-primary", token: "token" });
    expect(c.killSwitch?.port).toBe(9443);
    expect(c.metricsPort).toBe(9464);
  });

  it("refuses a partial set, a manifest of another chain and a secret in the environment", () => {
    expect(() => load({ ...base, KEEPER_INDEXER_URL: "http://indexer" })).toThrow(/KEEPER_INDEXER_KEY_FILE/);
    expect(() => load({ ...base, LIQUIDATION_BOT_CHAIN_ID: "1" })).toThrow(/chain 8453/);
    expect(() => load({ ...base, LIQUIDATION_BOT_PRIVATE_KEY: "x" })).toThrow(/secret-bearing/);
  });
});

describe("manifest lookups", () => {
  it("gives each integration its contracts and only the FlashLiquidator this signer operates", () => {
    expect(integrationsOf(manifest, SIGNER)).toEqual([
      { integrationId: 1, aaveAdapter: A(0x103), liquidationModule: A(0x102) },
      { integrationId: 2, aaveAdapter: A(0x203), liquidationModule: A(0x202), flashLiquidator: A(0x2f) },
    ]);
  });

  it("lists the debt reserves of each Spoke", () => {
    expect([...spokeDebtReservesOf(manifest)]).toEqual([
      [A(0xb0), [1n, 2n]],
      [A(0xb1), [1n]],
    ]);
  });
});
