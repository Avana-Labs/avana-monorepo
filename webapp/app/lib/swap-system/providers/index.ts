import { cowSwapProvider } from "./cow-swap"
import { createOnchainPoolsProvider, type OnchainPoolsConfig, type QuoterClient } from "./onchain-pools"
import type { SwapProviderId, SwapQuoteProvider } from "./types"

export type { SwapProviderId, SwapQuoteProvider } from "./types"
export {
  createOnchainPoolsProvider,
  encodePoolPath,
  QUOTER_V2_ABI,
  type OnchainPoolsConfig,
  type PoolToken,
  type PoolVenue,
  type QuoterClient,
} from "./onchain-pools"
export { cowSwapProvider } from "./cow-swap"

/**
 * The swap provider of this network, from NEXT_PUBLIC_AVANA_SWAP_PROVIDER: "cow-swap" (default,
 * the public networks) or "onchain-pools" (a network CoW Swap does not serve, such as the local chains).
 */
export function swapProviderId(): SwapProviderId {
  return process.env.NEXT_PUBLIC_AVANA_SWAP_PROVIDER?.trim() === "onchain-pools" ? "onchain-pools" : "cow-swap"
}

/**
 * The provider for a chain. With "onchain-pools" it needs that chain's pool config and a chain
 * client; without them it falls back to CoW Swap, which answers "unsupported" until connected.
 */
export function resolveSwapQuoteProvider(
  pools?: { config: OnchainPoolsConfig; client: QuoterClient } | null,
): SwapQuoteProvider {
  if (swapProviderId() === "onchain-pools" && pools) return createOnchainPoolsProvider(pools.config, pools.client)
  return cowSwapProvider
}
