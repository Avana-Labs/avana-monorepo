// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-33: the standby instance's signer below its minimum balance warns at every block it stays below, so the standby is
// never found empty when it must take over; its configuration defaults the minimum to 3 days of the expected spend.

import { describe, expect, it, vi } from "vitest";
import type { Address, PublicClient } from "viem";
import { standbySigner } from "../src/config.ts";
import type { Alert } from "../src/monitoring/alerts.ts";
import { fundingCheck, m33Level } from "../src/monitoring/funding.ts";

const STANDBY = "0x0000000000000000000000000000000000000052" as Address;

function check(balance: bigint) {
  const sent: Alert[] = [];
  const client = { getBalance: vi.fn(async () => balance) } as unknown as PublicClient;
  const run = fundingCheck({
    chainId: 8453,
    primary: client,
    fallback: client,
    alerts: { send: async (a) => void sent.push(a) },
    assets: [],
    fundingSafe: STANDBY,
    helper: STANDBY,
    largest: new Map(),
    free: () => 0n,
    gas: null,
    standby: { signer: STANDBY, minBalanceWei: 1_000n },
  });
  return { run, sent };
}

describe("M-33 standby signer", () => {
  it("warns below its minimum balance and never pages", async () => {
    expect([999n, 1_000n].map((b) => m33Level(b, 1_000n))).toEqual(["warn", "ok"]);
    const low = check(999n);
    await low.run({ number: 5n, timestamp: 0n });
    expect(low.sent).toEqual([expect.objectContaining({ signal: "M-33", level: "warn", chainId: 8453, blockNumber: 5n, subject: `standby:${STANDBY}`, detail: expect.objectContaining({ balanceWei: "999", minBalanceWei: "1000" }) })]);
    const ok = check(1_000n);
    await ok.run({ number: 5n, timestamp: 0n });
    expect(ok.sent).toEqual([]);
  });

  it("reads KEEPER_STANDBY_SIGNER_<CHAIN> and its minimum, 3 days of the expected spend by default", () => {
    expect(standbySigner({}, "BASE", 10n)).toBeNull();
    expect(standbySigner({ KEEPER_STANDBY_SIGNER_BASE: STANDBY }, "BASE", 10n)).toEqual({ signer: STANDBY, minBalanceWei: 30n });
    expect(standbySigner({ KEEPER_STANDBY_SIGNER_BASE: STANDBY, KEEPER_STANDBY_MIN_BALANCE_WEI_BASE: "7" }, "BASE", undefined)).toEqual({ signer: STANDBY, minBalanceWei: 7n });
    expect(() => standbySigner({ KEEPER_STANDBY_SIGNER_BASE: "0x12" }, "BASE", 10n)).toThrow(/address/);
    expect(() => standbySigner({ KEEPER_STANDBY_MIN_BALANCE_WEI_BASE: "7" }, "BASE", 10n)).toThrow(/without KEEPER_STANDBY_SIGNER_BASE/);
    expect(() => standbySigner({ KEEPER_STANDBY_SIGNER_BASE: STANDBY }, "BASE", undefined)).toThrow(/KEEPER_STANDBY_MIN_BALANCE_WEI_BASE/);
  });
});
