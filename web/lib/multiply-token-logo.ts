import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"
import { MULTIPLY_TOKEN_LOGOS } from "@/app/lib/multiply-sim"

/** Resolves a multiply token logo with case-insensitive catalog symbol matching. */
export function resolveMultiplyTokenLogo(symbol: string): string {
  const normalized = symbol.trim()
  if (!normalized) return getLocalAssetIcon("USDC")

  const matchedKey = (Object.keys(MULTIPLY_TOKEN_LOGOS) as Array<keyof typeof MULTIPLY_TOKEN_LOGOS>).find(
    (key) => key.toLowerCase() === normalized.toLowerCase(),
  )

  return matchedKey ? MULTIPLY_TOKEN_LOGOS[matchedKey] : getLocalAssetIcon(normalized)
}
