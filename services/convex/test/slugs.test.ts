// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Default slugs of debt-reserve pages are unique per (chain, Spoke, Hub, token): one Spoke drawing the same token from
// two Hubs gets two pages, a single-Hub reserve keeps its slug, and no slug depends on the order the reserves are read.

import { describe, expect, it } from "vitest";
import { type AssetSlugInput, assetSlugs, defaultSlug } from "../convex/lib/format.ts";

const USDC = "0x00000000000000000000000000000000000000a1";
const USDC_BRIDGED = "0x00000000000000000000000000000000000000b2";
const GHO = "0x00000000000000000000000000000000000000c3";
const r = (key: string, hubLabel: string, symbol: string, asset: string, spokeLabel = "uniV3Stable"): AssetSlugInput => ({ key, spokeLabel, hubLabel, symbol, asset });

describe("debt reserve slugs", () => {
  it("keeps chain-spoke-symbol for a token the Spoke draws from one Hub", () => {
    const slugs = assetSlugs(1, [r("s:1", "Stable LP", "GHO", GHO), r("s:2", "Stable LP", "USDC", USDC)]);
    expect(slugs.get("s:1")).toBe(defaultSlug.asset(1, "uniV3Stable", "GHO"));
    expect(slugs.get("s:1")).toBe("ethereum-univ3stable-gho");
    expect(slugs.get("s:2")).toBe("ethereum-univ3stable-usdc");
  });

  it("tells the same token from two Hubs on one Spoke apart by the Hub, in any order", () => {
    const reserves = [r("s:1", "Stable LP", "USDC", USDC), r("s:2", "Core", "USDC", USDC), r("s:3", "Stable LP", "GHO", GHO)];
    const slugs = assetSlugs(1, reserves);
    expect(slugs.get("s:1")).toBe("ethereum-univ3stable-stable-lp-usdc");
    expect(slugs.get("s:2")).toBe("ethereum-univ3stable-core-usdc");
    expect(slugs.get("s:3")).toBe("ethereum-univ3stable-gho");
    expect(assetSlugs(1, [...reserves].reverse())).toEqual(slugs);
    expect(new Set(slugs.values()).size).toBe(reserves.length);
  });

  it("adds the token's address when two tokens share a symbol on one Hub", () => {
    const native = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
    const bridged = "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca";
    const slugs = assetSlugs(8453, [r("s:1", "Core", "USDC", native), r("s:2", "Core", "USDC", bridged)]);
    expect(slugs.get("s:1")).toBe("base-univ3stable-core-usdc-833589");
    expect(slugs.get("s:2")).toBe("base-univ3stable-core-usdc-d9aaec");
    // Addresses that share their first six digits fall back to the whole address.
    const close = assetSlugs(8453, [r("s:1", "Core", "USDC", USDC), r("s:2", "Core", "USDC", USDC_BRIDGED)]);
    expect(close.get("s:1")).toBe(`base-univ3stable-core-usdc-${USDC.slice(2)}`);
    expect(new Set(close.values()).size).toBe(2);
  });

  it("does not rename the same token on two different Spokes", () => {
    const slugs = assetSlugs(1, [r("a:1", "Stable LP", "USDC", USDC, "uniV3Stable"), r("b:1", "Core", "USDC", USDC, "slipCore")]);
    expect(slugs.get("a:1")).toBe("ethereum-univ3stable-usdc");
    expect(slugs.get("b:1")).toBe("ethereum-slipcore-usdc");
  });
});
