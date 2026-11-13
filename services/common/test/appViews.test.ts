// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Lens views the app reads per account or Hub asset: each reader calls its view with the arguments in the
// Solidity order, a revert throws, and every fragment round-trips its struct through ABI encoding field for field.

import { describe, expect, it } from "vitest";
import { decodeFunctionResult, encodeFunctionResult, toFunctionSelector } from "viem";
import {
  LENS_SPOKE_KINDS,
  lensAppViewsAbi,
  readAccountFees,
  readActionPreview,
  readCloseAccount,
  readDeleverageTo,
  readHubAsset,
  readMaxWithdraw,
  readPositionFees,
} from "../src/views/appViews.ts";
import type { ContractCall, ViewClient } from "../src/views/client.ts";

const LENS = "0x9999999999999999999999999999999999999999" as const;
const WALLET = "0xaaaa00000000000000000000000000000000beef" as const;
const KEY = `0x${"ab".repeat(32)}` as const;
const WAD = 10n ** 18n;

function scripted(result: unknown = {}): ViewClient & { calls: ContractCall[] } {
  const calls: ContractCall[] = [];
  return {
    calls,
    async multicall(batch) {
      calls.push(...batch);
      return batch.map(() => ({ status: "success" as const, result }));
    },
  };
}

describe("app Lens readers", () => {
  it("call each view with its arguments in the Solidity order", async () => {
    const c = scripted();
    await readPositionFees(c, LENS, 4n, KEY);
    await readAccountFees(c, LENS, WALLET, 4n);
    await readActionPreview(c, LENS, { kind: "borrow", debtReserveId: 1n, amount: 2_500n }, WALLET, 4n);
    await readActionPreview(c, LENS, { kind: "repay", debtReserveId: 1n, amount: 2_500n }, WALLET, 4n);
    await readActionPreview(c, LENS, { kind: "pledge", positionKey: KEY }, WALLET, 4n);
    await readActionPreview(c, LENS, { kind: "withdraw", positionKey: KEY }, WALLET, 4n);
    await readMaxWithdraw(c, LENS, WALLET, 4n, 12n * 10n ** 17n);
    await readDeleverageTo(c, LENS, WALLET, 4n, KEY, 1n, 15n * 10n ** 17n);
    await readCloseAccount(c, LENS, WALLET, 4n, 1_800_000_000n);
    await readHubAsset(c, LENS, "0x1111111111111111111111111111111111111111", 2n);
    expect(c.calls.map((x) => [x.address, x.functionName, x.args])).toEqual([
      [LENS, "getPositionFees", [4n, KEY]],
      [LENS, "getAccountFees", [WALLET, 4n]],
      [LENS, "previewBorrowAfter", [WALLET, 4n, 1n, 2_500n]],
      [LENS, "previewRepayAfter", [WALLET, 4n, 1n, 2_500n]],
      [LENS, "previewPledgeAfter", [WALLET, 4n, KEY]],
      [LENS, "previewWithdrawAfter", [WALLET, 4n, KEY]],
      [LENS, "previewMaxWithdraw", [WALLET, 4n, 12n * 10n ** 17n]],
      [LENS, "previewDeleverageTo", [WALLET, 4n, KEY, 1n, 15n * 10n ** 17n]],
      [LENS, "previewCloseAccount", [WALLET, 4n, 1_800_000_000n]],
      [LENS, "getHubAsset", ["0x1111111111111111111111111111111111111111", 2n]],
    ]);
  });

  it("throw when the view reverts", async () => {
    const reverting: ViewClient = { multicall: async (calls) => calls.map(() => ({ status: "failure" as const, error: new Error("UnknownHubAsset") })) };
    await expect(readHubAsset(reverting, LENS, "0x1111111111111111111111111111111111111111", 9n)).rejects.toThrow(/getHubAsset .* reverted/);
  });

  it("name the Lens Spoke kinds in enum order, the DAO deficit offset last", () => {
    expect(LENS_SPOKE_KINDS).toEqual(["lend", "cdp", "coverage", "feeReceiver", "other", "deficitOffset"]);
  });
});

describe("app Lens fragments", () => {
  it("round-trip an after-action preview and a close-account view field for field", () => {
    const preview = {
      blockNumber: 7n,
      timestamp: 1_000n,
      proxy: "0xbBBB00000000000000000000000000000000CafE",
      amount: 2_500n,
      healthFactorBefore: 2n * WAD,
      healthFactorAfter: 15n * 10n ** 17n,
      liquidationPriceBefore: 10n ** 8n,
      liquidationPriceAfter: 13n * 10n ** 7n,
      collateralValueAfter: 4n * 10n ** 30n,
      debtValueAfterRay: 3n * 10n ** 57n,
    } as const;
    const data = encodeFunctionResult({ abi: lensAppViewsAbi, functionName: "previewBorrowAfter", result: preview });
    expect(decodeFunctionResult({ abi: lensAppViewsAbi, functionName: "previewBorrowAfter", data })).toEqual(preview);

    const close = {
      blockNumber: 7n,
      timestamp: 1_000n,
      proxy: "0xbBBB00000000000000000000000000000000CafE",
      debts: [{ reserveId: 1n, asset: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", total: 1_950n, maxRepaySpend: 1_951n }],
      records: [{ positionKey: KEY, units: 10n ** 18n, amounts: [5n, 6n] }],
    } as const;
    const closeData = encodeFunctionResult({ abi: lensAppViewsAbi, functionName: "previewCloseAccount", result: close });
    expect(decodeFunctionResult({ abi: lensAppViewsAbi, functionName: "previewCloseAccount", data: closeData })).toEqual(close);
  });

  it("use the selectors of the Solidity signatures", () => {
    const sel = (name: string) => toFunctionSelector(lensAppViewsAbi.find((f) => f.type === "function" && f.name === name)!);
    expect(sel("getHubAsset")).toBe(toFunctionSelector("getHubAsset(address,uint256)"));
    expect(sel("previewDeleverageTo")).toBe(toFunctionSelector("previewDeleverageTo(address,uint256,bytes32,uint256,uint256)"));
    expect(sel("getAccountFees")).toBe(toFunctionSelector("getAccountFees(address,uint256)"));
  });
});
