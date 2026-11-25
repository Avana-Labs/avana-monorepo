// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The deployment row from a release manifest (schema 2): each integration's core stack, both markets of a pool, the
// loss layers and debt reserves, and the snapshot reader's deployment built from the row.

import { describe, expect, it } from "vitest";
import { sampleManifest } from "@avana/protocol/manifest/sample";
import { deploymentOfManifest } from "../convex/deployments.ts";
import { chainDeployment } from "../convex/ingest/sampler.ts";

const settings = { explorerUrl: "https://sepolia.etherscan.io", nativeUsdFeed: "0x00000000000000000000000000000000000000f9" };

describe("deploymentOfManifest", () => {
  it("records the integrations, both markets of the pool, the loss layers and the debt reserves", () => {
    const m = sampleManifest();
    const d = deploymentOfManifest(JSON.parse(JSON.stringify(m)), settings);
    expect(d.integrations!.map((x) => [x.integrationId, x.kind, x.aaveAdapter])).toEqual([[1, "uniswap-v3", m.avana.integrations[0]!.aaveAdapter.address]]);
    expect(d.markets!.map((x) => [x.marketId, x.kind])).toEqual([
      ["1", "full-range"],
      ["2", "custom-range"],
    ]);
    expect(d.firstLossReserves).toHaveLength(1);
    expect(d.deficitOffsets).toHaveLength(1);
    expect(d.debtReserves).toEqual([{ spoke: m.debtReserves[0]!.spoke, reserveId: "1", fixedPrice: false }]);
    expect(d.feeRecipient).toBe(m.feeRecipient);
  });

  it("refuses a manifest of the replaced schema", () => {
    expect(() => deploymentOfManifest({ ...sampleManifest(), schemaVersion: 1 }, settings)).toThrow(/schema 1/);
  });

  it("gives the snapshot reader each market with its integration's RiskModule", () => {
    const m = sampleManifest();
    const d = deploymentOfManifest(JSON.parse(JSON.stringify(m)), settings);
    const row = { ...d, _id: "x", _creationTime: 0, chainSlug: "sepolia", cdpSpokes: d.cdpSpokes.map((s) => ({ address: (s as string).toLowerCase() })) } as never;
    const dep = chainDeployment(row);
    expect(dep.riskModules).toEqual([m.avana.integrations[0]!.riskModule.address]);
    expect(dep.markets.map((x) => [x.marketId, x.riskModule])).toEqual([
      [1n, m.avana.integrations[0]!.riskModule.address],
      [2n, m.avana.integrations[0]!.riskModule.address],
    ]);
  });
});
