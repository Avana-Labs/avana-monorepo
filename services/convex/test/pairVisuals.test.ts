// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A market's pair icons from its tokens' listing entries.

import { describe, expect, it } from "vitest";
import { fixtureMarkets } from "@avana/services-common/fixtures";
import { type MarketDoc, type World, pairVisuals } from "../convex/model.ts";

const m = { ...fixtureMarkets[0]!, slug: "m", updatedAt: 0 } as MarketDoc;
const token = (address: string, symbol: string, iconUrl?: string) => ({ scope: "token", chainId: m.chainId, key: address.toLowerCase(), symbol, name: symbol, ...(iconUrl ? { iconUrl } : {}) });
const world = (content: unknown[]) => ({ content }) as unknown as World;

describe("pair visuals", () => {
  it("takes each token's symbol and icon from its token entry", () => {
    const w = world([token(m.tokens[0]!, "USDC", "https://example.org/usdc.png"), token(m.tokens[1]!, "USDT")]);
    expect(pairVisuals(w, m)).toEqual([
      { symbol: "USDC", shortLabel: "USDC", bgClassName: "bg-muted", textClassName: "text-foreground", iconUrl: "https://example.org/usdc.png" },
      { symbol: "USDT", shortLabel: "USDT", bgClassName: "bg-muted", textClassName: "text-foreground" },
    ]);
  });

  it("gives none until both tokens have an entry", () => {
    expect(pairVisuals(world([token(m.tokens[0]!, "USDC")]), m)).toBeUndefined();
  });
});
