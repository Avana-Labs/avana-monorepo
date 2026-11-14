"use client"

import { Check } from "@/app/components/icons"
import type { HomeBorrowToken } from "@/app/lib/home-view-model"
import { TokenBubble } from "@/app/components/home-workspace-primitives"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { cn } from "@/lib/utils"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const TOKEN_ADDRESS_BY_SYMBOL: Record<string, string> = {
  ETH: "Native",
  USDC: "0xA0b8...eB48",
  USDT: "0xdAC1...1ec7",
  WBTC: "0x2260...C599",
  DAI: "0x6B17...1d0F",
  ARB: "0x912C...6a20",
  LINK: "0x5149...1Ca",
  UNI: "0x1f98...48f1",
  AAVE: "0x7Fc6...A9e9",
  MATIC: "0x7D1A...0e4a",
  SOL: "So111...1112",
  AVAX: "0x8580...0cF8",
  OP: "0x4200...0042",
  FTM: "0x4E15...AAF8",
}

// Mirror the search-command popup exactly so the pickers share its look/feel.
const PICKER_CONTENT_CLASS =
  "flex max-h-[min(620px,calc(100dvh-96px))] w-full max-w-[600px] flex-col gap-0 overflow-hidden rounded-radius-xl border-border bg-background p-0 shadow-[0_24px_80px_rgba(15,23,42,0.22)] sm:w-[calc(100vw-24px)] sm:max-w-[600px] sm:rounded-radius-xl [&>button]:right-3.5 [&>button]:top-3.5 [&>button]:rounded-full"

export function TokenPickerDialog({
  open,
  onOpenChange,
  selectedTokenId,
  onSelect,
  tokens = [],
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  selectedTokenId: string | null
  onSelect: (tokenId: string) => void
  tokens?: HomeBorrowToken[]
}) {
  const { t } = useTranslation()

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className={PICKER_CONTENT_CLASS}>
        <DialogHeader className="border-b border-border px-5 pb-3 pt-4 text-left">
          <DialogTitle className="text-[14px] font-normal leading-5">{t("Choose asset to borrow")}</DialogTitle>
        </DialogHeader>

        <div className="flex-1 overflow-y-auto py-1.5">
          {tokens.map((token) => {
            const isSelected = token.id === selectedTokenId
            const address = TOKEN_ADDRESS_BY_SYMBOL[token.symbol] ?? ""

            return (
              <button
                key={token.id}
                type="button"
                onClick={() => onSelect(token.id)}
                className={cn(
                  "flex w-full items-center gap-3 px-5 py-2.5 text-left transition-colors hover:bg-hover",
                  isSelected && "bg-surface-inset",
                )}
              >
                <TokenBubble visual={token.visual} />
                <div className="flex min-w-0 flex-1 flex-col">
                  <span className="truncate text-[14px] font-normal leading-5 text-foreground">{token.name}</span>
                  <div className="flex items-center gap-1.5 text-[12px] leading-4 text-muted-foreground">
                    <span>{token.symbol}</span>
                    {address ? <span className="truncate font-data">{address}</span> : null}
                  </div>
                </div>
                {isSelected ? <Check className="h-3.5 w-3.5 text-foreground" /> : null}
              </button>
            )
          })}

          {tokens.length === 0 ? (
            <div className="mx-4 my-3 rounded-radius-sm border border-dashed border-border px-4 py-6 text-center text-[12px] text-muted-foreground">
              {t("No borrowable assets for this collateral.")}
            </div>
          ) : null}
        </div>
      </DialogContent>
    </Dialog>
  )
}
