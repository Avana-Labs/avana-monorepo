"use client"

import { useEffect, useMemo, useState } from "react"
import { Check, LoaderCircle } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

/**
 * The processing stage narrates its (synthetic) work like a reasoning stream — one
 * readable line at a time — instead of a bare spinner. Lines are per-action and flow
 * through `t()`, so they translate with the header language switcher.
 *
 * Cadence is tuned so a 5-line script fully reveals within PROCESSING_SIMULATED_MS
 * (see action-submit-runtime.ts); the last line keeps spinning until the flow advances
 * to `success` and this component unmounts.
 */
const LINE_MS = 780

const SCRIPTS: Record<string, string[]> = {
  borrow: [
    "Connecting to Uniswap v3",
    "Verifying your collateral position",
    "Locking collateral on Aave v4",
    "Opening your credit line",
    "Releasing funds to your wallet",
  ],
  deposit: [
    "Connecting to Aave v4",
    "Routing your deposit to the market",
    "Confirming the supply rate",
    "Minting your yield position",
    "Starting to accrue interest",
  ],
  withdraw: [
    "Connecting to Aave v4",
    "Checking available liquidity",
    "Unwinding your supplied position",
    "Releasing funds to your wallet",
    "Updating your balances",
  ],
  repay: [
    "Connecting to Aave v4",
    "Reading your outstanding debt",
    "Preparing your repayment",
    "Settling your balance",
    "Freeing up your borrowing power",
  ],
  deleverage: [
    "Connecting to Uniswap v3",
    "Reading your leveraged position",
    "Unwinding part of your loop",
    "Repaying borrowed funds",
    "Updating your leverage",
  ],
  remove: [
    "Checking your health factor headroom",
    "Unlocking your collateral",
    "Withdrawing from Aave v4",
    "Returning funds to your wallet",
    "Updating your borrowing power",
  ],
  claim: [
    "Tallying your rewards",
    "Verifying eligibility",
    "Signing your claim",
    "Sending rewards to your wallet",
    "Updating your balances",
  ],
  swap: [
    "Connecting to the swap router",
    "Refreshing your quote",
    "Submitting your swap",
    "Confirming the transaction",
    "Updating your wallet balances",
  ],
  pledge: [
    "Connecting to Uniswap v3",
    "Verifying your LP position",
    "Pledging collateral on Aave v4",
    "Boosting your borrowing power",
    "Finalizing your position",
  ],
  generic: [
    "Connecting to Aave v4",
    "Preparing your transaction",
    "Confirming on-chain",
    "Finalizing your position",
    "Updating your balances",
  ],
}

/**
 * Pick the narration script for an action from its verb. Order matters: "deleverage"
 * must be tested before "leverage", and "supply" (pledge collateral) must not fall into
 * the lend-deposit branch. Covers all descriptor verbs — Borrow, Repay, Supply, Remove,
 * Claim, Deposit, Withdraw, Multiply, Deleverage — with a generic fallback for the rest.
 */
export function processingNarrationScript(verb: string): string[] {
  const v = (verb || "").trim().toLowerCase()
  if (v.includes("borrow")) return SCRIPTS.borrow
  if (v.includes("repay")) return SCRIPTS.repay
  if (v.includes("withdraw")) return SCRIPTS.withdraw
  if (v.includes("deleverage") || v.includes("reduce") || v.includes("close")) return SCRIPTS.deleverage
  if (v.includes("remove")) return SCRIPTS.remove
  if (v.includes("supply") || v.includes("pledge") || v.includes("collateral")) return SCRIPTS.pledge
  if (v.includes("deposit") || v.includes("lend")) return SCRIPTS.deposit
  if (v.includes("claim")) return SCRIPTS.claim
  if (v.includes("swap")) return SCRIPTS.swap
  return SCRIPTS.generic
}

function usePrefersReducedMotion() {
  const [reduce, setReduce] = useState(false)
  useEffect(() => {
    if (typeof window === "undefined" || !window.matchMedia) return
    const query = window.matchMedia("(prefers-reduced-motion: reduce)")
    setReduce(query.matches)
    const onChange = () => setReduce(query.matches)
    query.addEventListener?.("change", onChange)
    return () => query.removeEventListener?.("change", onChange)
  }, [])
  return reduce
}

export function ProcessingNarration({ verb }: { verb: string }) {
  const { t } = useTranslation()
  const lines = useMemo(() => processingNarrationScript(verb), [verb])
  const reduceMotion = usePrefersReducedMotion()
  const [shown, setShown] = useState(1)

  useEffect(() => {
    if (reduceMotion) {
      setShown(lines.length)
      return
    }
    setShown(1)
    let revealed = 1
    const id = window.setInterval(() => {
      revealed += 1
      setShown((prev) => Math.min(lines.length, prev + 1))
      if (revealed >= lines.length) window.clearInterval(id)
    }, LINE_MS)
    return () => window.clearInterval(id)
  }, [lines, reduceMotion])

  return (
    <ol data-testid="processing-narration" aria-live="polite" className="space-y-3 border-t border-border pt-4">
      {lines.slice(0, shown).map((line, index) => {
        const isDone = index < shown - 1
        return (
          <li
            key={line}
            className={cn(
              "flex items-center gap-2.5 text-[14px] animate-in fade-in slide-in-from-bottom-1 duration-300 motion-reduce:animate-none",
              isDone ? "text-muted-foreground" : "font-medium text-foreground",
            )}
          >
            {isDone ? (
              <Check className="size-4 shrink-0 text-emerald-500" aria-hidden />
            ) : (
              <LoaderCircle
                className="size-4 shrink-0 animate-spin text-violet-400 motion-reduce:animate-none"
                aria-hidden
              />
            )}
            <span>{t(line)}</span>
          </li>
        )
      })}
    </ol>
  )
}
