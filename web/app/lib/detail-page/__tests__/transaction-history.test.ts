import { describe, expect, it } from "vitest"
import {
  enrichBorrowRowWithAsset,
  enrichDetailTransactionRow,
  enrichPoolRowWithPair,
  formatWalletLabel,
  formatRelativeTime,
  mapBorrowSessionRows,
  mapLendSessionRows,
  mapMultiplyHistoryKind,
  mapMultiplySessionRows,
  mergeTransactionRows,
  scopedAssetKeysMatch,
} from "@/app/lib/detail-page/transaction-history"
import {
  MULTIPLY_KIND_CONFIG,
  resolveTransactionKindLabel,
} from "@/app/components/detail-transaction-table/kind-configs"

describe("transaction-history helpers", () => {
  it("formats the canonical wallet address", () => {
    expect(formatWalletLabel("0x1234567890abcdef1234567890abcdef12345678")).toBe("0x1234…5678")
    expect(formatWalletLabel()).toBeUndefined()
  })

  it("formatRelativeTime returns compact labels", () => {
    const now = Date.now()
    expect(formatRelativeTime(new Date(now - 32_000).toISOString())).toMatch(/32s|32 sec/)
  })

  it("mergeTransactionRows dedupes by id with session first", () => {
    const merged = mergeTransactionRows(
      [{ id: "a", at: "", kind: "supply", amountLabel: "$1", txHashShort: "0x" }],
      [{ id: "a", at: "", kind: "borrow", amountLabel: "$2", txHashShort: "0x" }],
      [{ id: "b", at: "", kind: "repay", amountLabel: "$3", txHashShort: "0x" }],
    )
    expect(merged).toHaveLength(2)
    expect(merged[0]?.amountLabel).toBe("$1")
  })

  it("mapLendSessionRows separates USD and token amounts", () => {
    const rows = mapLendSessionRows(
      [
        {
          id: "l1",
          marketId: "gho",
          kind: "deposit",
          amount: 1200,
          timestamp: Date.now() - 60_000,
          hash: "0xabc1234567890",
        } as never,
      ],
      "gho",
      "GHO",
      1,
      "0x1234567890abcdef1234567890abcdef12345678",
    )
    expect(rows[0]?.tokenSymbol).toBe("GHO")
    expect(rows[0]?.tokenAmountLabel).toBe("1,200")
    expect(rows[0]?.amountLabel).toBe("$1.2K")
    expect(rows[0]?.walletLabel).toBe("0x1234…5678")
  })

  it("mapBorrowSessionRows maps borrow actions with token symbol", () => {
    const rows = mapBorrowSessionRows(
      [
        {
          id: "b1",
          marketId: "uni-v2:usdc",
          assetId: "uni-v2:usdc",
          kind: "borrow",
          executedAmountUsd6: 1_500_000_000n,
          timestamp: Date.now() - 120_000,
          hash: "0xdef1234567890",
        } as never,
      ],
      "uni-v2:usdc",
      "USDC",
      undefined,
      "0x1234567890abcdef1234567890abcdef12345678",
    )
    expect(rows[0]?.kind).toBe("borrow")
    expect(rows[0]?.tokenSymbol).toBe("USDC")
    expect(rows[0]?.walletLabel).toBe("0x1234…5678")
  })

  it("mapBorrowSessionRows splits sides: pool hides borrow/repay, asset keeps them", () => {
    const history = [
      {
        id: "d1",
        marketId: "bal-stable-sdai-usdc",
        kind: "deposit",
        executedAmountUsd6: 5_000_000n,
        timestamp: Date.now(),
        hash: "0xdep1234567890",
      },
      {
        id: "b1",
        marketId: "bal-stable-sdai-usdc",
        assetId: "bal-stable:gho",
        kind: "borrow",
        executedAmountUsd6: 10_000_000n,
        timestamp: Date.now(),
        hash: "0xbor1234567890",
      },
    ] as never[]
    const pool = mapBorrowSessionRows(history, "bal-stable-sdai-usdc", undefined, "pool")
    expect(pool.map((r) => r.kind)).toEqual(["supply"])
    const asset = mapBorrowSessionRows(history, "bal-stable:gho", "GHO", "asset")
    expect(asset.map((r) => r.kind)).toEqual(["borrow"])
  })

  it("enrichBorrowRowWithAsset adds symbol when missing", () => {
    const row = enrichBorrowRowWithAsset(
      { id: "1", at: "", kind: "supply", amountLabel: "+$1.2K", txHashShort: "0x" },
      "USDC",
    )
    expect(row.tokenSymbol).toBe("USDC")
  })

  it("enrichPoolRowWithPair adds paired token symbols", () => {
    const row = enrichPoolRowWithPair(
      { id: "1", at: "", kind: "supply", amountLabel: "$50K", txHashShort: "0x" },
      "WETH",
      "USDC",
      "12.4",
      "42.8K",
    )
    expect(row.tokenSymbol).toBe("WETH")
    expect(row.tokenSymbolSecondary).toBe("USDC")
    expect(row.token0AmountLabel).toBe("12.4")
    expect(row.token1AmountLabel).toBe("42.8K")
  })

  it("enrichDetailTransactionRow derives For amount from USD when convex row only has amountLabel", () => {
    const row = enrichDetailTransactionRow(
      { id: "1", at: "", kind: "supply", amountLabel: "$37.50K", tokenSymbol: "GHO", txHashShort: "0x" },
      { assetSymbol: "GHO" },
    )
    expect(row.tokenSymbol).toBe("GHO")
    expect(row.tokenAmountLabel).toBeTruthy()
    expect(row.tokenAmountLabel).not.toBe("37.50K")
  })

  it("scopedAssetKeysMatch treats gho and bal-stable:gho as the same asset", () => {
    expect(scopedAssetKeysMatch("gho", "bal-stable:gho")).toBe(true)
    expect(scopedAssetKeysMatch("bal-stable:gho", "bal-stable:gho")).toBe(true)
    expect(scopedAssetKeysMatch("uni-v2:gho", "bal-stable:gho")).toBe(false)
    expect(scopedAssetKeysMatch("bal-stable-sdai-usdc", "bal-stable:gho")).toBe(false)
  })
})
