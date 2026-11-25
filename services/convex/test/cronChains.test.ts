// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The crons run on the chains of AVANA_CHAIN_IDS only: a deployment without it (a development deployment) schedules
// nothing, the production deployment names Ethereum and Base and the test deployment Sepolia and Base Sepolia. The
// sampler and the pull run every 60 s; the intent tracker runs about once a block while intents are open (intents.ts).
// A bad list stops the push instead of scheduling nothing.

import { describe, expect, it } from "vitest";
import { CHAIN_IDS_ENV, PULL_SECONDS, SAMPLE_SECONDS, chainSchedule, cronChainIds, cronChains } from "../convex/lib/cronChains.ts";

describe("cron chains", () => {
  it("schedules no chain when AVANA_CHAIN_IDS is unset or blank", () => {
    expect(cronChainIds({})).toEqual([]);
    expect(cronChainIds({ [CHAIN_IDS_ENV]: "  " })).toEqual([]);
    expect(cronChains({})).toEqual([]);
  });

  it("samples and pulls every 60 s and tracks intents about once a block, on Ethereum and Base", () => {
    expect([SAMPLE_SECONDS, PULL_SECONDS]).toEqual([60, 60]);
    expect(cronChains({ [CHAIN_IDS_ENV]: "1,8453" })).toEqual([
      { chainId: 1, sampleSeconds: 60, pullSeconds: 60, intentSeconds: 12, merklCron: "17 * * * *" },
      { chainId: 8453, sampleSeconds: 60, pullSeconds: 60, intentSeconds: 4, merklCron: "47 * * * *" },
    ]);
  });

  it("schedules Sepolia and Base Sepolia when the test deployment names them", () => {
    expect(cronChains({ [CHAIN_IDS_ENV]: "11155111, 84532" })).toEqual([
      { chainId: 11155111, sampleSeconds: 60, pullSeconds: 60, intentSeconds: 12, merklCron: "17 * * * *" },
      { chainId: 84532, sampleSeconds: 60, pullSeconds: 60, intentSeconds: 4, merklCron: "47 * * * *" },
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
