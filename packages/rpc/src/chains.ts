// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chains the RPC manager resolves. `symbol` names the explicit override variable RPC_<symbol> (the Aave toolbox's
// convention, also what contracts/foundry.toml reads). Freshness limits: a head more than `maxLagBlocks` behind the
// best head seen, or older than `maxHeadAgeMs`, is stale.

import type { Chain } from "viem";
import { base, baseSepolia, mainnet, sepolia } from "viem/chains";

export interface RpcChain {
  readonly id: number;
  readonly symbol: string;
  readonly chain: Chain;
  readonly maxLagBlocks: number;
  readonly maxHeadAgeMs: number;
}

export const RPC_CHAINS: Readonly<Record<number, RpcChain>> = {
  [mainnet.id]: { id: mainnet.id, symbol: "MAINNET", chain: mainnet, maxLagBlocks: 3, maxHeadAgeMs: 90_000 },
  [sepolia.id]: { id: sepolia.id, symbol: "SEPOLIA", chain: sepolia, maxLagBlocks: 3, maxHeadAgeMs: 90_000 },
  [base.id]: { id: base.id, symbol: "BASE", chain: base, maxLagBlocks: 15, maxHeadAgeMs: 30_000 },
  [baseSepolia.id]: { id: baseSepolia.id, symbol: "BASE_SEPOLIA", chain: baseSepolia, maxLagBlocks: 15, maxHeadAgeMs: 30_000 },
};

export class UnsupportedChainError extends Error {
  readonly chainId: number;
  constructor(chainId: number) {
    super(`chain ${chainId} is not supported by the RPC manager: ${Object.keys(RPC_CHAINS).join(", ")}`);
    this.name = "UnsupportedChainError";
    this.chainId = chainId;
  }
}

export function rpcChain(chainId: number): RpcChain {
  const c = RPC_CHAINS[chainId];
  if (!c) throw new UnsupportedChainError(chainId);
  return c;
}
