import { describe, expect, it } from "vitest"
import { lendPrincipal, readFullHistory, type HistoryRecordLike, type OlderHistoryLike } from "../lend-principal"
import { mergeChainLendPositions } from "../chain-lend-positions"
import { emptyLendSystemState, lendMarketFromSnapshot } from "../market-hydration"

const WALLET = "0x00000000000000000000000000000000000000aa"
const OTHER = "0x00000000000000000000000000000000000000bb"
const SPOKE = "0x0000000000000000000000000000000000000d01"
const HUB_ASSETS = [
  {
    chainId: 31337,
    slug: "usdc-core",
    underlying: "0xusdc",
    decimals: 6,
    lendReserves: [{ spoke: SPOKE, reserveId: "0" }],
  },
]

const supply = (key: string, amount: string, user = WALLET): HistoryRecordLike => ({
  key,
  kind: "AaveSpoke.Supply",
  address: SPOKE,
  args: { reserveId: "0", user, suppliedAmount: amount },
})
const withdraw = (key: string, amount: string): HistoryRecordLike => ({
  key,
  kind: "AaveSpoke.Withdraw",
  address: SPOKE,
  args: { reserveId: "0", user: WALLET, withdrawnAmount: amount },
})

describe("lendPrincipal", () => {
  it("is Σ supplied − Σ withdrawn of the wallet's own events", () => {
    const history = [
      supply("a", "1000000000"),
      supply("b", "500000000"),
      withdraw("c", "300000000"),
      supply("d", "9000000", OTHER),
    ]
    expect(lendPrincipal(WALLET, new Map([[31337, history]]), HUB_ASSETS)).toEqual({ "usdc-core": 1200 })
  })
})

describe("readFullHistory", () => {
  it("reads every page, and gives up on a refused page", async () => {
    const pages: Record<string, OlderHistoryLike> = {
      first: { status: "ok", records: [supply("b", "1")], next: "100" },
      "100": { status: "ok", records: [supply("a", "1")], next: null },
    }
    const ok = await readFullHistory(async ({ before }) => pages[before ?? "first"]!, 31337, WALLET)
    expect(ok?.map((r) => r.key)).toEqual(["b", "a"])
    const refused = await readFullHistory(async () => ({ status: "rateLimited" }), 31337, WALLET)
    expect(refused).toBeNull()
  })
})

describe("principal in the lend positions", () => {
  const market = lendMarketFromSnapshot(
    {
      slug: "usdc-core",
      scope: "lend",
      symbol: "USDC",
      assetPriceUsd: 1,
      suppliedUsd: 0,
      borrowedUsd: 0,
      availableUsd: 0,
      utilizationPct: 0,
      supplyApyPct: 4,
    },
    1,
    0,
  )
  const state = { ...emptyLendSystemState(WALLET, 0), markets: { "usdc-core": market } }

  it("earns the supply above the principal, and 0 without a full history", () => {
    const read = { supplied: { "usdc-core": 1210 }, walletBalances: {} }
    const withHistory = mergeChainLendPositions(state, WALLET, { ...read, principal: { "usdc-core": 1200 } })
    expect(withHistory.positions[`${WALLET}:usdc-core`]).toMatchObject({ principalAmount: 1200, interestEarned: 10 })
    const without = mergeChainLendPositions(state, WALLET, { ...read, principal: null })
    expect(without.positions[`${WALLET}:usdc-core`]).toMatchObject({ principalAmount: 1210, interestEarned: 0 })
  })
})
