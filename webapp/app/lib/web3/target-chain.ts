import { mainnet } from "wagmi/chains"

/**
 * The single chain this app operates on. wagmi's config is built from the same
 * `mainnet` (see web3-provider.tsx), so this is the one network a connected wallet
 * must be on before any action is allowed.
 */
export const TARGET_CHAIN = mainnet
export const TARGET_CHAIN_ID = mainnet.id
export const TARGET_CHAIN_NAME = mainnet.name
