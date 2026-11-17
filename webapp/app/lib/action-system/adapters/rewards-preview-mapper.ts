import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"
import { formatActionFeeSummary } from "@/app/lib/action-system/formatters"

/** The texts of the redeem preview, already localized by the page. */
export type RewardsRedeemLabels = {
  /** "1,000 pts" */
  points: string
  /** "2 bps off" */
  discount: string
  /** The date the discount ends, localized. */
  validUntil: string
  /** "300 pts": the points left after the redemption. */
  pointsLeft: string
}

/**
 * The preview of redeeming points for a temporary fee discount, in the same rows as every other action page: the points
 * spent as the amount, the discount as the rate row, when it ends and the points left as metrics, and the platform fee
 * row (a redemption pays no fee).
 */
export function mapRewardsRedeemPreviewToActionUi(options: {
  allowed: boolean
  points: number
  labels: RewardsRedeemLabels
  blockedReason?: string | null
}): ActionPreviewUi {
  const { labels } = options
  return {
    allowed: options.allowed,
    amountLabel: "PTS",
    amountValue: String(options.points),
    assetLabel: "PTS",
    assetSymbol: "PTS",
    amountUsdLabel: labels.discount,
    rateLabel: "Fee discount",
    rateValue: labels.discount,
    marketLabel: "Program",
    marketValue: "",
    balanceLabel: "Redeemable",
    balanceValue: labels.points,
    maxAmount: options.points,
    metrics: options.allowed
      ? [
          { id: "redeem-valid-until", label: "Valid until", value: labels.validUntil },
          { id: "redeem-points-left", label: "Points left", value: labels.pointsLeft },
        ]
      : [],
    platformFeeLabel: formatActionFeeSummary("redeem", 0),
    risk: null,
    blockedReason: options.allowed ? null : (options.blockedReason ?? "Not enough points to redeem."),
    validationErrors: options.blockedReason ? [options.blockedReason] : [],
    warnings: [],
  }
}
