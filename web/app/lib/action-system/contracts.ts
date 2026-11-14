export type ActionProduct = "borrow" | "lend" | "multiply" | "rewards" | "umbrella"

export type BorrowActionKind = "borrow" | "repay" | "supply" | "remove" | "claim" | "pledge"
export type LendActionKind = "deposit" | "withdraw"
export type MultiplyActionKind = "multiply" | "deleverage" | "close"
export type RewardsActionKind = "claim"
export type UmbrellaActionKind = "stake" | "claim" | "cooldown" | "unstake"

export type ActionKind = BorrowActionKind | LendActionKind | MultiplyActionKind | RewardsActionKind | UmbrellaActionKind

export type ActionPageMode = "page" | "overlay" | "embedded"

export type ActionStage =
  | "select"
  | "configure"
  | "review"
  | "approve_allowance"
  | "wallet_sign"
  | "processing"
  | "submitted"
  | "confirmed"
  | "refreshing_position"
  | "reconciled"
  | "success"
  | "error"

export type ActionMetricTone = "default" | "positive" | "warning" | "danger"

export type ActionMetricLiveUsd = {
  anchorMs: number | null
  before: { baseUsd: number; ratePerYearUsd: number }
  after: { baseUsd: number; ratePerYearUsd: number }
  fractionDigits?: number
}

export type ActionMetricRow = {
  id: string
  label: string
  value: string
  before?: string
  after?: string
  tone?: ActionMetricTone
  tooltip?: string
  tokenSymbols?: string[]
  liveUsd?: ActionMetricLiveUsd
}

export type ActionRiskLevel = "safe" | "warning" | "danger"

export type ActionPreviewUi = {
  quoteId?: string
  loopCount?: number
  executionSteps?: Array<{ id: string; label: string }>
  allowed: boolean
  amountLabel: string
  amountTitle?: string
  amountValue?: string
  amountUnitLabel?: string
  assetLabel?: string
  assetSymbol?: string
  borrowSymbol?: string
  amountUsd?: number
  amountUsdLabel: string
  rateLabel: string
  rateValue: string
  marketLabel: string
  marketValue: string
  marketBreakdown?: {
    collateral: { symbol: string; apy: string }
    borrow: { symbol: string; apy: string }
  }
  balanceLabel: string
  balanceValue: string
  maxAmount: number | null
  metrics: ActionMetricRow[]
  networkFeeLabel: string
  risk: {
    level: ActionRiskLevel
    title: string | null
    message: string | null
  } | null
  blockedReason: string | null
  validationErrors: string[]
  warnings: string[]
}

export type ActionSuccessUi = {
  quoteId?: string
  title: string
  description: string
  receiptHash: string | null
  metrics: ActionMetricRow[]
  primaryCtaLabel: string
  primaryCtaHref: string
  secondaryCtaLabel: string
  receiptContext?: {
    verb: string
    amountUsd?: number
    amountLabel: string
    rateLabel: string
    rateValue: string
    marketValue: string
    /**
     * Real network fee (USD) for this receipt. Set by swaps to their quote fee so
     * the inline receipt matches the estimate and permalink. Left undefined for
     * non-swap actions, which fall back to the 15 bps platform fee on the amount.
     */
    networkFeeUsd?: number
  }
}

type ActionPageDescriptor = {
  product: ActionProduct
  kind: ActionKind
  title: string
  subtitle: string
  primaryVerb: string
}

export const ACTION_DESCRIPTORS: Record<ActionProduct, Partial<Record<ActionKind, ActionPageDescriptor>>> = {
  borrow: {
    borrow: {
      product: "borrow",
      kind: "borrow",
      title: "Borrow",
      subtitle: "Configure and review your loan.",
      primaryVerb: "Borrow",
    },
    repay: {
      product: "borrow",
      kind: "repay",
      title: "Repay",
      subtitle: "Configure and review your repayment.",
      primaryVerb: "Repay",
    },
    supply: {
      product: "borrow",
      kind: "supply",
      title: "Pledge",
      subtitle: "Configure and review your collateral pledge.",
      primaryVerb: "Pledge",
    },
    remove: {
      product: "borrow",
      kind: "remove",
      title: "Remove",
      subtitle: "Configure and review your collateral removal.",
      primaryVerb: "Remove",
    },
    claim: {
      product: "borrow",
      kind: "claim",
      title: "Claim",
      subtitle: "Configure and review your claim.",
      primaryVerb: "Claim",
    },
  },
  lend: {
    deposit: {
      product: "lend",
      kind: "deposit",
      title: "Deposit",
      subtitle: "Configure and review your deposit.",
      primaryVerb: "Deposit",
    },
    withdraw: {
      product: "lend",
      kind: "withdraw",
      title: "Withdraw",
      subtitle: "Configure and review your withdrawal.",
      primaryVerb: "Withdraw",
    },
  },
  multiply: {
    multiply: {
      product: "multiply",
      kind: "multiply",
      title: "Multiply",
      subtitle: "Configure and review your leverage.",
      primaryVerb: "Multiply",
    },
    deleverage: {
      product: "multiply",
      kind: "deleverage",
      title: "Deleverage",
      subtitle: "Configure and review your unwind.",
      primaryVerb: "Deleverage",
    },
    close: {
      product: "multiply",
      kind: "close",
      title: "Close position",
      subtitle: "Review the full unwind and collateral withdrawal.",
      primaryVerb: "Close",
    },
  },
  rewards: {
    claim: {
      product: "rewards",
      kind: "claim",
      title: "Claim",
      subtitle: "Configure and review your rewards claim.",
      primaryVerb: "Claim",
    },
  },
  umbrella: {
    stake: {
      product: "umbrella",
      kind: "stake",
      title: "Stake",
      subtitle: "Configure and review your Umbrella stake.",
      primaryVerb: "Stake",
    },
    claim: {
      product: "umbrella",
      kind: "claim",
      title: "Claim",
      subtitle: "Configure and review your Umbrella rewards claim.",
      primaryVerb: "Claim",
    },
    cooldown: {
      product: "umbrella",
      kind: "cooldown",
      title: "Start cooldown",
      subtitle: "Choose how much stake should enter cooldown.",
      primaryVerb: "Start cooldown",
    },
    unstake: {
      product: "umbrella",
      kind: "unstake",
      title: "Unstake",
      subtitle: "Withdraw stake from an open Umbrella withdrawal window.",
      primaryVerb: "Unstake",
    },
  },
}

export function normalizeActionKind(product: string, kind: string): ActionKind {
  if (product === "borrow" && kind === "pledge") return "supply"
  return kind as ActionKind
}

export function getActionDescriptor(product: ActionProduct, kind: ActionKind): ActionPageDescriptor {
  const normalizedKind = product === "borrow" && kind === "pledge" ? "supply" : kind
  const descriptor = ACTION_DESCRIPTORS[product][normalizedKind as keyof (typeof ACTION_DESCRIPTORS)[typeof product]]
  if (!descriptor) {
    throw new Error(`Unknown action ${product}/${kind}`)
  }
  return descriptor
}

export function isValidActionProduct(product: string): product is ActionProduct {
  return (
    product === "borrow" ||
    product === "lend" ||
    product === "multiply" ||
    product === "rewards" ||
    product === "umbrella"
  )
}

export function isValidAction(product: string, kind: string): product is ActionProduct {
  if (!isValidActionProduct(product)) return false
  const normalizedKind = normalizeActionKind(product, kind)
  return Boolean(ACTION_DESCRIPTORS[product][normalizedKind as keyof (typeof ACTION_DESCRIPTORS)[typeof product]])
}

export function actionPagePath(product: ActionProduct, kind: ActionKind, params?: Record<string, string>) {
  const search = params ? `?${new URLSearchParams(params).toString()}` : ""
  return `/actions/${product}/${kind}${search}`
}

const ACTION_CLOSE_HREF: Record<ActionProduct, string> = {
  borrow: "/borrow",
  lend: "/lend",
  multiply: "/multiply",
  rewards: "/dashboard",
  umbrella: "/umbrella",
}

function normalizeReturnHref(returnHref: string) {
  if (returnHref.startsWith("/multiply/market/") && !returnHref.startsWith("/multiply/markets/")) {
    return returnHref.replace("/multiply/market/", "/multiply/markets/")
  }
  if (returnHref.startsWith("/borrow/pool/") && !returnHref.startsWith("/borrow/markets/")) {
    return returnHref.replace("/borrow/pool/", "/borrow/markets/")
  }
  if (returnHref.startsWith("/borrow/asset/") && !returnHref.startsWith("/borrow/assets/")) {
    return returnHref.replace("/borrow/asset/", "/borrow/assets/")
  }
  return returnHref
}

export function resolveActionCloseHref(product: ActionProduct, returnHref?: string) {
  const fallback = ACTION_CLOSE_HREF[product] ?? "/"
  if (!returnHref) return fallback
  if (!returnHref.startsWith("/") || returnHref.startsWith("//")) return fallback
  return normalizeReturnHref(returnHref)
}
