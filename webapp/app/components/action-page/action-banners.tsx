"use client"

import { AlertTriangle } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"
import type { ActionRiskLevel } from "@/app/lib/action-system/contracts"

export function ActionRiskBanner({
  level,
  title,
  message,
  className,
}: {
  level: ActionRiskLevel
  title: string
  message: string
  className?: string
}) {
  const { t } = useTranslation()
  return (
    <div
      data-testid="action-risk-banner"
      className={cn(
        "flex gap-3 rounded-radius-lg border px-4 py-3",
        level === "danger" && "border-danger/30 bg-danger/10 text-danger",
        level === "warning" && "border-warning/30 bg-warning/10 text-warning",
        level === "safe" && "border-success/30 bg-success/10 text-success",
        className,
      )}
    >
      <AlertTriangle
        className={cn(
          "mt-0.5 size-4 shrink-0",
          level === "danger" && "text-danger",
          level === "warning" && "text-warning",
          level === "safe" && "text-success",
        )}
      />
      <div>
        <div className="text-[15px] font-semibold">{t(title)}</div>
        <div className="mt-1 text-[13px] leading-relaxed opacity-90">{t(message)}</div>
      </div>
    </div>
  )
}

export function ActionOutcomeBanner({
  tone,
  title,
  message,
}: {
  tone: "error" | "success"
  title: string
  message: string
}) {
  const { t } = useTranslation()
  return (
    <div
      data-testid="action-outcome-banner"
      className={cn(
        "flex gap-3 rounded-radius-lg border px-4 py-3",
        tone === "error" && "border-danger/30 bg-danger/10",
        tone === "success" && "border-success/30 bg-success/10",
      )}
    >
      <AlertTriangle className={cn("mt-0.5 size-4 shrink-0", tone === "error" ? "text-danger" : "text-success")} />
      <div>
        <div className="text-[15px] font-semibold">{t(title)}</div>
        <div className="mt-1 text-[13px] text-muted-foreground">{t(message)}</div>
      </div>
    </div>
  )
}

export function ActionWalletToast({ message }: { message: string }) {
  const { t } = useTranslation()
  return (
    <div
      data-testid="action-wallet-toast"
      className="fixed bottom-6 left-1/2 z-[60] w-[min(calc(100vw-2rem),420px)] -translate-x-1/2 rounded-full border border-border bg-surface-raised px-4 py-3 text-center text-[13px] shadow-elev-3"
    >
      {t(message)}
    </div>
  )
}
