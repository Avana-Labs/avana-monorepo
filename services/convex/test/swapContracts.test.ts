// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The swap provider's contracts from the manifest's `external` list.

import { describe, expect, it } from "vitest";
import { swapContracts } from "../convex/lib/swapContracts.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const e = (group: string, name: string, n: number, standIn = false) => ({ group, name, address: A(n), standIn });

describe("swap contracts", () => {
  it("lists a venue only when the manifest names both its router and quoter", () => {
    const c = swapContracts(31337, A(9), [
      e("uniswap-v3", "UniswapV3SwapRouter", 1),
      e("uniswap-v3", "UniswapV3QuoterV2", 2),
      e("uniswap-v4", "UniswapV4Quoter", 3),
      e("slipstream", "SlipstreamSwapRouter", 4),
      e("slipstream", "SlipstreamQuoterV2", 5),
      e("slipstream", "AeroSlipstreamFactory", 6),
      e("token", "USDC", 7, true),
      e("token", "WETH", 8),
      e("feed", "USDC / USD (primary)", 10),
    ]);
    expect(c.venues).toEqual([
      { venue: "uniswap-v3", router: A(1), quoter: A(2) },
      { venue: "slipstream", router: A(4), quoter: A(5) },
    ]);
    expect(c.tokens).toEqual([
      { symbol: "USDC", address: A(7) },
      { symbol: "WETH", address: A(8) },
    ]);
    expect(c.nativeUsdFeed).toBe(A(9));
  });
});
