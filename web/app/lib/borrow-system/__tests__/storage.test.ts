import { afterEach, describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import {
  clearBorrowSessionState,
  readBorrowSessionState,
  writeBorrowSessionState,
} from "@/app/lib/borrow-system/storage"
import { serializeBorrowSystemState } from "@/app/lib/borrow-system/codec"

describe("borrow session storage", () => {
  const walletId = "demo-wallet"

  afterEach(() => {
    clearBorrowSessionState(walletId)
  })

  it("hydrates from the seed when storage is empty and persists later writes", () => {
    const seedState = buildMockBorrowSystemState(walletId)
    const seed = serializeBorrowSystemState(seedState)

    expect(readBorrowSessionState(walletId, seed)).toEqual(seedState)

    const nextState = buildMockBorrowSystemState(walletId)
    nextState.transactions.push({
      id: "tx-1",
      walletId,
      kind: "borrow",
      amountUsd6: 100n,
      at: nextState.now,
    })

    writeBorrowSessionState(walletId, nextState)
    expect(readBorrowSessionState(walletId, seed)).toEqual(nextState)
  })
})
