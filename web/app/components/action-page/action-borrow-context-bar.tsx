"use client"

import { useState } from "react"
import type { HomeCollateralPool } from "@/app/lib/borrow-system/home-contracts"
import { HomeActionContextBar } from "@/app/components/home/home-action-context-bar"
import { PoolPickerDialog } from "@/app/components/home/pool-picker-dialog"
import { SwapStyleFieldStack } from "@/app/components/action-page/swap-style-field"
import type { PoolDialogMode } from "@/app/components/home/types"
import { useTranslation } from "@/app/lib/i18n/use-translation"

function poolDialogModeForKind(kind: "supply" | "borrow" | "repay" | "remove" | "claim"): PoolDialogMode {
  if (kind === "repay") return "repay"
  if (kind === "remove") return "remove"
  return "borrow"
}

export function ActionBorrowContextBar({
  kind,
  pool,
  pools,
  debts,
  onPoolChange,
  variant = "card",
  workspace = false,
  amountField,
  switchable = true,
}: {
  kind: "supply" | "borrow" | "repay" | "remove" | "claim"
  pool: HomeCollateralPool | null
  pools: HomeCollateralPool[]
  debts: Record<string, number>
  onPoolChange: (poolId: string) => void
  variant?: "card" | "inset"
  workspace?: boolean
  amountField?: React.ReactNode
  /** When false the collateral is fixed (no picker) — e.g. a market detail page
   *  where the action is scoped to the market you're viewing. */
  switchable?: boolean
}) {
  const { t } = useTranslation()
  const [poolDialogOpen, setPoolDialogOpen] = useState(false)
  const poolDialogMode = poolDialogModeForKind(kind)

  // One collateral card in every state (pool selected or not) so the input does
  // not visibly switch between two different card layouts. HomeActionContextBar
  // handles the null-pool placeholder itself.
  const poolField = (
    <HomeActionContextBar
      pool={pool}
      onOpenPool={() => setPoolDialogOpen(true)}
      variant={variant}
      workspace={workspace}
      label={t("Collateral")}
      switchable={switchable}
    />
  )

  return (
    <>
      {variant === "inset" ? (
        <SwapStyleFieldStack showConnector={!workspace}>
          {poolField}
          {amountField}
        </SwapStyleFieldStack>
      ) : (
        poolField
      )}

      {switchable ? (
        <PoolPickerDialog
          open={poolDialogOpen}
          onOpenChange={setPoolDialogOpen}
          selectedPoolId={pool?.id ?? ""}
          onSelect={(poolId) => {
            onPoolChange(poolId)
            setPoolDialogOpen(false)
          }}
          mode={poolDialogMode}
          pools={pools}
          debts={debts}
        />
      ) : null}
    </>
  )
}
