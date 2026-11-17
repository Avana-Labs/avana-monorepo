// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The per-chain crons run on the chains of AVANA_CHAIN_IDS: Ethereum and Base by default, with today's intervals, and
// Sepolia and Base Sepolia when the test deployment names them. A bad list stops the push instead of scheduling nothing.

import { describe, expect, it } from "vitest";
import { CHAIN_IDS_ENV, chainSchedule, cronChainIds, cronChains } from "../convex/lib/cronChains.ts";

describe("cron chains", () => {
  it("schedules Ethereum and Base when AVANA_CHAIN_IDS is unset or blank", () => {
    expect(cronChainIds({})).toEqual([1, 8453]);
    expect(cronChainIds({ [CHAIN_IDS_ENV]: "  " })).toEqual([1, 8453]);
  });

  it("keeps the production intervals: 30 s and 12 s on Ethereum, 10 s and 4 s on Base", () => {
    expect(cronChains({})).toEqual([
      { chainId: 1, pullSeconds: 30, intentSeconds: 12, merklCron: "17 * * * *" },
      { chainId: 8453, pullSeconds: 10, intentSeconds: 4, merklCron: "47 * * * *" },
    ]);
  });

  it("schedules Sepolia and Base Sepolia at their block times when the test deployment names them", () => {
    expect(cronChains({ [CHAIN_IDS_ENV]: "11155111, 84532" })).toEqual([
      { chainId: 11155111, pullSeconds: 30, intentSeconds: 12, merklCron: "17 * * * *" },
      { chainId: 84532, pullSeconds: 10, intentSeconds: 4, merklCron: "47 * * * *" },
    ]);
    expect(cronChainIds({ [CHAIN_IDS_ENV]: "84532" })).toEqual([84532]);
  });

  it("schedules the local nodes like the networks they stand in for", () => {
    expect(chainSchedule(31337)).toEqual({ ...chainSchedule(1), chainId: 31337 });
    expect(chainSchedule(31338)).toEqual({ ...chainSchedule(8453), chainId: 31338 });
  });

  it("refuses an unknown, repeated or malformed chain ID", () => {
    expect(() => cronChainIds({ [CHAIN_IDS_ENV]: "1,10" })).toThrow(/chain 10 is not one Convex serves/);
    expect(() => cronChainIds({ [CHAIN_IDS_ENV]: "84532,84532" })).toThrow(/listed twice/);
    expect(() => cronChainIds({ [CHAIN_IDS_ENV]: "sepolia" })).toThrow(/not a chain ID/);
    expect(() => cronChainIds({ [CHAIN_IDS_ENV]: "," })).toThrow(/names no chain/);
    expect(() => chainSchedule(10)).toThrow(/no schedule/);
  });
});
