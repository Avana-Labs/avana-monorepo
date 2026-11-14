import { describe, expect, it } from "vitest"
import { formatCompactUsd } from "@/app/lib/format"
import { setCanonicalPrices, resetCanonicalPrices } from "@/app/lib/prices/canonical"
import {
  isUsdMirroredTokenLabel,
  resolvePoolTokenAmounts,
  resolvePoolUsdValue,
  resolveTransactionTokenDisplay,
  resolveTransactionUsdValue,
} from "@/app/lib/detail-page/transaction-display"
import type { DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"

const baseRow = (overrides: Partial<DetailTransactionRow>): DetailTransactionRow => ({
  id: "1",
  at: "",
  kind: "supply",
  amountLabel: "$1.00K",
  txHashShort: "0x",
  ...overrides,
})

const usdLabel = (usd: number | null) =>
  usd == null ? null : `${usd < 0 ? "-" : ""}${formatCompactUsd(Math.abs(usd))}`

describe("transaction-display", () => {
  it("detects USD mirrored token labels", () => {
    expect(
      isUsdMirroredTokenLabel(baseRow({ amountLabel: "$37.50K", tokenAmountLabel: "37.50K", tokenSymbol: "OP" })),
    ).toBe(true)
    expect(
      isUsdMirroredTokenLabel(baseRow({ amountLabel: "$37.50K", tokenAmountLabel: "378,041.33", tokenSymbol: "OP" })),
    ).toBe(false)
  })

  it("keeps FOR fixed while USD tracks live price", () => {
    const row = baseRow({
      amountLabel: "$37.50K",
      tokenAmountLabel: "378,041.33",
      tokenSymbol: "OP",
    })
    expect(resolveTransactionTokenDisplay(row)).toEqual({ amount: "378,041.33", symbol: "OP" })

    setCanonicalPrices({ OP: 1.46 })
    expect(usdLabel(resolveTransactionUsdValue(row))).toBe("$551.9K")

    setCanonicalPrices({ OP: 0.73 })
    expect(usdLabel(resolveTransactionUsdValue(row))).toBe("$276.0K")
    expect(resolveTransactionTokenDisplay(row)).toEqual({ amount: "378,041.33", symbol: "OP" })

    resetCanonicalPrices()
  })

  it("derives frozen For from USD using seed fixture price", () => {
    const row = baseRow({
      amountLabel: "$37.50K",
      amountUsd: 37_500,
      tokenSymbol: "GHO",
    })
    expect(resolveTransactionTokenDisplay(row)).toEqual({ amount: "37,500", symbol: "GHO" })
    expect(usdLabel(resolveTransactionUsdValue(row))).toBe("$37.5K")
  })

  it("values pool USD from each constituent leg at live prices", () => {
    const row = baseRow({
      amountLabel: "$48.53K",
      token0AmountLabel: "10.1831",
      token1AmountLabel: "24,271.21",
      tokenSymbol: "WETH",
      tokenSymbolSecondary: "USDT",
    })
    setCanonicalPrices({ WETH: 1934, USDT: 1 })
    expect(usdLabel(resolvePoolUsdValue(row, "WETH", "USDT"))).toBe("$44.0K")
    expect(resolvePoolTokenAmounts(row, "WETH", "USDT")).toEqual({
      token0Amount: "10.1831",
      token1Amount: "24,271.21",
    })

    setCanonicalPrices({ WETH: 1500, USDT: 1 })
    expect(usdLabel(resolvePoolUsdValue(row, "WETH", "USDT"))).toBe("$39.5K")
    expect(resolvePoolTokenAmounts(row, "WETH", "USDT").token0Amount).toBe("10.1831")

    resetCanonicalPrices()
  })

  it("falls back to embedded amountLabel token pairs", () => {
    const row = baseRow({
      amountLabel: "+1200.0000 GHO",
      tokenSymbol: "GHO",
    })
    expect(resolveTransactionTokenDisplay(row)).toEqual({ amount: "1200.0000", symbol: "GHO" })
    expect(usdLabel(resolveTransactionUsdValue(row))).toBe("$1.2K")
  })

  it("does not treat multiply collateral rows as pool legs", () => {
    const row = baseRow({
      amountLabel: "+$50.0K",
      tokenAmountLabel: "25.8521",
      tokenSymbol: "WETH",
      tokenSymbolSecondary: "USDC",
    })
    setCanonicalPrices({ WETH: 1934, USDC: 1 })
    expect(usdLabel(resolveTransactionUsdValue(row))).toBe("$50.0K")
    expect(resolveTransactionTokenDisplay(row)).toEqual({ amount: "25.8521", symbol: "WETH" })
    resetCanonicalPrices()
  })

  it("reconciles a debt row's token quantity to the recorded USD at the live price", () => {
    // A $2,471 WETH borrow. The record stores only USD, so the token amount was bootstrapped from
    // a frozen seed price (WETH 1934 → 2471/1934 = 1.2776) — which then re-values at the live
    // price (~2450) to ~$3.1K, disagreeing with the record and the dashboard debt row.
    const row = baseRow({
      kind: "borrow",
      amountLabel: "$2.5K",
      amountUsd: 2_471,
      tokenAmountLabel: "1.2776",
      tokenSymbol: "WETH",
    })
    setCanonicalPrices({ WETH: 2450 })

    // Default (pool/lend/multiply): frozen seed quantity, USD re-valued at live → over-values.
    expect(resolveTransactionTokenDisplay(row)).toEqual({ amount: "1.2776", symbol: "WETH" })
    expect(resolveTransactionUsdValue(row)).toBeCloseTo(1.2776 * 2450, 0)

    // Reconciled (asset/debt feed): quantity = recorded USD / live price (~1.0086 WETH), and the
    // USD is the record ($2,471) — so token qty × price === recorded USD (~1.01 WETH, not 1.2776).
    const token = resolveTransactionTokenDisplay(row, undefined, true)
    expect(token?.symbol).toBe("WETH")
    expect(Number(token?.amount)).toBeCloseTo(2471 / 2450, 3)
    expect(resolveTransactionUsdValue(row, undefined, true)).toBe(2471)

    resetCanonicalPrices()
  })

  it("keeps withdrawal USD negative from FOR × live price", () => {
    const row = baseRow({
      kind: "withdraw",
      amountLabel: "-$1.2K",
      tokenAmountLabel: "1,200",
      tokenSymbol: "GHO",
    })
    expect(usdLabel(resolveTransactionUsdValue(row))).toBe("-$1.2K")
  })
})
