"use client"

import { ArrowUpRight, Copy } from "@/app/components/icons"
import { TestnetMetricsBadge } from "@/app/components/testnet-metrics-badge"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const ADDRESS_TEXT = "text-[15px] font-medium leading-none text-foreground/75"

/**
 * Detail-hero network line: "Asset on [TESTNET] | ⧉ 0x7573 ↗". The address shows only its
 * first four hex digits; the arrow opens the explorer when there is a real contract to show.
 */
export function HeroContractLine({
  contextLabel,
  address,
  isPlaceholder,
  explorerHref,
}: {
  /** Untranslated lead-in, e.g. "Asset on" or "Market on". */
  contextLabel: string
  /** Full 0x address (copied as-is). */
  address: string
  /** Synthetic placeholder addresses get no copy action or explorer link. */
  isPlaceholder: boolean
  explorerHref?: string | null
}) {
  const { t } = useTranslation()
  const shortAddress = address.slice(0, 6)
  const href = isPlaceholder ? null : explorerHref

  return (
    <div className="mt-0 flex flex-wrap items-center gap-3 text-[15px] font-medium text-foreground/75">
      {/* Testnet: the network label is swapped for the Testnet badge until mainnet. When testnet
          ends, render the chain name in place of the badge. */}
      <span className="inline-flex items-center gap-2">
        <span className="leading-none">{t(contextLabel)}</span>
        <TestnetMetricsBadge label={t("Testnet")} />
      </span>
      <span aria-hidden className="h-5 w-px bg-border" />
      <span className="inline-flex min-h-8 items-center gap-1.5">
        {isPlaceholder ? (
          <span className={ADDRESS_TEXT}>{shortAddress}</span>
        ) : (
          <button
            type="button"
            onClick={async () => {
              await navigator.clipboard.writeText(address)
            }}
            className={`inline-flex items-center gap-1.5 rounded-full ${ADDRESS_TEXT} transition-colors hover:text-foreground`}
            aria-label={`${t("Copy")} ${address}`}
            title={address}
          >
            <Copy className="h-4 w-4" strokeWidth={1.5} aria-hidden="true" />
            <span>{shortAddress}</span>
          </button>
        )}
        {href ? (
          <a
            href={href}
            target="_blank"
            rel="noreferrer"
            aria-label={t("View on explorer")}
            className="inline-flex size-5 items-center justify-center rounded-full text-foreground/75 transition-colors hover:text-foreground"
          >
            <ArrowUpRight className="h-4 w-4" strokeWidth={1.75} aria-hidden="true" />
          </a>
        ) : (
          <ArrowUpRight className="h-4 w-4 text-foreground/45" strokeWidth={1.75} aria-hidden="true" />
        )}
      </span>
    </div>
  )
}
