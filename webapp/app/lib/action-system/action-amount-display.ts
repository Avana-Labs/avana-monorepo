import type { ActionPreviewUi } from "@/app/lib/action-system/contracts"

export function resolveActionAmountCardProps(
  preview: Pick<ActionPreviewUi, "amountLabel" | "amountValue" | "assetLabel" | "assetSymbol" | "borrowSymbol">,
) {
  if (preview.amountValue != null) {
    return {
      amount: preview.amountValue,
      assetLabel: preview.assetLabel ?? preview.assetSymbol ?? "Asset",
      assetSymbol: preview.assetSymbol ?? preview.assetLabel ?? "Asset",
      borrowSymbol: preview.borrowSymbol,
    }
  }

  const pairMatch = preview.amountLabel.match(/^([\d,.]+)\s+(.+\s\/\s.+)$/)
  if (pairMatch) {
    const [, amount, pairLabel] = pairMatch
    const [collateralSymbol, borrowSymbol] = pairLabel.split("/").map((part) => part.trim())
    return {
      amount,
      assetLabel: pairLabel,
      assetSymbol: collateralSymbol ?? pairLabel,
      borrowSymbol: borrowSymbol || undefined,
    }
  }

  const parts = preview.amountLabel.trim().split(/\s+/)
  const assetSymbol = parts[parts.length - 1] ?? "Asset"
  const amount = parts.slice(0, -1).join(" ") || preview.amountLabel

  return {
    amount,
    assetLabel: assetSymbol,
    assetSymbol,
    borrowSymbol: undefined,
  }
}
