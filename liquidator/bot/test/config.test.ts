// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import { describe, expect, it } from "vitest";
import { loadConfig, parseSwapLegs, refuseSecrets } from "../src/config.ts";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const base = {
  LIQUIDATION_BOT_RPC_URL: "http://127.0.0.1:8545",
  LIQUIDATION_BOT_CHAIN_ID: "31337",
  LIQUIDATION_BOT_ADAPTER: A,
  LIQUIDATION_BOT_LIQUIDATION_MODULE: B,
  LIQUIDATION_BOT_DEBT_RESERVES: "1, 2",
  LIQUIDATION_BOT_KEYSTORE: "/keys/liquidator",
};

describe("config", () => {
  it("reads the settings with defaults", () => {
    const c = loadConfig(base);
    expect(c.debtReserves).toEqual([1n, 2n]);
    expect(c.flashLiquidator).toBeUndefined();
    expect(c.passwordFile).toBeUndefined();
    expect(c.profitSlippageBps).toBe(50n);
    expect(c.maxTopUp).toBe(0n);
  });

  it("needs a router with the flash path", () => {
    expect(() => loadConfig({ ...base, LIQUIDATION_BOT_FLASH_LIQUIDATOR: A })).toThrow(/SWAP_ROUTER/);
    const c = loadConfig({ ...base, LIQUIDATION_BOT_FLASH_LIQUIDATOR: A, LIQUIDATION_BOT_SWAP_ROUTER: B, LIQUIDATION_BOT_SWAP_LEGS: `${A}:500` });
    expect(c.swapLegs).toEqual([{ token: "0x00000000000000000000000000000000000000A1", fee: 500 }]);
  });

  it("refuses a key, a mnemonic or a password value in the environment", () => {
    for (const name of ["PRIVATE_KEY", "LIQUIDATION_BOT_PRIVATE_KEY", "ETH_PRIVATEKEY", "MNEMONIC", "LIQUIDATION_BOT_PASSWORD", "SEED_PHRASE"]) {
      expect(() => refuseSecrets({ [name]: "x" })).toThrow(/refusing/);
      expect(() => loadConfig({ ...base, [name]: "x" })).toThrow(/refusing/);
    }
    expect(() => refuseSecrets({ LIQUIDATION_BOT_PASSWORD_FILE: "/run/secrets/p", PRIVATE_KEY: "" })).not.toThrow();
  });

  it("rejects bad values", () => {
    expect(() => loadConfig({ ...base, LIQUIDATION_BOT_ADAPTER: "0x12" })).toThrow(/address/);
    expect(() => loadConfig({ ...base, LIQUIDATION_BOT_KEYSTORE: "" })).toThrow(/KEYSTORE/);
    expect(() => loadConfig({ ...base, LIQUIDATION_BOT_PROFIT_SLIPPAGE_BPS: "10001" })).toThrow(/10,000/);
    expect(() => parseSwapLegs("0x12:500")).toThrow(/swap leg/);
  });
});
