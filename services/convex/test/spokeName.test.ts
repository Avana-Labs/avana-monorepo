// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A Borrow pool's Spoke name from the Spoke's listing entry.

import { describe, expect, it } from "vitest";
import { type World, spokeNameOf } from "../convex/model.ts";

const SPOKE = "0x00000000000000000000000000000000000000Ab";
const world = (content: unknown[]) => ({ content }) as unknown as World;

describe("Spoke name", () => {
  it("takes the name of the Spoke's listing entry", () => {
    const w = world([{ scope: "spoke", chainId: 1, key: SPOKE.toLowerCase(), name: "Avana Blue Chip" }]);
    expect(spokeNameOf(w, 1, SPOKE)).toBe("Avana Blue Chip");
  });

  it("gives none without an entry on that chain", () => {
    const w = world([{ scope: "spoke", chainId: 8453, key: SPOKE.toLowerCase(), name: "Avana Blue Chip" }]);
    expect(spokeNameOf(w, 1, SPOKE)).toBeUndefined();
  });
});
