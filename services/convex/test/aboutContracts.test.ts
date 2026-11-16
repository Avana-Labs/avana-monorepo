// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The About card's contract slots: each page fills Vault, Token, Risk Manager and Oracle Router with a short address
// and an explorer link, and leaves out a slot the deployment does not name yet.

import { describe, expect, it } from "vitest";
import { fixtureHubAsset, fixtureMarkets, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import { aboutContractRows } from "../convex/lib/aboutContracts.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const market = fixtureMarkets[0]!;
const reserve = fixtureSpokeReserves[0]!;
const dep = {
  explorerUrl: "https://etherscan.io",
  lpVaults: [{ integrationId: market.integrationId, address: A(0xa1) }],
  riskModule: A(0xa2),
  spokeOracles: [
    { spoke: reserve.spoke, oracle: A(0xa3) },
    { spoke: fixtureHubAsset.lendReserves[0]!.spoke, oracle: A(0xa4) },
  ],
};
const bySalt = (rows: ReturnType<typeof aboutContractRows>) => Object.fromEntries(rows.map((r) => [r.salt, r.address]));

describe("About card contract slots", () => {
  it("fills a pool page from its LPVault, vault token, RiskModule and LP oracle", () => {
    const rows = aboutContractRows("pool", "p", "ethereum", market, dep);
    expect(bySalt(rows)).toEqual({ vault: A(0xa1), token: market.vaultToken.toLowerCase(), riskManager: A(0xa2), oracleRouter: market.lpOracle.toLowerCase() });
    expect(rows[0]).toMatchObject({ label: "0x0000...00a1", href: `https://etherscan.io/address/${A(0xa1)}`, isSynthetic: false });
  });

  it("fills a Borrow asset page from its Hub, asset, CDP Spoke and that Spoke's oracle", () => {
    const rows = aboutContractRows("asset", "a", "ethereum", reserve, dep);
    expect(bySalt(rows)).toEqual({ vault: reserve.hub.toLowerCase(), token: reserve.asset.toLowerCase(), riskManager: reserve.spoke.toLowerCase(), oracleRouter: A(0xa3) });
  });

  it("fills a Lend page from its Hub, underlying, Lend Spoke and that Spoke's oracle", () => {
    const rows = aboutContractRows("lend", "l", "ethereum", fixtureHubAsset, dep);
    expect(rows.map((r) => r.salt)).toEqual(["vault", "token", "riskManager", "oracleRouter"]);
    expect(bySalt(rows).oracleRouter).toBe(A(0xa4));
  });

  it("leaves out slots the deployment does not name, and links nothing on a chain with no explorer", () => {
    const rows = aboutContractRows("pool", "p", "local", market, { explorerUrl: "" });
    expect(rows.map((r) => r.salt)).toEqual(["token", "oracleRouter"]);
    expect(rows.every((r) => r.href === "")).toBe(true);
  });
});
