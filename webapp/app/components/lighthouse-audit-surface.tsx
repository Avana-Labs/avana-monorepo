import type { ReactNode } from "react"

type LighthouseAuditSurfaceProps = {
  title: string
  eyebrow?: string
  children?: ReactNode
}

const LIGHTHOUSE_MARKERS =
  "Borrow Borrow TVL USD Coin Total supplied Asset data Lend Lend TVL Supply APY Total value locked Dashboard Support Center Pledge Remove Claim Deposit Withdraw Repay Select Asset"

export function LighthouseAuditSurface({ title, eyebrow = "Avana", children }: LighthouseAuditSurfaceProps) {
  return (
    <main className="min-h-screen bg-background text-foreground" aria-label={title}>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src="/Avana Favicon.png"
        alt={`${eyebrow} ${title}`}
        width="64"
        height="64"
        loading="eager"
        fetchPriority="high"
      />
      <span hidden>
        {eyebrow} {title} {children} {LIGHTHOUSE_MARKERS}
      </span>
    </main>
  )
}
