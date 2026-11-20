// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Calldata of the AaveAdapter user actions, encoded with the generated `aaveAdapterAbi`. Amounts, market and reserve
// IDs are bigints (uint256 or uint128 on chain); a position key is the bytes32 the LPVault keys the NFT by.
//
// The Adapter routes a pledge itself (RiskModule.routeOf: exact full-range ticks go to the pool's Full range market,
// positions inside the Custom band to its Custom range market; anything else reverts NoMarketFits), so a pledge names
// no market. Borrow, repay and fee collection name the market, since a wallet has one account per (wallet, market).

import { decodeFunctionData, encodeAbiParameters, encodeFunctionData, maxUint256, type Address, type Hex } from "viem";
import { aaveAdapterAbi } from "../abis/index.ts";

/** A call to the AaveAdapter, ready for `sendTransaction`. Every action is non-payable. */
export interface AaveAdapterCall {
  readonly to: Address;
  readonly data: Hex;
  readonly value: 0n;
}

export interface BorrowArgs {
  readonly marketId: bigint;
  readonly reserveId: bigint;
  /** Debt-asset base units to draw. */
  readonly amount: bigint;
  readonly recipient: Address;
}

export interface RepayArgs {
  readonly marketId: bigint;
  readonly reserveId: bigint;
  /** Most debt asset pulled from the caller; the Adapter pulls only what is owed. */
  readonly amount: bigint;
  /** The wallet whose debt is repaid (anyone may repay for anyone). */
  readonly wallet: Address;
}

export interface PledgeArgs {
  readonly positionKey: Hex;
}

export interface AddLiquidityArgs {
  readonly positionKey: Hex;
  readonly amount0Desired: bigint;
  readonly amount1Desired: bigint;
  readonly amount0Min: bigint;
  readonly amount1Min: bigint;
}

export interface WithdrawArgs {
  readonly positionKey: Hex;
  /** Liquidity to remove; 0 withdraws the whole NFT. */
  readonly liquidity: bigint;
  readonly amount0Min: bigint;
  readonly amount1Min: bigint;
  readonly recipient: Address;
}

export interface CollectFeesArgs {
  readonly marketId: bigint;
  readonly positionKeys: readonly Hex[];
}

/** One swap the FlashloanRepay runs after the withdrawal (`SwapCalls.Swap`). */
export interface Swap {
  readonly tokenIn: Address;
  readonly target: Address;
  readonly data: Hex;
  /** Byte offset in `data` where the amount in is written; type(uint256).max to leave `data` as it is. */
  readonly amountInOffset: bigint;
}

export interface RepayWithCollateralArgs {
  /** The FlashloanRepay periphery, the operator the allowance is given to. */
  readonly flashloanRepay: Address;
  readonly positionKey: Hex;
  /** Liquidity the FlashloanRepay may remove (the allowance's bound) and removes. */
  readonly liquidity: bigint;
  readonly reserveId: bigint;
  /** Most debt repaid; `maxUint256` repays all of it (full repay). */
  readonly amount: bigint;
  readonly amount0Min: bigint;
  readonly amount1Min: bigint;
  readonly swaps: readonly Swap[];
}

/** `IFlashloanRepay.RepayParams` (a struct the interface takes only as encoded bytes, so its ABI does not carry it). */
const repayParams = [
  {
    type: "tuple",
    components: [
      { name: "reserveId", type: "uint256" },
      { name: "amount", type: "uint256" },
      { name: "liquidity", type: "uint128" },
      { name: "amount0Min", type: "uint256" },
      { name: "amount1Min", type: "uint256" },
      {
        name: "swaps",
        type: "tuple[]",
        components: [
          { name: "tokenIn", type: "address" },
          { name: "target", type: "address" },
          { name: "data", type: "bytes" },
          { name: "amountInOffset", type: "uint256" },
        ],
      },
    ],
  },
] as const;

export function encodePledge(a: PledgeArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "pledge", args: [a.positionKey] });
}

export function encodeAddLiquidity(a: AddLiquidityArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "addLiquidity",
    args: [a.positionKey, a.amount0Desired, a.amount1Desired, a.amount0Min, a.amount1Min],
  });
}

/** Withdraws part of the position (`liquidity` > 0) or the whole NFT (`liquidity` = 0). */
export function encodeWithdraw(a: WithdrawArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "withdraw",
    args: [a.positionKey, a.liquidity, a.amount0Min, a.amount1Min, a.recipient],
  });
}

export function encodeBorrow(a: BorrowArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "borrow", args: [a.marketId, a.reserveId, a.amount, a.recipient] });
}

/** Repays up to `amount` of the wallet's debt in the reserve. */
export function encodeRepay(a: RepayArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "repay", args: [a.marketId, a.reserveId, a.amount, a.wallet] });
}

/** Repays the wallet's whole debt in the reserve (amount = type(uint256).max). */
export function encodeRepayAll(a: Omit<RepayArgs, "amount">): Hex {
  return encodeRepay({ ...a, amount: maxUint256 });
}

export function encodeCollectFees(a: CollectFeesArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "collectFees", args: [a.marketId, a.positionKeys] });
}

/** The `data` the FlashloanRepay decodes in `onWithdrawAllowed` (`abi.encode(RepayParams)`). */
export function encodeRepayParams(a: Omit<RepayWithCollateralArgs, "flashloanRepay" | "positionKey">): Hex {
  return encodeAbiParameters(repayParams, [
    {
      reserveId: a.reserveId,
      amount: a.amount,
      liquidity: a.liquidity,
      amount0Min: a.amount0Min,
      amount1Min: a.amount1Min,
      swaps: a.swaps.map((s) => ({ tokenIn: s.tokenIn, target: s.target, data: s.data, amountInOffset: s.amountInOffset })),
    },
  ]);
}

/**
 * Repay with collateral, partial or full: `allowWithdraw(flashloanRepay, positionKey, liquidity, RepayParams)`. The
 * FlashloanRepay flash-borrows the debt asset, repays, withdraws `liquidity`, swaps and returns the rest to the wallet;
 * the Adapter reverts HealthFactorDecreased if the account ends with a lower health factor.
 */
export function encodeRepayWithCollateral(a: RepayWithCollateralArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "allowWithdraw",
    args: [a.flashloanRepay, a.positionKey, a.liquidity, encodeRepayParams(a)],
  });
}

/** The call to send: `data` from one of the encoders above, `to` the chain's AaveAdapter. */
export function aaveAdapterCall(to: Address, data: Hex): AaveAdapterCall {
  return { to, data, value: 0n };
}

/** Decodes AaveAdapter calldata (for a transaction review screen or a test). */
export function decodeAaveAdapterCall(data: Hex) {
  return decodeFunctionData({ abi: aaveAdapterAbi, data });
}
