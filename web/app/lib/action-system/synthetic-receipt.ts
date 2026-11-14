/**
 * Deterministic receipt trimmings derived from a transaction hash.
 *
 * The synthetic ledger doesn't record a block number or gas fee, but a receipt looks
 * bare without them. Deriving from the hash keeps these stable across revisits and
 * identical between the inline success stage and the `/sandbox/transactions/[hash]`
 * permalink for the same transaction. No Date.now()/Math.random(), so it's pure.
 */
function hashSeed(hash: string, salt: number): number {
  let value = salt
  for (let i = 0; i < hash.length; i += 1) {
    value = (value * 31 + hash.charCodeAt(i)) >>> 0
  }
  return value
}

/** Plausible mainnet-ish block number, stable per hash. */
export function syntheticBlockFromHash(hash: string): number {
  return 25_000_000 + (hashSeed(hash, 7) % 900_000)
}

/** Plausible network fee in USD (~$0.20–$1.14), stable per hash. */
export function syntheticNetworkFeeUsdFromHash(hash: string): number {
  return Math.round((0.2 + (hashSeed(hash, 17) % 95) / 100) * 100) / 100
}
