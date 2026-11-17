// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The HTTP read clients. Reads issued in the same tick and pinned to the same block are sent as one Multicall3
// `aggregate3` eth_call (viem's multicall batching), so a pass that reads every oracle, market and the gas vault costs
// a few eth_calls instead of one per read. viem batches only when the client's chain names a Multicall3 address, and
// never batches a call that carries a sender, gas or value; state-changing simulations opt out explicitly
// (`batch: false` in chain/reads.ts), because the calls of one aggregate3 share state.

import { type PublicClient, createPublicClient, defineChain, http } from "viem";
import { MULTICALL3_ADDRESS } from "@avana/services-common/chains";

/**
 * Calldata bytes per batched eth_call (viem's default): about 28 reads with one address argument. It bounds the gas
 * of one aggregate3, which runs every read in a single call.
 */
export const READ_BATCH_BYTES = 1_024;

export function readClient(chainId: number, url: string): PublicClient {
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [url] } },
    contracts: { multicall3: { address: MULTICALL3_ADDRESS } },
  });
  return createPublicClient({ chain, transport: http(url), batch: { multicall: { batchSize: READ_BATCH_BYTES } } }) as PublicClient;
}
