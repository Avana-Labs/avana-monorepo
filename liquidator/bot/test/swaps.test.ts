// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import { describe, expect, it } from "vitest";
import { decodeFunctionData, getAddress, hexToBigInt, slice } from "viem";
import { swapRouter02Abi } from "../src/abis.ts";
import { EXACT_INPUT_SINGLE_AMOUNT_OFFSET, buildSwaps } from "../src/swaps.ts";

const WETH = "0x4200000000000000000000000000000000000006";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const BOT = getAddress("0x00000000000000000000000000000000000000b0");

describe("swaps", () => {
  it("sells each pool token that is not the debt asset", () => {
    const swaps = buildSwaps(ROUTER, BOT, USDC, [WETH, USDC], [{ token: WETH, fee: 500 }]);
    expect(swaps).toHaveLength(1);
    const [s] = swaps;
    const { args } = decodeFunctionData({ abi: swapRouter02Abi, data: s!.data });
    expect(args[0]).toMatchObject({ tokenIn: WETH, tokenOut: USDC, fee: 500, recipient: BOT, amountIn: 0n });
  });

  it("points the amount offset at amountIn", () => {
    const [s] = buildSwaps(ROUTER, BOT, USDC, [WETH], [{ token: WETH, fee: 500 }]);
    const o = Number(EXACT_INPUT_SINGLE_AMOUNT_OFFSET);
    // Write a marker where the contract would, then decode it back as amountIn.
    const patched = (s!.data.slice(0, 2 + o * 2) + (1234n).toString(16).padStart(64, "0") + s!.data.slice(2 + (o + 32) * 2)) as `0x${string}`;
    const { args } = decodeFunctionData({ abi: swapRouter02Abi, data: patched });
    expect(args[0].amountIn).toBe(1234n);
    expect(hexToBigInt(slice(patched, o, o + 32))).toBe(1234n);
  });

  it("skips a token without a leg", () => {
    expect(buildSwaps(ROUTER, BOT, USDC, [WETH], [])).toEqual([]);
  });
});
