// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Calldata of the AaveAdapter user actions the web app sends, encoded with the generated `aaveAdapterAbi`. Every amount,
// ID, deadline and health factor is a bigint (uint256 or uint128 on chain); an integration ID is a number (uint32).
// The builders only encode: amounts, minimums and deadlines come from the caller's preview (Lens) and slippage settings.

import { decodeFunctionData, encodeFunctionData, type Address, type Hex } from "viem";
import { aaveAdapterAbi } from "../abis/index.ts";

/** A position in an LPVault: the integration that holds it and its key there (`PositionRef`). */
export interface PositionRef {
  readonly integrationId: number;
  readonly positionKey: Hex;
}

/** A call to the AaveAdapter proxy, ready for `sendTransaction`. Every action is non-payable. */
export interface AaveAdapterCall {
  readonly to: Address;
  readonly data: Hex;
  readonly value: 0n;
}

export interface BorrowArgs {
  readonly marketId: bigint;
  readonly debtReserveId: bigint;
  /** Debt-asset base units to draw. */
  readonly amount: bigint;
  readonly receiver: Address;
  /** Last valid `block.timestamp`. */
  readonly deadline: bigint;
  /** Least health factor after the borrow, WAD; 0 for none. */
  readonly minHealthFactor: bigint;
  /** Must equal the account's `borrowNonce(proxy)`. */
  readonly expectedNonce: bigint;
}

export interface RepayArgs {
  readonly borrower: Address;
  readonly marketId: bigint;
  readonly debtReserveId: bigint;
  /** Most the payer allows to be pulled, base units; Aave takes at most the debt and the rest is returned. */
  readonly maxRepaySpend: bigint;
  readonly deadline: bigint;
}

export interface RepayWithCollateralArgs {
  readonly marketId: bigint;
  readonly position: PositionRef;
  /** Credited units released and sold for the debt asset. */
  readonly units: bigint;
  readonly debtReserveId: bigint;
  /** Least raw amount of each pool token from the release, one per market token, or empty. */
  readonly minAmounts: readonly bigint[];
  readonly minDebtRepaid: bigint;
  /** Least debt asset returned to the wallet after the repayment. */
  readonly minAssetOut: bigint;
  readonly deadline: bigint;
  readonly minHealthFactor: bigint;
}

export interface PositionArgs {
  readonly marketId: bigint;
  readonly position: PositionRef;
  readonly deadline: bigint;
}

export interface RecreditArgs extends PositionArgs {
  /** Integration-encoded LP amount for a fungible-share position; `0x` for an NFT position. */
  readonly topUp: Hex;
}

export interface WithdrawArgs extends PositionArgs {
  /** The record's credited units after reconcile: a withdrawal releases the whole position. */
  readonly units: bigint;
  /** Least health factor after the withdrawal while debt remains, WAD; 0 for none. */
  readonly minHealthFactor: bigint;
}

export interface RemoveLiquidityArgs extends PositionArgs {
  /** Credited units removed, below the record's credited units. */
  readonly units: bigint;
  /** Least raw amount of each pool token, one per market token. */
  readonly minAmounts: readonly bigint[];
  /** Least health factor after the removal while debt remains, WAD; 0 for none. */
  readonly minHealthFactor: bigint;
}

export interface RepayAllAndWithdrawArgs extends PositionArgs {
  /** The record's credited units after reconcile. */
  readonly units: bigint;
  /** Each debt reserve to repay in full, with its spend cap (base units of its asset) at the same index. */
  readonly debtReserveIds: readonly bigint[];
  readonly maxRepaySpends: readonly bigint[];
}

const position = (p: PositionRef) => ({ integrationId: p.integrationId, positionKey: p.positionKey });

export function encodeBorrow(a: BorrowArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "borrow",
    args: [a.marketId, a.debtReserveId, a.amount, a.receiver, a.deadline, a.minHealthFactor, a.expectedNonce],
  });
}

/** Repays up to `maxRepaySpend` of the borrower's debt in the reserve. */
export function encodeRepay(a: RepayArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "repay",
    args: [a.borrower, a.marketId, a.debtReserveId, a.maxRepaySpend, false, a.deadline],
  });
}

/** Repays the borrower's whole debt in the reserve, interest to the block included, spending at most `maxRepaySpend`. */
export function encodeRepayAll(a: RepayArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "repay",
    args: [a.borrower, a.marketId, a.debtReserveId, a.maxRepaySpend, true, a.deadline],
  });
}

export function encodeRepayWithCollateral(a: RepayWithCollateralArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "repayWithCollateral",
    args: [
      {
        marketId: a.marketId,
        position: position(a.position),
        units: a.units,
        debtReserveId: a.debtReserveId,
        minAmounts: a.minAmounts,
        minDebtRepaid: a.minDebtRepaid,
        minAssetOut: a.minAssetOut,
        deadline: a.deadline,
        minHealthFactor: a.minHealthFactor,
      },
    ],
  });
}

export function encodePledge(a: PositionArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "pledge", args: [a.marketId, position(a.position), a.deadline] });
}

export function encodeRecredit(a: RecreditArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "recredit", args: [a.marketId, position(a.position), a.topUp, a.deadline] });
}

/** Releases the whole position to the depositor of record. */
export function encodeWithdraw(a: WithdrawArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "withdraw",
    args: [a.marketId, position(a.position), a.units, a.deadline, a.minHealthFactor],
  });
}

/** Removes part of the position's liquidity; the pool tokens go to the depositor of record. */
export function encodeRemoveLiquidity(a: RemoveLiquidityArgs): Hex {
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "removeLiquidity",
    args: [a.marketId, position(a.position), a.units, a.minAmounts, a.deadline, a.minHealthFactor],
  });
}

/** Repays the named debt reserves in full, then releases the whole position. */
export function encodeRepayAllAndWithdraw(a: RepayAllAndWithdrawArgs): Hex {
  if (a.debtReserveIds.length !== a.maxRepaySpends.length) {
    throw new Error(`repayAllAndWithdraw: ${a.debtReserveIds.length} debt reserves but ${a.maxRepaySpends.length} spend limits`);
  }
  return encodeFunctionData({
    abi: aaveAdapterAbi,
    functionName: "repayAllAndWithdraw",
    args: [a.marketId, position(a.position), a.units, a.debtReserveIds, a.maxRepaySpends, a.deadline],
  });
}

/** Collects the fees of a custodied position, for an AMM protocol that keeps fees apart from the liquidity. */
export function encodeCollectFees(a: PositionArgs): Hex {
  return encodeFunctionData({ abi: aaveAdapterAbi, functionName: "collectFees", args: [a.marketId, position(a.position), a.deadline] });
}

/** The call to send: `data` from one of the encoders above, `to` the chain's AaveAdapter proxy. */
export function aaveAdapterCall(to: Address, data: Hex): AaveAdapterCall {
  return { to, data, value: 0n };
}

/** Decodes AaveAdapter calldata (for a transaction review screen or a test). */
export function decodeAaveAdapterCall(data: Hex) {
  return decodeFunctionData({ abi: aaveAdapterAbi, data });
}
