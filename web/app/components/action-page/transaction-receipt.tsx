"use client"

import Link from "next/link"
import { CheckCircle2, ExternalLink } from "@/app/components/icons"
import type { ActionMetricRow } from "@/app/lib/action-system/contracts"
import { ActionCard, ActionInfoRow, ActionMetricsBlock } from "@/app/components/action-page/action-metrics"
import { ActionTokenIcon } from "@/app/components/action-page/action-token-icon"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

/**
 * The single receipt design, shared by the inline success stage and the standalone
 * transaction permalink so there is exactly one "receipt" in the app.
 *
 * Everything localizes: labels flow through `ActionInfoRow` -> `t()`, and the fiat
 * figures (Value, Avana Platform Fee) format through `useCurrency`, so both react live to the
 * header language/currency switchers. Token amounts stay in their own units.
 */
export type TransactionReceiptData = {
  /** Status pill text; defaults to "Confirmed". */
  statusLabel?: string
  /** Headline, e.g. "Borrow successful" (composed English keys translate automatically). */
  title: string
  /** Optional subheadline, e.g. "$1,000 processed." */
  description?: string | null
  /** Token symbol driving the icon + fallback glyph. */
  symbol: string
  /** Label for the amount row (the action verb, e.g. "Borrow"). */
  amountRowLabel?: string
  /** Token amount, already unit-formatted (e.g. "1000.00 USDC") — not currency-converted. Row hidden when absent. */
  amountLabel?: string
  /** Raw USD value of the action; rendered as a currency-reactive "Value" row when present. */
  amountUsd?: number | null
  rateLabel?: string | null
  rateValue?: string | null
  marketValue?: string | null
  quoteId?: string | null
  /** Raw USD network fee; rendered as a currency-reactive "Avana Platform Fee" row when present. */
  networkFeeUsd?: number | null
  block?: number | string | null
  /** Epoch ms; rendered as a localized date row when present. */
  dateMs?: number | null
  hash?: string | null
  /** Where the hash + explorer link point; omit to render the hash as plain text. */
  hashHref?: string | null
  /** External (new tab) vs in-app navigation for the hash link. */
  hashExternal?: boolean
  /** Extra metric rows (health factor, LTV, …) rendered below the receipt card. */
  metrics?: ActionMetricRow[]
  /** Play the reveal animation on mount (default true). */
  animate?: boolean
}

/** Deterministic bar pattern derived from the hash so a receipt looks identical on revisit. */
function barcodeBars(hash: string) {
  const source = hash || "sim"
  const count = Math.min(60, source.length * 2)
  const bars: { width: number; height: number; on: boolean }[] = []
  for (let i = 0; i < count; i += 1) {
    const code = source.charCodeAt(i % source.length)
    bars.push({ width: (code % 3) + 1, height: 16 + ((code * (i + 1)) % 22), on: i % 4 !== 3 })
  }
  return bars
}

function formatReceiptDate(ms: number) {
  return new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
}

export function TransactionReceipt({ data, className }: { data: TransactionReceiptData; className?: string }) {
  const { t } = useTranslation()
  const { exact } = useCurrency()
  const animate = data.animate ?? true

  const hashLink = data.hash && data.hashHref
  const linkClass =
    "text-foreground underline decoration-dotted underline-offset-2 transition-colors hover:text-brand-readable"

  const hashNode = data.hash ? (
    hashLink ? (
      data.hashExternal ? (
        <a href={data.hashHref ?? undefined} target="_blank" rel="noreferrer" className={linkClass}>
          {data.hash}
        </a>
      ) : (
        <Link href={data.hashHref ?? "#"} className={linkClass}>
          {data.hash}
        </Link>
      )
    ) : (
      <span className="text-foreground">{data.hash}</span>
    )
  ) : null

  return (
    <div data-testid="transaction-receipt" className={cn("space-y-4", className)}>
      <ActionCard
        className={cn(
          "overflow-hidden border-t-2 border-t-emerald-500/70",
          animate && "animate-in fade-in slide-in-from-top-2 duration-500 motion-reduce:animate-none",
        )}
      >
        <div className="relative px-4 pb-2 pt-4">
          <div className="flex items-center justify-between">
            <div className="inline-flex items-center gap-2 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-3 py-1 text-[11px] font-medium text-emerald-300">
              <CheckCircle2 className="size-3.5" />
              {t(data.statusLabel ?? "Confirmed")}
            </div>
            {hashLink && data.hashExternal ? (
              <a
                href={data.hashHref ?? undefined}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 text-[12px] text-muted-foreground transition-colors hover:text-foreground"
              >
                {t("Explorer")}
                <ExternalLink className="size-3.5" />
              </a>
            ) : null}
          </div>

          <div className="flex flex-col items-center py-6 text-center">
            <ActionTokenIcon symbol={data.symbol} className="size-14" />
            <h2 className="mt-4 text-[1.25rem] font-medium tracking-[-0.03em]">{t(data.title)}</h2>
            {data.description ? (
              <p className="mt-1.5 max-w-sm text-[14px] text-muted-foreground">{t(data.description)}</p>
            ) : null}
            {hashNode ? (
              <p className="mt-2 font-data text-[12px] text-muted-foreground">
                {t("Receipt")}: {hashNode}
              </p>
            ) : null}
          </div>

          <div className="divide-y divide-border border-t border-border">
            {data.amountLabel ? (
              <ActionInfoRow label={data.amountRowLabel ?? "Amount"} value={data.amountLabel} tooltip="amount" />
            ) : null}
            {typeof data.amountUsd === "number" ? <ActionInfoRow label="Value" value={exact(data.amountUsd)} /> : null}
            {data.rateLabel && data.rateValue ? (
              <ActionInfoRow label={data.rateLabel} value={data.rateValue} tooltip="rate" />
            ) : null}
            {data.marketValue ? <ActionInfoRow label="Market" value={data.marketValue} tooltip="market" /> : null}
            {typeof data.networkFeeUsd === "number" ? (
              <ActionInfoRow label="Avana Platform Fee" value={exact(data.networkFeeUsd)} tooltip="fee" />
            ) : null}
            {data.block != null ? <ActionInfoRow label="Block" value={String(data.block)} /> : null}
            {data.dateMs != null ? (
              <ActionInfoRow label="Transaction date" value={formatReceiptDate(data.dateMs)} />
            ) : null}
          </div>

          {data.hash ? (
            <div className="mt-4 border-t border-dashed border-border pt-4">
              <div className="flex h-10 items-end justify-center gap-[2px]" aria-hidden="true">
                {barcodeBars(data.hash).map((bar, index) => (
                  <span
                    key={index}
                    className={cn("block", bar.on ? "bg-foreground" : "bg-transparent")}
                    style={{ width: `${bar.width}px`, height: `${bar.height}px` }}
                  />
                ))}
              </div>
              <p className="mt-2 break-all text-center font-data text-[12px] text-muted-foreground">{data.hash}</p>
            </div>
          ) : null}
        </div>
      </ActionCard>

      {data.metrics && data.metrics.length > 0 ? <ActionMetricsBlock rows={data.metrics} /> : null}
    </div>
  )
}
