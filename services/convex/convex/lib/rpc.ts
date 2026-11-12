// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Convex's own RPC (README, "Scheduled pull": hashes are checked against it, never against the indexer's), from
// the Convex environment variables `RPC_<CHAIN>` and `RPC_<CHAIN>_FALLBACK`, the names every service uses.

import { createPublicClient, fallback, http, type PublicClient } from "viem";
import { MULTICALL3_ADDRESS, chainById } from "@avana/services-common/chains";
import { optionalEnv, requireEnv, rpcEnvName } from "@avana/services-common/env";
import type { CallResult, ContractCall, ViewClient } from "@avana/services-common/views";

export function rpcClient(chainId: number): PublicClient {
  const chain = chainById(chainId);
  const urls = [requireEnv(process.env, rpcEnvName(chain, "PRIMARY")), optionalEnv(process.env, rpcEnvName(chain, "FALLBACK"))].filter((u): u is string => u !== undefined);
  return createPublicClient({ transport: fallback(urls.map((u) => http(u))) }) as PublicClient;
}

/** A multicall pinned to one block, for the snapshot reader. */
export function pinnedViews(client: PublicClient, blockNumber: bigint): ViewClient {
  return {
    multicall: async (calls: readonly ContractCall[]) =>
      (await client.multicall({ contracts: calls as never, allowFailure: true, blockNumber, multicallAddress: MULTICALL3_ADDRESS })) as unknown as readonly CallResult[],
  };
}
