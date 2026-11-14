// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The raw-key signer exists only for the local anvil rehearsal: KEEPER_LOCAL_KEY_<CHAIN> is refused on every other
// network set, so a published or test-network keeper signs only through the KMS (Q-245).

import { describe, expect, it } from "vitest";
import { CHAINS } from "@avana/services-common";
import { localKeySigner } from "../src/adapters/localKey.ts";
import { localKey } from "../src/config.ts";

// Anvil's published test account #7, the operator helper's signer in the rehearsal world.
const KEY = "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356";

describe("local rehearsal key", () => {
  it("is read on the local network set", () => {
    expect(localKey({ KEEPER_LOCAL_KEY_ANVIL: KEY }, CHAINS.anvil)).toBe(KEY);
    expect(localKey({}, CHAINS.anvil)).toBeUndefined();
  });

  it("is refused on production and test networks", () => {
    for (const chain of [CHAINS.mainnet, CHAINS.base, CHAINS.sepolia, CHAINS.baseSepolia]) {
      expect(() => localKey({ [`KEEPER_LOCAL_KEY_${chain.envSuffix}`]: KEY }, chain)).toThrow(/only on the local network set/);
    }
  });

  it("must be a 32-byte hex key", () => {
    expect(() => localKey({ KEEPER_LOCAL_KEY_ANVIL: "0x1234" }, CHAINS.anvil)).toThrow(/32-byte hex key/);
  });

  it("signs as the account the rehearsal binds the operator helper to", () => {
    expect(localKeySigner(KEY).address).toBe("0x14dC79964da2C08b23698B3D3cc7Ca32193d9955");
  });
});
