"use client"

import { useAuthedQueryArgs } from "@/app/lib/convex/use-authed-query-args"
import Link from "next/link"
import { useEffect, useState } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { Skeleton } from "@/components/ui/skeleton"
import { ExternalLink } from "@/app/components/icons"
import { primaryCtaClass, secondaryCtaClass } from "@/app/components/action-page/action-cta"
import { TransactionReceipt, type TransactionReceiptData } from "@/app/components/action-page/transaction-receipt"
import { syntheticBlockFromHash, syntheticNetworkFeeUsdFromHash } from "@/app/lib/action-system/synthetic-receipt"
import { avanaPlatformFeeUsd } from "@/app/lib/action-system/formatters"
import { useSiweAuth } from "@/app/lib/siwe/use-siwe-auth"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useSwapSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { getSwapAsset, type SwapTransactionRecord } from "@/app/lib/swap-system"

const KIND_VERB: Record<string, string> = {
  borrow: "Borrow",
  deposit: "Deposit",
  withdraw: "Withdraw",
  repay: "Repay",
  claim: "Claim",
  multiply: "Multiply",
  deleverage: "Deleverage",
  liquidate: "Liquidate",
}

function prettyKind(kind: string) {
  return KIND_VERB[kind] ?? `${kind.charAt(0).toUpperCase()}${kind.slice(1)}`
}

export function inferLegacyDebtAssetId(receipt: { product?: string; kind?: string; marketSlug?: string | null }) {
  if (receipt.product !== "borrow" || (receipt.kind !== "borrow" && receipt.kind !== "repay")) return undefined
  const token = receipt.marketSlug?.split("-").at(-1)?.trim()
  return token || undefined
}

/**
 * Shared swap-receipt builder so the in-session record and the durable Convex row
 * render an identical breakdown. `succeeded` picks the summary line; optional economics
 * are shown only when present (a durable row seeded before this change omits them, and a
 * failed swap has no meaningful min-received / impact).
 */
function buildSwapReceiptData(input: {
  inputSymbol: string
  outputSymbol: string
  inputAmount: number
  outputAmount: number
  amountUsd: number
  hash: string
  dateMs: number
  succeeded: boolean
  failureReason?: string
  provider?: string | null
  networkFeeUsd?: number
  minOutputAmount?: number
  priceImpactPct?: number
  slippageBps?: number
  quoteId?: string
}): TransactionReceiptData {
  const metrics: NonNullable<TransactionReceiptData["metrics"]> = []
  if (input.minOutputAmount !== undefined) {
    metrics.push({
      id: "minimum-received",
      label: "Minimum received",
      value: `${input.minOutputAmount.toLocaleString()} ${input.outputSymbol}`,
    })
  }
  if (input.priceImpactPct !== undefined) {
    metrics.push({ id: "price-impact", label: "Price impact", value: `${input.priceImpactPct.toFixed(2)}%` })
  }
  if (input.slippageBps !== undefined) {
    metrics.push({ id: "slippage", label: "Max slippage", value: `${(input.slippageBps / 100).toFixed(2)}%` })
  }
  return {
    title: `Swap ${input.inputSymbol} for ${input.outputSymbol}`,
    description: input.succeeded
      ? `${input.inputAmount.toLocaleString()} ${input.inputSymbol} swapped for ${input.outputAmount.toLocaleString()} ${input.outputSymbol}.`
      : (input.failureReason ?? "Swap did not complete."),
    symbol: input.inputSymbol,
    amountRowLabel: "Sold",
    amountLabel: `${input.inputAmount.toLocaleString()} ${input.inputSymbol}`,
    amountUsd: input.amountUsd,
    rateLabel: "Received",
    rateValue: `${input.outputAmount.toLocaleString()} ${input.outputSymbol}`,
    marketValue: input.provider ?? null,
    networkFeeUsd: input.networkFeeUsd ?? syntheticNetworkFeeUsdFromHash(input.hash),
    block: syntheticBlockFromHash(input.hash),
    dateMs: input.dateMs,
    hash: input.hash,
    metrics: metrics.length ? metrics : undefined,
    quoteId: input.quoteId,
  }
}

/** Map a stored synthetic transaction (durable Convex row) to the shared receipt shape. */
export function toReceiptData(receipt: {
  at: number
  syntheticTxHash: string
  amountUsd: number
  product?: string
  kind?: string
  status?: string
  marketSlug?: string | null
  assetId?: string | null
  swapInputSymbol?: string
  swapOutputSymbol?: string
  swapInputAmount?: number
  swapOutputAmount?: number
  swapProvider?: string
  swapQuoteId?: string
  swapNetworkFeeUsd?: number
  swapMinOutputAmount?: number
  swapPriceImpactPct?: number
  swapSlippageBps?: number
}): TransactionReceiptData {
  const hash = receipt.syntheticTxHash
  if (receipt.product === "swap") {
    return buildSwapReceiptData({
      inputSymbol: receipt.swapInputSymbol ?? "Asset",
      outputSymbol: receipt.swapOutputSymbol ?? "Asset",
      inputAmount: receipt.swapInputAmount ?? 0,
      outputAmount: receipt.swapOutputAmount ?? 0,
      amountUsd: receipt.amountUsd,
      hash,
      dateMs: receipt.at,
      succeeded: receipt.status !== "failed",
      provider: receipt.swapProvider,
      networkFeeUsd: receipt.swapNetworkFeeUsd,
      minOutputAmount: receipt.swapMinOutputAmount,
      priceImpactPct: receipt.swapPriceImpactPct,
      slippageBps: receipt.swapSlippageBps,
      quoteId: receipt.swapQuoteId,
    })
  }
  // Prefer the traded asset for the icon/title, then fall back to the market slug so a
  // row that only recorded its market (common for lend deposits) still resolves a real
  // token icon instead of the "?" placeholder + a missing-asset 404.
  const assetId = receipt.assetId ?? inferLegacyDebtAssetId(receipt)
  const symbol = (assetId ?? receipt.marketSlug ?? "").toUpperCase() || "Asset"
  const verb = receipt.kind ? prettyKind(receipt.kind) : "Transaction"
  return {
    title: symbol !== "Asset" ? `${verb} ${symbol}` : verb,
    symbol,
    amountRowLabel: verb,
    amountUsd: receipt.amountUsd,
    // Market slugs are stored lowercase ("usdc"); show the ticker uppercased ("USDC").
    marketValue: receipt.marketSlug ? receipt.marketSlug.toUpperCase() : null,
    // The review estimate and the receipt read one canonical fee, so a "~$0.03"
    // estimate can no longer confirm as "$0.89" (#F1).
    networkFeeUsd: avanaPlatformFeeUsd(receipt.amountUsd),
    block: syntheticBlockFromHash(hash),
    dateMs: receipt.at,
    hash,
  }
}

export function swapTransactionToReceiptData(transaction: SwapTransactionRecord): TransactionReceiptData {
  const inputAsset = getSwapAsset(transaction.inputAssetId)
  const outputAsset = getSwapAsset(transaction.outputAssetId)
  const hash = transaction.swapTransactionHash ?? transaction.approvalTransactionHash ?? transaction.id
  return buildSwapReceiptData({
    inputSymbol: inputAsset?.symbol ?? transaction.inputAssetId.toUpperCase(),
    outputSymbol: outputAsset?.symbol ?? transaction.outputAssetId.toUpperCase(),
    inputAmount: transaction.inputAmount,
    outputAmount: transaction.outputAmount,
    amountUsd: transaction.inputAmount * (inputAsset?.priceUsd ?? 0),
    hash,
    dateMs: transaction.confirmedAt ?? transaction.createdAt,
    succeeded: transaction.status === "confirmed",
    failureReason: transaction.failureReason,
    provider: transaction.provider,
    networkFeeUsd: transaction.networkFeeUsd,
    minOutputAmount: transaction.minimumOutputAmount,
    priceImpactPct: transaction.priceImpactPct,
    slippageBps: transaction.slippageBps,
    quoteId: transaction.quoteId,
  })
}

export function SyntheticTransactionClient({ hash }: { hash: string }) {
  const { t } = useTranslation()
  const swap = useSwapSessionContext()
  const { authedWallet, isSignedIn } = useSiweAuth()
  // Wait for Convex auth, not just the SIWE session: querying in between threw UNAUTHENTICATED
  // ("[CONVEX Q(...getTransactionByHash)] Server Error") on phones, where auth lands later.
  const receipt = useQuery(
    api.sandbox.transactions.getTransactionByHash,
    useAuthedQueryArgs(isSignedIn && authedWallet ? { wallet: authedWallet, hash } : null),
  )
  const swapTransaction = swap.transactionHistory.find(
    (transaction) =>
      transaction.id === hash ||
      transaction.swapTransactionHash === hash ||
      transaction.approvalTransactionHash === hash,
  )

  // When the backend is unreachable the query stays `undefined` forever, leaving an
  // empty card under the title. Time out so the user gets a clear message instead.
  const [timedOut, setTimedOut] = useState(false)
  useEffect(() => {
    if (receipt !== undefined) return
    const timer = setTimeout(() => setTimedOut(true), 8000)
    return () => clearTimeout(timer)
  }, [receipt])

  const etherscanHref = `https://etherscan.io/tx/${encodeURIComponent(hash)}`

  return (
    <main className="mx-auto flex min-h-[70vh] w-full max-w-md flex-col px-5 py-12 md:py-16">
      <header className="mb-6">
        <h1 className="text-[22px] font-medium leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
          {t("Transaction receipt")}
        </h1>
      </header>

      {swapTransaction ? (
        <TransactionReceipt data={swapTransactionToReceiptData(swapTransaction)} />
      ) : !isSignedIn ? (
        <p className="text-muted-foreground">{t("Sign in with the wallet that created this transaction.")}</p>
      ) : receipt === undefined ? (
        timedOut ? (
          <p className="text-muted-foreground">
            {t("This receipt is taking too long to load. It may not be available in this environment.")}
          </p>
        ) : (
          <Skeleton className="h-32 rounded-3xl" />
        )
      ) : receipt === null ? (
        <p className="text-muted-foreground">{t("This receipt does not exist for the authenticated wallet.")}</p>
      ) : (
        <TransactionReceipt data={toReceiptData(receipt)} />
      )}

      <div className="mt-8 flex flex-col gap-3 sm:flex-row sm:items-center">
        <Link href="/dashboard" className={primaryCtaClass({ size: "compact", className: "w-full sm:flex-1" })}>
          {t("Back to dashboard")}
        </Link>
        <a
          href={etherscanHref}
          target="_blank"
          rel="noreferrer"
          className={secondaryCtaClass({ size: "compact", className: "w-full gap-2 sm:flex-1" })}
        >
          {t("See on Etherscan")}
          <ExternalLink className="size-4" />
        </a>
      </div>
    </main>
  )
}
