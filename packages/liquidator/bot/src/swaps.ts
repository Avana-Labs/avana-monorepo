// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The flash path's route: each pool token sold for the debt asset through Uniswap's SwapRouter02 `exactInputSingle`.
// The amount is unknown until the liquidation pays out, so the contract writes its balance at `amountInOffset`.

import { type Address, encodeFunctionData } from "viem";
import { swapRouter02Abi } from "./abis.ts";
import type { SwapLeg } from "./config.ts";

/** Byte offset of `amountIn` in `exactInputSingle` calldata: the selector, then tokenIn, tokenOut, fee, recipient. */
export const EXACT_INPUT_SINGLE_AMOUNT_OFFSET = 4n + 4n * 32n;

export interface SwapCall {
  readonly tokenIn: Address;
  readonly target: Address;
  readonly data: `0x${string}`;
  readonly amountInOffset: bigint;
}

/**
 * One swap per pool token that is not the debt asset and has a leg. The minimum output is left to the contract's
 * `minProfit`, which the bot sets from a simulation of the whole transaction.
 */
export function buildSwaps(router: Address, recipient: Address, debtAsset: Address, tokens: readonly Address[], legs: readonly SwapLeg[]): SwapCall[] {
  const out: SwapCall[] = [];
  for (const token of tokens) {
    if (token.toLowerCase() === debtAsset.toLowerCase()) continue;
    const leg = legs.find((l) => l.token.toLowerCase() === token.toLowerCase());
    if (!leg) continue;
    const data = encodeFunctionData({
      abi: swapRouter02Abi,
      functionName: "exactInputSingle",
      args: [{ tokenIn: token, tokenOut: debtAsset, fee: leg.fee, recipient, amountIn: 0n, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }],
    });
    out.push({ tokenIn: token, target: router, data, amountInOffset: EXACT_INPUT_SINGLE_AMOUNT_OFFSET });
  }
  return out;
}
