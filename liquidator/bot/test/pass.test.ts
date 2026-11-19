// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import { describe, expect, it } from "vitest";
import type { Address } from "viem";
import type { Chain, ReadCall, WriteCall } from "../src/chain.ts";
import { type Config, loadConfig } from "../src/config.ts";
import { ONE } from "../src/decide.ts";
import { AccountSet } from "../src/discovery.ts";
import { Liquidator } from "../src/pass.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const ADAPTER = addr(0xa0);
const MODULE = addr(0xa1);
const RISK = addr(0xa2);
const VAULT = addr(0xa3);
const SPOKE = addr(0xa4);
const FLASH = addr(0xa5);
const ROUTER = addr(0xa6);
const USDC = addr(0xc0);
const WETH = addr(0xc1);
const BOT = addr(0xb0);
const SICK = addr(0x51);
const WELL = addr(0x52);

/** A node stand-in: two accounts in market 1, one below health factor 1. */
class FakeChain implements Chain {
  balance = 0n;
  allowance = 0n;
  flashBorrower = false;
  simulated: WriteCall[] = [];
  sent: WriteCall[] = [];
  logs = [
    { block: 5n, account: SICK, marketId: 1n },
    { block: 25_000n, account: WELL, marketId: 1n },
  ];

  async getBlockNumber() {
    return 30_000n;
  }
  async getAccountCreatedLogs(_: Address, from: bigint, to: bigint) {
    return this.logs.filter((l) => l.block >= from && l.block <= to);
  }
  async read<T>(c: ReadCall): Promise<T> {
    const r = (v: unknown) => v as T;
    switch (c.functionName) {
      case "RISK_MODULE":
        return r(RISK);
      case "LP_VAULT":
        return r(VAULT);
      case "getMarket":
        return r(c.address === RISK ? { spoke: SPOKE } : { token0: WETH, token1: USDC });
      case "getUserAccountData":
        return r({ healthFactor: c.args![0] === SICK ? ONE - 10n ** 16n : 2n * ONE });
      case "getUserTotalDebt":
        return r(c.args![0] === 2n ? 6500n * 10n ** 6n : 10n);
      case "getReserve":
        return r({ underlying: USDC });
      case "balanceOf":
        return r(this.balance);
      case "allowance":
        return r(this.allowance);
      case "isFlashBorrower":
        return r(this.flashBorrower);
    }
    throw new Error(`unexpected read ${c.functionName}`);
  }
  async simulate<T>(c: WriteCall): Promise<T> {
    this.simulated.push(c);
    return (c.functionName === "flashLiquidate" ? 200n * 10n ** 6n : {}) as T;
  }
  async send(c: WriteCall) {
    this.sent.push(c);
    return `0x${"11".repeat(32)}` as const;
  }
}

function config(flash: boolean): Config {
  return loadConfig({
    LIQUIDATOR_RPC_URL: "http://127.0.0.1:8545",
    LIQUIDATOR_CHAIN_ID: "31337",
    LIQUIDATOR_ADAPTER: ADAPTER,
    LIQUIDATOR_LIQUIDATION_MODULE: MODULE,
    LIQUIDATOR_DEBT_RESERVES: "1,2",
    LIQUIDATOR_KEYSTORE: "/unused",
    ...(flash ? { LIQUIDATOR_FLASH_LIQUIDATOR: FLASH, LIQUIDATOR_SWAP_ROUTER: ROUTER, LIQUIDATOR_SWAP_LEGS: `${WETH}:500` } : {}),
  });
}

describe("discovery", () => {
  it("reads AccountCreated in ranges and keeps what it saw", async () => {
    const chain = new FakeChain();
    const set = new AccountSet(chain, ADAPTER, 0n, 10_000n);
    expect((await set.refresh()).map((a) => a.account)).toEqual([SICK, WELL]);
    chain.logs = [];
    expect(await set.refresh()).toHaveLength(2);
  });
});

describe("liquidation pass", () => {
  const accounts = [
    { account: SICK, marketId: 1n },
    { account: WELL, marketId: 1n },
  ];

  it("liquidates only the unhealthy account, with its own funds, approving the module first", async () => {
    const chain = new FakeChain();
    chain.balance = 10_000n * 10n ** 6n;
    const outcomes = await new Liquidator(chain, config(false), BOT).pass(accounts);
    expect(outcomes).toHaveLength(1);
    expect(outcomes[0]!.decision).toEqual({ kind: "direct", debtToCover: 6500n * 10n ** 6n });
    expect(chain.sent.map((c) => c.functionName)).toEqual(["approve", "liquidate"]);
    const [p] = chain.sent[1]!.args as [{ debtReserveId: bigint; account: Address; receiver: Address }];
    expect(p).toMatchObject({ debtReserveId: 2n, account: SICK, receiver: BOT });
    expect(chain.simulated).toHaveLength(1);
  });

  it("takes a premium-free flash loan and sets the profit floor from the simulation", async () => {
    const chain = new FakeChain();
    chain.flashBorrower = true;
    chain.balance = 10_000n * 10n ** 6n;
    const outcomes = await new Liquidator(chain, config(true), BOT).pass(accounts);
    expect(outcomes[0]!.decision.kind).toBe("flash");
    expect(chain.sent).toHaveLength(1);
    const [req] = chain.sent[0]!.args as [{ flashAmount: bigint; minProfit: bigint; swaps: { tokenIn: Address }[] }];
    expect(req.flashAmount).toBe(6500n * 10n ** 6n);
    expect(req.minProfit).toBe(199n * 10n ** 6n);
    expect(req.swaps.map((s) => s.tokenIn)).toEqual([WETH]);
  });

  it("alerts when it has no funds and no flash path", async () => {
    const chain = new FakeChain();
    const lines: string[] = [];
    const outcomes = await new Liquidator(chain, config(false), BOT, (m) => lines.push(m)).pass(accounts);
    expect(outcomes[0]!.decision.kind).toBe("unfunded");
    expect(chain.sent).toHaveLength(0);
    expect(lines.some((l) => l.startsWith("ALERT"))).toBe(true);
  });

  it("records a failed account and goes on", async () => {
    const chain = new FakeChain();
    chain.balance = 10_000n * 10n ** 6n;
    chain.allowance = 10n ** 30n;
    chain.simulate = async () => {
      throw new Error("HealthyAccount");
    };
    const outcomes = await new Liquidator(chain, config(false), BOT).pass(accounts);
    expect(outcomes[0]!.decision).toEqual({ kind: "error", message: "HealthyAccount" });
    expect(chain.sent).toHaveLength(0);
  });
});
