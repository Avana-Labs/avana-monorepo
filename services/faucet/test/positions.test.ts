// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The starting positions run as the impersonated wallet, stop impersonating whatever happens, and record a market or
// reserve the chain cannot serve as a failed step instead of failing the grant.

import { describe, expect, it } from "vitest";
import type { Rpc } from "../src/chain.ts";
import { openStartingPositions, type PositionsManifest } from "../src/positions.ts";

const WALLET = "0x00000000000000000000000000000000000A11cE";
const manifest: PositionsManifest = {
  avana: {
    aaveAdapter: { address: "0x00000000000000000000000000000000000000a1" },
    marketRegistry: { address: "0x00000000000000000000000000000000000000a2" },
    lpVaults: [{ address: "0x00000000000000000000000000000000000000a3", integrationId: 1, kind: "uniswap-v3" }],
  },
  markets: [{ marketId: "1" }, { marketId: "2" }],
  debtReserves: [],
  aave: { hubs: [], lendSpokes: [] },
};

describe("openStartingPositions", () => {
  it("records unreachable markets as failed steps and stops impersonating", async () => {
    const calls: string[] = [];
    const rpc: Rpc = {
      async request({ method }) {
        calls.push(method);
        if (method === "eth_call") throw new Error("execution reverted");
        return null;
      },
    };
    const steps = await openStartingPositions(rpc, WALLET, manifest, []);
    expect(calls[0]).toBe("anvil_impersonateAccount");
    expect(calls.at(-1)).toBe("anvil_stopImpersonatingAccount");
    expect(steps.filter((s) => s.step.startsWith("LP position"))).toHaveLength(2);
    expect(steps.every((s) => s.failed)).toBe(true);
    // No LP position, so no pledge; the debts have no pledged market; no Lend token in an empty manifest.
    expect(steps.map((s) => s.step)).toEqual(["LP position market 1", "LP position market 2", "borrow USDC", "borrow USDT"]);
  });
});
