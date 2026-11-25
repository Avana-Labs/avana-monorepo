// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Each AaveAdapter calldata builder: encode, decode with the ABI, and compare the function and every argument.

import { decodeAbiParameters, getAddress, maxUint256, toFunctionSelector, type Hex } from "viem";
import { describe, expect, it } from "vitest";
import { aaveAdapterAbi } from "../src/abis/index.ts";
import {
  aaveAdapterCall,
  decodeAaveAdapterCall,
  encodeAddLiquidity,
  encodeBorrow,
  encodeCollectFees,
  encodePledge,
  encodeRepay,
  encodeRepayAll,
  encodeRepayParams,
  encodeRepayWithCollateral,
  encodeWithdraw,
} from "../src/calldata/index.ts";

const RECIPIENT = getAddress("0x00000000000000000000000000000000000000aa");
const WALLET = getAddress("0x00000000000000000000000000000000000000bb");
const ADAPTER = getAddress("0x0000000000000000000000000000000000000ada");
const REPAY = getAddress("0x00000000000000000000000000000000000000cc");
const ROUTER = getAddress("0x00000000000000000000000000000000000000dd");
const TOKEN = getAddress("0x00000000000000000000000000000000000000ee");
const KEY = `0x${"ab".repeat(32)}` as Hex;
const MAX_UINT128 = 2n ** 128n - 1n;

const selector = (name: string) => {
  const f = aaveAdapterAbi.find((x) => x.type === "function" && x.name === name);
  if (!f || f.type !== "function") throw new Error(name);
  return toFunctionSelector(f);
};

describe("AaveAdapter calldata", () => {
  it("pledge names only the position: the Adapter routes it to the Full or Custom market", () => {
    const data = encodePledge({ positionKey: KEY });
    expect(data.slice(0, 10)).toBe(selector("pledge"));
    expect(decodeAaveAdapterCall(data).args).toEqual([KEY]);
  });

  it("addLiquidity", () => {
    const d = decodeAaveAdapterCall(encodeAddLiquidity({ positionKey: KEY, amount0Desired: 10n, amount1Desired: 20n, amount0Min: 9n, amount1Min: 19n }));
    expect(d.functionName).toBe("addLiquidity");
    expect(d.args).toEqual([KEY, 10n, 20n, 9n, 19n]);
  });

  it("withdraw, in part or whole (liquidity 0)", () => {
    const part = decodeAaveAdapterCall(encodeWithdraw({ positionKey: KEY, liquidity: 500n, amount0Min: 1n, amount1Min: 2n, recipient: RECIPIENT }));
    expect(part.functionName).toBe("withdraw");
    expect(part.args).toEqual([KEY, 500n, 1n, 2n, RECIPIENT]);
    expect(decodeAaveAdapterCall(encodeWithdraw({ positionKey: KEY, liquidity: 0n, amount0Min: 0n, amount1Min: 0n, recipient: RECIPIENT })).args?.[1]).toBe(0n);
  });

  it("borrow", () => {
    const d = decodeAaveAdapterCall(encodeBorrow({ marketId: 7n, reserveId: 3n, amount: 2_500_000_000n, recipient: RECIPIENT }));
    expect(d.functionName).toBe("borrow");
    expect(d.args).toEqual([7n, 3n, 2_500_000_000n, RECIPIENT]);
  });

  it("repay names the wallet; repayAll repays type(uint256).max", () => {
    const part = decodeAaveAdapterCall(encodeRepay({ marketId: 7n, reserveId: 3n, amount: 1_000_000n, wallet: WALLET }));
    expect(part.functionName).toBe("repay");
    expect(part.args).toEqual([7n, 3n, 1_000_000n, WALLET]);
    expect(decodeAaveAdapterCall(encodeRepayAll({ marketId: 7n, reserveId: 3n, wallet: WALLET })).args).toEqual([7n, 3n, maxUint256, WALLET]);
  });

  it("collectFees", () => {
    const d = decodeAaveAdapterCall(encodeCollectFees({ marketId: 7n, positionKeys: [KEY] }));
    expect(d.functionName).toBe("collectFees");
    expect(d.args).toEqual([7n, [KEY]]);
  });

  it("repay with collateral is allowWithdraw to the FlashloanRepay with its RepayParams", () => {
    const swaps = [{ tokenIn: TOKEN, target: ROUTER, data: "0x1234" as Hex, amountInOffset: 4n }];
    const args = { flashloanRepay: REPAY, positionKey: KEY, liquidity: 700n, reserveId: 3n, amount: maxUint256, amount0Min: 1n, amount1Min: 2n, swaps };
    const d = decodeAaveAdapterCall(encodeRepayWithCollateral(args));
    expect(d.functionName).toBe("allowWithdraw");
    const [operator, key, maxLiquidity, data] = d.args as readonly [string, Hex, bigint, Hex];
    expect([operator, key, maxLiquidity]).toEqual([REPAY, KEY, 700n]);
    expect(data).toBe(encodeRepayParams(args));
    const [params] = decodeAbiParameters(
      [{ type: "tuple", components: [{ name: "reserveId", type: "uint256" }, { name: "amount", type: "uint256" }, { name: "liquidity", type: "uint128" }, { name: "amount0Min", type: "uint256" }, { name: "amount1Min", type: "uint256" }, { name: "swaps", type: "tuple[]", components: [{ name: "tokenIn", type: "address" }, { name: "target", type: "address" }, { name: "data", type: "bytes" }, { name: "amountInOffset", type: "uint256" }] }] }],
      data,
    );
    expect(params).toEqual({ reserveId: 3n, amount: maxUint256, liquidity: 700n, amount0Min: 1n, amount1Min: 2n, swaps });
  });

  it("refuses an amount outside its integer type", () => {
    expect(() => encodeWithdraw({ positionKey: KEY, liquidity: MAX_UINT128 + 1n, amount0Min: 0n, amount1Min: 0n, recipient: RECIPIENT })).toThrow();
    expect(() => encodeBorrow({ marketId: 7n, reserveId: 3n, amount: maxUint256 + 1n, recipient: RECIPIENT })).toThrow();
  });

  it("wraps calldata as a non-payable call to the Adapter", () => {
    const data = encodePledge({ positionKey: KEY });
    expect(aaveAdapterCall(ADAPTER, data)).toEqual({ to: ADAPTER, data, value: 0n });
  });
});
