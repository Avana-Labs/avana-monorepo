/**
 * Regression guard for the session-persistence wipe bug.
 *
 * Each product session hook (lend / multiply / borrow) initializes its state
 * from the SSR-safe seed and restores the real state from localStorage in an
 * effect. The bug: the "write state to storage" effect fired on mount with the
 * still-seeded state, clobbering richer persisted data (user positions) before
 * the restore effect ran.
 *
 * The property under test: mounting a session hook over richer existing storage
 * must NEVER persist the seed back over it (no transient data downgrade).
 */
import { renderHook, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SESSION_CACHE_VERSION as V } from "@/app/lib/session-cache-version"

import { useLendSession } from "@/app/lib/lend-system/use-lend-session"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"
import { serializeLendSystemState } from "@/app/lib/lend-system/codec"
import { writeLendSessionState, readLendSessionState } from "@/app/lib/lend-system/storage"

import { useMultiplySession } from "@/app/lib/multiply-system/use-multiply-session"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { serializeMultiplySystemState } from "@/app/lib/multiply-system/codec"
import { writeMultiplySessionState, readMultiplySessionState } from "@/app/lib/multiply-system/storage"

import { useBorrowSession } from "@/app/lib/borrow-system/use-borrow-session"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { serializeBorrowSystemState } from "@/app/lib/borrow-system/codec"
import { writeBorrowSessionState, readBorrowSessionState } from "@/app/lib/borrow-system/storage"

afterEach(() => {
  vi.restoreAllMocks()
  window.localStorage.clear()
})

function spyOnStateWrites(keyFragment: string) {
  const writes: string[] = []
  const original = Storage.prototype.setItem
  vi.spyOn(Storage.prototype, "setItem").mockImplementation(function (this: Storage, key: string, value: string) {
    if (key.includes(keyFragment)) writes.push(value)
    return original.call(this, key, value)
  })
  return writes
}

describe("session persistence does not clobber richer storage on mount", () => {
  it("lend session keeps the persisted state instead of writing the seed", async () => {
    const walletId = "persist-lend"
    const seed = buildMockLendSystemState(walletId)
    const sessionSeed = serializeLendSystemState(seed)

    const rich = buildMockLendSystemState(walletId)
    rich.walletBalances[walletId] = { ...(rich.walletBalances[walletId] ?? {}), "persist-marker": 4242 }
    writeLendSessionState(walletId, rich)

    const writes = spyOnStateWrites(`avana.lend.session.${V}`)
    const { result } = renderHook(() => useLendSession({ walletId, sessionSeed }))

    await waitFor(() => {
      expect(result.current.state.walletBalances[walletId]?.["persist-marker"]).toBe(4242)
    })

    expect(writes).not.toContain(sessionSeed)
    expect(readLendSessionState(walletId, sessionSeed).walletBalances[walletId]?.["persist-marker"]).toBe(4242)
  })

  it("multiply session keeps the persisted state instead of writing the seed", async () => {
    const walletId = "persist-multiply"
    const seed = buildMockMultiplySystemState(walletId)
    const sessionSeed = serializeMultiplySystemState(seed)

    const rich = buildMockMultiplySystemState(walletId)
    rich.now = 1_234_567_890
    writeMultiplySessionState(walletId, rich)

    const writes = spyOnStateWrites(`avana.multiply.session.${V}`)
    const { result } = renderHook(() => useMultiplySession({ walletId, sessionSeed }))

    await waitFor(() => {
      expect(result.current.state.now).toBe(1_234_567_890)
    })

    expect(writes).not.toContain(sessionSeed)
    expect(readMultiplySessionState(walletId, sessionSeed).now).toBe(1_234_567_890)
  })

  it("borrow session keeps the persisted state instead of writing the seed", async () => {
    const walletId = "persist-borrow"
    const seed = buildMockBorrowSystemState(walletId)
    const sessionSeed = serializeBorrowSystemState(seed)

    const rich = buildMockBorrowSystemState(walletId)
    rich.now = 1_234_567_890
    writeBorrowSessionState(walletId, rich)

    const writes = spyOnStateWrites(`avana.borrow.session.${V}`)
    const { result } = renderHook(() => useBorrowSession({ walletId, sessionSeed }))

    await waitFor(() => {
      expect(result.current.state.now).toBe(1_234_567_890)
    })

    expect(writes).not.toContain(sessionSeed)
    expect(readBorrowSessionState(walletId, sessionSeed).now).toBe(1_234_567_890)
  })
})
