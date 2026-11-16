"use client"

import { ArrowUpRight, Copy } from "@/app/components/icons"
import { NetworkBadge, networkBadgeLabel } from "@/app/components/network-badge"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { HeroContract } from "@/app/lib/detail-page/hero-contract"

const ADDRESS_TEXT = "text-[15px] font-medium leading-none text-foreground/75"

/**
 * Detail-hero network line: "Asset on Ethereum | ⧉ 0x7573 ↗". The address comes only from
 * services/convex (the release manifest), checksummed; without one the line shows the chain only.
 */
export function HeroContractLine({
  contextLabel,
  chainLabel,
  contract,
}: {
  /** Untranslated lead-in, e.g. "Asset on" or "Market on". */
  contextLabel: string
  /** Chain name shown after the lead-in, e.g. "Ethereum". */
  chainLabel: string
  /** The real contract, or null when services/convex has none. */
  contract: HeroContract | null | undefined
}) {
  const { t } = useTranslation()

  return (
    <div className="mt-0 flex flex-wrap items-center gap-3 text-[15px] font-medium text-foreground/75">
      <span className="inline-flex items-center gap-2">
        <span className="leading-none">{t(contextLabel)}</span>
        {networkBadgeLabel() ? <NetworkBadge /> : <span className="leading-none text-foreground">{t(chainLabel)}</span>}
      </span>
      {contract ? (
        <>
          <span aria-hidden className="h-5 w-px bg-border" />
          <span className="inline-flex min-h-8 items-center gap-1.5">
            <button
              type="button"
              onClick={async () => {
                await navigator.clipboard.writeText(contract.address)
              }}
              className={`inline-flex items-center gap-1.5 rounded-full ${ADDRESS_TEXT} transition-colors hover:text-foreground`}
              aria-label={`${t("Copy")} ${contract.address}`}
              title={contract.address}
            >
              <Copy className="h-4 w-4" strokeWidth={1.5} aria-hidden="true" />
              <span>{contract.address.slice(0, 6)}</span>
            </button>
            {contract.explorerHref ? (
              <a
                href={contract.explorerHref}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={t("View on explorer")}
                className="inline-flex size-5 items-center justify-center rounded-full text-foreground/75 transition-colors hover:text-foreground"
              >
                <ArrowUpRight className="h-4 w-4" strokeWidth={1.75} aria-hidden="true" />
              </a>
            ) : null}
          </span>
        </>
      ) : null}
    </div>
  )
}
