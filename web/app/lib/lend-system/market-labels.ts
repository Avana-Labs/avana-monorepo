import { isStableSymbol } from "@/app/lib/tokens/stable-symbols"

type LendMarketMeta = {
  hubBucket: "Stable" | "Volatile"
  marketTier: string
  issuerHub: string
}

export function getLendMarketMeta(symbol: string): LendMarketMeta {
  return { hubBucket: isStableSymbol(symbol) ? "Stable" : "Volatile", marketTier: "Core", issuerHub: "Core" }
}

/** Dropdown sublabel aligned with lend page hub filters (Stable / Volatile). */
export function formatLendMarketDropdownSublabel(symbol: string) {
  const meta = getLendMarketMeta(symbol)
  return `${meta.hubBucket} · ${meta.marketTier}`
}

/** Position / review market line (e.g. "ETH · Stable · Core"). */
export function formatLendMarketValueLabel(symbol: string) {
  const meta = getLendMarketMeta(symbol)
  return `${symbol} · ${meta.hubBucket} · ${meta.marketTier}`
}
