// Row shapes of the Lend list page. Rows are built from the Hub assets services/convex reports
// (see lend-system/read-model.ts); there is no static catalog.

export type LendAssetRow = {
  symbol: string
  name: string
  apy: string
  apyValue: number
  totalDepositsPrimary: string
  totalDepositsSecondary: string
  totalDepositsValue: number
  availableLiquidityPrimary: string
  availableLiquiditySecondary: string
  availableLiquidityValue: number
  hub: string
  market: string
  logoSrc?: string
  logoAlt?: string
  apyAccent?: boolean
}

export type LendAssetGroup = {
  title: string
  subtitle?: string
  rows: LendAssetRow[]
}

export type LendFeaturedAssetId = string

export type LendFeaturedAsset = {
  id: LendFeaturedAssetId
  symbol: string
  displayName: string
  eyebrow: string
  apy: number
  tone: "green" | "blue"
  iconUrl: string
  /** Sparkline path of the supply series; absent until series exist. */
  path?: string
}

/** Group titles of the Lend list, in display order. */
export const LEND_GROUP_TITLES = { stable: "Stablecoins", crypto: "Other Assets" } as const
