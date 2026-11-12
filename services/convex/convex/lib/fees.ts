// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The frontend fee and the total shown before signing. No contract charges a fee (Q-231): the app adds one token
// transfer to the action's batch (EIP-5792 `wallet_sendCalls`, or a smart account's multicall), so the fee and the
// action succeed or fail together. The rules live in Convex (`feeConfig`); this module is the one place that turns
// them into amounts, and the app calls the same function to build the transfer, so the amount shown is the amount
// sent. The gas estimate is the simulation of the whole batch, fee transfer included.

export type FeeAction = "supply" | "withdraw" | "pledge" | "borrow" | "repay" | "withdrawCollateral" | "repayWithCollateral" | "swap";

/** Whether the user pays the amount (supply, pledge, repay) or receives it (withdraw, borrow). */
export const DIRECTION: Readonly<Record<FeeAction, "pay" | "receive">> = {
  supply: "pay",
  pledge: "pay",
  repay: "pay",
  repayWithCollateral: "pay",
  swap: "pay",
  withdraw: "receive",
  borrow: "receive",
  withdrawCollateral: "receive",
};

export interface FeeRules {
  readonly enabled: boolean;
  readonly defaultBps: number;
  readonly actionBps: Readonly<Partial<Record<string, number>>>;
  readonly exemptActions: readonly string[];
  /** Largest fee in USD per action; null for no cap. */
  readonly maxFeeUsd: number | null;
}

export interface GasInputs {
  /** Gas of the whole batch from the wallet's simulation. */
  readonly gasUnits: bigint;
  readonly baseFeeWei: bigint;
  readonly priorityFeeWei: bigint;
  /** L1 data fee of the batch on an L2 (the OP Stack gas price oracle's `getL1Fee`), 0 on Ethereum. */
  readonly l1FeeWei: bigint;
  /** Native token price, USD with 8 decimals. */
  readonly nativeUsd8: bigint;
}

export interface FeeQuoteInput {
  readonly action: FeeAction;
  /** Action amount in the token's base units. */
  readonly amount: bigint;
  readonly decimals: number;
  /** The token's Lend Spoke price, USD with 8 decimals. */
  readonly priceUsd8: bigint;
  readonly gas: GasInputs;
}

export interface FeeQuote {
  readonly feeBps: number;
  /** Fee in the action token's base units; the app transfers exactly this. */
  readonly feeAmount: bigint;
  readonly capped: boolean;
  readonly amountUsd: number;
  readonly feeUsd: number;
  readonly gasWei: bigint;
  readonly gasUsd: number;
  /** Fee + gas. */
  readonly costUsd: number;
  /** What leaves the wallet (pay: amount + fee + gas) or what the wallet nets (receive: amount − fee − gas). */
  readonly totalUsd: number;
  readonly direction: "pay" | "receive";
}

const usd = (units: bigint, decimals: number, price8: bigint): number => Number((units * price8) / 10n ** BigInt(decimals)) / 1e8;

/** The rate that applies to an action: 0 when fees are off or the action is exempt. */
export function feeBpsFor(rules: FeeRules, action: FeeAction): number {
  if (!rules.enabled || rules.exemptActions.includes(action)) return 0;
  const bps = rules.actionBps[action] ?? rules.defaultBps;
  if (!Number.isInteger(bps) || bps < 0 || bps > 10_000) throw new Error(`fee rate ${bps} bps for ${action} is outside 0..10000`);
  return bps;
}

/**
 * Fee `⌊amount × bps / 10⁴⌋`, rounded down so the user never pays above the stated rate, then cut to the USD cap
 * (also rounded down). Gas `gasUnits × (baseFee + priorityFee) + l1Fee`, valued at the native price.
 */
export function quoteFee(rules: FeeRules, q: FeeQuoteInput): FeeQuote {
  if (q.amount < 0n || q.gas.gasUnits < 0n) throw new Error("amount and gas must be non-negative");
  const feeBps = feeBpsFor(rules, q.action);
  let feeAmount = (q.amount * BigInt(feeBps)) / 10_000n;
  let capped = false;
  if (rules.maxFeeUsd !== null && q.priceUsd8 > 0n) {
    const capAmount = (BigInt(Math.round(rules.maxFeeUsd * 1e8)) * 10n ** BigInt(q.decimals)) / q.priceUsd8;
    if (feeAmount > capAmount) {
      feeAmount = capAmount;
      capped = true;
    }
  }
  const gasWei = q.gas.gasUnits * (q.gas.baseFeeWei + q.gas.priorityFeeWei) + q.gas.l1FeeWei;
  const gasUsd = Number((gasWei * q.gas.nativeUsd8) / 10n ** 18n) / 1e8;
  const amountUsd = usd(q.amount, q.decimals, q.priceUsd8);
  const feeUsd = usd(feeAmount, q.decimals, q.priceUsd8);
  const costUsd = feeUsd + gasUsd;
  const direction = DIRECTION[q.action];
  return {
    feeBps,
    feeAmount,
    capped,
    amountUsd,
    feeUsd,
    gasWei,
    gasUsd,
    costUsd,
    totalUsd: direction === "pay" ? amountUsd + costUsd : amountUsd - costUsd,
    direction,
  };
}

/** Rules in force until a `feeConfig` row is written: no fee, and repay and collateral exits always exempt. */
export const DEFAULT_FEE_RULES: FeeRules = { enabled: false, defaultBps: 0, actionBps: {}, exemptActions: ["repay", "repayWithCollateral", "withdrawCollateral"], maxFeeUsd: null };
