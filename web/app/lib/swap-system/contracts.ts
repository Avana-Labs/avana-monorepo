export type SwapBalanceSource =
  | "wallet"
  | "lend_available"
  | "lend_deposited"
  | "borrow_collateral_unpledged"
  | "borrow_collateral_pledged"
  | "borrow_debt"
  | "borrow_claimable"
  | "multiply_available"
  | "multiply_active"
  | "multiply_debt"
  | "protocol_locked"

export type SwapRestrictionReason =
  | "ineligible_lp_token"
  | "ineligible_deposited"
  | "ineligible_pledged"
  | "ineligible_active_loop"
  | "ineligible_protocol_locked"
  | "insufficient_balance"
  | "unsupported_asset"
  | "unsupported_pair"
  | "same_asset"
  | "invalid_amount"
  | "below_minimum"
  | "above_maximum"
  | "insufficient_native_gas"

export type SwapOriginProduct = "wallet" | "lend" | "borrow" | "multiply"

export type SwapAssetType = "native" | "erc20" | "lp_token"

export type SwapAsset = {
  id: string
  chainId: number
  symbol: string
  name: string
  decimals: number
  assetType: SwapAssetType
  isNative: boolean
  isLpToken: boolean
  isSwapEnabled: boolean
  priceUsd: number
  minimumSwapAmount: number
  maximumSwapAmount: number
  /** LP tokens only: the two underlying token symbols, used to render a pair icon. */
  lpUnderlyingSymbols?: readonly [string, string]
}

export type SwapPair = {
  id: string
  chainId: number
  inputAssetId: string
  outputAssetId: string
  isEnabled: boolean
  provider: string
  feeBps: number
}

export type UserAssetBalance = {
  id: string
  walletId: string
  assetId: string
  amount: number
  valueUsd?: number
  sourceType: SwapBalanceSource
  sourcePositionId?: string
  /** Product-backed rows can carry their server-resolved display metadata. */
  symbol?: string
  name?: string
  isLpToken?: boolean
  /** Live LP unit price when the server could resolve a trustworthy token basis. */
  unitPriceUsd?: number
  /** Pool maximum loan-to-value percentage from the canonical market risk config. */
  ltvPct?: number
}

export type SwapContext = {
  originProduct: SwapOriginProduct
  chainId: number
  inputAssetId?: string
  outputAssetId?: string
}

export type SwapEligibilityResult =
  | {
      eligible: true
      availableAmount: number
    }
  | {
      eligible: false
      availableAmount: number
      reason: SwapRestrictionReason
    }

export type SwapAmountValidationResult =
  | {
      valid: true
      amount: number
      maxAmount: number
    }
  | {
      valid: false
      amount: number | null
      maxAmount: number
      reason: SwapRestrictionReason
    }
