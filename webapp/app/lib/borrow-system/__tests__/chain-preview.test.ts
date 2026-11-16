import { describe, expect, it } from "vitest"
import { NOT_PREVIEWED, previewBorrowOnChain, PREVIEWS_UNAVAILABLE, type BorrowPreviewDeps } from "../chain-preview"
import type { ChainBorrowRefs } from "../chain-refs"
import type { TransactionIntent } from "../contracts"
import type { BorrowSystemState } from "../model"

const WALLET = "0x00000000000000000000000000000000000000aa"
const LENS = "0x0000000000000000000000000000000000000001"
const WAD = 10n ** 18n
const MAX_UINT = (1n << 256n) - 1n
/** USD 6 decimals to Aave value units (USD × 1e26). */
const value = (usd6: bigint) => usd6 * 10n ** 20n

const refs: ChainBorrowRefs = {
  wallet: WALLET,
  lenses: [{ chainId: 31337, lens: LENS }],
  accounts: [{ chainId: 31337, marketId: "3", spoke: "0xspoke", proxy: "0xproxy", poolSlug: "weth-usdc" }],
  debtReserves: [
    {
      chainId: 31337,
      spoke: "0xspoke",
      reserveId: "1",
      asset: "0xusdc",
      assetSlug: "usdc",
      decimals: 6,
      priceUsd8: "100000000",
    },
  ],
}

function state(debtUsd6 = 0n): BorrowSystemState {
  return {
    markets: { "weth-usdc": { riskConfig: { collateralFactorWad: (75n * WAD) / 100n } } },
    accounts: {
      [WALLET]: {
        collateralPositions: [],
        debtPositions: debtUsd6
          ? [
              {
                id: "debt:31337:3:1",
                debtSharesUsd6: debtUsd6,
                debtIndexRay: 10n ** 27n,
                priceAtBorrowUsd6: 1_000_000n,
              },
            ]
          : [],
      },
    },
  } as unknown as BorrowSystemState
}

type Call = { functionName: string; args?: readonly unknown[] }

function deps(answers: Record<string, unknown>, debtUsd6 = 0n, calls: Call[] = []): BorrowPreviewDeps {
  return {
    refs: (wallet) => (wallet === WALLET ? refs : null),
    state: () => state(debtUsd6),
    chain: () => ({
      latestBlockTimestamp: async () => 1_000n,
      readContract: async ({ functionName, args }) => {
        calls.push({ functionName, args })
        const answer = answers[functionName]
        if (answer instanceof Error) throw answer
        return answer
      },
    }),
  }
}

const intent = (over: Partial<TransactionIntent>): TransactionIntent => ({
  id: "i",
  actionType: "borrow",
  walletId: WALLET,
  marketId: "weth-usdc",
  assetId: "usdc",
  amountUsd6: 100_000_000n,
  requestedAt: 0,
  simulated: false,
  ...over,
})

describe("previewBorrowOnChain", () => {
  it("previews a borrow from the Lens, with the protocol maximum as available borrowing power", async () => {
    const calls: Call[] = []
    const preview = await previewBorrowOnChain(
      deps(
        {
          previewBorrowAfter: {
            amount: 100_000_000n,
            healthFactorBefore: MAX_UINT,
            healthFactorAfter: 8n * WAD,
            collateralValueAfter: value(1_000_000_000n),
            debtValueAfterRay: value(100_000_000n) * 10n ** 27n,
          },
          previewBorrowMax: 700_000_000n,
        },
        0n,
        calls,
      ),
      intent({}),
    )
    expect(calls.find((c) => c.functionName === "previewBorrowAfter")?.args).toEqual([WALLET, 3n, 1n, 100_000_000n])
    expect(calls.find((c) => c.functionName === "previewBorrowMax")?.args).toEqual([WALLET, 3n, 1n, 1_600n])
    expect(preview.allowed).toBe(true)
    expect(preview.riskLabel).toBe("safe")
    expect(preview.before).toEqual({
      collateralValueUsd6: 1_000_000_000n,
      borrowCapacityUsd6: 750_000_000n,
      availableBorrowCapacityUsd6: 700_000_000n,
      totalBorrowedUsd6: 0n,
      currentLtvWad: 0n,
      healthFactorWad: null,
    })
    expect(preview.after).toEqual({
      collateralValueUsd6: 1_000_000_000n,
      borrowCapacityUsd6: 750_000_000n,
      availableBorrowCapacityUsd6: 600_000_000n,
      totalBorrowedUsd6: 100_000_000n,
      currentLtvWad: WAD / 10n,
      healthFactorWad: 8n * WAD,
    })
  })

  it("refuses a borrow above the protocol maximum", async () => {
    const preview = await previewBorrowOnChain(
      deps({
        previewBorrowAfter: {
          amount: 100_000_000n,
          healthFactorBefore: MAX_UINT,
          healthFactorAfter: WAD,
          collateralValueAfter: value(110_000_000n),
          debtValueAfterRay: value(100_000_000n) * 10n ** 27n,
        },
        previewBorrowMax: 50_000_000n,
      }),
      intent({}),
    )
    expect(preview.allowed).toBe(false)
    expect(preview.validationErrors).toEqual(["Exceeds available borrowing power."])
    expect(preview.riskLabel).toBe("danger")
  })

  it("previews a repay of the whole debt", async () => {
    const calls: Call[] = []
    const preview = await previewBorrowOnChain(
      deps(
        {
          previewRepayAfter: {
            amount: 100_000_000n,
            healthFactorBefore: 8n * WAD,
            healthFactorAfter: MAX_UINT,
            collateralValueAfter: value(1_000_000_000n),
            debtValueAfterRay: 0n,
          },
        },
        100_000_000n,
        calls,
      ),
      intent({ actionType: "repay", debtPositionId: "debt:31337:3:1", amountUsd6: 150_000_000n }),
    )
    // Above the debt: the debt itself is previewed, as the executor repays all of it.
    expect(calls[0]?.args).toEqual([WALLET, 3n, 1n, 100_000_000n])
    expect(preview.allowed).toBe(true)
    expect(preview.before.totalBorrowedUsd6).toBe(100_000_000n)
    expect(preview.after.totalBorrowedUsd6).toBe(0n)
    expect(preview.after.healthFactorWad).toBeNull()
  })

  it("answers not allowed, with the reason, for a Lens revert, an unknown market and other actions", async () => {
    const reverted = await previewBorrowOnChain(
      deps({
        previewBorrowAfter: Object.assign(new Error("x"), { shortMessage: "MarketPaused()" }),
        previewBorrowMax: 0n,
      }),
      intent({}),
    )
    expect(reverted).toMatchObject({ allowed: false, validationErrors: ["MarketPaused()"] })
    const unknown = await previewBorrowOnChain(deps({}), intent({ marketId: "other" }))
    expect(unknown.validationErrors).toEqual(["Pledge collateral in this market before borrowing."])
    const claim = await previewBorrowOnChain(deps({}), intent({ actionType: "claim" }))
    expect(claim.validationErrors).toEqual([PREVIEWS_UNAVAILABLE])
  })
})

const KEY = `0x${"0".repeat(62)}07` as const
const KEY_2 = `0x${"0".repeat(62)}08` as const
const withMarkets = (d: BorrowPreviewDeps): BorrowPreviewDeps => ({
  ...d,
  refs: () => ({ ...refs, markets: [{ chainId: 31337, marketId: "3", spoke: "0xspoke", poolSlug: "weth-usdc" }] }),
  lps: () => [
    {
      chainId: 31337,
      marketId: "3",
      integrationId: 1,
      positionKey: KEY,
      npm: "0xnpm",
      tokenId: 7n,
      lpVault: "0xvault",
      valueUsd6: 400_000_000n,
    },
  ],
})

describe("pledge and withdrawal previews", () => {
  const lens = {
    amount: 1n,
    healthFactorBefore: 2n * WAD,
    healthFactorAfter: 3n * WAD,
    collateralValueAfter: value(1_200_000_000n),
    debtValueAfterRay: value(300_000_000n) * 10n ** 27n,
  }

  it("previews the pledge of the intent's LP NFT, the collateral before less that NFT's value", async () => {
    const calls: Call[] = []
    const preview = await previewBorrowOnChain(
      withMarkets(deps({ previewPledgeAfter: lens }, 0n, calls)),
      intent({ actionType: "deposit", positionKey: KEY, amountUsd6: 400_000_000n }),
    )
    expect(calls[0]).toEqual({ functionName: "previewPledgeAfter", args: [WALLET, 3n, KEY] })
    expect(preview.allowed).toBe(true)
    expect(preview.before.collateralValueUsd6).toBe(800_000_000n)
    expect(preview.after.collateralValueUsd6).toBe(1_200_000_000n)
    expect(preview.before.totalBorrowedUsd6).toBe(300_000_000n)
    expect([preview.before.healthFactorWad, preview.after.healthFactorWad]).toEqual([2n * WAD, 3n * WAD])
  })

  it("allows a pledge of several NFTs without a health factor preview", async () => {
    const calls: Call[] = []
    const preview = await previewBorrowOnChain(
      withMarkets(deps({}, 0n, calls)),
      intent({ actionType: "deposit", amountUsd6: 900_000_000n }),
    )
    expect(calls).toEqual([])
    expect(preview).toMatchObject({ allowed: true, warnings: [NOT_PREVIEWED] })
  })

  it("previews withdrawing the one record the executor would withdraw, and refuses one below a health factor of 1", async () => {
    const calls: Call[] = []
    const records = [{ integrationId: 1, positionKey: KEY, creditedAfterReconcile: 5n }]
    const removeAll = intent({
      actionType: "withdraw",
      positionId: "collateral:31337:3",
      amountUsd6: 0n,
      payload: { type: "removeCollateral", walletId: WALLET, positionId: "collateral:31337:3", percentBps: 10_000 },
    })
    const ok = await previewBorrowOnChain(
      deps({ getRecords: records, previewWithdrawAfter: lens }, 0n, calls),
      removeAll,
    )
    expect(calls.map((c) => c.functionName)).toEqual(["getRecords", "previewWithdrawAfter"])
    expect(calls[1]?.args).toEqual([WALLET, 3n, KEY])
    expect(ok.allowed).toBe(true)

    const unsafe = await previewBorrowOnChain(
      deps({ getRecords: records, previewWithdrawAfter: { ...lens, healthFactorAfter: WAD / 2n } }),
      removeAll,
    )
    expect(unsafe.allowed).toBe(false)

    const several = await previewBorrowOnChain(
      deps({ getRecords: [...records, { integrationId: 1, positionKey: KEY_2, creditedAfterReconcile: 5n }] }),
      removeAll,
    )
    expect(several).toMatchObject({ allowed: true, warnings: [NOT_PREVIEWED] })
  })
})
