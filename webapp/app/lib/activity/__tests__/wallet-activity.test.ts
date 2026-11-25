import { describe, expect, it } from "vitest"
import { mapWalletActivityRows, type WalletActivityRowLike } from "../wallet-activity"

const MARKETS = {
  "weth-usdc": { display: { name: "WETH / USDC", visuals: [{ symbol: "WETH" }, { symbol: "USDC" }] } },
}

const row = (over: Partial<WalletActivityRowLike>): WalletActivityRowLike => ({
  id: "31337:0xabc:1",
  at: "2026-11-16T12:00:00.000Z",
  kind: "borrow",
  amountUsd: 100,
  tokenAmountLabel: "100 USDC",
  tokenSymbol: "USDC",
  txHash: "0xabc",
  chainId: 31337,
  page: { scope: "pool", slug: "weth-usdc" },
  ...over,
})

describe("mapWalletActivityRows", () => {
  it("maps pool-page events to borrow rows with the session mapper's kinds, signs and labels", () => {
    const rows = mapWalletActivityRows(
      [
        row({}),
        row({ id: "2", kind: "repay", amountUsd: 40 }),
        row({ id: "3", kind: "supply", amountUsd: 900, tokenSymbol: "WETH/USDC" }),
        row({ id: "4", kind: "withdraw", amountUsd: 300 }),
      ],
      MARKETS,
    )
    const pool = rows[2]!.primaryLabel
    expect(rows.map((r) => [r.product, r.kind, r.amountUsd, r.primaryLabel, r.secondaryLabel, r.marketId])).toEqual([
      ["borrow", "borrow", -100, "USDC", `via ${pool}`, "usdc"],
      ["borrow", "repay", 40, "USDC", `via ${pool}`, "usdc"],
      ["borrow", "pledge", 900, pool, "", "weth-usdc"],
      ["borrow", "withdraw", -300, pool, "", "weth-usdc"],
    ])
    expect(rows[0]).toMatchObject({ status: "confirmed", txHash: "0xabc", at: "2026-11-16T12:00:00.000Z" })
  })

  it("maps Lend-page supplies and withdrawals to lend rows and leaves out asset-page copies and Lend-page borrows", () => {
    const rows = mapWalletActivityRows([
      row({
        kind: "supply",
        amountUsd: 1500,
        tokenAmountLabel: "1,500 USDC",
        page: { scope: "lend", slug: "usdc-core" },
      }),
      row({ id: "2", kind: "borrow", page: { scope: "lend", slug: "usdc-core" } }),
      row({ id: "3", kind: "borrow", page: { scope: "asset", slug: "usdc" } }),
      row({ id: "4", page: undefined }),
    ])
    expect(rows).toEqual([
      {
        id: "31337:0xabc:1",
        at: "2026-11-16T12:00:00.000Z",
        product: "lend",
        kind: "supply",
        status: "confirmed",
        amountUsd: 1500,
        primaryLabel: "USDC",
        secondaryLabel: "1,500 USDC",
        txHash: "0xabc",
        marketId: "usdc-core",
      },
    ])
  })

  it("maps older rows without a USD value to their token amount, on Lend and borrow rows alike", () => {
    const rows = mapWalletActivityRows(
      [
        row({
          kind: "supply",
          amountUsd: undefined,
          tokenAmountLabel: "1,500.0135 USDC",
          page: { scope: "lend", slug: "usdc-core" },
        }),
        row({ id: "2", kind: "borrow", amountUsd: undefined, tokenAmountLabel: "250 USDC" }),
        row({ id: "3", kind: "repay", amountUsd: undefined, tokenAmountLabel: undefined, tokenSymbol: undefined }),
      ],
      MARKETS,
    )
    expect(rows.map((r) => [r.kind, r.amountUsd, r.tokenAmountLabel])).toEqual([
      ["supply", undefined, "1,500 USDC"],
      ["borrow", undefined, "250 USDC"],
      ["repay", undefined, undefined],
    ])
    expect(rows.every((r) => !("amountUsd" in r))).toBe(true)
  })
})
