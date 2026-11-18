// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Fee and gas-limit rules (services/README.md, Submission > Gas). Avana pays gas as an operating cost; the
// per-chain ceiling only stops a fault from draining the gas wallet, and reaching it pages.

import { type Address, type Hex, type PublicClient, parseAbi, serializeTransaction } from "viem";
import type { ChainInfo } from "@avana/services-common";
import { paddedGasLimit } from "@avana/services-common/gas";
import type { JobClass } from "../types.ts";

export const GWEI = 1_000_000_000n;

/** Priority fee: the 90th percentile of the last 5 blocks' priority fees, at least `minTip` (1 gwei unless configured). */
export function priorityFee(rewardsP90LastFiveBlocks: readonly bigint[], minTip: bigint = GWEI): bigint {
  if (rewardsP90LastFiveBlocks.length === 0) return minTip;
  const sorted = [...rewardsP90LastFiveBlocks].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const p90 = sorted[Math.min(sorted.length - 1, Math.ceil(0.9 * sorted.length) - 1)]!;
  return p90 > minTip ? p90 : minTip;
}

/**
 * One chain's fee policy per job class (keeper DESIGN.md, Fees; KEEPER_MIN_TIP_*, KEEPER_LAZY_* in .env.example).
 * The per-transaction ceiling (KEEPER_GAS_CEILING_WEI_<CHAIN>) applies to every class on top of it.
 */
export interface FeePolicy {
  /** Floor of the urgent tip; the urgent tip is the 90th percentile of the last 5 blocks when that is higher. */
  readonly minTipUrgent: bigint;
  /** The scheduled tip: a lazy transaction after `lazyMaxWait`, and any job that declares `scheduled`. */
  readonly minTipScheduled: bigint;
  /** The lazy tip, used only while the base fee is at most `lazyBaseFeeMax`. */
  readonly minTipLazy: bigint;
  /** Highest base fee, in wei, at which a lazy transaction is sent at the lazy tip. */
  readonly lazyBaseFeeMax: bigint;
  /** Seconds a lazy transaction waits for a low base fee from when it first fell due; then it goes at scheduled fees. */
  readonly lazyMaxWaitSeconds: bigint;
}

/** Today's rule for every class: urgent fees everywhere. Used where no policy is configured (tests, observe-only). */
export const URGENT_ONLY: FeePolicy = { minTipUrgent: GWEI, minTipScheduled: GWEI, minTipLazy: GWEI, lazyBaseFeeMax: 2n ** 255n, lazyMaxWaitSeconds: 0n };

export type FeeDecision =
  | { readonly send: true; readonly maxFeePerGas: bigint; readonly maxPriorityFeePerGas: bigint; /** The class whose fees were used. */ readonly paidAs: JobClass }
  | { readonly send: false; readonly reason: "lazyBaseFeeHigh"; readonly baseFee: bigint; readonly waitedSeconds: bigint };

/**
 * The fees of one transaction by its class. Max fee is always 2 × base fee + tip.
 * - urgent: tip = the 90th percentile of the last 5 blocks' priority fees, at least `minTipUrgent`;
 * - scheduled: tip = `minTipScheduled`;
 * - lazy: tip = `minTipLazy` while the base fee is at most `lazyBaseFeeMax`; above it, not sent until `lazyMaxWaitSeconds`
 *   have passed since it first fell due (`waitedSeconds`), then sent at scheduled fees.
 */
export function classFees(jobClass: JobClass, rewardsP90LastFiveBlocks: readonly bigint[], baseFee: bigint, policy: FeePolicy, waitedSeconds = 0n): FeeDecision {
  const at = (tip: bigint, paidAs: JobClass): FeeDecision => ({ send: true, maxPriorityFeePerGas: tip, maxFeePerGas: maxFee(baseFee, tip), paidAs });
  if (jobClass === "urgent") return at(priorityFee(rewardsP90LastFiveBlocks, policy.minTipUrgent), "urgent");
  if (jobClass === "scheduled") return at(policy.minTipScheduled, "scheduled");
  if (baseFee <= policy.lazyBaseFeeMax) return at(policy.minTipLazy, "lazy");
  if (waitedSeconds >= policy.lazyMaxWaitSeconds) return at(policy.minTipScheduled, "scheduled");
  return { send: false, reason: "lazyBaseFeeHigh", baseFee, waitedSeconds };
}

/** Max fee: twice the base fee plus the tip. */
export function maxFee(baseFee: bigint, tip: bigint): bigint {
  return 2n * baseFee + tip;
}

/**
 * Gas limit ⌈1.3 × estimate⌉ + 25,000 (`@avana/services-common/gas`): the estimate at `latest` misses the Hub accrual
 * a call pays when mined a second later, and LPVaultSwap's payout headroom check reverts an under-gassed call, so the
 * limit is never cut below the estimate.
 */
export function gasLimit(estimate: bigint): bigint {
  return paddedGasLimit(estimate);
}

/** A replacement raises both fee fields by 15 %, rounded up. */
export function bumpFees(fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }) {
  return {
    maxFeePerGas: (fees.maxFeePerGas * 115n + 99n) / 100n,
    maxPriorityFeePerGas: (fees.maxPriorityFeePerGas * 115n + 99n) / 100n,
  };
}

/** Worst-case cost; on Base the caller adds the L1 data fee from the chain's gas price oracle. */
export function worstCaseCost(limit: bigint, maxFeePerGas: bigint, l1DataFee = 0n): bigint {
  return limit * maxFeePerGas + l1DataFee;
}

/** The OP Stack gas price oracle predeploy, which prices a transaction's L1 data on Base and Base Sepolia. */
export const GAS_PRICE_ORACLE: Address = "0x420000000000000000000000000000000000000F";
const gasPriceOracleAbi = parseAbi(["function getL1Fee(bytes _data) view returns (uint256)"]);

/** Base and Base Sepolia charge an L1 data fee on top of L2 gas; the other chains do not. */
export function paysL1DataFee(chain: Pick<ChainInfo, "key">): boolean {
  return chain.key === "base" || chain.key === "baseSepolia";
}

export interface UnsignedTx {
  readonly chainId: number;
  readonly to: Address;
  readonly data: Hex;
  readonly nonce: number;
  readonly gas: bigint;
  readonly maxFeePerGas: bigint;
  readonly maxPriorityFeePerGas: bigint;
}

/** The L1 data fee of the unsigned transaction, from `GasPriceOracle.getL1Fee` at the latest block. */
export async function l1DataFee(client: Pick<PublicClient, "readContract">, tx: UnsignedTx): Promise<bigint> {
  const unsigned = serializeTransaction({ type: "eip1559", value: 0n, ...tx });
  return client.readContract({ address: GAS_PRICE_ORACLE, abi: gasPriceOracleAbi, functionName: "getL1Fee", args: [unsigned] });
}

/** True when the call's worst-case cost passes the chain's ceiling: the call is not sent and the on-call engineer is paged. */
export function aboveCeiling(cost: bigint, ceilingWei: bigint): boolean {
  return cost > ceilingWei;
}
