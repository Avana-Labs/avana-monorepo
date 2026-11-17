"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"

const rewardsPrimaryButtonClass =
  "bg-brand font-normal text-white shadow-none hover:bg-brand/90 disabled:bg-muted/60 disabled:text-muted-foreground"

/** The risk primer of the "Read the LP risk primer" quest; finishing it records the quest. */
export function RewardsEducationDialog({
  open,
  onOpenChange,
  onComplete,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  onComplete: () => Promise<void>
}) {
  const { t } = useTranslation()
  const [loading, setLoading] = useState(false)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("Risk primer")}</DialogTitle>
          <DialogDescription>{t("60-second briefing before you pledge an LP position.")}</DialogDescription>
        </DialogHeader>
        <div className="space-y-3 text-sm text-muted-foreground">
          <p>{t("LP collateral can lose value if the pool diverges, fees drop, or leverage gets too tight.")}</p>
          <p>{t("If the health factor falls below 1, the position can be liquidated.")}</p>
          <p>{t("Keep some headroom: check the health factor before and after every borrow or withdrawal.")}</p>
        </div>
        <DialogFooter>
          <Button
            className={rewardsPrimaryButtonClass}
            disabled={loading}
            onClick={() => {
              setLoading(true)
              void onComplete().finally(() => {
                setLoading(false)
                onOpenChange(false)
              })
            }}
          >
            {t("I read it")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/** Picks one of the given markets to pin to the wallet's watchlist; the pin completes the quest of its kind. */
export function RewardsPinMarketDialog({
  open,
  onOpenChange,
  markets,
  onPin,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  markets: ReadonlyArray<{ id: string; label: string }>
  onPin: (marketId: string) => Promise<void>
}) {
  const { t } = useTranslation()
  const [loadingId, setLoadingId] = useState<string | null>(null)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("Pin a market")}</DialogTitle>
          <DialogDescription>{t("Choose one market to add to your watchlist.")}</DialogDescription>
        </DialogHeader>
        {markets.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("No markets to pin yet.")}</p>
        ) : (
          <div className="grid max-h-80 gap-2 overflow-y-auto">
            {markets.map((market) => (
              <Button
                key={market.id}
                variant="outline"
                disabled={loadingId != null}
                onClick={() => {
                  setLoadingId(market.id)
                  void onPin(market.id).finally(() => {
                    setLoadingId(null)
                    onOpenChange(false)
                  })
                }}
              >
                {market.label}
              </Button>
            ))}
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
