import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"
import { formatActionApproxUsd, formatActionFeeSummary, formatActionUsd } from "@/app/lib/action-system/formatters"

export function mapBorrowRewardsClaimPreviewToActionUi(options: {
  allowed: boolean
  claimUsd: number
  marketLabel: string
  tokenTotals: Record<string, number>
  blockedReason?: string | null
}): ActionPreviewUi {
  const tokenRows = Object.entries(options.tokenTotals)
    .filter(([, usd]) => usd > 0)
    .sort((left, right) => right[1] - left[1])
    .map(([symbol, usd]) => ({
      id: `claim-${symbol.toLowerCase()}`,
      label: symbol,
      value: formatActionUsd(usd),
      tone: "positive" as const,
    }))

  // The claim total sits next to per-token rows that always show cents (each is
  // < $100). Format the total exactly too, so $68.99 + $42.11 reads "$111.10" and
  // not a cents-dropping "$111". (#25)
  const claimTotalLabel = formatActionUsd(options.claimUsd, { exact: true })

  return {
    allowed: options.allowed,
    amountValue: claimTotalLabel,
    amountLabel: claimTotalLabel,
    amountUsd: options.claimUsd,
    amountUsdLabel: formatActionApproxUsd(options.claimUsd),
    assetLabel: options.marketLabel,
    assetSymbol: Object.keys(options.tokenTotals)[0] ?? "Rewards",
    rateLabel: "Claim total",
    rateValue: claimTotalLabel,
    marketLabel: "Market",
    marketValue: options.marketLabel,
    balanceLabel: "Claimable",
    balanceValue: claimTotalLabel,
    maxAmount: options.claimUsd,
    metrics:
      tokenRows.length > 0
        ? tokenRows
        : [
            {
              id: "claim-total",
              label: "Total received",
              value: claimTotalLabel,
              tone: "positive" as const,
            },
          ],
    networkFeeLabel: formatActionFeeSummary(options.claimUsd, 0.02),
    risk: null,
    blockedReason: options.allowed ? null : (options.blockedReason ?? "Nothing to claim"),
    validationErrors: options.blockedReason ? [options.blockedReason] : [],
    warnings: [],
  }
}
