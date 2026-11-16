// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The standby's 60 s: an account first read below HF 1 at block `since` is acted on at since + 5 on a 12 s chain,
// never at since + 4, so its liquidation is mined at since + 6 at the earliest.

import { describe, expect, it } from "vitest";
import { CHAINS } from "@avana/services-common";
import { mayAct, standbyBlocks } from "../src/shard.ts";

const PROXY = "0x21C57963a01605D8E4262fB4896B828da4dEF75a";

describe("mayAct for the standby", () => {
  it("waits 5 blocks on Ethereum, 30 on Base", () => {
    expect(standbyBlocks(CHAINS.mainnet)).toBe(5);
    expect(standbyBlocks(CHAINS.base)).toBe(30);
  });

  it("acts on the drill's account at 7388, not at 7387, when it was first below HF 1 at 7383", () => {
    expect(mayAct(CHAINS.mainnet, "standby", null, PROXY, 7383n, 7387n)).toBe(false);
    expect(mayAct(CHAINS.mainnet, "standby", null, PROXY, 7383n, 7388n)).toBe(true);
  });
});
