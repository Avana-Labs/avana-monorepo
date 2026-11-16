// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Points for the fee a wallet paid (1 point per $1), verified on chain: the tracker reads the receipt of a confirmed
// transaction, keeps the ERC-20 Transfer logs from the wallet to the ParameterStore's `feeRecipient`, and prices each
// token at the Hub asset's price. The amount never comes from the client. Known gaps: a fee paid in native ETH is a plain
// value transfer with no log (it needs a call trace, so it earns nothing for now), a token that is not a Hub asset has
// no price here, and a smart account that sends the batch under another address than the signed-in wallet is not matched.

import type { MutationCtx } from "../_generated/server";
import { awardPoints } from "./rewards.ts";

/** keccak256("Transfer(address,address,uint256)"). */
export const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

export interface ReceiptLog {
  readonly address: string;
  readonly topics: readonly string[];
  readonly data: string;
}

export interface FeeTransfer {
  readonly token: string;
  /** Base units, decimal string. */
  readonly amount: string;
}

const padded = (address: string) => `0x${"0".repeat(24)}${address.slice(2).toLowerCase()}`;

/** The ERC-20 transfers in `logs` from `wallet` to `recipient`, summed per token (lower-case address). */
export function feeTransfers(logs: readonly ReceiptLog[], wallet: string, recipient: string): FeeTransfer[] {
  const from = padded(wallet);
  const to = padded(recipient);
  const byToken = new Map<string, bigint>();
  for (const log of logs) {
    if (log.topics.length !== 3 || log.topics[0]?.toLowerCase() !== TRANSFER_TOPIC) continue;
    if (log.topics[1]?.toLowerCase() !== from || log.topics[2]?.toLowerCase() !== to) continue;
    if (!/^0x[0-9a-fA-F]{1,64}$/.test(log.data)) continue;
    const token = log.address.toLowerCase();
    byToken.set(token, (byToken.get(token) ?? 0n) + BigInt(log.data));
  }
  return [...byToken].map(([token, amount]) => ({ token, amount: amount.toString() }));
}

/** USD value of the transfers at the Hub assets' prices now; a token with no Hub asset adds nothing. */
export async function feeUsdOf(ctx: Pick<MutationCtx, "db">, chainId: number, transfers: readonly FeeTransfer[]): Promise<number> {
  let usd = 0;
  for (const t of transfers) {
    const asset = await ctx.db.query("hubAssets").withIndex("by_chain_underlying", (q) => q.eq("chainId", chainId).eq("underlying", t.token)).first();
    if (!asset || !/^\d+$/.test(asset.priceUsd8) || !/^\d+$/.test(t.amount)) continue;
    usd += Number((BigInt(t.amount) * BigInt(asset.priceUsd8)) / 10n ** BigInt(asset.decimals)) / 1e8;
  }
  return usd;
}

/** Awards 1 point per whole dollar of fee for the transaction, once per transaction. Returns the points awarded now. */
export async function awardFeePoints(
  ctx: Pick<MutationCtx, "db">,
  a: { wallet: string; chainId: number; txHash: string; transfers: readonly FeeTransfer[]; at: number },
): Promise<number> {
  const points = Math.floor(await feeUsdOf(ctx, a.chainId, a.transfers));
  if (points <= 0) return 0;
  const awarded = await awardPoints(ctx, { wallet: a.wallet, kind: "fee", key: `fee:${a.chainId}:${a.txHash.toLowerCase()}`, points, at: a.at });
  return awarded ? points : 0;
}
