// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Sharding and takeover. An account belongs to shard keccak256(proxy) mod N. Any primary takes over an account its
// shard has not liquidated within the takeover window; the standby acts on any account still liquidatable after 60 s.

import { type Address, hexToBigInt, keccak256 } from "viem";
import { type ChainInfo, blocksFor } from "@avana/services-common";

export function shardOf(proxy: Address, count: number): number {
  return Number(hexToBigInt(keccak256(proxy)) % BigInt(count));
}

/** 2 blocks on Ethereum (24 s), 6 blocks on Base (12 s). */
export function takeoverBlocks(chain: ChainInfo): number {
  return chain.key === "base" || chain.key === "baseSepolia" ? 6 : 2;
}

/** 60 s: the M-09 warning level, 5 Ethereum blocks or 30 Base blocks. */
export function standbyBlocks(chain: ChainInfo): number {
  return blocksFor(chain, 60);
}

/** Whether this instance acts on an account liquidatable since `since` at block `now`. */
export function mayAct(
  chain: ChainInfo,
  role: "primary" | "standby",
  shard: { index: number; count: number } | null,
  proxy: Address,
  since: bigint,
  now: bigint,
): boolean {
  const age = now - since;
  if (role === "standby" || shard === null) return age >= BigInt(standbyBlocks(chain));
  return shardOf(proxy, shard.count) === shard.index || age >= BigInt(takeoverBlocks(chain));
}
