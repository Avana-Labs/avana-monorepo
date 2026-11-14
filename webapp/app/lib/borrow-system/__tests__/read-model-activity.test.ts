import { describe, expect, it } from "vitest"
import { parseFixed } from "@/app/lib/borrow-system/model"
import { mapTransactionHistoryToActivityRows } from "@/app/lib/borrow-system/read-model"

describe("mapTransactionHistoryToActivityRows", () => {
  it("maps borrow history into portfolio activity rows without internal simulation labels", () => {
    const rows = mapTransactionHistoryToActivityRows([
      {
        id: "history-1",
        intentId: "intent-1",
        walletId: "demo-wallet",
        marketId: "uni-v3-bluechip-weth-usdc",
        assetId: "uni-v3-bluechip:usdc",
        kind: "borrow",
        status: "success",
        requestedAmountUsd6: parseFixed("250", 6),
        executedAmountUsd6: parseFixed("250", 6),
        simulated: true,
        timestamp: Date.UTC(2026, 5, 19),
        hash: "sim_abc123",
      },
    ])

    expect(rows).toHaveLength(1)
    expect(rows[0]?.kind).toBe("borrow")
    expect(rows[0]?.txHash).toBe("sim_abc123")
    expect(rows[0]?.secondaryLabel).toBe("")
    expect(rows[0]?.amountUsd).toBeLessThan(0)
  })

  it("keeps the collateral pool label + id for collateral actions (withdraw)", () => {
    const markets = {
      "uni-v3-bluechip-weth-usdc": { display: { visuals: [{ symbol: "WETH" }, { symbol: "USDC" }] } },
    }
    const [row] = mapTransactionHistoryToActivityRows(
      [
        {
          id: "withdraw-1",
          intentId: "intent-w1",
          walletId: "demo-wallet",
          marketId: "uni-v3-bluechip-weth-usdc",
          kind: "withdraw",
          status: "success",
          requestedAmountUsd6: 0n,
          executedAmountUsd6: parseFixed("100", 6),
          simulated: true,
          timestamp: Date.UTC(2026, 5, 19),
          hash: "sim_withdraw1",
        },
      ],
      markets,
    )

    expect(row?.primaryLabel).toBe("WETH / USDC")
    expect(row?.marketId).toBe("uni-v3-bluechip-weth-usdc")
    expect(row?.secondaryLabel).not.toContain("via")
  })

  it("maps collateral withdrawals using the executed USD amount", () => {
    const rows = mapTransactionHistoryToActivityRows([
      {
        id: "history-2",
        intentId: "intent-2",
        walletId: "demo-wallet",
        marketId: "uni-v3-bluechip-weth-usdc",
        kind: "withdraw",
        status: "success",
        requestedAmountUsd6: 0n,
        executedAmountUsd6: parseFixed("421.75", 6),
        simulated: true,
        timestamp: Date.UTC(2026, 5, 19),
        hash: "sim_withdraw",
      },
    ])

    expect(rows).toHaveLength(1)
    expect(rows[0]?.kind).toBe("withdraw")
    expect(rows[0]?.amountUsd).toBeCloseTo(-421.75, 6)
  })
})
