// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Fee and gas-limit rules (services/README.md, Submission > Gas). Avana pays gas as an operating cost; the
// per-chain ceiling only stops a fault from draining the gas wallet, and reaching it pages.

import { type Address, type Hex, type PublicClient, parseAbi, serializeTransaction } from "viem";
import type { ChainInfo } from "@avana/services-common";
import { paddedGasLimit } from "@avana/services-common/gas";

export const GWEI = 1_000_000_000n;

/** Priority fee: the 90th percentile of the last 5 blocks' priority fees, at least 1 gwei. */
export function priorityFee(rewardsP90LastFiveBlocks: readonly bigint[]): bigint {
  if (rewardsP90LastFiveBlocks.length === 0) return GWEI;
  const sorted = [...rewardsP90LastFiveBlocks].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const p90 = sorted[Math.min(sorted.length - 1, Math.ceil(0.9 * sorted.length) - 1)]!;
  return p90 > GWEI ? p90 : GWEI;
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
