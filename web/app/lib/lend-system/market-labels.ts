import { LEND_ASSET_GROUPS } from "@/app/lib/data/catalog/lend"

const STABLE_SYMBOLS = new Set(LEND_ASSET_GROUPS[0]?.rows.map((row) => row.symbol) ?? [])

type LendMarketMeta = {
  hubBucket: "Stable" | "Volatile"
  marketTier: string
  issuerHub: string
}

const META_BY_SYMBOL = new Map<string, LendMarketMeta>()

for (const group of LEND_ASSET_GROUPS) {
  for (const row of group.rows) {
    META_BY_SYMBOL.set(row.symbol.toUpperCase(), {
      hubBucket: STABLE_SYMBOLS.has(row.symbol) ? "Stable" : "Volatile",
      marketTier: row.market,
      issuerHub: row.hub,
    })
  }
}

export function getLendMarketMeta(symbol: string): LendMarketMeta {
  return (
    META_BY_SYMBOL.get(symbol.toUpperCase()) ?? {
      hubBucket: STABLE_SYMBOLS.has(symbol) ? "Stable" : "Volatile",
      marketTier: "Core",
      issuerHub: "Core",
    }
  )
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
