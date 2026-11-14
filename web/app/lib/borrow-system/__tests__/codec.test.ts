import { describe, expect, it } from "vitest"
import { simulateBorrow, parseFixed } from "@/app/lib/credit-engine"
import {
  deserializeBorrowSystemState,
  normalizeBorrowSystemState,
  serializeBorrowSystemState,
} from "@/app/lib/borrow-system/codec"
import {
  EXAMPLE_UNI_MARKET_ID,
  EXAMPLE_UNI_USDC_ASSET_ID,
  makeExampleBorrowSystemState,
} from "@/app/lib/credit-engine/__tests__/fixtures"

describe("borrow session codec", () => {
  it("normalizes legacy accounts missing rewardPositions", () => {
    const state = makeExampleBorrowSystemState()
    const legacy = {
      ...state,
      accounts: {
        ...state.accounts,
        "wallet-1": {
          ...state.accounts["wallet-1"]!,
          rewardPositions: undefined as unknown as [],
        },
      },
    }

    const normalized = normalizeBorrowSystemState(legacy)
    const preview = simulateBorrow(normalized, {
      type: "borrow",
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("100", 6),
    })

    expect(preview.validationErrors[0] ?? "").not.toContain("reading 'map'")
    expect(preview.allowed).toBe(true)
  })

  it("repairs rewardPositions when deserializing stored state", () => {
    const state = makeExampleBorrowSystemState()
    const legacy = {
      ...state,
      accounts: {
        ...state.accounts,
        "wallet-1": {
          ...state.accounts["wallet-1"]!,
          rewardPositions: undefined as unknown as [],
        },
      },
    }

    const serialized = serializeBorrowSystemState(legacy)
    const restored = deserializeBorrowSystemState(serialized)

    expect(restored.accounts["wallet-1"]?.rewardPositions).toEqual([])
  })
})
